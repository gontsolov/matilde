import XCTest
import AppKit
@testable import Matilde

@MainActor
final class EditorInteractionTests: XCTestCase {
    private func editor(_ text: String, selection: NSRange? = nil) -> WritingTextView {
        let view = WritingTextView(frame: NSRect(x: 0, y: 0, width: 680, height: 500))
        view.isRichText = false
        view.allowsUndo = true
        view.string = text
        view.setSelectedRange(selection ?? NSRange(location: (text as NSString).length, length: 0))
        return view
    }

    func testBoldTogglesWithoutLosingUnicodeSelection() {
        let view = editor("Hello 日本語 🌱", selection: NSRange(location: 6, length: 6))
        view.wrap("**")
        XCTAssertEqual(view.string, "Hello **日本語 🌱**")
        XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "日本語 🌱")
        view.wrap("**")
        XCTAssertEqual(view.string, "Hello 日本語 🌱")
    }

    func testItalicInsideBoldDoesNotRemoveBoldMarkers() {
        let view = editor("**word**", selection: NSRange(location: 2, length: 4))
        view.wrap("*")
        XCTAssertEqual(view.string, "***word***")
        view.wrap("*")
        XCTAssertEqual(view.string, "**word**")
    }

    func testFormattingEntireMarkedSelectionTogglesOff() {
        let view = editor("**word**", selection: NSRange(location: 0, length: 8))
        view.wrap("**")
        XCTAssertEqual(view.string, "word")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 4))
    }

    func testTypingDuringInitialLayoutIsReported() {
        var reported = ""
        let parent = MarkdownEditor(draftID: "test", text: "Hello", initialCursor: 5, initialScroll: 0,
                                    onChange: { reported = $0 }, onPosition: { _, _ in })
        let coordinator = parent.makeCoordinator()
        let view = editor("Hello")
        let scroll = NSScrollView()
        scroll.documentView = view
        coordinator.view = view; coordinator.scroll = scroll
        view.delegate = coordinator
        coordinator.load(parent, restore: true)
        view.insertText("!", replacementRange: view.selectedRange())
        XCTAssertEqual(reported, "Hello!")
    }

    func testFormattingUndoRedoPreservesText() {
        let view = editor("hello", selection: NSRange(location: 0, length: 5))
        let delegate = UndoDelegate()
        view.delegate = delegate
        delegate.history.beginUndoGrouping()
        view.wrap("**")
        delegate.history.endUndoGrouping()
        XCTAssertTrue(delegate.history.canUndo)
        delegate.history.undo()
        XCTAssertEqual(view.string, "hello")
        delegate.history.redo()
        XCTAssertEqual(view.string, "**hello**")
    }

    func testReturnContinuesListsAndResetsCheckedTask() {
        for (source, expected) in [("- item", "- item\n- "), ("9. item", "9. item\n10. "), ("- [x] done", "- [x] done\n- [ ] "), ("> quote", "> quote\n> ")] {
            let view = editor(source)
            view.insertNewline(nil)
            XCTAssertEqual(view.string, expected)
        }
    }

    func testEmptyListExitsAndCodeDoesNotContinueList() {
        let empty = editor("- item\n- ")
        empty.insertNewline(nil)
        XCTAssertEqual(empty.string, "- item\n")
        let code = editor("```\n- literal")
        code.insertNewline(nil)
        XCTAssertEqual(code.string, "```\n- literal\n")
    }

    func testReturnBeforeListMarkerDoesNotDuplicateIt() {
        let view = editor("- item", selection: NSRange(location: 0, length: 0))
        view.insertNewline(nil)
        XCTAssertEqual(view.string, "\n- item")
    }

    func testLargeOrderedListDoesNotOverflow() {
        let source = "\(Int.max). item"
        let view = editor(source)
        view.insertNewline(nil)
        XCTAssertEqual(view.string, source + "\n\(Int.max). ")
    }

    func testPlainTextPastePreservesMarkdownLinksAndUnicode() {
        let view = editor("Replace me", selection: NSRange(location: 0, length: 10))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let text = "日本語 🌱\n[Example](https://example.com)\n- [ ] Task"
        pasteboard.setString(text, forType: .string)
        XCTAssertTrue(view.readSelection(from: pasteboard, type: .string))
        XCTAssertEqual(view.string, text)
    }
}

private final class UndoDelegate: NSObject, NSTextViewDelegate {
    let history = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { history }
    func textDidChange(_ notification: Notification) {
        if let view = notification.object as? NSTextView, let storage = view.textStorage {
            MarkdownStyler.style(storage)
        }
    }
}
