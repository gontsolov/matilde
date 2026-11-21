import Foundation

/// Pure decisions behind the sidebar context menus.
public enum SidebarActions {
    /// Drafts stored in `folder` or any of its subfolders.
    public static func drafts(in folder: String, among drafts: [Draft]) -> [Draft] {
        guard !folder.isEmpty else { return drafts }
        return drafts.filter { $0.folder == folder || $0.folder.hasPrefix(folder + "/") }
    }

    /// Sidebar note rows inside `folder` and its subfolders: one per draft family per folder.
    public static func noteCount(in folder: String, among drafts: [Draft]) -> Int {
        Set(Self.drafts(in: folder, among: drafts).map { $0.folder + "\u{0}" + $0.family }).count
    }

    /// Folders a note in `current` can move to: the workspace root ("Documents") first, then
    /// every other folder in sidebar order.
    public static func moveTargets(folders: [String], from current: String) -> [String] {
        ([""] + folders.filter { !$0.isEmpty }).filter { $0 != current }
    }

    /// The note to open after `removed` notes leave the sidebar: `current` if it stays, otherwise
    /// the next remaining note below it, then the nearest one above, in the visible `order`.
    public static func successor(of current: String?, removing removed: Set<String>, in order: [String]) -> String? {
        guard let current, let index = order.firstIndex(of: current) else {
            return order.first { !removed.contains($0) }
        }
        if !removed.contains(current) { return current }
        if let next = order[(index + 1)...].first(where: { !removed.contains($0) }) { return next }
        return order[..<index].last { !removed.contains($0) }
    }

    /// The folder path after renaming `folder`'s last component to `name`.
    public static func renamedFolder(_ folder: String, to name: String) -> String {
        let parent = (folder as NSString).deletingLastPathComponent
        return parent.isEmpty || parent == "." ? name : parent + "/" + name
    }

    /// `path` inside `folder` rewritten to live inside `renamed`. Paths outside `folder` stay.
    public static func path(_ path: String, movingFolder folder: String, to renamed: String) -> String {
        if path == folder { return renamed }
        guard path.hasPrefix(folder + "/") else { return path }
        return renamed + path.dropFirst(folder.count)
    }
}

/// Folder rename, folder Trash and note duplication. Same safety rules as single-draft Trash
/// and note moves: native macOS Trash only, metadata archived, rollback on failure.
extension Workspace {
    /// A new, independent note beside `draft` with the same text and goal.
    public func duplicate(_ draft: Draft, text: String) throws -> Draft {
        let path = try availablePath(title: draft.title + " copy", folder: draft.folder)
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return try create(name: name, folder: draft.folder, goal: draft.goal, text: text)
    }

    /// Rename the last component of `folder`. Returns the new folder path.
    @discardableResult
    public func renameFolder(_ folder: String, to name: String,
                      moveItem: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) throws -> String {
        let fm = FileManager.default
        guard !folder.isEmpty else { throw WorkspaceError.message("The workspace folder cannot be renamed here.") }
        let source = try validFolder(folder)
        let renamed = SidebarActions.renamedFolder(folder, to: try validName(name))
        guard renamed != folder else { return folder }
        let target = try url(for: renamed)
        // A case-only rename points at the same folder on case-insensitive volumes.
        if renamed.lowercased() != folder.lowercased(), fm.fileExists(atPath: target.path) {
            throw WorkspaceError.message("That folder already exists.")
        }
        let contained = SidebarActions.drafts(in: folder, among: try allDrafts())
        var moved = false
        try db.execute("BEGIN IMMEDIATE")
        do {
            for draft in contained {
                try db.execute("UPDATE drafts SET path=? WHERE id=?",
                               [SidebarActions.path(draft.path, movingFolder: folder, to: renamed), draft.id])
            }
            try moveItem(source, target)
            moved = true
            try db.execute("COMMIT")
        } catch {
            if moved { try? fm.moveItem(at: target, to: source) }
            _ = try? db.execute("ROLLBACK")
            throw error
        }
        return renamed
    }

    /// Move `folder` and everything in it to the macOS Trash. Every draft inside is archived in
    /// `trashed_drafts` like a single-draft Trash; drafts outside reconnect to the nearest
    /// surviving ancestor. Returns the drafts that were removed.
    @discardableResult
    public func trashFolder(_ folder: String, move: (URL) throws -> Void = { url in
        try WorkspaceTrash.move(url)
    }) throws -> [Draft] {
        guard !folder.isEmpty else { throw WorkspaceError.message("The workspace folder cannot be moved to the Trash.") }
        let directory = try validFolder(folder)
        let contained = SidebarActions.drafts(in: folder, among: try allDrafts())
        try db.execute("CREATE TABLE IF NOT EXISTS trashed_drafts AS SELECT *, '' AS trashed_at FROM drafts WHERE 0")
        let trashedAt = ISO8601DateFormatter().string(from: Date())
        try db.execute("BEGIN IMMEDIATE")
        do {
            for draft in contained {
                try db.execute("INSERT INTO trashed_drafts SELECT *, ? FROM drafts WHERE id=?", [trashedAt, draft.id])
                // Read the parent from the database: an earlier removal in this loop may have changed it.
                try db.execute("UPDATE drafts SET parent=(SELECT parent FROM drafts WHERE id=?) WHERE parent=?", [draft.id, draft.id])
                try db.execute("DELETE FROM drafts WHERE id=?", [draft.id])
            }
            try move(directory)
            try db.execute("COMMIT")
        } catch {
            _ = try? db.execute("ROLLBACK")
            throw error
        }
        return contained
    }
}
