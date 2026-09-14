import Foundation
import CSQLite

struct Draft: Identifiable, Hashable {
    var id: String
    var path: String
    var family: String
    var parent: String?
    var goal: String
    var cursor: Int
    var scroll: Double
    var createdAt: Date?
    var editedAt: Date?
    var title: String { URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }
    var folder: String {
        let value = (path as NSString).deletingLastPathComponent
        return value == "." ? "" : value
    }
}

enum WorkspaceError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

final class Database {
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            throw WorkspaceError.message("Could not open the workspace database.")
        }
        sqlite3_busy_timeout(handle, 3000)
        try execute("PRAGMA foreign_keys = ON")
        // A single database file makes closed-workspace backups straightforward.
        try execute("PRAGMA journal_mode = DELETE")
        try execute("CREATE TABLE IF NOT EXISTS drafts (id TEXT PRIMARY KEY, path TEXT UNIQUE NOT NULL, family TEXT NOT NULL, parent TEXT, goal TEXT NOT NULL DEFAULT '', cursor INTEGER NOT NULL DEFAULT 0, scroll REAL NOT NULL DEFAULT 0)")
        try execute("CREATE TABLE IF NOT EXISTS snapshots (id TEXT PRIMARY KEY, source TEXT NOT NULL, child TEXT NOT NULL, path TEXT NOT NULL, created TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        try execute("PRAGMA user_version = 1")
        try execute("CREATE TABLE IF NOT EXISTS draft_dates (id TEXT PRIMARY KEY, created REAL NOT NULL, edited REAL NOT NULL)")
    }
    deinit { sqlite3_close(handle) }

    @discardableResult
    func execute(_ sql: String, _ values: [String?] = []) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let result: Int32
            if let value { result = sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) }
            else { result = sqlite3_bind_null(statement, Int32(index + 1)) }
            guard result == SQLITE_OK else { throw error() }
        }
        var rows: [[String: String]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw error() }
            var row: [String: String] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                if let value = sqlite3_column_text(statement, index) {
                    row[String(cString: sqlite3_column_name(statement, index))] = String(cString: value)
                }
            }
            rows.append(row)
        }
    }
    private func error() -> WorkspaceError { .message(String(cString: sqlite3_errmsg(handle))) }
}

final class Workspace {
    let root: URL
    let db: Database
    private let fm = FileManager.default

    init(root: URL) throws {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: self.root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorkspaceError.message("The workspace folder is no longer available. Choose it again.")
        }
        let metadata = self.root.appendingPathComponent(".matilde", isDirectory: true)
        if fm.fileExists(atPath: metadata.path), metadata.resolvingSymlinksInPath().path != metadata.path {
            throw WorkspaceError.message("The .matilde folder cannot be a symbolic link.")
        }
        try fm.createDirectory(at: metadata.appendingPathComponent("snapshots"), withIntermediateDirectories: true)
        db = try Database(url: metadata.appendingPathComponent("workspace.sqlite"))
    }

    func url(for path: String) throws -> URL {
        var componentURL = root
        for component in path.split(separator: "/") {
            guard component != "..", component != ".matilde" else { throw WorkspaceError.message("Files must stay inside the workspace and outside .matilde.") }
            componentURL.appendPathComponent(String(component))
            if (try? componentURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw WorkspaceError.message("Symbolic links inside the workspace are not supported.")
            }
        }
        let url = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/"), !path.split(separator: "/").contains(".matilde") else {
            throw WorkspaceError.message("Files must stay inside the workspace and outside .matilde.")
        }
        return url
    }

    func scan() throws -> (drafts: [Draft], folders: [String]) {
        var paths: [String] = []
        var folders = [""]
        var scanError: Error?
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles], errorHandler: { _, error in
            scanError = error; return false
        }) else { throw WorkspaceError.message("Could not read the workspace folder.") }
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            let canonical = file.standardizedFileURL.resolvingSymlinksInPath().path
            guard canonical.hasPrefix(root.path + "/") else { continue }
            let relative = String(canonical.dropFirst(root.path.count + 1))
            if values.isDirectory == true { folders.append(relative) }
            else if file.pathExtension.lowercased() == "md" { paths.append(relative) }
        }
        if let scanError { throw scanError }
        let known = Set(try allDrafts().map(\.path))
        for path in paths where !known.contains(path) {
            let id = UUID().uuidString
            try db.execute("INSERT INTO drafts (id, path, family) VALUES (?, ?, ?)", [id, path, id])
        }
        let visible = Set(paths)
        return (try allDrafts().filter { visible.contains($0.path) }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }, folders.sorted())
    }

    func allDrafts() throws -> [Draft] {
        try db.execute("SELECT * FROM drafts").map {
            try dated(Draft(id: $0["id"]!, path: $0["path"]!, family: $0["family"]!, parent: $0["parent"], goal: $0["goal"] ?? "", cursor: Int($0["cursor"] ?? "0") ?? 0, scroll: Double($0["scroll"] ?? "0") ?? 0))
        }
    }
    // Preserve the imported creation date across atomic saves. File modification
    // dates remain authoritative for external edits; metadata edits are tracked separately.
    private func dated(_ draft: Draft) throws -> Draft {
        var result = draft
        let values = try? url(for: draft.path).resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        if let created = values?.creationDate ?? values?.contentModificationDate {
            try db.execute("INSERT OR IGNORE INTO draft_dates VALUES (?,?,?)", [draft.id, String(created.timeIntervalSince1970), String((values?.contentModificationDate ?? created).timeIntervalSince1970)])
        }
        if let row = try db.execute("SELECT * FROM draft_dates WHERE id=?", [draft.id]).first {
            result.createdAt = Double(row["created"] ?? "").map(Date.init(timeIntervalSince1970:))
            result.editedAt = Double(row["edited"] ?? "").map(Date.init(timeIntervalSince1970:))
        }
        if let modified = values?.contentModificationDate {
            result.editedAt = max(result.editedAt ?? modified, modified)
        }
        return result
    }
    private func touch(_ draft: Draft) throws {
        try db.execute("UPDATE draft_dates SET edited=? WHERE id=?", [String(Date().timeIntervalSince1970), draft.id])
    }
    func read(_ draft: Draft) throws -> String { try String(contentsOf: url(for: draft.path), encoding: .utf8) }
    /// Trash only this file. Keep its metadata and snapshots as history, and reconnect children.
    func trash(_ draft: Draft, move: (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }) throws {
        let file = try url(for: draft.path)
        try db.execute("CREATE TABLE IF NOT EXISTS trashed_drafts AS SELECT *, '' AS trashed_at FROM drafts WHERE 0")
        try db.execute("BEGIN IMMEDIATE")
        do {
            try db.execute("INSERT INTO trashed_drafts SELECT *, ? FROM drafts WHERE id=?", [ISO8601DateFormatter().string(from: Date()), draft.id])
            try db.execute("UPDATE drafts SET parent=? WHERE parent=?", [draft.parent, draft.id])
            try db.execute("DELETE FROM drafts WHERE id=?", [draft.id])
            try move(file)
            try db.execute("COMMIT")
        } catch {
            _ = try? db.execute("ROLLBACK")
            throw error
        }
    }
    func save(_ draft: Draft, text: String) throws {
        _ = try dated(draft)
        // Branching/explicit saves of unchanged writing must not reset its age.
        guard try read(draft) != text else { return }
        try text.write(to: url(for: draft.path), atomically: true, encoding: .utf8)
    }

    func validName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("."), !trimmed.contains("/"), !trimmed.contains(":"), !trimmed.contains("\\"), !trimmed.contains(where: { $0.isNewline || $0.asciiValue == 0 }) else {
            throw WorkspaceError.message("Use a name without slashes, colons, or a leading dot.")
        }
        return trimmed
    }
    func filePath(name: String, folder: String) throws -> String {
        let name = try validName(name)
        let filename = name.lowercased().hasSuffix(".md") ? name : name + ".md"
        return folder.isEmpty ? filename : folder + "/" + filename
    }
    func create(name: String, folder: String, goal: String, text: String = "") throws -> Draft {
        let path = try filePath(name: name, folder: folder)
        let file = try url(for: path)
        guard !fm.fileExists(atPath: file.path) else { throw WorkspaceError.message("A file with that name already exists.") }
        let id = UUID().uuidString
        try text.write(to: file, atomically: true, encoding: .utf8)
        do { try db.execute("INSERT INTO drafts (id,path,family,goal) VALUES (?,?,?,?)", [id, path, id, goal]) }
        catch { try? fm.removeItem(at: file); throw error }
        return try dated(Draft(id: id, path: path, family: id, parent: nil, goal: goal, cursor: 0, scroll: 0))
    }
    func createUntitled(folder: String) throws -> Draft {
        var name = "Untitled"
        var number = 2
        while fm.fileExists(atPath: try url(for: filePath(name: name, folder: folder)).path) {
            name = "Untitled \(number)"; number += 1
        }
        let draft = try create(name: name, folder: folder, goal: "")
        try setState("untitled:\(draft.id)", "true")
        return draft
    }
    func createFolder(name: String, parent: String) throws {
        let name = try validName(name)
        let path = parent.isEmpty ? name : parent + "/" + name
        let target = try url(for: path)
        guard !fm.fileExists(atPath: target.path) else { throw WorkspaceError.message("That folder already exists.") }
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
    }
    func branch(_ source: Draft, text: String) throws -> Draft {
        try save(source, text: text)
        var number = 1
        var path: String
        repeat {
            path = try filePath(name: source.title + " — Alternative \(number)", folder: source.folder)
            number += 1
        } while fm.fileExists(atPath: try url(for: path).path)
        let child = UUID().uuidString
        let snapshot = UUID().uuidString
        let snapshotPath = ".matilde/snapshots/\(snapshot).md"
        let snapshotURL = root.appendingPathComponent(snapshotPath)
        let childURL = try url(for: path)
        try text.write(to: snapshotURL, atomically: true, encoding: .utf8)
        do {
            try text.write(to: childURL, atomically: true, encoding: .utf8)
            try db.execute("BEGIN IMMEDIATE")
            do {
                try db.execute("INSERT INTO drafts (id,path,family,parent,goal,cursor,scroll) VALUES (?,?,?,?,?,?,?)", [child, path, source.family, source.id, source.goal, String(source.cursor), String(source.scroll)])
                try db.execute("INSERT INTO snapshots VALUES (?,?,?,?,?)", [snapshot, source.id, child, snapshotPath, ISO8601DateFormatter().string(from: Date())])
                try db.execute("COMMIT")
            } catch { _ = try? db.execute("ROLLBACK"); throw error }
        } catch {
            try? fm.removeItem(at: snapshotURL); try? fm.removeItem(at: childURL); throw error
        }
        return try dated(Draft(id: child, path: path, family: source.family, parent: source.id, goal: source.goal, cursor: source.cursor, scroll: source.scroll))
    }
    func rename(_ draft: Draft, name: String) throws {
        let path = try filePath(name: name, folder: draft.folder)
        if path == draft.path { return }
        _ = try dated(draft)
        let old = try url(for: draft.path), new = try url(for: path)
        guard !fm.fileExists(atPath: new.path) else { throw WorkspaceError.message("A file with that name already exists.") }
        try fm.moveItem(at: old, to: new)
        do { try db.execute("UPDATE drafts SET path=? WHERE id=?", [path, draft.id]) }
        catch { try? fm.moveItem(at: new, to: old); throw error }
        try touch(draft)
    }
    func goal(_ draft: Draft, text: String) throws {
        _ = try dated(draft)
        let current = try db.execute("SELECT goal FROM drafts WHERE id=?", [draft.id]).first?["goal"]
        guard current != text else { return }
        try db.execute("UPDATE drafts SET goal=? WHERE id=?", [text, draft.id])
        try touch(draft)
    }
    func position(_ draft: Draft, cursor: Int, scroll: Double) throws {
        try db.execute("UPDATE drafts SET cursor=?, scroll=? WHERE id=?", [String(cursor), String(scroll), draft.id])
    }
    func state(_ key: String) throws -> String? { try db.execute("SELECT value FROM state WHERE key=?", [key]).first?["value"] }
    func setState(_ key: String, _ value: String) throws {
        try db.execute("INSERT INTO state VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key, value])
    }
}
