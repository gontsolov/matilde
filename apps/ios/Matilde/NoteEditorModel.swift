import Foundation
import Observation
import UIKit
import MatildeKit

/// One open note: its text, title and goal, autosave, private comments and Ask Matilde threads.
/// The text view (`NoteTextView`) reports edits here; accepted rewrites go back through it so
/// they can be undone.
@MainActor
@Observable
final class NoteEditorModel {
    enum Sheet: Identifiable, Equatable {
        case comments
        case comment(UserComment)
        case thread(runID: UUID, commentID: UUID)
        var id: String {
            switch self {
            case .comments: return "comments"
            case .comment(let comment): return "comment-" + comment.id.uuidString
            case .thread(_, let commentID): return "thread-" + commentID.uuidString
            }
        }
    }

    static let saveDelay: Duration = .milliseconds(800)

    let library: NoteLibrary
    private(set) var draft: Draft
    var title: String { didSet { if title != oldValue { headerChanged() } } }
    var goal: String { didSet { if goal != oldValue { headerChanged() } } }
    private(set) var text: String
    /// Bumped when the text was replaced from outside the text view (sync), so it reloads.
    private(set) var externalRevision = 0
    let comments = CommentStore()
    @ObservationIgnored let review: WritingReviewModel
    var sheet: Sheet? = nil
    var selection = NSRange(location: 0, length: 0)
    /// Set when the note disappeared (deleted on another device).
    private(set) var gone = false
    /// How far the big title has scrolled under the top bar: 0 fully visible, 1 gone. The small
    /// title in the navigation bar fades in with it.
    var titleProgress: Double = 0

    @ObservationIgnored weak var textView: UITextView?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var bodyDirty = false
    @ObservationIgnored private var headerDirty = false
    @ObservationIgnored private var loading = false

    init(library: NoteLibrary, draft: Draft, review: WritingReviewModel? = nil) {
        self.library = library
        self.draft = draft
        self.title = library.displayTitle(draft)
        self.goal = draft.goal
        self.text = library.text(of: draft)
        self.review = review ?? WritingReviewModel()
        self.review.automaticAllowed = { false }
        self.review.bind(workspace: library.workspace, draftID: draft.id, input: input)
        comments.bind(workspace: library.workspace, draftID: draft.id, body: text)
    }

    var input: ReviewInput { ReviewInput(title: title.isEmpty ? draft.title : title, goal: goal, body: text) }

    /// Tapping the small title: back to the top of the note.
    func scrollToTop() {
        guard let textView else { return }
        textView.setContentOffset(CGPoint(x: 0, y: -textView.adjustedContentInset.top), animated: true)
    }

    // MARK: Editing

    /// The text view changed the writing.
    func textChanged(_ new: String) {
        guard new != text else { return }
        text = new
        bodyDirty = true
        comments.changed(workspace: library.workspace, draftID: draft.id, body: text)
        review.invalidate(input)
        scheduleSave()
    }

    private func headerChanged() {
        guard !loading else { return }
        headerDirty = true
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Saves now (leaving the note, the app going to the background, before a sync).
    func flush() {
        saveTask?.cancel(); saveTask = nil
        guard !gone else { return }
        if bodyDirty {
            bodyDirty = false
            library.save(draft, text: text)
        }
        if headerDirty {
            headerDirty = false
            if let renamed = library.rename(draft, to: title) { draft = renamed }
            library.setGoal(draft, to: goal)
            if let fresh = library.draft(id: draft.id) { draft = fresh }
        }
    }

    /// Sync applied changes: pick up the new text, title, goal, comments and threads.
    func remoteChanged() {
        guard let fresh = library.draft(id: draft.id) else { gone = true; return }
        guard !bodyDirty, !headerDirty else { return }
        loading = true
        draft = fresh
        title = library.displayTitle(fresh)
        goal = fresh.goal
        loading = false
        let current = library.text(of: fresh)
        if current != text {
            text = current
            externalRevision += 1
            comments.changed(workspace: library.workspace, draftID: draft.id, body: text)
        }
        comments.reload(body: text)
        review.reload()
        review.invalidate(input)
    }

    // MARK: Comments and threads

    /// The open Ask Matilde threads anchored in the current text.
    var threads: [(runID: UUID, comment: ReviewComment)] {
        guard let run = review.history.first, !run.stale else { return [] }
        return run.comments.filter { $0.status == "open" && $0.matches(text) }.map { (run.id, $0) }
    }

    func commentOnSelection() {
        guard let comment = comments.draft(for: selection) else { return }
        sheet = .comment(comment)
    }

    func askMatildeOnSelection() {
        guard selection.length > 0 else { return }
        flush()
        review.beginSelection(selection, input: input)
        guard let run = review.history.first, let id = review.focusedCommentID else { return }
        sheet = .thread(runID: run.id, commentID: id)
    }

    /// Ask Matilde to read the whole note and leave threads where it has suggestions.
    func reviewNote() {
        flush()
        review.start(input: input)
    }

    /// A tap in the text: open the comment or thread under it.
    func tapped(at index: Int) {
        if let thread = threads.last(where: { index >= $0.comment.location && index < NSMaxRange($0.comment.range) }) {
            sheet = .thread(runID: thread.runID, commentID: thread.comment.id)
        } else if let comment = comments.comment(containing: index) {
            sheet = .comment(comment)
        }
    }

    /// The passage the open comment or thread sheet is about, highlighted while it is open.
    var sheetPassage: NSRange? {
        let range: NSRange?
        switch sheet {
        case .comment(let comment): range = comment.attached ? comment.range : nil
        case .thread(let runID, let commentID):
            range = review.history.first { $0.id == runID }?.comments.first { $0.id == commentID }?.range
        case .comments, nil: range = nil
        }
        guard let range, range.length > 0, NSMaxRange(range) <= (text as NSString).length else { return nil }
        return range
    }

    /// A comment or thread sheet opened: scroll its passage above the sheet.
    func revealSheetPassage() {
        guard let range = sheetPassage else { return }
        (textView as? NoteUITextView)?.reveal(range)
    }

    func select(_ range: NSRange) {
        guard let textView, NSMaxRange(range) <= (textView.text as NSString).length else { return }
        textView.becomeFirstResponder()
        textView.selectedRange = range
        textView.scrollRangeToVisible(range)
    }

    /// Replaces the passage with Matilde's rewrite through the text view, so Undo restores it.
    func accept(runID: UUID, commentID: UUID) {
        guard let textView, textView.text == text,
              let run = review.history.first(where: { $0.id == runID }), run.draftID == draft.id, !run.stale,
              run.revision == WritingReview.revision(input),
              let comment = run.comments.first(where: { $0.id == commentID }), comment.status == "open",
              let replacement = comment.suggestion.replacement, comment.rewriteApplies, comment.matches(text),
              let start = textView.position(from: textView.beginningOfDocument, offset: comment.range.location),
              let end = textView.position(from: start, offset: comment.range.length),
              let range = textView.textRange(from: start, to: end) else {
            review.fail("The passage has changed. Review the current note before accepting a rewrite.")
            return
        }
        let expected = (text as NSString).replacingCharacters(in: comment.range, with: replacement)
        textView.replace(range, withText: replacement)
        textChanged(textView.text)
        guard text == expected else { review.fail("The rewrite couldn’t be applied. The thread is still available."); return }
        review.setStatus("accepted", runID: runID, commentID: commentID)
        review.invalidate(input)
    }

    // MARK: Formatting (keyboard bar)

    enum Format { case heading, bold, italic, list, quote, indent, outdent }

    func apply(_ format: Format) {
        guard let textView, let selected = textView.selectedTextRange else { return }
        if format == .indent || format == .outdent {
            // Nesting follows the shared rules (MatildeKit's MarkdownEditing), as Tab does.
            let selection = textView.selectedRange
            let edit = format == .indent ? MarkdownEditing.indent(in: textView.text, selection: selection)
                : MarkdownEditing.outdent(in: textView.text, selection: selection)
            if let edit, let view = textView as? NoteUITextView { view.applyMarkdownEdit(edit) }
            return
        }
        let source = textView.text as NSString
        let range = textView.selectedRange
        switch format {
        case .bold, .italic:
            let mark = format == .bold ? "**" : "*"
            let inner = source.substring(with: range)
            textView.replace(selected, withText: mark + inner + mark)
            textView.selectedRange = NSRange(location: range.location + mark.count, length: (inner as NSString).length)
        case .indent, .outdent:
            return
        case .heading, .list, .quote:
            let line = source.lineRange(for: NSRange(location: range.location, length: 0))
            let current = source.substring(with: line)
            let prefix = format == .heading ? "# " : format == .list ? "- " : "> "
            let replaced: String
            if format == .heading, let match = current.range(of: "^#{1,5} ", options: .regularExpression) {
                // Each tap goes one level smaller, up to ######.
                replaced = "#" + String(current[match]) + String(current[match.upperBound...])
            } else if format == .heading, current.hasPrefix("###### ") {
                replaced = String(current.dropFirst(7))
            } else if current.hasPrefix(prefix) {
                replaced = String(current.dropFirst(prefix.count))
            } else {
                replaced = prefix + current
            }
            guard let start = textView.position(from: textView.beginningOfDocument, offset: line.location),
                  let end = textView.position(from: start, offset: line.length),
                  let lineRange = textView.textRange(from: start, to: end) else { return }
            textView.replace(lineRange, withText: replaced)
            let delta = (replaced as NSString).length - line.length
            textView.selectedRange = NSRange(location: max(line.location, range.location + delta), length: range.length)
        }
        textChanged(textView.text)
    }

    // MARK: Export

    /// The note as Markdown, with its title as the first heading.
    var markdownForSharing: String {
        let heading = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return heading.isEmpty ? text : "# \(heading)\n\n\(text)"
    }
}
