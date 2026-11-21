import Foundation

// SYNC-07: the workspace side of sync. Applies pulled records to the Markdown files and the app's
// own tables (the mirror), and keeps the change ledger (SYNC-02) in step so an applied record is
// never sent back as a local change.
//
// Runs on the sync engine's executor with its own `Workspace` (its own SQLite connection), never on
// the main thread. Writes go in small transactions so the app's own writes wait at most briefly.
//
// Safety rules:
// - A body or stash file is only overwritten if it is unchanged since the ledger last saw it;
//   otherwise the local edit is left alone and the next push turns it into a conflict branch.
// - Deleted drafts and images go to the macOS Trash, never straight to deletion.
// - A record whose parent isn't here yet (a body before its draft, a message before its thread)
//   waits in `sync_inbox` and is applied once the parent arrives.

final class WorkspaceSyncStore: SyncLocalStore {
    let workspace: Workspace
    /// Applied in this order (parents before children); tombstones go in the reverse order.
    static let applyOrder: [SyncRecordType] = [.folder, .draft, .body, .snapshot, .stash, .asset, .comment, .thread, .message, .readMarker, .trashed, .settings]
    static let transactionSize = 50
    private let fm = FileManager.default
    private var db: Database { workspace.db }
    /// Name used for conflict branches made from this Mac's text ("Letter — from MacBook Air").
    var deviceName = "this Mac"
    /// Moves a file to the Trash; replaceable in tests.
    var trashItem: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    init(workspace: Workspace) throws {
        self.workspace = workspace
        try workspace.ensureSyncLedger()
        try db.execute("CREATE TABLE IF NOT EXISTS sync_blobs (id TEXT PRIMARY KEY, hlc TEXT NOT NULL, reference TEXT NOT NULL)")
        try db.execute("CREATE TABLE IF NOT EXISTS sync_inbox (id TEXT PRIMARY KEY, type INTEGER NOT NULL, hlc TEXT NOT NULL, server_hlc TEXT NOT NULL, record TEXT NOT NULL, blob BLOB)")
    }

    // MARK: Ledger

    func track() throws { try workspace.trackSyncChanges() }

    func pendingRecords(limit: Int) throws -> [SyncRecord] { try workspace.pendingSyncRecords(limit: limit) }

    func localStates(ids: [String]) throws -> [String: SyncLocalState] {
        var entries: [String: SyncLedgerEntry] = [:]
        for id in ids { if let entry = try workspace.syncLedgerEntries(id: id).first { entries[id] = entry } }
        // Only pending records need their current fields (for merging); read the sources once.
        let needFields = entries.values.contains { $0.pending && !$0.deleted }
        let sources = needFields ? Dictionary(try workspace.syncSources().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) : [:]
        var states: [String: SyncLocalState] = [:]
        for (id, entry) in entries {
            var record: SyncRecord?
            if entry.deleted {
                record = workspace.record(entry, fields: [:])
            } else if entry.pending, let source = sources[id], case .present(_, let load) = source.state,
                      let fields = try? load(), (try? JSONValue.object(fields).digest()) == entry.digest {
                record = workspace.record(entry, fields: fields)
            }
            states[id] = SyncLocalState(hlc: entry.hlc, serverHLC: entry.serverHLC, deleted: entry.deleted, record: record)
        }
        return states
    }

    func markAccepted(_ versions: [(id: String, hlc: HLC)]) throws { try workspace.markSyncAccepted(versions) }
    func observeClock(_ remote: HLC) throws { try workspace.observeSyncClock(remote) }

    func nextHLC() throws -> HLC {
        var clock = try workspace.syncClock()
        let hlc = clock.next()
        try workspace.saveSyncClock(clock)
        return hlc
    }

    private func meta(_ key: String) throws -> String? { try db.execute("SELECT value FROM sync_meta WHERE key=?", [key]).first?["value"] }
    private func setMeta(_ key: String, _ value: String?) throws {
        if let value { try db.execute("INSERT INTO sync_meta VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key, value]) }
        else { try db.execute("DELETE FROM sync_meta WHERE key=?", [key]) }
    }

    func cursor() throws -> SyncCursor {
        SyncCursor(userId: try meta("sync_user"), since: Int(try meta("sync_cursor") ?? "0") ?? 0, epoch: try meta("sync_epoch"))
    }

    func saveCursor(_ cursor: SyncCursor) throws {
        try transaction {
            try setMeta("sync_user", cursor.userId)
            try setMeta("sync_cursor", String(cursor.since))
            try setMeta("sync_epoch", cursor.epoch)
        }
    }

    func resetServerState(userId: String, accountChanged: Bool) throws {
        try transaction {
            if accountChanged {
                try db.execute("DELETE FROM sync_records WHERE deleted=1")
                try db.execute("DELETE FROM sync_inbox")
            }
            try db.execute("UPDATE sync_records SET server_hlc=NULL")
            try db.execute("DELETE FROM sync_blobs")
            try setMeta("sync_user", userId)
            try setMeta("sync_cursor", "0")
            try setMeta("sync_epoch", nil)
        }
    }

    // MARK: Blobs

    func assetData(for record: SyncRecord) throws -> Data? {
        guard let payload = try? record.payload(AssetPayload.self), let url = try? workspace.url(for: payload.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    func cachedBlob(recordId: String, hlc: HLC) throws -> SyncBlobReference? {
        guard let row = try db.execute("SELECT reference FROM sync_blobs WHERE id=? AND hlc=?", [recordId, hlc.description]).first,
              let text = row["reference"] else { return nil }
        return try? JSONDecoder().decode(SyncBlobReference.self, from: Data(text.utf8))
    }

    func cacheBlob(_ reference: SyncBlobReference, recordId: String, hlc: HLC) throws {
        let text = String(decoding: try JSONEncoder().encode(reference), as: UTF8.self)
        try db.execute("INSERT OR REPLACE INTO sync_blobs VALUES (?, ?, ?)", [recordId, hlc.description, text])
    }

    func forgetBlob(recordId: String) throws { try db.execute("DELETE FROM sync_blobs WHERE id=?", [recordId]) }

    // MARK: Apply

    /// Outcome of writing one record to the local data.
    private enum Outcome { case written, parked, skipped }

    func apply(_ steps: [SyncStep], blobs: [String: Data]) throws -> SyncApplyReport {
        var report = SyncApplyReport()
        // 1. Conflict branches, while the drafts they come from still exist.
        for step in steps {
            guard case .conflictCopy(let copy) = step else { continue }
            if try conflictBranch(copy) { report.conflicts += 1 }
        }
        // 2. Writes, parents first; then tombstones, children first.
        var writes: [(SyncRecord, HLC)] = []
        var acknowledgements: [(id: String, hlc: HLC)] = []
        for step in steps {
            switch step {
            case .write(let record, let server): writes.append((record, server))
            case .acknowledge(let id, let server): acknowledgements.append((id, server))
            case .conflictCopy: break
            }
        }
        let rank = Dictionary(uniqueKeysWithValues: Self.applyOrder.enumerated().map { ($1, $0) })
        let live = writes.filter { !$0.0.deleted }.sorted { rank[$0.0.type, default: 99] < rank[$1.0.type, default: 99] }
        let gone = writes.filter { $0.0.deleted }.sorted { rank[$0.0.type, default: 99] > rank[$1.0.type, default: 99] }
        var written: [(SyncRecord, HLC)] = []
        for chunk in (live + gone).chunked(Self.transactionSize) {
            try transaction {
                for (record, server) in chunk {
                    switch try write(record, blob: blobs[record.id]) {
                    case .written: written.append((record, server))
                    case .parked: try park(record, server: server, blob: blobs[record.id]); report.parked += 1
                    case .skipped: break
                    }
                }
            }
        }
        report.applied += written.count
        // 3. Records waiting for a parent that may have just arrived.
        let retried = try retryInbox()
        report.applied += retried.count
        written += retried
        // 4. Remember the applied versions in the ledger, as the local data now shows them.
        try recordApplied(written)
        if !acknowledgements.isEmpty {
            try transaction {
                for item in acknowledgements {
                    try db.execute("UPDATE sync_records SET server_hlc=? WHERE id=?", [item.hlc.description, item.id])
                }
            }
        }
        return report
    }

    private func transaction(_ body: () throws -> Void) throws {
        try db.execute("BEGIN IMMEDIATE")
        do {
            try body()
            try db.execute("COMMIT")
        } catch {
            _ = try? db.execute("ROLLBACK")
            throw error
        }
    }

    /// Updates the ledger for applied records with the fields the local data now yields, so the next
    /// tracking run sees no change. A live record the local data doesn't show goes to the inbox.
    private func recordApplied(_ applied: [(SyncRecord, HLC)]) throws {
        guard !applied.isEmpty else { return }
        let sources = Dictionary(try workspace.syncSources().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        try transaction {
            for (record, server) in applied {
                if record.deleted {
                    try upsertLedger(record, server: server, fields: nil, fingerprint: nil)
                    continue
                }
                guard let source = sources[record.id], case .present(let fingerprint, let load) = source.state, let fields = try? load() else {
                    // Written but not visible (e.g. a file the scan skips): never let tracking tombstone it.
                    if record.type != .settings { try park(record, server: server, blob: nil) }
                    continue
                }
                try upsertLedger(record, server: server, fields: fields, fingerprint: fingerprint, entity: source.entity)
            }
        }
    }

    private func upsertLedger(_ record: SyncRecord, server: HLC, fields: [String: JSONValue]?, fingerprint: String?, entity: String = "") throws {
        var clocks: [String: SyncLedgerEntry.Field] = [:]
        var digest: String?
        if let fields {
            for (key, value) in fields { clocks[key] = .init(d: try value.digest(), t: (record.fieldHLCs[key] ?? record.hlc).description) }
            digest = try JSONValue.object(fields).digest()
        }
        try db.execute("""
            INSERT INTO sync_records (id, type, entity, hlc, server_hlc, deleted, schema_version, digest, fields, fingerprint)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET type=excluded.type, entity=CASE WHEN excluded.entity='' THEN sync_records.entity ELSE excluded.entity END,
                hlc=excluded.hlc, server_hlc=excluded.server_hlc, deleted=excluded.deleted, schema_version=excluded.schema_version,
                digest=excluded.digest, fields=excluded.fields, fingerprint=excluded.fingerprint
            """, [record.id, String(record.type.rawValue), entity, record.hlc.description, server.description, record.deleted ? "1" : "0",
                  String(record.schemaVersion), digest, try workspace.encodeLedgerFields(clocks), fingerprint])
    }

    // MARK: Inbox

    private struct Parked: Codable {
        var fields: [String: JSONValue]
        var fieldHlcs: [String: String]
    }

    private func park(_ record: SyncRecord, server: HLC, blob: Data?) throws {
        let parked = Parked(fields: record.fields, fieldHlcs: record.fieldHLCs.mapValues(\.description))
        let text = String(decoding: try JSONEncoder().encode(parked), as: UTF8.self)
        try db.execute("DELETE FROM sync_inbox WHERE id=? AND hlc<?", [record.id, record.hlc.description])
        try db.execute("INSERT OR IGNORE INTO sync_inbox (id, type, hlc, server_hlc, record) VALUES (?, ?, ?, ?, ?)",
                       [record.id, String(record.type.rawValue), record.hlc.description, server.description, text])
        if let blob {
            // Keep the decrypted image next to the parked record (the database is device-local).
            let url = try inboxBlobURL(record.id)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try blob.write(to: url, options: .atomic)
        }
    }

    private func inboxBlobURL(_ id: String) throws -> URL {
        workspace.store.databaseURL.deletingLastPathComponent().appendingPathComponent("sync-inbox", isDirectory: true).appendingPathComponent(id)
    }

    private func retryInbox() throws -> [(SyncRecord, HLC)] {
        var applied: [(SyncRecord, HLC)] = []
        var progress = true
        while progress {
            progress = false
            for row in try db.execute("SELECT * FROM sync_inbox ORDER BY type, hlc") {
                guard let id = row["id"], let type = row["type"].flatMap(Int.init).flatMap(SyncRecordType.init(rawValue:)),
                      let hlc = row["hlc"].flatMap(HLC.init), let server = row["server_hlc"].flatMap(HLC.init),
                      let parked = row["record"].flatMap({ try? JSONDecoder().decode(Parked.self, from: Data($0.utf8)) }) else { continue }
                // A newer local or applied version supersedes the parked one.
                if let entry = try workspace.syncLedgerEntries(id: id).first, entry.hlc >= hlc {
                    try db.execute("DELETE FROM sync_inbox WHERE id=?", [id]); continue
                }
                let record = SyncRecord(id: id, type: type, hlc: hlc, deleted: false, fields: parked.fields,
                                        fieldHLCs: parked.fieldHlcs.compactMapValues(HLC.init))
                let blobURL = try inboxBlobURL(id)
                let blob = try? Data(contentsOf: blobURL)
                var outcome = Outcome.parked
                try transaction { outcome = try write(record, blob: blob) }
                guard outcome != .parked else { continue }
                try db.execute("DELETE FROM sync_inbox WHERE id=?", [id])
                try? fm.removeItem(at: blobURL)
                if outcome == .written { applied.append((record, server)); progress = true }
            }
        }
        return applied
    }

    // MARK: Writing records

    private func upper(_ id: String) -> String { id.uppercased() }
    private func string(_ record: SyncRecord, _ key: String) -> String? {
        if case .string(let value)? = record.fields[key] { return value }
        return nil
    }

    private func draftRow(_ id: String) throws -> [String: String]? {
        try db.execute("SELECT * FROM drafts WHERE lower(id)=?", [id.lowercased()]).first
    }

    private func write(_ record: SyncRecord, blob: Data?) throws -> Outcome {
        switch record.type {
        case .folder: return try writeFolder(record)
        case .draft: return try writeDraft(record)
        case .body: return try writeBody(record)
        case .snapshot: return try writeSnapshot(record)
        case .stash: return try writeStash(record)
        case .asset: return try writeAsset(record, blob: blob)
        case .comment: return try writeComment(record)
        case .thread, .message, .readMarker: return try writeReview(record)
        case .trashed: return try writeTrashed(record)
        case .settings: return .skipped
        }
    }

    /// The ledger's view of a file-backed record, to tell whether the file changed since.
    private func fileUnchanged(_ id: String, _ url: URL) throws -> Bool {
        guard fm.fileExists(atPath: url.path) else { return true }
        guard let entry = try workspace.syncLedgerEntries(id: id).first, !entry.deleted else { return false }
        return entry.fingerprint == workspace.fileFingerprint(url)
    }

    private func writeText(_ text: String, to url: URL, modified: Double? = nil) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if let modified {
            try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified / 1000)], ofItemAtPath: url.path)
        }
    }

    private func writeFolder(_ record: SyncRecord) throws -> Outcome {
        let path = try record.payload(FolderPayload.self).path
        guard let url = try? workspace.url(for: path) else { return .skipped }
        if record.deleted {
            let names = ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).filter { $0 != ".DS_Store" }
            if names.isEmpty { try? fm.removeItem(at: url) }
            return .written
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return .written
    }

    /// A free path: the wanted one, or "Title 2.md", "Title 3.md"… in the same folder.
    private func freePath(_ wanted: String, except id: String? = nil) throws -> String {
        func taken(_ path: String) throws -> Bool {
            let row = try db.execute("SELECT id FROM drafts WHERE path=?", [path]).first
            if let row, row["id"]?.lowercased() != id?.lowercased() { return true }
            return try row == nil && fm.fileExists(atPath: workspace.url(for: path).path)
        }
        guard try taken(wanted) else { return wanted }
        let folder = (wanted as NSString).deletingLastPathComponent
        let name = ((wanted as NSString).lastPathComponent as NSString).deletingPathExtension
        for number in 2... {
            let file = "\(name) \(number).md"
            let path = folder.isEmpty ? file : folder + "/" + file
            if try !taken(path) { return path }
        }
        return wanted
    }

    private func writeDraft(_ record: SyncRecord) throws -> Outcome {
        let row = try draftRow(record.id)
        if record.deleted {
            guard let row, let id = row["id"] else { return .written }
            try db.execute("UPDATE drafts SET parent=? WHERE parent=?", [row["parent"], id])
            try db.execute("DELETE FROM drafts WHERE id=?", [id])
            if let path = row["path"], let url = try? workspace.url(for: path), fm.fileExists(atPath: url.path) { try? trashItem(url) }
            return .written
        }
        let payload = try record.payload(DraftPayload.self)
        guard (try? workspace.url(for: payload.path)) != nil, payload.path.lowercased().hasSuffix(".md") else { return .skipped }
        let family = upper(payload.family), parent = payload.parent.map(upper)
        if let row, let id = row["id"], let old = row["path"] {
            var path = old
            let free = try payload.path == old ? old : freePath(payload.path, except: id)
            if free != old {
                path = free
                let from = try workspace.url(for: old), to = try workspace.url(for: path)
                if fm.fileExists(atPath: from.path) {
                    try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: from, to: to)
                }
            }
            try db.execute("UPDATE drafts SET path=?, family=?, parent=?, goal=? WHERE id=?", [path, family, parent, payload.goal, id])
        } else {
            let id = upper(record.id)
            let path = try freePath(payload.path)
            try db.execute("INSERT INTO drafts (id, path, family, parent, goal) VALUES (?, ?, ?, ?, ?)", [id, path, family, parent, payload.goal])
        }
        if let created = payload.created {
            let id = try draftRow(record.id)?["id"] ?? upper(record.id)
            let seconds = String(created / 1000)
            try db.execute("INSERT INTO draft_dates VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET created=excluded.created", [id, seconds, seconds])
        }
        return .written
    }

    private func writeBody(_ record: SyncRecord) throws -> Outcome {
        if record.deleted { return .written }  // the draft's own tombstone removes the file
        let payload = try record.payload(BodyPayload.self)
        guard let row = try draftRow(payload.draft), let path = row["path"], let url = try? workspace.url(for: path) else { return .parked }
        guard try fileUnchanged(record.id, url) else { return .skipped }
        if (try? String(contentsOf: url, encoding: .utf8)) != payload.text {
            try writeText(payload.text, to: url, modified: payload.edited)
        }
        return .written
    }

    private func writeSnapshot(_ record: SyncRecord) throws -> Outcome {
        let id = upper(record.id)
        if record.deleted {
            if let path = try db.execute("SELECT path FROM snapshots WHERE lower(id)=?", [record.id]).first?["path"],
               path.hasPrefix(".matilde/snapshots/"), !path.contains("..") {
                try? fm.removeItem(at: workspace.root.appendingPathComponent(path))
            }
            try db.execute("DELETE FROM snapshots WHERE lower(id)=?", [record.id])
            return .written
        }
        let payload = try record.payload(SnapshotPayload.self)
        let path = try db.execute("SELECT path FROM snapshots WHERE lower(id)=?", [record.id]).first?["path"]
            .flatMap { $0.hasPrefix(".matilde/snapshots/") && !$0.contains("..") ? $0 : nil } ?? ".matilde/snapshots/\(id).md"
        try writeText(payload.text, to: workspace.root.appendingPathComponent(path))
        let created = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: (payload.created ?? 0) / 1000))
        try db.execute("DELETE FROM snapshots WHERE lower(id)=?", [record.id])
        try db.execute("INSERT INTO snapshots VALUES (?, ?, ?, ?, ?)", [id, upper(payload.source), upper(payload.child), path, created])
        return .written
    }

    private func stashFile(family: String) throws -> URL {
        // Keep an existing file's spelling of the family id.
        let directory = try workspace.stashDirectory()
        if let names = try? fm.contentsOfDirectory(atPath: directory.path),
           let name = names.first(where: { $0.hasSuffix(".md") && $0.dropLast(3).lowercased() == family.lowercased() }) {
            return directory.appendingPathComponent(name)
        }
        return try workspace.stashURL(upper(family))
    }

    private func writeStash(_ record: SyncRecord) throws -> Outcome {
        guard let entity = try workspace.syncLedgerEntries(id: record.id).first?.entity ?? string(record, "family") else { return .skipped }
        let url = try stashFile(family: record.deleted ? entity : (string(record, "family") ?? entity))
        guard try fileUnchanged(record.id, url) else { return .skipped }
        if record.deleted {
            if fm.fileExists(atPath: url.path) { try? trashItem(url) }
            return .written
        }
        let payload = try record.payload(StashPayload.self)
        if (try? String(contentsOf: url, encoding: .utf8)) != payload.text { try writeText(payload.text, to: url) }
        return .written
    }

    private func writeAsset(_ record: SyncRecord, blob: Data?) throws -> Outcome {
        if record.deleted {
            if let path = try workspace.syncLedgerEntries(id: record.id).first?.entity, let url = try? workspace.url(for: path),
               fm.fileExists(atPath: url.path) { try? trashItem(url) }
            return .written
        }
        let payload = try record.payload(AssetPayload.self)
        guard let url = try? workspace.url(for: payload.path), url.deletingLastPathComponent().lastPathComponent == ".assets" else { return .skipped }
        guard let blob else {
            // The image itself didn't arrive (gone from the server); keep any local copy.
            return fm.fileExists(atPath: url.path) ? .written : .skipped
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? Data(contentsOf: url)) != blob { try blob.write(to: url, options: .atomic) }
        return .written
    }

    private func writeComment(_ record: SyncRecord) throws -> Outcome {
        try workspace.ensureUserComments()
        if record.deleted {
            try db.execute("DELETE FROM user_comments WHERE lower(id)=?", [record.id])
            return .written
        }
        let payload = try record.payload(CommentPayload.self)
        try db.execute("DELETE FROM user_comments WHERE lower(id)=?", [record.id])
        try db.execute("""
            INSERT INTO user_comments (id, draft_id, body, location, length, quote, prefix, suffix, created, modified, archived)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [upper(record.id), upper(payload.draft), payload.body, String(payload.location), String(payload.length),
                  payload.quote, payload.prefix, payload.suffix, String(payload.created / 1000), String(payload.modified / 1000),
                  payload.archived ? "1" : "0"])
        return .written
    }

    private func writeTrashed(_ record: SyncRecord) throws -> Outcome {
        try db.execute("CREATE TABLE IF NOT EXISTS trashed_drafts AS SELECT *, '' AS trashed_at FROM drafts WHERE 0")
        if record.deleted {
            guard let draft = try workspace.syncLedgerEntries(id: record.id).first?.entity else { return .written }
            try db.execute("DELETE FROM trashed_drafts WHERE lower(id)=?", [draft.lowercased()])
            return .written
        }
        let payload = try record.payload(TrashedPayload.self)
        let trashedAt = payload.trashedAt.map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0 / 1000)) } ?? ""
        try db.execute("DELETE FROM trashed_drafts WHERE lower(id)=?", [payload.draft])
        try db.execute("INSERT INTO trashed_drafts (id, path, family, parent, goal, cursor, scroll, trashed_at) VALUES (?, ?, ?, ?, ?, 0, 0, ?)",
                       [upper(payload.draft), payload.path, upper(payload.family), payload.parent.map(upper), payload.goal, trashedAt])
        return .written
    }

    // MARK: Reviews

    private func ensureReviews() throws {
        try db.execute("CREATE TABLE IF NOT EXISTS writing_reviews (id TEXT PRIMARY KEY, draft_id TEXT NOT NULL, created REAL NOT NULL, payload TEXT NOT NULL)")
    }

    private func reviews() throws -> [WritingReview] {
        try db.execute("SELECT payload FROM writing_reviews").compactMap { row in
            row["payload"].flatMap { try? JSONDecoder().decode(WritingReview.self, from: Data($0.utf8)) }
        }
    }

    /// The review holding a thread, and the thread's index in it.
    private func locate(thread: String) throws -> (WritingReview, Int)? {
        for review in try reviews() {
            if let index = review.comments.firstIndex(where: { $0.id.uuidString.lowercased() == thread }) { return (review, index) }
        }
        return nil
    }

    private func writeReview(_ record: SyncRecord) throws -> Outcome {
        try ensureReviews()
        switch record.type {
        case .thread:
            if record.deleted {
                guard let found = try locate(thread: record.id) else { return .written }
                var review = found.0
                let index = found.1
                review.comments.remove(at: index)
                if review.comments.isEmpty { try db.execute("DELETE FROM writing_reviews WHERE id=?", [review.id.uuidString]) }
                else { try workspace.saveReview(review) }
                return .written
            }
            let payload = try record.payload(ThreadPayload.self)
            guard let threadID = UUID(uuidString: record.id), let reviewID = UUID(uuidString: payload.review) else { return .skipped }
            var review: WritingReview
            if let row = try db.execute("SELECT payload FROM writing_reviews WHERE id=?", [reviewID.uuidString]).first,
               let decoded = row["payload"].flatMap({ try? JSONDecoder().decode(WritingReview.self, from: Data($0.utf8)) }) {
                review = decoded
            } else {
                review = WritingReview(id: reviewID, draftID: upper(payload.draft), created: Date(timeIntervalSince1970: payload.reviewCreated / 1000),
                                       model: payload.model, revision: payload.revision, stale: payload.stale, comments: [])
            }
            // A thread moved to another review (shouldn't happen) leaves the old one.
            if let found = try locate(thread: record.id), found.0.id != reviewID {
                var other = found.0
                other.comments.remove(at: found.1)
                try workspace.saveReview(other)
            }
            review.revision = payload.revision
            review.stale = payload.stale
            let suggestion = ReviewSuggestion(quote: payload.quote, prefix: payload.prefix, suffix: payload.suffix,
                                              explanation: payload.explanation, replacement: payload.replacement)
            var comment = review.comments.first(where: { $0.id == threadID }) ?? ReviewComment(id: threadID, suggestion: suggestion, location: payload.location, length: payload.length)
            comment.suggestion = suggestion
            comment.location = payload.location
            comment.length = payload.length
            comment.status = payload.status
            comment.userInitiated = payload.userInitiated
            comment.rewriteQuote = payload.rewriteQuote
            comment.rewriteMessageID = payload.rewriteMessage.flatMap(UUID.init(uuidString:))
            comment.initialReplacement = payload.initialReplacement
            if let index = review.comments.firstIndex(where: { $0.id == threadID }) { review.comments[index] = comment }
            else { review.comments.append(comment) }
            try workspace.saveReview(review)
            return .written
        case .message:
            if record.deleted {
                for var review in try reviews() {
                    for index in review.comments.indices {
                        guard let at = review.comments[index].messages?.firstIndex(where: { $0.id.uuidString.lowercased() == record.id }) else { continue }
                        review.comments[index].messages?.remove(at: at)
                        try workspace.saveReview(review)
                        return .written
                    }
                }
                return .written
            }
            let payload = try record.payload(MessagePayload.self)
            guard let messageID = UUID(uuidString: record.id) else { return .skipped }
            guard let found = try locate(thread: payload.thread) else { return .parked }
            var review = found.0
            let index = found.1
            var messages = review.comments[index].messages ?? []
            var message = ReviewMessage(id: messageID, role: payload.role, text: payload.text, delivery: payload.delivery, replacement: payload.replacement)
            if let existing = messages.firstIndex(where: { $0.id == messageID }) {
                message.prompt = messages[existing].prompt
                messages.remove(at: existing)
            }
            messages.insert(message, at: min(max(payload.index, 0), messages.count))
            review.comments[index].messages = messages
            try workspace.saveReview(review)
            return .written
        case .readMarker:
            if record.deleted { return .written }
            let payload = try record.payload(ReadMarkerPayload.self)
            guard let found = try locate(thread: payload.thread) else { return .parked }
            var review = found.0
            let index = found.1
            review.comments[index].unread = payload.unread ? true : nil
            try workspace.saveReview(review)
            return .written
        default:
            return .skipped
        }
    }

    // MARK: Conflict branches

    /// Keeps a body's text as a new draft in the same family, branched from the body's draft.
    private func conflictBranch(_ copy: SyncRecord) throws -> Bool {
        guard let text = string(copy, "text"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let draft = try string(copy, "draft") ?? workspace.syncLedgerEntries(id: copy.id).first?.entity.lowercased() ?? ""
        try db.execute("CREATE TABLE IF NOT EXISTS trashed_drafts AS SELECT *, '' AS trashed_at FROM drafts WHERE 0")
        let original = try draftRow(draft) ?? db.execute("SELECT * FROM trashed_drafts WHERE lower(id)=? ORDER BY rowid DESC", [draft]).first
        let originalPath = original?["path"] ?? "Recovered draft.md"
        let folder = (originalPath as NSString).deletingLastPathComponent
        let title = ((originalPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let local = copy.hlc.device == workspace.syncDeviceID
        let name = local ? "\(title) — from \(deviceName)" : "\(title) — recovered"
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let path = try freePath(folder.isEmpty ? safe + ".md" : folder + "/" + safe + ".md")
        let id = UUID().uuidString
        let url = try workspace.url(for: path)
        try writeText(text, to: url)
        do {
            try db.execute("INSERT INTO drafts (id, path, family, parent, goal) VALUES (?, ?, ?, ?, ?)",
                           [id, path, original?["family"] ?? id, original?["id"], original?["goal"] ?? ""])
        } catch {
            try? fm.removeItem(at: url)
            throw error
        }
        return true
    }
}

private extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
