import XCTest
import MatildeKit

/// EDIT-31: every editing rule as input text plus selection mapped to output text plus selection.
/// In the strings, `|` is the caret and `«…»` a selection. An expectation of nil means the
/// editor's native behaviour applies (the rule returns no edit).
final class MarkdownEditingTests: XCTestCase {
    enum Action {
        case backspace, delete, enter, lineBreak, tab, shiftTab, paste(String), type(String)
    }

    static func parse(_ marked: String) -> (String, NSRange) {
        let source = marked as NSString
        let open = source.range(of: "«")
        if open.location != NSNotFound {
            let close = source.range(of: "»")
            let text = marked.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: "")
            return (text, NSRange(location: open.location, length: close.location - open.location - 1))
        }
        let caret = source.range(of: "|")
        precondition(caret.location != NSNotFound, "no caret in \(marked)")
        return (source.replacingCharacters(in: caret, with: ""), NSRange(location: caret.location, length: 0))
    }

    static func render(_ text: String, _ selection: NSRange) -> String {
        let source = text as NSString
        if selection.length == 0 { return source.replacingCharacters(in: selection, with: "|") }
        return source.substring(to: selection.location) + "«" + source.substring(with: selection) + "»" + source.substring(from: NSMaxRange(selection))
    }

    func run(_ action: Action, _ marked: String, options: MarkdownEditingOptions = .concealed) -> String? {
        let (text, selection) = Self.parse(marked)
        let edit: MarkdownEdit?
        switch action {
        case .backspace: edit = MarkdownEditing.deleteBackward(in: text, selection: selection, options: options)
        case .delete: edit = MarkdownEditing.deleteForward(in: text, selection: selection, options: options)
        case .enter: edit = MarkdownEditing.insertNewline(in: text, selection: selection)
        case .lineBreak: edit = MarkdownEditing.insertLineBreak(in: text, selection: selection)
        case .tab: edit = MarkdownEditing.indent(in: text, selection: selection)
        case .shiftTab: edit = MarkdownEditing.outdent(in: text, selection: selection)
        case .paste(let value): edit = MarkdownEditing.paste(value, in: text, selection: selection)
        case .type(let value): edit = MarkdownEditing.insertText(value, in: text, selection: selection, options: options)
        }
        guard let edit else { return nil }
        let result = edit.applied(to: text)
        XCTAssertLessThanOrEqual(NSMaxRange(edit.selection), (result as NSString).length, "selection out of bounds for \(marked)")
        return Self.render(result, edit.selection)
    }

    func check(_ action: Action, _ input: String, _ expected: String?, options: MarkdownEditingOptions = .concealed,
               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(run(action, input, options: options), expected, "\(action) on \(input.debugDescription)", file: file, line: line)
    }

    // MARK: Backspace

    func testBackspaceAtHeadingStartMakesAParagraph() {
        check(.backspace, "# |Title", "|Title")
        check(.backspace, "Intro\n### |Three", "Intro\n|Three")
        check(.backspace, "## |", "|")
    }

    func testDeletingAHeadingsLastCharacterRemovesItsMarks() {
        check(.backspace, "# a|", "|")
        check(.backspace, "Before\n## 日|\nAfter", "Before\n|\nAfter")
        check(.backspace, "# 🌱|", "|")
        check(.delete, "# |a", "|")
        check(.backspace, "# «Title»", "|")
        // Not the last character: native.
        check(.backspace, "# ab|", nil)
    }

    func testBackspaceAtListItemStartRemovesTheMarker() {
        check(.backspace, "- |item", "|item")
        check(.backspace, "* |item", "|item")
        check(.backspace, "- [ ] |task", "|task")
        check(.backspace, "- [x] |done", "|done")
        check(.backspace, "- |", "|")
        check(.backspace, "1. |one", "|one")
    }

    func testBackspaceAtTopLevelItemRenumbersTheRest() {
        check(.backspace, "Para\n\n1. a\n2. |b\n3. c\n4. d", "Para\n\n1. a\n|b\n2. c\n3. d")
    }

    func testBackspaceAtNestedItemOutdentsFirst() {
        check(.backspace, "- a\n  - |b", "- a\n- |b")
        check(.backspace, "1. a\n   1. |b", "1. a\n2. |b")
        check(.backspace, "- a\n  - b\n    - |c", "- a\n  - b\n  - |c")
        check(.backspace, "- a\n  - [ ] |task", "- a\n- [ ] |task")
    }

    func testBackspaceAtQuoteStartRemovesOneLevel() {
        check(.backspace, "> |quote", "|quote")
        check(.backspace, ">|quote", "|quote")
        check(.backspace, "> > |deep", "> |deep")
        check(.backspace, "> |", "|")
    }

    func testBackspaceInsideMarkersOrTextIsNative() {
        check(.backspace, "- it|em", nil)
        check(.backspace, "-| item", nil)
        check(.backspace, "|- item", nil)
        check(.backspace, "plain|", nil)
        check(.backspace, "```\n- |code\n```", nil)
        check(.backspace, "```\n# |code", nil)
    }

    func testBackspaceStepsOverHiddenInlineMarkers() {
        check(.backspace, "a **bold**|", "a **bol|**")
        check(.backspace, "a **bold**| tail", "a **bol|** tail")
        check(.backspace, "x **|bold**", "x|**bold**")
        check(.backspace, "`code`|", "`cod|`")
        check(.backspace, "[label](https://matilde.page)|", "[labe|](https://matilde.page)")
        check(.backspace, "*soft*|", "*sof|*")
        check(.backspace, "_soft_|", "_sof|_")
    }

    func testDeletingASpansLastCharacterRemovesTheSpan() {
        check(.backspace, "a **b**|", "a |")
        check(.backspace, "a **b|**", "a |")
        check(.backspace, "`x`|", "|")
        check(.backspace, "[x](https://a.b)|", "|")
        check(.backspace, "a «bold» b".replacingOccurrences(of: "«bold»", with: "**«bold»**"), "a | b")
        check(.delete, "|**b** c", "| c")
    }

    func testVisibleMarkersAreDeletedNatively() {
        check(.backspace, "a **bold**|", nil, options: .visibleMarkers)
        check(.backspace, "a **b**|", nil, options: .visibleMarkers)
        // Links that the renderer leaves visible aren't stepped over either.
        check(.backspace, "[label](notes.md)|", nil)
    }

    func testBackspaceInAnEmptyBracketPairRemovesBoth() {
        check(.backspace, "see (|)", "see |")
        check(.backspace, "[|]", "|")
        check(.backspace, "see (|)", "see (|)".replacingOccurrences(of: "(|)", with: "|"), options: .visibleMarkers)
        check(.backspace, "(|)", nil, options: MarkdownEditingOptions(concealsInlineMarkers: false, pairsBrackets: false))
    }

    func testUnicodeDeletesWholeCharacters() {
        check(.backspace, "**日本🌱**|", "**日本|**")
        check(.backspace, "**👩‍👩‍👧**|", "|")
    }

    // MARK: Delete

    func testDeleteAtLineEndJoinsTheNextLinesText() {
        check(.delete, "one|\n- two", "one|two")
        check(.delete, "- one|\n- two", "- one|two")
        check(.delete, "one|\n# Two", "one|Two")
        check(.delete, "one|\n> two", "one|two")
        check(.delete, "one|\ntwo", nil)
        check(.delete, "|\n- two", nil)
        check(.delete, "```\nx|\n- y\n```", nil)
    }

    // MARK: Return

    func testReturnContinuesLists() {
        check(.enter, "- item|", "- item\n- |")
        check(.enter, "* item|", "* item\n* |")
        check(.enter, "9. item|", "9. item\n10. |")
        check(.enter, "3) item|", "3) item\n4) |")
        check(.enter, "- [x] done|", "- [x] done\n- [ ] |")
        check(.enter, "  - nested|", "  - nested\n  - |")
        check(.enter, "> - quoted|", "> - quoted\n> - |")
    }

    func testReturnSplitsAnItem() {
        check(.enter, "- one| two", "- one\n- |two")
        check(.enter, "- |item", "- \n- |item")
        check(.enter, "1. a|b\n2. c", "1. a\n2. |b\n3. c")
        check(.enter, "- «sel»ected", "- \n- |ected")
    }

    func testReturnRenumbersFollowingItems() {
        check(.enter, "1. a|\n2. b\n3. c", "1. a\n2. |\n3. b\n4. c")
        check(.enter, "1. a\n   1. x|\n   2. y\n2. b", "1. a\n   1. x\n   2. |\n   3. y\n2. b")
    }

    func testReturnOnAnEmptyItemEndsTheListOrOutdents() {
        check(.enter, "- item\n- |", "- item\n|")
        check(.enter, "- [ ] |", "|")
        check(.enter, "1. a\n2. |", "1. a\n|")
        check(.enter, "- a\n  - |", "- a\n- |")
        check(.enter, "1. a\n   1. |", "1. a\n2. |")
        check(.enter, "> - |", "> |")
    }

    func testReturnInQuotes() {
        check(.enter, "> quote|", "> quote\n> |")
        check(.enter, "> > deep|", "> > deep\n> > |")
        check(.enter, "> |", "|")
        check(.enter, "> > |", "> |")
    }

    func testReturnAtHeadingStartOpensALineAbove() {
        check(.enter, "# |Title", "\n# |Title")
        check(.enter, "# Ti|tle", nil)
        check(.enter, "# Title|", nil)
    }

    func testReturnIsNativeElsewhere() {
        check(.enter, "plain|", nil)
        check(.enter, "|- item", nil)
        check(.enter, "```\n- item|", nil)
        check(.enter, "- a«\n- »b", nil)
        check(.enter, "\(Int.max). item|", "\(Int.max). item\n\(Int.max). |")
    }

    func testShiftReturnContinuesTheItemsText() {
        check(.lineBreak, "- item|", "- item\n  |")
        check(.lineBreak, "12. item|", "12. item\n    |")
        check(.lineBreak, "- [ ] task|", "- [ ] task\n  |")
        check(.lineBreak, "plain|", "plain\n|")
    }

    // MARK: Tab and Shift-Tab

    func testTabNestsAnOrderedItemAndRestartsAtOne() {
        // The owner's report: "1. Here is a test", Return, Tab.
        check(.tab, "1. Here is a test\n2. |", "1. Here is a test\n   1. |")
        check(.tab, "1. a\n2. b|\n3. c", "1. a\n   1. b|\n2. c")
        check(.tab, "1. a\n   1. x\n2. |b", "1. a\n   1. x\n   2. |b")
    }

    func testTabNestsBulletsAndTasks() {
        check(.tab, "- a\n- |b", "- a\n  - |b")
        check(.tab, "- a\n- b|", "- a\n  - b|")
        check(.tab, "- [ ] a\n- [ ] |b", "- [ ] a\n  - [ ] |b")
        check(.tab, "> - a\n> - |b", "> - a\n>   - |b")
    }

    func testTabCarriesChildren() {
        check(.tab, "- a\n- |b\n  - c\n- d", "- a\n  - |b\n    - c\n- d")
    }

    func testTabOnTheFirstItemIsHandledButChangesNothing() {
        check(.tab, "- |a", "- |a")
        check(.tab, "- a\n  - |b", "- a\n  - |b")
    }

    func testTabOutsideListsIsNative() {
        check(.tab, "plain|", nil)
        check(.tab, "```\n- a\n- |b", nil)
    }

    func testTabWithASelectionNestsEverySelectedItem() {
        check(.tab, "1. a\n2. «b\n3. c»", "1. a\n   1. «b\n   2. c»")
        check(.tab, "- «a\n- b»", "- «a\n- b»")
    }

    func testShiftTabOutdentsAndRenumbers() {
        check(.shiftTab, "1. a\n   1. |b", "1. a\n2. |b")
        check(.shiftTab, "1. a\n   1. b\n   2. |c\n   3. d\n2. e", "1. a\n   1. b\n2. |c\n   1. d\n3. e")
        check(.shiftTab, "- a\n  - |b\n    - c", "- a\n- |b\n  - c")
        check(.shiftTab, "- |a", "- |a")
        check(.shiftTab, "  - |a", "- |a")
        check(.shiftTab, "plain|", nil)
    }

    func testTabThenShiftTabRestoresTheList() {
        let start = "1. a\n2. b|\n3. c"
        let nested = run(.tab, start)!
        XCTAssertEqual(run(.shiftTab, nested), start)
    }

    // MARK: Typing

    func testTypingWrapsASelection() {
        check(.type("*"), "a «word» b", "a *«word»* b")
        check(.type("_"), "«word»", "_«word»_")
        check(.type("`"), "«code»", "`«code»`")
        check(.type("["), "«label»", "[«label»]")
        check(.type("("), "«aside»", "(«aside»)")
        check(.type("x"), "«word»", nil)
        check(.type("*"), "«a\nb»", nil)
    }

    func testBracketsPairAndStepOver() {
        check(.type("("), "see |", "see (|)")
        check(.type("["), "|", "[|]")
        check(.type("("), "|word", nil)
        check(.type(")"), "(a|)", "(a)|")
        check(.type(")"), "a|)", nil)
        check(.type("]"), "[x|]", "[x]|")
        check(.type("("), "see |", nil, options: MarkdownEditingOptions(concealsInlineMarkers: true, pairsBrackets: false))
    }

    func testCheckboxShortcut() {
        check(.type(" "), "[ ]|", "- [ ] |")
        check(.type(" "), "[]|", "- [ ] |")
        check(.type(" "), "[x]|", "- [x] |")
        check(.type(" "), "  [ ]|", "  - [ ] |")
        check(.type(" "), "- []|", "- [ ] |")
        check(.type(" "), "ordinary [ ]|", nil)
        check(.type(" "), "```\n[ ]|", nil)
        check(.type(" "), "- [ ]|", nil)
    }

    func testTypingIsNativeInCode() {
        check(.type("("), "```\n|", nil)
        check(.type("*"), "```\n«x»\n```", nil)
    }

    // MARK: Paste

    func testPasteIntoAnEmptyItemReplacesItsMarker() {
        check(.paste("- a\n- b"), "- |", "- a\n- b|")
        check(.paste("1. a\n2. b"), "  - |", "  1. a\n  2. b|")
        check(.paste("> q"), "> |", "> q|")
        check(.paste("> a\n> b"), "> |", "> a\n> b|")
        check(.paste("- a\n\n- b"), "> |", "> - a\n>\n> - b|")
        check(.paste("# Title"), "# |", "# Title|")
    }

    func testPasteNormalisesLineEndings() {
        check(.paste("a\r\nb\rc"), "|", "a\nb\nc|")
        check(.paste("plain"), "|", nil)
        check(.paste("- a"), "text|", nil)
    }

    // MARK: Rendering help and edits

    /// Cases the Mac and iPhone editors' own tests depend on.
    func testCasesTheEditorsRelyOn() {
        check(.backspace, "Intro\n## A|", "Intro\n|")
        check(.enter, "- one\n  - |", "- one\n- |")
        check(.enter, "- one\n- |", "- one\n|")
        check(.tab, "Plain|", nil)
        check(.shiftTab, "1. Here is a test\n   1. |", "1. Here is a test\n2. |")
        check(.paste("- a\r\n- b"), "- |", "- a\n- b|")
        check(.type(" "), "[ ]|", "- [ ] |")
        // iPhone: Backspace before a nested item's (hidden) indentation moves it out.
        check(.shiftTab, "- one\n    |- two", "- one\n|- two", options: .visibleMarkers)
    }

    func testListDepths() {
        let text = "- a\n  - b\n    - c\n- d\n\n1. x\n   1. y\nPara\n  - e"
        let depths = MarkdownEditing.listDepths(in: text)
        let source = text as NSString
        func depth(_ line: String) -> Int? { depths[source.range(of: line).location] }
        XCTAssertEqual(depth("- a"), 0)
        XCTAssertEqual(depth("  - b"), 1)
        XCTAssertEqual(depth("    - c"), 2)
        XCTAssertEqual(depth("- d"), 0)
        XCTAssertEqual(depth("1. x"), 0)
        XCTAssertEqual(depth("   1. y"), 1)
        XCTAssertEqual(depth("  - e"), 0)
    }

    func testMinimalEditsNeverSplitSurrogatePairs() {
        let edit = MarkdownEdit.between("a🌱b", "a🌿b", selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(edit.range, NSRange(location: 1, length: 2))
        XCTAssertEqual(edit.replacement, "🌿")
        let insert = MarkdownEdit.between("- a\n- b", "- a\n  - b", selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(insert.range, NSRange(location: 4, length: 0))
        XCTAssertEqual(insert.replacement, "  ")
    }

    func testLinePrefixes() {
        XCTAssertEqual(MarkdownLinePrefix.parse("## Two").kind, .heading(2))
        XCTAssertEqual(MarkdownLinePrefix.parse("#Not").kind, .paragraph)
        XCTAssertEqual(MarkdownLinePrefix.parse("  - [x] t").kind, .task(checked: true))
        XCTAssertEqual(MarkdownLinePrefix.parse("12. t").number, 12)
        XCTAssertEqual(MarkdownLinePrefix.parse("> > q").quote, "> > ")
        XCTAssertEqual(MarkdownLinePrefix.parse("---").kind, .paragraph)
        XCTAssertEqual(MarkdownLinePrefix.parse("\t- t").indentColumns, 4)
    }
}
