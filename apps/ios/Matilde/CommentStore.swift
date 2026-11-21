import Foundation
import Observation
import MatildeKit

/// IOS-06: private comments on one note, a port of the Mac app's UserCommentStore
/// (apps/macos UserComments.swift). Comments live in the workspace database (`user_comments`),
/// never in the Markdown, and follow their passage through every edit.
@MainActor
@Observable
final class CommentStore {
    static let maximumLength = 8000
    private(set) var comments: [UserComment] = []
    private(set) var body = ""
    @ObservationIgnored private var workspace: Workspace?
    private(set) var draftID: String? = nil
    var error: String? = nil

    func bind(workspace: Workspace?, draftID: String?, body: String) {
        guard self.workspace !== workspace || self.draftID != draftID else {
            changed(workspace: workspace, draftID: draftID, body: body); return
        }
        self.workspace = workspace; self.draftID = draftID; self.body = body
        var loaded: [UserComment] = []
        do { loaded = try draftID.map { try workspace?.userComments(draftID: $0) ?? [] } ?? [] }
        catch { self.error = "Comments couldn’t be loaded." }
        // An empty comment was abandoned while new.
        for comment in loaded where comment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? workspace?.deleteUserComment(comment.id)
        }
        loaded.removeAll { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let anchored = loaded.map { comment -> UserComment in
            if let range = CommentAnchor.relocate(comment, in: body) { return CommentAnchor.refreshed(comment, range: range, in: body) }
            var detached = comment; detached.length = 0
            return detached
        }
        persist(zip(loaded, anchored).filter { $0.0 != $0.1 }.map { $0.1 })
        comments = anchored
    }

    /// Sync changed the database: re-read this note's comments.
    func reload(body: String) {
        guard let workspace, let draftID else { return }
        self.workspace = nil
        bind(workspace: workspace, draftID: draftID, body: body)
    }

    func changed(workspace: Workspace?, draftID: String?, body: String) {
        guard self.workspace === workspace, self.draftID == draftID, body != self.body else { return }
        let previous = self.body
        self.body = body
        guard !comments.isEmpty else { return }
        let edit = WritingEdit.between(previous, body)
        let updated = comments.map { CommentAnchor.track($0, edit: edit, in: body) }
        persist(zip(comments, updated).filter { $0.0 != $0.1 }.map { $0.1 })
        comments = updated
    }

    /// A new, unsaved comment on the selection (or the existing one on exactly that passage).
    /// It is saved once it has text.
    func draft(for range: NSRange) -> UserComment? {
        let source = body as NSString
        guard let draftID, workspace != nil, range.location != NSNotFound, range.length > 0,
              NSMaxRange(range) <= source.length else { return nil }
        let whole = source.rangeOfComposedCharacterSequences(for: range)
        if let existing = comments.first(where: { $0.attached && $0.range == whole }) { return existing }
        let now = Date()
        return CommentAnchor.refreshed(UserComment(id: UUID(), draftID: draftID, text: "", location: 0, length: 0,
                                                   quote: "", prefix: "", suffix: "", created: now, modified: now),
                                       range: whole, in: body)
    }

    /// Saves a comment's text; an empty text deletes it.
    func save(_ comment: UserComment, text: String) {
        let limited = String(text.prefix(Self.maximumLength))
        if limited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { delete(comment.id); return }
        var updated = comments.first(where: { $0.id == comment.id }) ?? comment
        guard updated.text != limited || !comments.contains(where: { $0.id == comment.id }) else { return }
        updated.text = limited
        updated.modified = Date()
        persist([updated])
        if let index = comments.firstIndex(where: { $0.id == updated.id }) { comments[index] = updated }
        else { comments.append(updated); comments.sort { $0.location < $1.location } }
    }

    /// Hides a comment from the note while keeping it in the database.
    func archive(_ id: UUID) {
        do { try workspace?.archiveUserComment(id) }
        catch { self.error = "This comment couldn’t be archived. Your writing is unaffected."; return }
        comments.removeAll { $0.id == id }
    }

    func delete(_ id: UUID) {
        do { try workspace?.deleteUserComment(id) }
        catch { self.error = "This comment couldn’t be deleted. Your writing is unaffected." }
        comments.removeAll { $0.id == id }
    }

    func comment(containing index: Int) -> UserComment? {
        comments.last { $0.attached && index >= $0.location && index < NSMaxRange($0.range) }
    }

    private func persist(_ changed: [UserComment]) {
        let saved = changed.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        do { try workspace?.saveUserComments(saved) }
        catch { self.error = "Comments couldn’t be saved. Your writing is unaffected." }
    }
}
