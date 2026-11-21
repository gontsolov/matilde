import Foundation

/// Moving notes between workspace folders keeps draft identity, family,
/// snapshots and `.assets` image references intact. Existing files are never replaced.
extension Workspace {
    /// Drafts shown as one sidebar row: the family members stored in the row's folder.
    public func movableNote(family: String, folder: String) throws -> [Draft] {
        try allDrafts().filter { $0.family == family && $0.folder == folder }
            .filter { FileManager.default.fileExists(atPath: (try? url(for: $0.path).path) ?? "") }
    }

    public func validFolder(_ folder: String) throws -> URL {
        if folder.isEmpty { return root }
        guard !folder.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else {
            throw WorkspaceError.message("Notes can only move into visible folders.")
        }
        let target = try url(for: folder)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorkspaceError.message("That folder is no longer available.")
        }
        return target
    }

    /// The first free `Title.md`, `Title 2.md`, … in `folder`, avoiding files on disk,
    /// metadata rows and paths already reserved by the same move.
    public func availablePath(title: String, folder: String, reserved: Set<String> = []) throws -> String {
        let taken = Set(try allDrafts().map(\.path)).union(reserved)
        var name = title
        var number = 2
        while true {
            let path = try filePath(name: name, folder: folder)
            if !taken.contains(path), !FileManager.default.fileExists(atPath: try url(for: path).path) { return path }
            name = "\(title) \(number)"; number += 1
        }
    }

    /// Relative `.assets/…` image references written by Matilde.
    public static func assetReferences(in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: #"!\[[^\]\n]*\]\(([^\s)]+)\)"#) else { return [] }
        let source = text as NSString
        var references: [String] = []
        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard let decoded = source.substring(with: match.range(at: 1)).removingPercentEncoding,
                  decoded.hasPrefix(".assets/"), !decoded.contains(":"),
                  decoded.split(separator: "/", omittingEmptySubsequences: false).count == 2,
                  !decoded.hasSuffix("/") else { continue }
            if !references.contains(decoded) { references.append(decoded) }
        }
        return references
    }

    /// Move `drafts` into `folder`. Returns the new path for each moved draft id.
    /// Referenced images are copied, not moved, because other drafts and snapshots may share them.
    @discardableResult
    public func move(_ drafts: [Draft], to folder: String,
              moveItem: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) throws -> [String: String] {
        let fm = FileManager.default
        _ = try validFolder(folder)
        let pending = drafts.filter { $0.folder != folder }
        guard !pending.isEmpty else { return [:] }

        var plan: [(draft: Draft, from: URL, to: URL, path: String)] = []
        var reserved: Set<String> = []
        for draft in pending {
            let from = try url(for: draft.path)
            guard fm.fileExists(atPath: from.path) else { throw WorkspaceError.message("‘\(draft.title)’ is no longer on disk.") }
            let path = try availablePath(title: draft.title, folder: folder, reserved: reserved)
            reserved.insert(path)
            let to = try url(for: path)
            plan.append((draft: draft, from: from, to: to, path: path))
        }

        // Check every asset before changing anything.
        var assets: [(from: URL, to: URL)] = []
        for item in plan {
            for reference in Self.assetReferences(in: try read(item.draft)) {
                let source = try url(for: item.draft.folder.isEmpty ? reference : item.draft.folder + "/" + reference)
                guard fm.fileExists(atPath: source.path) else { continue }
                let target = try url(for: folder.isEmpty ? reference : folder + "/" + reference)
                if assets.contains(where: { $0.to == target }) { continue }
                if fm.fileExists(atPath: target.path) {
                    guard fm.contentsEqual(atPath: source.path, andPath: target.path) else {
                        throw WorkspaceError.message("A different image named \(target.lastPathComponent) already exists in that folder.")
                    }
                    continue
                }
                assets.append((from: source, to: target))
            }
        }

        var copied: [URL] = []
        var createdDirectories: [URL] = []
        var moved: [(from: URL, to: URL)] = []
        try db.execute("BEGIN IMMEDIATE")
        do {
            for asset in assets {
                let directory = asset.to.deletingLastPathComponent()
                if !fm.fileExists(atPath: directory.path) {
                    try fm.createDirectory(at: directory, withIntermediateDirectories: false)
                    createdDirectories.append(directory)
                }
                try fm.copyItem(at: asset.from, to: asset.to)
                copied.append(asset.to)
            }
            for item in plan {
                try db.execute("UPDATE drafts SET path=? WHERE id=?", [item.path, item.draft.id])
                guard !fm.fileExists(atPath: item.to.path) else {
                    throw WorkspaceError.message("A file with that name already exists.")
                }
                try moveItem(item.from, item.to)
                moved.append((from: item.from, to: item.to))
            }
            try db.execute("COMMIT")
        } catch {
            for item in moved.reversed() { try? fm.moveItem(at: item.to, to: item.from) }
            for file in copied { try? fm.removeItem(at: file) }
            for directory in createdDirectories.reversed() { try? fm.removeItem(at: directory) }
            _ = try? db.execute("ROLLBACK")
            throw error
        }
        return Dictionary(uniqueKeysWithValues: plan.map { ($0.draft.id, $0.path) })
    }
}
