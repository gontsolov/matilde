import Foundation
import Testing
import UIKit
import MatildeKit
@testable import Matilde

@MainActor
struct MarkdownStyleTests {
    private func kinds(_ text: String) -> [MarkdownStyle.Kind] { MarkdownStyle.spans(in: text).map(\.kind) }

    @Test func headingsAndTheirMarks() {
        let spans = MarkdownStyle.spans(in: "## Two\nBody")
        #expect(spans.contains(MarkdownStyle.Span(kind: .heading(2), range: NSRange(location: 0, length: 6))))
        #expect(spans.contains(MarkdownStyle.Span(kind: .hiddenMark, range: NSRange(location: 0, length: 3))))
        #expect(!kinds("#Not a heading").contains(.heading(1)))
    }

    @Test func headingMarksShowOnlyWhileTheHeadingIsEmpty() {
        #expect(MarkdownStyle.spans(in: "## ").contains(MarkdownStyle.Span(kind: .mark, range: NSRange(location: 0, length: 3))))
        #expect(!kinds("##  ").contains(.hiddenMark))
        #expect(MarkdownStyle.spans(in: "Body\n### Three").contains(MarkdownStyle.Span(kind: .hiddenMark, range: NSRange(location: 5, length: 4))))
    }

    @Test func hiddenHeadingMarkerForBackspace() {
        let text = "Intro\n# One\n## \n```\n# code\n```"
        #expect(MarkdownStyle.hiddenHeadingMarker(in: text, at: 8) == NSRange(location: 6, length: 2))
        #expect(MarkdownStyle.hiddenHeadingMarker(in: text, at: 11) == NSRange(location: 6, length: 2))
        #expect(MarkdownStyle.hiddenHeadingMarker(in: text, at: 2) == nil)
        #expect(MarkdownStyle.hiddenHeadingMarker(in: text, at: 15) == nil)
        #expect(MarkdownStyle.hiddenHeadingMarker(in: text, at: 22) == nil)
    }

    @Test func boldIsNotAlsoItalic() {
        let spans = MarkdownStyle.spans(in: "a **bold** b *soft*")
        #expect(spans.contains(MarkdownStyle.Span(kind: .bold, range: NSRange(location: 4, length: 4))))
        #expect(spans.contains(MarkdownStyle.Span(kind: .italic, range: NSRange(location: 14, length: 4))))
        #expect(spans.filter { $0.kind == .italic }.count == 1)
    }

    @Test func codeIsNotEmphasised() {
        #expect(!kinds("`*x*`").contains(.italic))
        #expect(kinds("```\n*x*\n```").filter { $0 == .italic }.isEmpty)
    }

    @Test func linksQuotesAndLists() {
        let spans = MarkdownStyle.spans(in: "> q\n- item\n[label](https://matilde.page)")
        #expect(spans.contains { $0.kind == .quote })
        #expect(spans.contains(MarkdownStyle.Span(kind: .listMarker, range: NSRange(location: 4, length: 2))))
        #expect(spans.contains(MarkdownStyle.Span(kind: .link, range: NSRange(location: 12, length: 5))))
    }

    @Test func nestedItemsAreIndentedByDepth() {
        let spans = MarkdownStyle.spans(in: "- one\n   1. two\n- [ ] three")
        #expect(spans.contains(MarkdownStyle.Span(kind: .listItem(depth: 0, marker: "- "), range: NSRange(location: 0, length: 5))))
        #expect(spans.contains(MarkdownStyle.Span(kind: .hiddenMark, range: NSRange(location: 6, length: 3))))
        #expect(spans.contains(MarkdownStyle.Span(kind: .listMarker, range: NSRange(location: 9, length: 3))))
        #expect(spans.contains(MarkdownStyle.Span(kind: .listItem(depth: 1, marker: "1. "), range: NSRange(location: 6, length: 9))))
        #expect(spans.contains(MarkdownStyle.Span(kind: .listItem(depth: 0, marker: "- [ ] "), range: NSRange(location: 16, length: 11))))
        let storage = NSTextStorage(string: "- one\n   1. two")
        MarkdownStyle.apply(to: storage)
        let nested = storage.attribute(.paragraphStyle, at: 6, effectiveRange: nil) as? NSParagraphStyle
        #expect(nested?.firstLineHeadIndent == MarkdownStyle.listIndent)
        #expect((nested?.headIndent ?? 0) > MarkdownStyle.listIndent)
    }

    @Test func caretIsKeptOutOfHiddenIndentation() {
        let text = "- one\n    - two\n```\n  - code\n```"
        #expect(MarkdownStyle.hiddenListIndent(in: text, at: 8) == NSRange(location: 6, length: 4))
        #expect(MarkdownStyle.hiddenLineStart(in: text, at: 6) == NSRange(location: 6, length: 4))
        #expect(MarkdownStyle.hiddenListIndent(in: text, at: 2) == nil)
        #expect(MarkdownStyle.hiddenListIndent(in: text, at: 22) == nil)
    }

    @Test func headingSizesFollowTheMacScale() {
        #expect(MarkdownStyle.textSize == 20)
        #expect(MarkdownStyle.headingSize(level: 1) == 28.5)
        #expect(MarkdownStyle.headingSize(level: 4) == 20)
    }

    @Test func stylingNeverChangesTheText() {
        let text = "# Title\n**bold** and *soft* `code` [l](https://x.y)"
        let storage = NSTextStorage(string: text)
        MarkdownStyle.apply(to: storage)
        #expect(storage.string == text)
    }
}

@MainActor
struct CommentStoreTests {
    @Test func commentsFollowTheirPassage() throws {
        let library = try makeLibrary()
        let draft = try #require(library.create())
        library.save(draft, text: "One two three")
        let store = CommentStore()
        store.bind(workspace: library.workspace, draftID: draft.id, body: "One two three")
        let new = try #require(store.draft(for: NSRange(location: 4, length: 3)))
        #expect(new.quote == "two")
        store.save(new, text: "Better word?")
        #expect(store.comments.count == 1)
        store.changed(workspace: library.workspace, draftID: draft.id, body: "Well, one two three")
        #expect(store.comments.first?.range == NSRange(location: 10, length: 3))
        // Saved in the database, not the Markdown.
        let reloaded = CommentStore()
        reloaded.bind(workspace: library.workspace, draftID: draft.id, body: "Well, one two three")
        #expect(reloaded.comments.first?.text == "Better word?")
        #expect(library.text(of: try #require(library.draft(id: draft.id))) == "One two three")
    }

    @Test func emptyTextDeletesAndArchiveHides() throws {
        let library = try makeLibrary()
        let draft = try #require(library.create())
        let store = CommentStore()
        store.bind(workspace: library.workspace, draftID: draft.id, body: "Alpha beta")
        let first = try #require(store.draft(for: NSRange(location: 0, length: 5)))
        store.save(first, text: "x")
        store.save(first, text: "  ")
        #expect(store.comments.isEmpty)
        let second = try #require(store.draft(for: NSRange(location: 6, length: 4)))
        store.save(second, text: "keep")
        store.archive(second.id)
        #expect(store.comments.isEmpty)
        #expect(store.comment(containing: 7) == nil)
    }
}

@MainActor
struct NoteEditorModelTests {
    @Test func editsTrackCommentsAndAutosaveOnFlush() throws {
        let library = try makeLibrary()
        let draft = try #require(library.create())
        library.save(draft, text: "Hello world")
        let model = NoteEditorModel(library: library, draft: try #require(library.draft(id: draft.id)))
        #expect(model.text == "Hello world")
        model.textChanged("Hello, world")
        model.title = "Greeting"
        model.goal = "Be friendly"
        model.flush()
        let saved = try #require(library.draft(id: draft.id))
        #expect(saved.title == "Greeting")
        #expect(saved.goal == "Be friendly")
        #expect(library.text(of: saved) == "Hello, world")
        #expect(model.markdownForSharing == "# Greeting\n\nHello, world")
    }

    @Test func askMatildeOnASelectionOpensAThread() throws {
        let library = try makeLibrary()
        let draft = try #require(library.create())
        library.save(draft, text: "A sentence to improve.")
        let model = NoteEditorModel(library: library, draft: try #require(library.draft(id: draft.id)))
        model.selection = NSRange(location: 2, length: 8)
        model.askMatildeOnSelection()
        guard case .thread(_, let id) = model.sheet else { Issue.record("no thread sheet"); return }
        #expect(model.threads.map(\.comment.id) == [id])
        #expect(model.threads.first?.comment.suggestion.quote == "sentence")
    }

    @Test func exportFileNames() {
        #expect(MarkdownExport.fileName(for: "A letter") == "A letter.md")
        #expect(MarkdownExport.fileName(for: " ") == "Untitled.md")
        #expect(MarkdownExport.fileName(for: "a/b:c") == "a-b-c.md")
    }
}

@MainActor
struct SyncControllerTests {
    @Test func startsSignedOutOnProduction() {
        let defaults = UserDefaults(suiteName: "MatildeTests-\(UUID().uuidString)")!
        let sync = SyncController(defaults: defaults, startsAutomatically: false)
        #expect(sync.phase == .signedOut)
        #expect(!sync.isSignedIn)
        #expect(sync.statusText == "Waiting")
    }

    @Test func friendlyMessages() {
        #expect(SyncController.message(for: URLError(.notConnectedToInternet)) == "You’re offline.")
        #expect(SyncController.message(for: SyncCryptoError.invalidRecoveryCode) == "That Matilde key doesn’t look right.")
    }
}
