import Foundation

/// Where deleted writing goes. On the Mac it is the Finder Trash. iOS has no Trash for app files,
/// so there (and on Linux, for tests) the file moves into the workspace's own
/// `.matilde/trash/` folder, from which it can be restored; nothing is deleted outright.
public enum WorkspaceTrash {
    public static func move(_ url: URL) throws {
        #if os(macOS)
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        #else
        try moveIntoWorkspaceTrash(url)
        #endif
    }

    /// The workspace trash folder for a file: `.matilde/trash` in the nearest enclosing folder
    /// that has a `.matilde` folder.
    public static func folder(for url: URL) throws -> URL {
        let fm = FileManager.default
        var directory = url.deletingLastPathComponent()
        while directory.path != "/" && !directory.path.isEmpty {
            let metadata = directory.appendingPathComponent(".matilde", isDirectory: true)
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: metadata.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return metadata.appendingPathComponent("trash", isDirectory: true)
            }
            directory = directory.deletingLastPathComponent()
        }
        throw WorkspaceError.message("This file is not inside a Matilde workspace.")
    }

    public static func moveIntoWorkspaceTrash(_ url: URL) throws {
        let fm = FileManager.default
        let trash = try folder(for: url)
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        var target = trash.appendingPathComponent("\(stamp) \(url.lastPathComponent)")
        var number = 2
        while fm.fileExists(atPath: target.path) {
            target = trash.appendingPathComponent("\(stamp) \(number) \(url.lastPathComponent)"); number += 1
        }
        try fm.moveItem(at: url, to: target)
    }
}
