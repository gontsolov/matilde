import Foundation
import Observation
import MatildeKit

/// IOS-04: the notes on this phone. A MatildeKit `Workspace` (Markdown files plus the SQLite
/// store, the same layout as on the Mac) in Application Support, filled and kept current by sync.
/// It is not exposed in the Files app: sync is the only way notes come and go.
@MainActor
@Observable
final class NoteLibrary {
    struct Section: Identifiable, Equatable {
        let folder: String
        var drafts: [Draft]
        var id: String { folder }
        var title: String { folder.isEmpty ? "Notes" : folder }
    }

    private(set) var workspace: Workspace? = nil
    private(set) var drafts: [Draft] = []
    private(set) var folders: [String] = [""]
    var error: String? = nil
    /// Bumped whenever sync changed the files or the database, so an open note reloads.
    private(set) var remoteRevision = 0

    /// A local change was saved (wired to `SyncController.localChange`).
    @ObservationIgnored var onLocalChange: (@MainActor () -> Void)?
    /// Saves the open note before sync reads the files (set by the open editor).
    @ObservationIgnored var flushOpenNote: (@MainActor () -> Void)?
    @ObservationIgnored private var bodies: [String: (edited: Date?, text: String)] = [:]

    /// `Application Support/Matilde/Notes`.
    static var defaultRoot: URL {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Matilde/Notes", isDirectory: true)
    }

    init(root: URL? = NoteLibrary.defaultRoot, storeBase: URL = WorkspaceStore.defaultBase) {
        guard let root else { return }
        do {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(".matilde", isDirectory: true), withIntermediateDirectories: true)
            workspace = try Workspace(root: root, storeBase: storeBase)
            try workspace?.ensureUserComments()
            reload()
        } catch {
            self.error = "Your notes couldn’t be opened on this iPhone."
            NSLog("Matilde: couldn’t open the workspace (%@)", String(describing: type(of: error)))
        }
    }

    var root: URL? { workspace?.root }

    // MARK: Reading

    func reload() {
        guard let workspace else { return }
        do {
            let scanned = try workspace.scan()
            drafts = scanned.drafts
            folders = scanned.folders
        } catch {
            self.error = "Your notes couldn’t be read."
        }
    }

    /// Sync applied records: re-read the list and tell an open note.
    func remoteChangesApplied() {
        bodies = [:]
        reload()
        remoteRevision += 1
    }

    func draft(id: Draft.ID?) -> Draft? {
        guard let id else { return nil }
        return drafts.first { $0.id == id }
    }

    func text(of draft: Draft) -> String {
        if let cached = bodies[draft.id], cached.edited == draft.editedAt { return cached.text }
        let text = (try? workspace?.read(draft)) ?? ""
        bodies[draft.id] = (draft.editedAt, text)
        return text
    }

    /// The title a note shows: empty for a new note whose name was never set.
    func displayTitle(_ draft: Draft) -> String {
        isUntitled(draft) ? "" : draft.title
    }

    func isUntitled(_ draft: Draft) -> Bool {
        (try? workspace?.state("untitled:\(draft.id)")) == "true"
    }

    /// The first line of writing, for the list.
    func preview(of draft: Draft) -> String {
        Self.preview(text(of: draft))
    }

    nonisolated static func preview(_ text: String) -> String {
        for line in text.split(whereSeparator: \.isNewline) {
            var value = line.trimmingCharacters(in: .whitespaces)
            while let first = value.first, "#>-*+".contains(first) { value.removeFirst() }
            value = value.trimmingCharacters(in: .whitespaces)
            if !value.isEmpty, !value.hasPrefix("![") { return String(value.prefix(160)) }
        }
        return ""
    }

    /// Newest first, like the Mac sidebar (UI-09), filtered by title, goal and text.
    func sorted(matching query: String = "") -> [Draft] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return drafts
            .filter { draft in
                trimmed.isEmpty || draft.title.localizedStandardContains(trimmed)
                    || draft.goal.localizedStandardContains(trimmed) || text(of: draft).localizedStandardContains(trimmed)
            }
            .sorted { ($0.editedAt ?? .distantPast) > ($1.editedAt ?? .distantPast) }
    }

    /// Folder sections: top-level notes first, then folders alphabetically; newest first inside.
    func sections(matching query: String = "") -> [Section] {
        var grouped: [String: [Draft]] = [:]
        for draft in sorted(matching: query) { grouped[draft.folder, default: []].append(draft) }
        return grouped.keys
            .sorted { $0.isEmpty != $1.isEmpty ? $0.isEmpty : $0.localizedStandardCompare($1) == .orderedAscending }
            .map { Section(folder: $0, drafts: grouped[$0] ?? []) }
    }

    // MARK: Changes

    func create(folder: String = "") -> Draft? {
        attempt("The note couldn’t be created.") { () -> Draft? in
            guard let workspace else { return nil }
            let draft = try workspace.createUntitled(folder: folder)
            reload()
            onLocalChange?()
            return draft
        } ?? nil
    }

    func save(_ draft: Draft, text: String) {
        attempt("Your changes couldn’t be saved.") {
            guard let workspace else { return }
            guard (try? workspace.read(draft)) != text else { return }
            try workspace.save(draft, text: text)
            bodies[draft.id] = nil
            refresh(draft.id)
            onLocalChange?()
        }
    }

    /// Renames the file; an empty title leaves an untitled note alone. Returns the updated draft.
    @discardableResult
    func rename(_ draft: Draft, to title: String) -> Draft? {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return draft }
        return attempt("The note couldn’t be renamed. Use a name without slashes or colons that no other note in this folder has.") { () -> Draft in
            guard let workspace else { return draft }
            if name != draft.title || isUntitled(draft) {
                try workspace.rename(draft, name: name)
                try workspace.setState("untitled:\(draft.id)", "false")
                reload()
                onLocalChange?()
            }
            return self.draft(id: draft.id) ?? draft
        } ?? draft
    }

    func setGoal(_ draft: Draft, to goal: String) {
        attempt("The goal couldn’t be saved.") {
            guard let workspace, goal != draft.goal else { return }
            try workspace.goal(draft, text: goal)
            refresh(draft.id)
            onLocalChange?()
        }
    }

    func trash(_ draft: Draft) {
        attempt("The note couldn’t be deleted.") {
            try workspace?.trash(draft)
            bodies[draft.id] = nil
            reload()
            onLocalChange?()
        }
    }

    func createFolder(named name: String) {
        attempt("The folder couldn’t be created. Use a name without slashes or colons.") {
            try workspace?.createFolder(name: name, parent: "")
            reload()
        }
    }

    private func refresh(_ id: String) {
        guard let workspace, let fresh = try? workspace.allDrafts().first(where: { $0.id == id }),
              let index = drafts.firstIndex(where: { $0.id == id }) else { reload(); return }
        drafts[index] = fresh
    }

    private func attempt<T>(_ message: String, _ body: () throws -> T) -> T? {
        do { return try body() } catch {
            self.error = (error as? WorkspaceError)?.errorDescription ?? message
            return nil
        }
    }
}
