import XCTest
import AppKit
@testable import Matilde

final class DividerTests: XCTestCase {
    func testDividerIsLosslessAndOnlyStandaloneOutsideCode() {
        let source = "日本語 🌱\n---\nAfter\ntext --- text\n--\n```\n---\n```\n`---`\n  ---  "
        let text = NSMutableAttributedString(string: source)
        MarkdownStyler.style(text)
        XCTAssertEqual(text.string, source)
        var rules: [NSRange] = []
        text.enumerateAttribute(.divider, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value != nil { rules.append(range) }
        }
        XCTAssertEqual(rules.count, 2)
        for range in rules {
            XCTAssertEqual((source as NSString).substring(with: range).trimmingCharacters(in: .whitespaces), "---")
            XCTAssertEqual(text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor, .clear)
        }
        text.replaceCharacters(in: rules[0], with: "--")
        MarkdownStyler.style(text)
        XCTAssertNil(text.attribute(.divider, at: rules[0].location, effectiveRange: nil))
        XCTAssertEqual(text.attribute(.foregroundColor, at: rules[0].location, effectiveRange: nil) as? NSColor, Paper.ink)
    }

    @MainActor
    func testReturnAfterDividerDoesNotContinueListAndUndoPreservesSource() {
        let view = WritingTextView(frame: NSRect(x: 0, y: 0, width: 680, height: 500))
        view.allowsUndo = true
        let delegate = DividerUndoDelegate()
        view.delegate = delegate
        view.string = "---"
        view.setSelectedRange(NSRange(location: 3, length: 0))
        delegate.history.beginUndoGrouping()
        view.insertNewline(nil)
        delegate.history.endUndoGrouping()
        XCTAssertEqual(view.string, "---\n")
        XCTAssertTrue(delegate.history.canUndo)
        delegate.history.undo()
        XCTAssertEqual(view.string, "---")
    }
}

private final class DividerUndoDelegate: NSObject, NSTextViewDelegate {
    let history = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { history }
}
