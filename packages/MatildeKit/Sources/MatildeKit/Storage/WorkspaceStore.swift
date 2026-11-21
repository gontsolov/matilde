import Foundation
import CSQLite

/// SYNC-01: the live SQLite database lives in Application Support, keyed by the
/// workspace ID in `.matilde/workspace.json`, never inside the workspace folder,
/// which may sit in a file-synced folder (iCloud Drive "Desktop & Documents",
/// Dropbox) that can corrupt an open database.
///
/// Layout: `<Application Support>/Matilde/workspaces/<workspaceID>/workspace.sqlite`
/// plus `store.json` (`id`, last `root` path) to tell a moved workspace from a copy.
///
/// The one-time migration copies `.matilde/workspace.sqlite` with SQLite's online
/// backup API (which reads committed `-wal` content and rolls back a hot journal),
/// verifies the copy, renames it into place atomically and only then renames the old
/// file to `workspace.sqlite.migrated`. Every step can be interrupted and repeated:
/// the store database only exists once it is complete, and the old file is renamed,
/// never deleted.
public struct WorkspaceStore {
    public static let databaseName = "workspace.sqlite"
    public static let migratedName = "workspace.sqlite.migrated"
    public static let identityName = "workspace.json"
    public static let recordName = "store.json"
    public static let incomingPrefix = "workspace.sqlite.incoming-"
    public static let sidecarSuffixes = ["-wal", "-shm", "-journal"]

    public enum Origin: Equatable {
        /// The store database already existed.
        case existing
        /// Copied from `.matilde/workspace.sqlite` in this workspace.
        case migratedLegacy
        /// Copied from a `workspace.sqlite.migrated` left by another Mac that migrated first.
        case importedMigratedCopy
        /// The workspace folder is a copy of another workspace; its data was seeded from that store.
        case forked
        /// No earlier data: a new, empty database.
        case fresh
        /// Migration failed; the old in-workspace database stays live for this session and
        /// migration is retried at the next launch. Nothing is renamed or removed.
        case legacyFallback
    }

    public let workspaceID: String
    public let directory: URL
    public let databaseURL: URL
    public let origin: Origin

    public static var defaultBase: URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["MATILDE_STORE_DIRECTORY"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        // Tests must never touch the real Application Support folder.
        if NSClassFromString("XCTestCase") != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("matilde-test-store", isDirectory: true)
        }
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("Matilde/workspaces", isDirectory: true)
    }

    /// Resolve the database for a workspace, migrating the old in-workspace database once.
    /// `metadata` is the workspace's `.matilde` folder, which must already exist.
    public static func prepare(root: URL, metadata: URL, base: URL = defaultBase, fileManager fm: FileManager = .default) throws -> WorkspaceStore {
        var id = try identity(metadata: metadata, fileManager: fm)
        var forkSource: URL?
        if let previous = storeRecord(in: base.appendingPathComponent(id, isDirectory: true)),
           let recordedRoot = previous["root"], recordedRoot != root.path,
           (try? existingIdentity(metadata: URL(fileURLWithPath: recordedRoot).appendingPathComponent(".matilde", isDirectory: true))) == id {
            // Another folder on this Mac still carries this ID: this folder is a copy
            // (for example duplicated in Finder). Give it its own ID and store.
            forkSource = base.appendingPathComponent(id, isDirectory: true).appendingPathComponent(databaseName)
            id = UUID().uuidString
            try writeJSON(["id": id], to: metadata.appendingPathComponent(identityName))
        }

        let directory = base.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        removeIncoming(in: directory, fileManager: fm)
        let database = directory.appendingPathComponent(databaseName)
        let legacy = metadata.appendingPathComponent(databaseName)
        let workspaceID = id
        func store(_ origin: Origin, _ url: URL? = nil) throws -> WorkspaceStore {
            if origin != .legacyFallback { try writeJSON(["id": workspaceID, "root": root.path], to: directory.appendingPathComponent(recordName)) }
            return WorkspaceStore(workspaceID: workspaceID, directory: directory, databaseURL: url ?? database, origin: origin)
        }

        if fm.fileExists(atPath: database.path) {
            // Finish an interrupted migration, or set aside a database an older Matilde
            // (for example on another Mac sharing this folder) created after migration.
            // It is renamed, never deleted.
            if fm.fileExists(atPath: legacy.path) { retireLogged(legacy, fileManager: fm) }
            return try store(.existing)
        }

        if fm.fileExists(atPath: legacy.path) {
            do {
                try copyVerified(from: legacy, to: database, fileManager: fm)
            } catch {
                NSLog("Matilde: could not move the workspace database to Application Support; using it in place for now: \(error.localizedDescription)")
                return try store(.legacyFallback, legacy)
            }
            // The copy is complete; if renaming fails, the next launch retries it.
            retireLogged(legacy, fileManager: fm)
            return try store(.migratedLegacy)
        }

        if let forkSource, fm.fileExists(atPath: forkSource.path) {
            do {
                try copyVerified(from: forkSource, to: database, fileManager: fm)
                return try store(.forked)
            } catch {
                NSLog("Matilde: could not copy the database of the original workspace: \(error.localizedDescription)")
            }
        }

        // Another Mac sharing this folder migrated first: start from its last copy,
        // which stays in place.
        if let migrated = newestMigratedCopy(in: metadata, fileManager: fm) {
            do {
                try copyVerified(from: migrated, to: database, fileManager: fm, readOnly: true)
                return try store(.importedMigratedCopy)
            } catch {
                NSLog("Matilde: could not import \(migrated.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return try store(.fresh)
    }

    // MARK: Identity

    /// Read the workspace ID, creating it on first use.
    public static func identity(metadata: URL, fileManager fm: FileManager = .default) throws -> String {
        if let id = try? existingIdentity(metadata: metadata) { return id }
        let id = UUID().uuidString
        try writeJSON(["id": id], to: metadata.appendingPathComponent(identityName))
        return id
    }

    /// The ID is used as a folder name, so only a well-formed UUID is accepted.
    public static func existingIdentity(metadata: URL) throws -> String? {
        let data = try Data(contentsOf: metadata.appendingPathComponent(identityName))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["id"] as? String, let uuid = UUID(uuidString: raw) else { return nil }
        return uuid.uuidString
    }

    private static func storeRecord(in directory: URL) -> [String: String]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(recordName)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    }

    private static func writeJSON(_ object: [String: String], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    // MARK: Migration steps

    /// Rename the old database (and any SQLite sidecar files) out of the way. Never deletes.
    public static func retire(_ legacy: URL, fileManager fm: FileManager = .default) throws {
        let folder = legacy.deletingLastPathComponent()
        var target = folder.appendingPathComponent(migratedName)
        if fm.fileExists(atPath: target.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            target = folder.appendingPathComponent("\(migratedName)-\(stamp)-\(UUID().uuidString.prefix(8))")
        }
        try fm.moveItem(at: legacy, to: target)
        for suffix in sidecarSuffixes {
            let sidecar = URL(fileURLWithPath: legacy.path + suffix)
            if fm.fileExists(atPath: sidecar.path) {
                try? fm.moveItem(at: sidecar, to: URL(fileURLWithPath: target.path + suffix))
            }
        }
    }

    private static func retireLogged(_ legacy: URL, fileManager fm: FileManager) {
        do { try retire(legacy, fileManager: fm) }
        catch { NSLog("Matilde: could not rename the old workspace database: \(error.localizedDescription)") }
    }

    public static func newestMigratedCopy(in metadata: URL, fileManager fm: FileManager = .default) -> URL? {
        let names = (try? fm.contentsOfDirectory(atPath: metadata.path)) ?? []
        let candidates = names.filter { name in
            name.hasPrefix(migratedName) && !sidecarSuffixes.contains { name.hasSuffix($0) }
        }.map { metadata.appendingPathComponent($0) }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return candidates.max { modified($0) < modified($1) }
    }

    private static func removeIncoming(in directory: URL, fileManager fm: FileManager) {
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasPrefix(incomingPrefix) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Copy `source` into a temporary file beside `destination`, verify it, then rename
    /// it into place. `destination` only ever appears complete.
    public static func copyVerified(from source: URL, to destination: URL, fileManager fm: FileManager = .default, readOnly: Bool = false) throws {
        let incoming = destination.deletingLastPathComponent().appendingPathComponent(incomingPrefix + UUID().uuidString)
        func cleanUp() {
            try? fm.removeItem(at: incoming)
            for suffix in sidecarSuffixes { try? fm.removeItem(atPath: incoming.path + suffix) }
        }
        do {
            var expected: [String: Int] = [:]
            do {
                // Read-write lets SQLite recover a hot journal or fold in a -wal file.
                let from = try SQLiteConnection(source, flags: readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE)
                let to = try SQLiteConnection(incoming, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
                try to.backup(from: from)
                for table in try from.tables() { expected[table] = try from.count(table) }
                guard try to.single("PRAGMA journal_mode = DELETE")?.lowercased() == "delete" else {
                    throw WorkspaceError.message("The copied database could not leave WAL mode.")
                }
            }
            // Reopen the closed copy: it must open in rollback-journal mode, pass the
            // integrity check and hold exactly the rows of the source.
            do {
                let check = try SQLiteConnection(incoming, flags: SQLITE_OPEN_READONLY)
                guard try check.single("PRAGMA journal_mode")?.lowercased() == "delete" else {
                    throw WorkspaceError.message("The copied database is still in WAL mode.")
                }
                guard try check.single("PRAGMA integrity_check") == "ok" else {
                    throw WorkspaceError.message("The copied database failed its integrity check.")
                }
                var actual: [String: Int] = [:]
                for table in try check.tables() { actual[table] = try check.count(table) }
                guard actual == expected else { throw WorkspaceError.message("The copied database is incomplete.") }
            }
            // Apple's SQLite can keep empty -wal/-shm files after closing (persistent WAL).
            // The copy is now in rollback mode, so SQLite ignores them; drop them so they
            // never sit beside the live file. A leftover journal would be a hot journal.
            for suffix in ["-wal", "-shm"] { try? fm.removeItem(atPath: incoming.path + suffix) }
            guard !fm.fileExists(atPath: incoming.path + "-journal") else {
                throw WorkspaceError.message("The copied database was not closed cleanly.")
            }
            try fm.moveItem(at: incoming, to: destination)
        } catch {
            cleanUp()
            throw error
        }
    }

    public init(workspaceID: String, directory: URL, databaseURL: URL, origin: Origin) {
        self.workspaceID = workspaceID
        self.directory = directory
        self.databaseURL = databaseURL
        self.origin = origin
    }
}

/// Minimal SQLite connection for the migration (the app's `Database` creates its schema on open).
private final class SQLiteConnection {
    private var handle: OpaquePointer?

    init(_ url: URL, flags: Int32) throws {
        let result = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard result == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error \(result)"
            sqlite3_close(handle)
            handle = nil
            throw WorkspaceError.message(message)
        }
        sqlite3_busy_timeout(handle, 3000)
    }
    deinit { sqlite3_close(handle) }

    func backup(from source: SQLiteConnection) throws {
        guard let backup = sqlite3_backup_init(handle, "main", source.handle, "main") else { throw error() }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else { throw error() }
    }

    func rows(_ sql: String) throws -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(statement) }
        var rows: [[String?]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw error() }
            rows.append((0..<sqlite3_column_count(statement)).map { index in
                sqlite3_column_text(statement, index).map { String(cString: $0) }
            })
        }
    }

    func single(_ sql: String) throws -> String? { try rows(sql).first?.first ?? nil }

    func tables() throws -> [String] {
        try rows("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").compactMap { $0.first ?? nil }
    }

    func count(_ table: String) throws -> Int {
        let quoted = "\"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        return Int(try single("SELECT count(*) FROM \(quoted)") ?? "") ?? -1
    }

    private func error() -> WorkspaceError { .message(String(cString: sqlite3_errmsg(handle))) }
}
