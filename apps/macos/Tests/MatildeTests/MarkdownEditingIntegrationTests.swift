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
        let (view, _) = editor("Intro\n## A")
        view.deleteBackward(nil)
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
        let (view, _) = editor("Plain")
        view.insertTab(nil)
        XCTAssertEqual(view.string, "Plain\t")
    }

    func testEnterOnAnEmptyNestedItemOutdentsThenEndsTheList() {
        let (view, _) = editor("- one\n  - ")
        view.insertNewline(nil)
        XCTAssertEqual(view.string, "- one\n- ")
        view.insertNewline(nil)
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
        let (view, _) = editor("- ")
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer { pasteboard.clearContents(); if let saved { pasteboard.setString(saved, forType: .string) } }
        pasteboard.clearContents()
        pasteboard.setString("- a\r\n- b", forType: .string)
        view.paste(nil)
        XCTAssertEqual(view.string, "- a\n- b")
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
