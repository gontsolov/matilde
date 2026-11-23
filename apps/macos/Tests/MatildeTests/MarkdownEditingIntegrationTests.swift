import XCTest
import AppKit
@testable import Matilde
import MatildeKit

/// EDIT-31: the shared Markdown editing rules wired into the Mac editor, including undo and the
/// caret around hidden markers. The rules themselves are tested in MatildeKit.
@MainActor
final class MarkdownEditingIntegrationTests: XCTestCase {
    private func editor(_ text: String, caret: Int? = nil) -> (WritingTextView, EditingUndoDelegate) {
        let view = WritingTextView(frame: NSRect(x: 0, y: 0, width: 680, height: 500))
        view.isRichText = false
        view.allowsUndo = true
        let delegate = EditingUndoDelegate()
        view.delegate = delegate
        view.string = text
        MarkdownStyler.style(view.textStorage!)
        view.setSelectedRange(NSRange(location: caret ?? (text as NSString).length, length: 0))
        return (view, delegate)
    }

    func testBackspaceAtHeadingStartRemovesTheMarksAndUndoes() {
        let (view, delegate) = editor("# Title", caret: 2)
        delegate.step { view.deleteBackward(nil) }
        XCTAssertEqual(view.string, "Title")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 0))
        delegate.history.undo()
        XCTAssertEqual(view.string, "# Title")
        delegate.history.redo()
        XCTAssertEqual(view.string, "Title")
    }

    func testEmptyingAHeadingLeavesNoStrayMarks() {
        let (view, delegate) = editor("Intro\n## A")
        delegate.step { view.deleteBackward(nil) }
        XCTAssertEqual(view.string, "Intro\n")
    }

    func testTabNestsAnOrderedItemAndShiftTabRestoresIt() {
        let (view, delegate) = editor("1. Here is a test\n2. ")
        delegate.step { view.insertTab(nil) }
        XCTAssertEqual(view.string, "1. Here is a test\n   1. ")
        XCTAssertEqual(view.selectedRange().location, (view.string as NSString).length)
        delegate.step { view.insertBacktab(nil) }
        XCTAssertEqual(view.string, "1. Here is a test\n2. ")
        delegate.history.undo()
        XCTAssertEqual(view.string, "1. Here is a test\n   1. ")
        delegate.history.undo()
        XCTAssertEqual(view.string, "1. Here is a test\n2. ")
    }

    func testTabOutsideListsStillTypesATab() {
        let (view, delegate) = editor("Plain")
        delegate.step { view.insertTab(nil) }
        XCTAssertEqual(view.string, "Plain\t")
    }

    func testEnterOnAnEmptyNestedItemOutdentsThenEndsTheList() {
        let (view, delegate) = editor("- one\n  - ")
        delegate.step { view.insertNewline(nil) }
        XCTAssertEqual(view.string, "- one\n- ")
        delegate.step { view.insertNewline(nil) }
        XCTAssertEqual(view.string, "- one\n")
    }

    func testCheckboxShortcutUndoesInOneStep() {
        let (view, delegate) = editor("[ ]")
        delegate.step { view.insertText(" ", replacementRange: view.selectedRange()) }
        XCTAssertEqual(view.string, "- [ ] ")
        delegate.history.undo()
        XCTAssertEqual(view.string, "[ ]")
    }

    func testArrowKeysStepOverHiddenMarkers() {
        let (view, _) = editor("a**b**c", caret: 1)
        view.moveRight(nil)
        XCTAssertEqual(view.selectedRange().location, 4, "lands after b, past the hidden opening **")
        view.moveRight(nil)
        XCTAssertEqual(view.selectedRange().location, 7)
        view.moveLeft(nil)
        XCTAssertEqual(view.selectedRange().location, 6, "before c, which looks the same as after b")
        view.moveLeft(nil)
        XCTAssertEqual(view.selectedRange().location, 3, "before b")
    }

    func testLeftFromHeadingTextGoesToThePreviousLine() {
        let (view, _) = editor("Intro\n# Title", caret: 8)
        view.moveLeft(nil)
        XCTAssertEqual(view.selectedRange().location, 5)
    }

    func testNestedItemsAreIndentedByDepth() throws {
        let (view, _) = editor("- one\n    - two\n- three")
        let storage = try XCTUnwrap(view.textStorage)
        let top = try XCTUnwrap(storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let nested = try XCTUnwrap(storage.attribute(.paragraphStyle, at: 6, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(top.firstLineHeadIndent, 0)
        XCTAssertGreaterThan(nested.firstLineHeadIndent, 0)
        XCTAssertGreaterThan(nested.headIndent, nested.firstLineHeadIndent)
        XCTAssertNotNil(storage.attribute(.concealed, at: 6, effectiveRange: nil), "raw indentation is hidden")
    }

    func testPasteIntoAnEmptyItemReplacesItsMarker() {
        let (view, delegate) = editor("- ")
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer { pasteboard.clearContents(); if let saved { pasteboard.setString(saved, forType: .string) } }
        pasteboard.clearContents()
        pasteboard.setString("- a\r\n- b", forType: .string)
        delegate.step { view.paste(nil) }
        XCTAssertEqual(view.string, "- a\n- b")
    }
}

extension MarkdownEditingIntegrationTests {
    func testCommandBackspaceEmptyingAHeadingRemovesItsHiddenMarks() {
        let (view, delegate) = editor("Intro\n## Delete me")
        delegate.step { view.deleteToBeginningOfLine(nil) }
        XCTAssertEqual(view.string, "Intro\n")
        delegate.step { view.insertText("plain", replacementRange: view.selectedRange()) }
        XCTAssertEqual(view.string, "Intro\nplain")
        delegate.history.undo()
        delegate.history.undo()
        XCTAssertEqual(view.string, "Intro\n## Delete me")
    }

    func testOptionBackspaceEmptyingAHeadingRemovesItsHiddenMarks() {
        let (view, delegate) = editor("## Two words")
        delegate.step { view.deleteWordBackward(nil) }
        XCTAssertEqual(view.string, "## Two ")
        delegate.step { view.deleteWordBackward(nil) }
        XCTAssertEqual(view.string, "")
    }

    func testCommandBackspaceInAListItemKeepsTheMarkerThenRemovesIt() {
        let (view, delegate) = editor("- first\n- second item")
        delegate.step { view.deleteToBeginningOfLine(nil) }
        XCTAssertEqual(view.string, "- first\n- ")
        delegate.step { view.deleteToBeginningOfLine(nil) }
        XCTAssertEqual(view.string, "- first\n")
    }

    /// On an empty line, or at the start of a line, ⌘⌫ and ⌥⌫ join it to the line above like
    /// Backspace, as in other Mac editors, instead of doing nothing or eating the word above.
    func testCommandAndOptionBackspaceOnAnEmptyLineJoinTheLineAbove() {
        for delete in [{ (view: WritingTextView) in view.deleteToBeginningOfLine(nil) },
                       { (view: WritingTextView) in view.deleteWordBackward(nil) }] {
            let (heading, headingDelegate) = editor("## Hello\n\nNext", caret: 9)
            headingDelegate.step { delete(heading) }
            XCTAssertEqual(heading.string, "## Hello\nNext")
            XCTAssertEqual(heading.selectedRange(), NSRange(location: 8, length: 0))

            let (plain, plainDelegate) = editor("abc\n\ndef", caret: 4)
            plainDelegate.step { delete(plain) }
            XCTAssertEqual(plain.string, "abc\ndef")

            let (start, startDelegate) = editor("abc\ndef", caret: 4)
            startDelegate.step { delete(start) }
            XCTAssertEqual(start.string, "abcdef")
        }
    }

    func testOptionBackspaceStopsAtANestedItemsText() {
        let (view, delegate) = editor("- a\n  - word")
        delegate.step { view.deleteWordBackward(nil) }
        XCTAssertEqual(view.string, "- a\n  - ")
    }

    /// Hidden marks at the start of a line (a heading's `#`, a quote's `>`, a nested item's
    /// indentation) must not swallow the space the block above leaves under it.
    func testHiddenLineStartsKeepTheSpaceAboveThem() throws {
        let parent = MarkdownEditor(draftID: "spacing", text: "", initialCursor: 0, initialScroll: 0, onChange: { _ in }, onPosition: { _, _ in })
        let coordinator = parent.makeCoordinator()
        let (view, _) = editor("Paragraph\n## Heading\n- item\n  - nested\n> quote")
        let layoutManager = try XCTUnwrap(view.layoutManager)
        layoutManager.delegate = coordinator
        MarkdownStyler.style(view.textStorage!)
        layoutManager.invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: view.textStorage!.length), changeInLength: 0, actualCharacterRange: nil)
        layoutManager.ensureLayout(for: view.textContainer!)
        let source = view.string as NSString
        for (line, next) in [("Paragraph", "## Heading"), ("- item", "  - nested"), ("  - nested", "> quote")] {
            let start = source.range(of: line).location
            let style = try XCTUnwrap(view.textStorage!.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: start), effectiveRange: nil)
            let used = layoutManager.lineFragmentUsedRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: start), effectiveRange: nil)
            XCTAssertGreaterThan(style.paragraphSpacing, 0)
            XCTAssertEqual(fragment.height - used.height, style.paragraphSpacing, accuracy: 0.5, "space under \(line) before \(next)")
        }
        // The hidden marks still take no room: the heading's text starts at the left edge.
        let heading = source.range(of: "Heading").location
        let paragraph = layoutManager.location(forGlyphAt: 0).x
        XCTAssertEqual(layoutManager.location(forGlyphAt: layoutManager.glyphIndexForCharacter(at: heading)).x, paragraph, accuracy: 0.5)
    }
}

private final class EditingUndoDelegate: NSObject, NSTextViewDelegate {
    let history: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }()
    /// One user action, as one undo group (tests have no event loop to close groups).
    func step(_ action: () -> Void) {
        history.beginUndoGrouping()
        action()
        history.endUndoGrouping()
    }
    func undoManager(for view: NSTextView) -> UndoManager? { history }
    func textDidChange(_ notification: Notification) {
        if let view = notification.object as? NSTextView, let storage = view.textStorage {
            MarkdownStyler.style(storage)
        }
    }
}
