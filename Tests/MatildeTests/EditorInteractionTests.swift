import XCTest
import AppKit
import SwiftUI
@testable import Matilde

@MainActor
final class EditorInteractionTests: XCTestCase {
    func testWrappedHeaderGrowsDownAndMovesBodyBelowIt() {
        let view = editor("Body")
        func header(_ title: String) -> AnyView {
            AnyView(VStack(alignment: .leading, spacing: 15) {
                Text("Draft controls")
                Text(title).font(.system(size: 32)).fixedSize(horizontal: false, vertical: true)
                Text("Writing goal")
            }.padding(.top, 29))
        }
        let hosted = WritingHeaderView(content: header("Short title"))
        view.scrollingHeader = hosted
        view.addSubview(hosted)
        view.layout()
        let shortHeight = view.headerHeight
        let shortBody = view.textContainerOrigin.y
        hosted.update(content: header(String(repeating: "Long wrapping title ", count: 8)))
        view.layout()
        XCTAssertEqual(hosted.frame.minY, 0)
        XCTAssertGreaterThan(view.headerHeight, shortHeight + 30)
        XCTAssertEqual(view.textContainerOrigin.y - shortBody, view.headerHeight - shortHeight, accuracy: 1)
        hosted.update(content: header("Short title"))
        view.layout()
        XCTAssertEqual(view.headerHeight, shortHeight, accuracy: 1)
    }

    func testListWrapsAlignWithFirstWordAndHonorSpacing() throws {
        for size in [17.0, 19.0, 24.0] {
            for prefix in ["- ", "12. ", "- [ ] ", "- [x] "] {
                let source = prefix + String(repeating: "sample words for wrapping ", count: 6)
                let parent = MarkdownEditor(draftID: "list", text: source, initialCursor: 0, initialScroll: 0,
                                            onChange: { _ in }, onPosition: { _, _ in })
                let coordinator = parent.makeCoordinator()
                let view = editor(source)
                let layout = try XCTUnwrap(view.layoutManager)
                let container = try XCTUnwrap(view.textContainer)
                container.widthTracksTextView = false
                container.containerSize = NSSize(width: 220, height: 2000)
                container.lineFragmentPadding = 0
                layout.delegate = coordinator
                MarkdownStyler.style(view.textStorage!, textSize: size, lineSpacing: 9)
                layout.ensureLayout(for: container)
                let firstWord = layout.glyphIndexForCharacter(at: (prefix as NSString).length)
                var firstLine = NSRange()
                _ = layout.lineFragmentRect(forGlyphAt: firstWord, effectiveRange: &firstLine)
                let firstX = layout.location(forGlyphAt: firstWord).x
                let secondRect = layout.lineFragmentRect(forGlyphAt: NSMaxRange(firstLine), effectiveRange: nil)
                let secondX = secondRect.minX + layout.location(forGlyphAt: NSMaxRange(firstLine)).x
                XCTAssertEqual(firstX, secondX, accuracy: 1, "\(prefix) at \(size)")
                let style = try XCTUnwrap(view.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
                XCTAssertEqual(style.lineSpacing, 9)
                XCTAssertEqual(view.string, source)
            }
        }
    }

    func testStashMeasuresWrappedContentAndGrowsUntilWindowLimit() throws {
        let view = editor("A short note")
        let container = try XCTUnwrap(view.textContainer)
        container.widthTracksTextView = false
        container.containerSize = NSSize(width: 380, height: 100000)
        var measured: CGFloat = 0
        view.onContentHeight = { measured = $0 }
        MarkdownStyler.style(view.textStorage!)
        view.reportContentHeight()
        XCTAssertEqual(StashLayout.height(content: measured, header: 32, available: 800), 420)
        view.string = String(repeating: "A disposable line that wraps across the writing space.\n", count: 12)
        MarkdownStyler.style(view.textStorage!)
        view.reportContentHeight()
        let expanded = StashLayout.height(content: measured, header: 32, available: 1400)
        XCTAssertGreaterThan(expanded, 420)
        let wideHeight = measured
        container.containerSize.width = 180
        view.reportContentHeight()
        XCTAssertGreaterThan(measured, wideHeight)
        XCTAssertEqual(StashLayout.height(content: measured, header: 32, available: 500), 484)
        view.string = ""
        view.reportContentHeight()
        XCTAssertEqual(StashLayout.height(content: measured, header: 32, available: 800), 420)
    }

    func testCaretAndInlineCodeExcludeExtraLineSpacing() throws {
        let source = "Some 日本語 with `sample code that wraps across lines` here."
        for size in [17.0, 19.0, 24.0] {
            var previousHeight: CGFloat?
            for spacing in [3.0, 15.0] {
                let storage = NSTextStorage(string: source)
                let layout = WritingLayoutManager()
                let container = NSTextContainer(size: NSSize(width: 220, height: 2000))
                storage.addLayoutManager(layout)
                layout.addTextContainer(container)
                let view = WritingTextView(frame: NSRect(x: 0, y: 0, width: 220, height: 2000), textContainer: container)
                container.widthTracksTextView = false
                MarkdownStyler.style(storage, textSize: size, lineSpacing: spacing)
                layout.ensureLayout(for: container)
                let range = (source as NSString).range(of: "sample")
                XCTAssertNotNil(storage.attribute(.inlineCode, at: range.location, effectiveRange: nil))
                XCTAssertNil(storage.attribute(.backgroundColor, at: range.location, effectiveRange: nil))
                let backgrounds = layout.inlineCodeRects(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs))
                XCTAssertGreaterThan(backgrounds.count, 1)
                let height = try XCTUnwrap(backgrounds.first).height
                if let previousHeight { XCTAssertEqual(height, previousHeight, accuracy: 0.01) }
                previousHeight = height
                for rect in backgrounds { XCTAssertEqual(rect.height, height, accuracy: 0.01) }
                view.setSelectedRange(NSRange(location: range.location, length: 0))
                let caret = view.alignedCaretRect(NSRect(x: 42, y: 0, width: 1, height: 100))
                XCTAssertEqual(caret.height, height, accuracy: 0.01)
                XCTAssertEqual(caret.minY, backgrounds[0].minY + view.textContainerOrigin.y, accuracy: 0.01)
                XCTAssertEqual(caret.minX, 42)
                XCTAssertEqual(storage.string, source)
            }
        }
    }

    func testCheckboxCreationToggleContinuationAndUndo() {
        let view = editor("A 日本語 task 🌱")
        let delegate = UndoDelegate()
        view.delegate = delegate
        delegate.history.beginUndoGrouping()
        view.insertCheckbox(nil)
        delegate.history.endUndoGrouping()
        XCTAssertEqual(view.string, "- [ ] A 日本語 task 🌱")
        delegate.history.undo()
        XCTAssertEqual(view.string, "A 日本語 task 🌱")
        delegate.history.redo()
        view.insertCheckbox(nil)
        XCTAssertEqual(view.string, "- [x] A 日本語 task 🌱")
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertNewline(nil)
        XCTAssertTrue(view.string.hasSuffix("\n- [ ] "))
        view.insertNewline(nil)
        XCTAssertTrue(view.string.hasSuffix("🌱\n"))
        let bullet = editor("  - Existing item")
        bullet.insertCheckbox(nil)
        XCTAssertEqual(bullet.string, "  - [ ] Existing item")
    }

    func testBareCheckboxTypingAndCodeFenceProtection() {
        for (source, expected) in [("[ ]", "- [ ] "), ("[x]", "- [x] "), ("  [ ]", "  - [ ] "),
                                   ("ordinary [ ]", "ordinary [ ] "), ("```\n[ ]", "```\n[ ] ")] {
            let view = editor(source)
            view.insertText(" ", replacementRange: view.selectedRange())
            XCTAssertEqual(view.string, expected)
        }
        let code = editor("```\n- literal")
        code.insertCheckbox(nil)
        XCTAssertEqual(code.string, "```\n- literal")
    }

    func testSlashQueryBoundariesFilteringAndCodeProtection() {
        func query(_ text: String) -> (range: NSRange, filter: String)? {
            SlashCommand.query(in: text, selection: NSRange(location: (text as NSString).length, length: 0))
        }
        XCTAssertEqual(query("日本語 /check")?.filter, "check")
        XCTAssertEqual(query("日本語 /check")?.range, NSRange(location: 4, length: 6))
        XCTAssertNil(query("/heading "))
        XCTAssertNil(query("https://example.com/path"))
        XCTAssertNil(query("word/slash"))
        XCTAssertNil(query("```\n/check"))
        XCTAssertNil(SlashCommand.query(in: "`/code`", selection: NSRange(location: 6, length: 0)))
        XCTAssertEqual(SlashCommand.matching("check").map(\.title), ["Checkbox"])
        XCTAssertEqual(SlashCommand.matching("h3").map(\.title), ["Heading 3"])
        XCTAssertTrue(SlashCommand.matching("nonexistent").isEmpty)
    }

    func testSlashReplacesQueryAndSelectsPlaceholderWithUndo() {
        let view = editor("Before /bold after", selection: NSRange(location: 12, length: 0))
        let delegate = UndoDelegate()
        view.delegate = delegate
        delegate.history.beginUndoGrouping()
        view.insertSlashCommand(SlashCommand.matching("bold")[0], replacing: NSRange(location: 7, length: 5))
        delegate.history.endUndoGrouping()
        XCTAssertEqual(view.string, "Before **text** after")
        XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "text")
        delegate.history.undo()
        XCTAssertEqual(view.string, "Before /bold after")
        let divider = editor("/divider")
        divider.insertSlashCommand(SlashCommand.matching("divider")[0], replacing: NSRange(location: 0, length: 8))
        XCTAssertEqual(divider.string, "---\n")
        XCTAssertEqual(divider.selectedRange(), NSRange(location: 4, length: 0))
    }

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
