import Foundation

// SYNC-02: change tracking for the portable record model.
//
// The existing tables (`drafts`, `user_comments`, `writing_reviews`, …) and the Markdown files stay
// the source of truth and are never rewritten. The ledger (`sync_records`) remembers, per record id,
// the last version this device knows: its HLC, per-field digests and HLCs, a tombstone flag and the
// version the server last acknowledged. `trackSyncChanges()` compares the current local state with
// the ledger and issues a new HLC for every record that changed, and a tombstone for every record
// whose entity is gone. Running it is the migration for existing data too: the first run gives every
// existing entity a record; later runs only touch what changed. Every run is idempotent.
//
// Pending changes (the outbox) are the records whose `hlc` differs from `server_hlc`.

/// The random per-install device id (lowercase UUID). It is the device part of every HLC
/// and the `deviceId` the sync server knows the install by.
enum SyncDevice {
    static let defaultsKey = "sync.deviceID"

    static func current(_ defaults: UserDefaults = .standard) -> String {
        if let stored = defaults.string(forKey: defaultsKey), SyncID.isCanonical(stored) { return stored }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: defaultsKey)
        return id
    }
}

struct SyncTrackResult: Equatable {
    /// New records and new versions of changed records.
    var updated = 0
    /// Records whose entity disappeared.
    var tombstoned = 0
}

/// One record as currently found in the local data.
struct SyncSource {
    enum State {
        /// Present. `fingerprint` (size and modification time of a backing file) lets an unchanged
        /// file skip reading; `load` returns the record's fields.
        case present(fingerprint: String?, load: () throws -> [String: JSONValue])
        /// Exists but can't be read right now (file missing, evicted by iCloud, not UTF-8):
        /// keep the last known version, never tombstone it.
        case unavailable
    }
    let id: String
    let type: SyncRecordType
    /// The local key (draft id, comment id, path…). Stored locally only, for debugging and the mirror.
    let entity: String
    let state: State
}

/// A ledger row.
struct SyncLedgerEntry: Equatable {
    struct Field: Codable, Equatable {
        /// SHA-256 of the field's canonical JSON.
        let d: String
        /// HLC of the field's last change.
        let t: String
    }
    let id: String
    let type: SyncRecordType
    let entity: String
    let hlc: HLC
    let serverHLC: HLC?
    let deleted: Bool
    let digest: String?
    let fields: [String: Field]
    let fingerprint: String?
    var pending: Bool { serverHLC != hlc }
}

extension Workspace {
    static let syncLedgerVersion = 1

    func ensureSyncLedger() throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS sync_records (
                id TEXT PRIMARY KEY, type INTEGER NOT NULL, entity TEXT NOT NULL,
                hlc TEXT NOT NULL, server_hlc TEXT, deleted INTEGER NOT NULL DEFAULT 0,
                schema_version INTEGER NOT NULL, digest TEXT, fields TEXT NOT NULL DEFAULT '{}', fingerprint TEXT)
            """)
        try db.execute("CREATE TABLE IF NOT EXISTS sync_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        try db.execute("INSERT OR IGNORE INTO sync_meta VALUES ('ledger_version', ?)", [String(Self.syncLedgerVersion)])
    }

    // MARK: Tracking

    /// Bring the ledger up to date with the local data. Safe to run at any time and any number
    /// of times; it never modifies the Markdown files or the app's own tables.
    @discardableResult
    func trackSyncChanges(now: Date = Date()) throws -> SyncTrackResult {
        try ensureSyncLedger()
        let sources = try syncSources()
        try db.execute("BEGIN IMMEDIATE")
        do {
            let entries = Dictionary(try syncLedgerEntries().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var clock = try syncClock()
            var result = SyncTrackResult()
            var seen = Set<String>()
            for source in sources.sorted(by: { ($0.type, $0.id) < ($1.type, $1.id) }) {
                guard seen.insert(source.id).inserted else { continue }
                guard case .present(let fingerprint, let load) = source.state else { continue }
                let previous = entries[source.id]
                if let previous, !previous.deleted, let fingerprint, previous.fingerprint == fingerprint { continue }
                let fields: [String: JSONValue]
                do { fields = try load() }
                catch {
                    // Disappeared or became unreadable since it was listed: leave it for the next run.
                    continue
                }
                let digests = try fields.mapValues { try $0.digest() }
                let digest = try JSONValue.object(fields).digest()
                if let previous, !previous.deleted, previous.digest == digest, previous.type == source.type {
                    if previous.fingerprint != fingerprint {
                        try db.execute("UPDATE sync_records SET fingerprint=? WHERE id=?", [fingerprint, source.id])
                    }
                    continue
                }
                let hlc = clock.next(now: now)
                var clocks: [String: SyncLedgerEntry.Field] = [:]
                for (key, value) in digests {
                    if let previous, !previous.deleted, let field = previous.fields[key], field.d == value {
                        clocks[key] = field
                    } else {
                        clocks[key] = .init(d: value, t: hlc.description)
                    }
                }
                try db.execute("""
                    INSERT INTO sync_records (id, type, entity, hlc, server_hlc, deleted, schema_version, digest, fields, fingerprint)
                    VALUES (?, ?, ?, ?, NULL, 0, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET type=excluded.type, entity=excluded.entity, hlc=excluded.hlc, deleted=0,
                        schema_version=excluded.schema_version, digest=excluded.digest, fields=excluded.fields, fingerprint=excluded.fingerprint
                    """, [source.id, String(source.type.rawValue), source.entity, hlc.description, String(SyncRecord.schemaVersion),
                          digest, try encodeLedgerFields(clocks), fingerprint])
                result.updated += 1
            }
            for entry in entries.values.sorted(by: { ($0.type, $0.id) < ($1.type, $1.id) }) where !entry.deleted && !seen.contains(entry.id) {
                let hlc = clock.next(now: now)
                try db.execute("UPDATE sync_records SET hlc=?, deleted=1, digest=NULL, fields='{}', fingerprint=NULL WHERE id=?",
                               [hlc.description, entry.id])
                result.tombstoned += 1
            }
            try saveSyncClock(clock)
            try db.execute("COMMIT")
            return result
        } catch {
            _ = try? db.execute("ROLLBACK")
            throw error
        }
    }

    /// Track changes without letting a failure interrupt the caller (opening or quitting).
    /// Logs only counts and the error type, never content or paths.
    func trackSyncChangesLogged() {
        do {
            let result = try trackSyncChanges()
            if result != SyncTrackResult() {
                NSLog("Matilde sync: %ld record versions, %ld tombstones", result.updated, result.tombstoned)
            }
        } catch {
            NSLog("Matilde sync: change tracking failed (%@)", String(describing: type(of: error)))
        }
    }

    // MARK: Outbox

    /// Records with local changes the server hasn't acknowledged yet, oldest first. Tracks changes first.
    func pendingSyncRecords(limit: Int = 200) throws -> [SyncRecord] {
        try trackSyncChanges()
        let pending = try syncLedgerEntries().filter(\.pending).sorted { $0.hlc < $1.hlc }.prefix(limit)
        guard !pending.isEmpty else { return [] }
        let sources = Dictionary(try syncSources().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return try pending.compactMap { entry in
            if entry.deleted { return record(entry, fields: [:]) }
            guard let source = sources[entry.id], case .present(_, let load) = source.state,
                  let fields = try? load(), try JSONValue.object(fields).digest() == entry.digest else {
                // Changed again or unreadable since tracking; the next round picks it up.
                return nil
            }
            return record(entry, fields: fields)
        }
    }

    /// The current version of one record, or nil if the ledger doesn't know it.
    func syncRecord(id: String) throws -> SyncRecord? {
        try ensureSyncLedger()
        guard let entry = try syncLedgerEntries(id: id).first else { return nil }
        if entry.deleted { return record(entry, fields: [:]) }
        guard let source = try syncSources().first(where: { $0.id == id }), case .present(_, let load) = source.state else { return nil }
        let fields = try load()
        guard try JSONValue.object(fields).digest() == entry.digest else { return nil }
        return record(entry, fields: fields)
    }

    /// The server accepted these versions. A record changed again since keeps its newer version pending.
    func markSyncAccepted(_ versions: [(id: String, hlc: HLC)]) throws {
        try ensureSyncLedger()
        try db.execute("BEGIN IMMEDIATE")
        do {
            for version in versions {
                try db.execute("UPDATE sync_records SET server_hlc=? WHERE id=? AND hlc=?", [version.hlc.description, version.id, version.hlc.description])
            }
            try db.execute("COMMIT")
        } catch {
            _ = try? db.execute("ROLLBACK")
            throw error
        }
    }

    /// Fold a clock seen on the server into this device's clock, so later local writes order after it.
    func observeSyncClock(_ remote: HLC) throws {
        try ensureSyncLedger()
        var clock = try syncClock()
        clock.observe(remote)
        try saveSyncClock(clock)
    }

    func syncLedgerEntries(id: String? = nil) throws -> [SyncLedgerEntry] {
        let rows = try id.map { try db.execute("SELECT * FROM sync_records WHERE id=?", [$0]) } ?? db.execute("SELECT * FROM sync_records")
        return rows.compactMap { row in
            guard let id = row["id"], let type = row["type"].flatMap(Int.init).flatMap(SyncRecordType.init(rawValue:)),
                  let hlc = row["hlc"].flatMap(HLC.init) else { return nil }
            let fields = row["fields"].flatMap { try? JSONDecoder().decode([String: SyncLedgerEntry.Field].self, from: Data($0.utf8)) } ?? [:]
            return SyncLedgerEntry(id: id, type: type, entity: row["entity"] ?? "", hlc: hlc, serverHLC: row["server_hlc"].flatMap(HLC.init),
                                   deleted: row["deleted"] == "1", digest: row["digest"], fields: fields, fingerprint: row["fingerprint"])
        }
    }

    private func record(_ entry: SyncLedgerEntry, fields: [String: JSONValue]) -> SyncRecord {
        var clocks: [String: HLC] = [:]
        for key in fields.keys { clocks[key] = entry.fields[key].flatMap { HLC($0.t) } ?? entry.hlc }
        return SyncRecord(id: entry.id, type: entry.type, hlc: entry.hlc, baseHlc: entry.serverHLC, deleted: entry.deleted,
                          fields: entry.deleted ? [:] : fields, fieldHLCs: entry.deleted ? [:] : clocks)
    }

    private func encodeLedgerFields(_ fields: [String: SyncLedgerEntry.Field]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(fields), as: UTF8.self)
    }

    private func syncClock() throws -> HybridClock {
        var clock = HybridClock(device: syncDeviceID)
        if let stored = try db.execute("SELECT value FROM sync_meta WHERE key='clock'").first?["value"].flatMap(HLC.init) {
            clock.observe(stored)
        }
        // Never issue a clock at or below a version already in the ledger.
        if let newest = try db.execute("SELECT max(hlc) AS hlc FROM sync_records").first?["hlc"].flatMap(HLC.init) {
            clock.observe(newest)
        }
        return clock
    }

    private func saveSyncClock(_ clock: HybridClock) throws {
        guard let last = clock.last else { return }
        try db.execute("INSERT INTO sync_meta VALUES ('clock', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [last.description])
    }

    // MARK: Sources

    private func tableExists(_ name: String) throws -> Bool {
        try !db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name=?", [name]).isEmpty
    }

    private static func milliseconds(_ seconds: String?) -> Double? {
        seconds.flatMap(Double.init).map { ($0 * 1000).rounded() }
    }

    private static func milliseconds(iso: String?) -> Double? {
        guard let iso, let date = ISO8601DateFormatter().date(from: iso) else { return nil }
        return (date.timeIntervalSince1970 * 1000).rounded()
    }

    /// Size and modification time of a regular file, or nil if it isn't one.
    private func fileFingerprint(_ url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
              values.isRegularFile == true, let size = values.fileSize else { return nil }
        return "\(size):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }

    private func textSource(id: String, type: SyncRecordType, entity: String, url: URL?,
                            fields: @escaping (String, URL) throws -> [String: JSONValue]) -> SyncSource {
        guard let url, let fingerprint = fileFingerprint(url) else { return SyncSource(id: id, type: type, entity: entity, state: .unavailable) }
        return SyncSource(id: id, type: type, entity: entity, state: .present(fingerprint: fingerprint, load: {
            try fields(try String(contentsOf: url, encoding: .utf8), url)
        }))
    }

    /// Every record the local data currently holds.
    func syncSources() throws -> [SyncSource] {
        var sources: [SyncSource] = []
        func add<T: Encodable>(_ type: SyncRecordType, _ id: String, _ entity: String, _ payload: T) throws {
            let fields = try JSONValue.fields(of: payload)
            sources.append(SyncSource(id: id, type: type, entity: entity, state: .present(fingerprint: nil, load: { fields })))
        }

        // Drafts and their bodies.
        let dates = Dictionary(try db.execute("SELECT * FROM draft_dates").compactMap { row in row["id"].map { ($0, row) } },
                               uniquingKeysWith: { first, _ in first })
        for row in try db.execute("SELECT * FROM drafts") {
            guard let raw = row["id"], let id = SyncID.canonical(raw), let path = row["path"],
                  let family = row["family"].flatMap(SyncID.canonical) else { continue }
            try add(.draft, id, raw, DraftPayload(path: path, family: family, parent: row["parent"].flatMap(SyncID.canonical),
                                                  goal: row["goal"] ?? "", created: Self.milliseconds(dates[raw]?["created"])))
            sources.append(textSource(id: SyncID.derived("body", id), type: .body, entity: raw, url: try? url(for: path)) { text, url in
                let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                return try JSONValue.fields(of: BodyPayload(draft: id, text: text, edited: modified.map { ($0.timeIntervalSince1970 * 1000).rounded() }))
            })
        }

        // Branch snapshots (immutable files in .matilde/snapshots).
        for row in try db.execute("SELECT * FROM snapshots") {
            guard let raw = row["id"], let id = SyncID.canonical(raw),
                  let source = row["source"].flatMap(SyncID.canonical), let child = row["child"].flatMap(SyncID.canonical) else { continue }
            let file: URL? = row["path"].flatMap { path in
                path.hasPrefix(".matilde/snapshots/") && !path.split(separator: "/").contains("..") && !path.hasSuffix("/")
                    ? root.appendingPathComponent(path) : nil
            }
            let created = Self.milliseconds(iso: row["created"])
            sources.append(textSource(id: id, type: .snapshot, entity: raw, url: file) { text, _ in
                try JSONValue.fields(of: SnapshotPayload(source: source, child: child, text: text, created: created))
            })
        }

        // Stashes (one file per family in .matilde/stashes).
        if let directory = try? stashDirectory(), let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for name in names where name.hasSuffix(".md") && !name.hasPrefix(".") {
                guard let family = SyncID.canonical(String(name.dropLast(3))) else { continue }
                let file = directory.appendingPathComponent(name)
                guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
                sources.append(textSource(id: SyncID.derived("stash", family), type: .stash, entity: family, url: file) { text, _ in
                    try JSONValue.fields(of: StashPayload(family: family, text: text))
                })
            }
            // A stash file iCloud evicted is still there.
            for name in names where name.hasPrefix(".") && name.hasSuffix(".md.icloud") {
                guard let family = SyncID.canonical(String(name.dropFirst().dropLast(".md.icloud".count))) else { continue }
                sources.append(SyncSource(id: SyncID.derived("stash", family), type: .stash, entity: family, state: .unavailable))
            }
        }

        // Private comments.
        if try tableExists("user_comments") {
            for row in try db.execute("SELECT * FROM user_comments") {
                guard let raw = row["id"], let id = SyncID.canonical(raw), let draft = row["draft_id"].flatMap(SyncID.canonical),
                      let location = row["location"].flatMap(Int.init), let length = row["length"].flatMap(Int.init) else { continue }
                try add(.comment, id, raw, CommentPayload(
                    draft: draft, body: row["body"] ?? "", location: location, length: length,
                    quote: row["quote"] ?? "", prefix: row["prefix"] ?? "", suffix: row["suffix"] ?? "",
                    created: Self.milliseconds(row["created"]) ?? 0, modified: Self.milliseconds(row["modified"]) ?? 0,
                    archived: (row["archived"] ?? "0") != "0"))
            }
        }

        // Ask Matilde reviews, normalised into threads, messages and read markers.
        if try tableExists("writing_reviews") {
            for row in try db.execute("SELECT payload FROM writing_reviews") {
                guard let payload = row["payload"], var review = try? JSONDecoder().decode(WritingReview.self, from: Data(payload.utf8)),
                      let draft = SyncID.canonical(review.draftID) else { continue }
                let reviewID = review.id.uuidString.lowercased()
                for index in review.comments.indices { review.comments[index].attachLegacyRewrite() }
                for comment in review.comments {
                    let thread = comment.id.uuidString.lowercased()
                    try add(.thread, thread, comment.id.uuidString, ThreadPayload(
                        review: reviewID, draft: draft, reviewCreated: (review.created.timeIntervalSince1970 * 1000).rounded(),
                        model: review.model, revision: review.revision, stale: review.stale,
                        quote: comment.suggestion.quote, prefix: comment.suggestion.prefix, suffix: comment.suggestion.suffix,
                        explanation: comment.suggestion.explanation, replacement: comment.suggestion.replacement,
                        location: comment.location, length: comment.length, status: comment.status,
                        userInitiated: comment.userInitiated, rewriteQuote: comment.rewriteQuote,
                        rewriteMessage: comment.rewriteMessageID?.uuidString.lowercased(), initialReplacement: comment.initialReplacement))
                    try add(.readMarker, SyncID.derived("read", thread), comment.id.uuidString,
                            ReadMarkerPayload(thread: thread, unread: comment.isUnread))
                    for (index, message) in (comment.messages ?? []).enumerated() {
                        try add(.message, message.id.uuidString.lowercased(), message.id.uuidString, MessagePayload(
                            thread: thread, index: index, role: message.role, text: message.text,
                            delivery: message.delivery, replacement: message.replacement))
                    }
                }
            }
        }

        // The Trash archive (newest row per draft wins).
        if try tableExists("trashed_drafts") {
            for row in try db.execute("SELECT * FROM trashed_drafts ORDER BY rowid") {
                guard let raw = row["id"], let draft = SyncID.canonical(raw), let path = row["path"],
                      let family = row["family"].flatMap(SyncID.canonical) else { continue }
                let id = SyncID.derived("trashed", draft)
                sources.removeAll { $0.id == id }
                try add(.trashed, id, raw, TrashedPayload(draft: draft, path: path, family: family,
                                                         parent: row["parent"].flatMap(SyncID.canonical), goal: row["goal"] ?? "",
                                                         trashedAt: Self.milliseconds(iso: row["trashed_at"])))
            }
        }

        // Folders and images.
        let files = try syncFiles()
        for folder in files.folders {
            try add(.folder, SyncID.derived("folder", folder), folder, FolderPayload(path: folder))
        }
        for asset in files.assets {
            let id = SyncID.derived("asset", asset.path)
            if let size = asset.size, let fingerprint = asset.fingerprint {
                let fields = try JSONValue.fields(of: AssetPayload(path: asset.path, size: size))
                sources.append(SyncSource(id: id, type: .asset, entity: asset.path, state: .present(fingerprint: fingerprint, load: { fields })))
            } else {
                sources.append(SyncSource(id: id, type: .asset, entity: asset.path, state: .unavailable))
            }
        }
        return sources
    }

    /// Folders (relative paths, root excluded) and the files in every `.assets` folder. Skips
    /// `.matilde`, other hidden folders and symbolic links, like `scan()`.
    private func syncFiles() throws -> (folders: [String], assets: [(path: String, size: Int?, fingerprint: String?)]) {
        let fm = FileManager.default
        var folders: [String] = []
        var assets: [(path: String, size: Int?, fingerprint: String?)] = []
        var pending: [(url: URL, relative: String)] = [(root, "")]
        while let next = pending.popLast() {
            let (directory, relative) = next
            guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names {
                let url = directory.appendingPathComponent(name)
                let path = relative.isEmpty ? name : relative + "/" + name
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isSymbolicLink != true, values.isDirectory == true else { continue }
                if name == ".assets" {
                    for file in (try? fm.contentsOfDirectory(atPath: url.path)) ?? [] {
                        let item = url.appendingPathComponent(file)
                        if file.hasPrefix(".") {
                            // `.name.png.icloud`: an evicted image keeps its record.
                            if file.hasSuffix(".icloud"), file.count > ".icloud".count + 1 {
                                assets.append((path + "/" + String(file.dropFirst().dropLast(".icloud".count)), nil, nil))
                            }
                            continue
                        }
                        guard let fingerprint = fileFingerprint(item),
                              let size = try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize else { continue }
                        assets.append((path + "/" + file, size, fingerprint))
                    }
                } else if !name.hasPrefix(".") {
                    folders.append(path)
                    pending.append((url, path))
                }
            }
        }
        return (folders, assets)
    }
}
