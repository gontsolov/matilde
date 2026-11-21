import Foundation

extension Workspace {
    public func stashDirectory() throws -> URL {
        var url = root
        for component in [".matilde", "stashes"] {
            url.appendPathComponent(component)
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  url.resolvingSymlinksInPath().path == url.path else {
                throw WorkspaceError.message("Stash storage cannot contain symbolic links.")
            }
        }
        return url
    }
    public func stashURL(_ family: String) throws -> URL {
        guard UUID(uuidString: family) != nil else { throw WorkspaceError.message("Invalid stash identity.") }
        let url = try stashDirectory().appendingPathComponent(family + ".md")
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw WorkspaceError.message("A stash cannot be a symbolic link.")
        }
        return url
    }
    public func readStash(_ family: String) throws -> String {
        let url = try stashURL(family)
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        return try String(contentsOf: url, encoding: .utf8)
    }
    public func saveStash(_ family: String, text: String, expected: String) throws {
        guard try readStash(family) == expected else {
            throw WorkspaceError.message("The stash changed outside Matilde. Your notes are still open. Use Reload Stash from Disk to preserve your changes in a recovery file and load the external version.")
        }
        guard text != expected else { return }
        let url = try stashURL(family)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
