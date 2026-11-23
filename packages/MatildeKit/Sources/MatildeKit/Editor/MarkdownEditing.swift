import Foundation

/// How the editor using the rules draws Markdown.
public struct MarkdownEditingOptions: Equatable, Sendable {
    /// The editor hides inline markers (`**`, `*`, `_`, `` ` ``, a link's `[`/`](url)`), as the
    /// Mac editor does. Backspace and Delete then step over hidden markers and remove a span
    /// whose last visible character goes, instead of deleting invisible characters.
    public var concealsInlineMarkers: Bool
    /// Typing `(` or `[` before a space or the line end adds the closing bracket; typing the
    /// closing bracket over it steps past; Backspace in an empty pair removes both.
    public var pairsBrackets: Bool

    public init(concealsInlineMarkers: Bool, pairsBrackets: Bool = true) {
        self.concealsInlineMarkers = concealsInlineMarkers
        self.pairsBrackets = pairsBrackets
    }

    /// The Mac editor: markers hidden.
    public static let concealed = MarkdownEditingOptions(concealsInlineMarkers: true)
    /// The iPhone editor: inline markers faded but visible (only heading marks are hidden).
    public static let visibleMarkers = MarkdownEditingOptions(concealsInlineMarkers: false)
}

/// EDIT-31: the Markdown editing rules shared by the Mac and iPhone editors, as pure functions
/// from (text, selection) to an edit. Each returns nil when the editor's native behaviour is
/// right, so ordinary typing keeps the platform's own undo coalescing, spelling and input
/// methods. The editors must not call these while text is being composed (marked text).
///
/// All locations are UTF-16 offsets (`NSRange`), as in AppKit and UIKit. The rules are listed in
/// `docs/editor-behaviour.md`.
public enum MarkdownEditing {

    // MARK: Backspace and Delete

    /// Backspace.
    ///
    /// - At the start of a heading's text: the `#` marks go (it becomes a paragraph).
    /// - At the start of a list item's text: a nested item moves out one level; a top-level item
    ///   loses its marker (bullet, number or checkbox) and following numbers are renumbered.
    /// - At the start of a quote's text: one level of `>` goes.
    /// - Deleting a heading's last character removes its `#` marks too, leaving an empty line.
    /// - With hidden markers: steps over them, and removes a span (`**…**`, `` `…` ``, a link)
    ///   whose last character is deleted, so no stray marks are left.
    /// - In an empty bracket pair `(|)` removes both.
    public static func deleteBackward(in text: String, selection: NSRange, options: MarkdownEditingOptions) -> MarkdownEdit? {
        let document = MarkdownLines(text)
        let source = document.source
        guard selection.location != NSNotFound, NSMaxRange(selection) <= source.length else { return nil }
        if selection.length > 0 { return deleteSelection(document, selection: selection, options: options) }
        let caret = selection.location
        let lineIndex = document.index(at: caret)
        let line = document.ranges[lineIndex]
        guard !document.code[lineIndex] else { return nil }
        let prefix = document.prefix(lineIndex)
        if prefix.length > 0, caret == line.location + prefix.length {
            return removeBlockMarker(document, line: lineIndex, prefix: prefix, caret: caret)
        }
        guard caret > 0 else { return nil }
        if options.pairsBrackets, caret < source.length, caret > line.location {
            let pair = source.substring(with: NSRange(location: caret - 1, length: 2))
            if pair == "()" || pair == "[]" {
                return MarkdownEdit(range: NSRange(location: caret - 1, length: 2), replacement: "",
                                    selection: NSRange(location: caret - 1, length: 0))
            }
        }
        var target = caret
        if options.concealsInlineMarkers, caret > line.location {
            target = MarkdownInline.visibleBoundary(before: caret, spans: MarkdownInline.spans(document, line: lineIndex))
        }
        guard target > 0 else { return nil }
        let character = source.rangeOfComposedCharacterSequence(at: target - 1)
        return deletion(document, range: character, natural: source.rangeOfComposedCharacterSequence(at: caret - 1),
                        options: options)
    }

    /// Forward delete.
    ///
    /// - At the end of a line followed by a list item, quote or heading: joins the next line's
    ///   text without its marker.
    /// - Deleting a heading's last character removes its marks; hidden markers are stepped over
    ///   and emptied spans removed, as for Backspace.
    public static func deleteForward(in text: String, selection: NSRange, options: MarkdownEditingOptions) -> MarkdownEdit? {
        let document = MarkdownLines(text)
        let source = document.source
        guard selection.location != NSNotFound, NSMaxRange(selection) <= source.length else { return nil }
        if selection.length > 0 { return deleteSelection(document, selection: selection, options: options) }
        let caret = selection.location
        guard caret < source.length else { return nil }
        let lineIndex = document.index(at: caret)
        let line = document.ranges[lineIndex]
        guard !document.code[lineIndex] else { return nil }
        if caret == NSMaxRange(line), lineIndex + 1 < document.count, !document.code[lineIndex + 1],
           line.length > 0, !document.isBlank(lineIndex) {
            let next = document.prefix(lineIndex + 1)
            guard next.length > 0 else { return nil }
            return MarkdownEdit(range: NSRange(location: caret, length: 1 + next.length), replacement: "",
                                selection: NSRange(location: caret, length: 0))
        }
        var target = caret
        if options.concealsInlineMarkers {
            target = MarkdownInline.visibleBoundary(after: caret, spans: MarkdownInline.spans(document, line: lineIndex))
        }
        guard target < NSMaxRange(line) else { return nil }
        let character = source.rangeOfComposedCharacterSequence(at: target)
        return deletion(document, range: character, natural: source.rangeOfComposedCharacterSequence(at: caret), options: options)
    }

    /// Deleting a selection: removes spans it empties and a heading's marks when it empties the heading.
    static func deleteSelection(_ document: MarkdownLines, selection: NSRange, options: MarkdownEditingOptions) -> MarkdownEdit? {
        deletion(document, range: selection, natural: selection, options: options)
    }

    /// Deletes `range`, widened to whole spans it empties. Returns nil when the result is what the
    /// editor would do itself (deleting `natural`).
    private static func deletion(_ document: MarkdownLines, range: NSRange, natural: NSRange, options: MarkdownEditingOptions) -> MarkdownEdit? {
        var range = range
        if options.concealsInlineMarkers {
            let first = document.index(at: range.location), last = document.index(at: NSMaxRange(range))
            var spans: [MarkdownInline.Span] = []
            for line in first...last { spans += MarkdownInline.spans(document, line: line) }
            range = MarkdownInline.widen(range, toSpansEmptiedIn: spans)
        }
        let old = document.source as String
        var new = (old as NSString).replacingCharacters(in: range, with: "")
        var caret = range.location
        // A heading left without text loses its marks too ("# a" → Backspace → "", not "# ").
        let lineIndex = document.index(at: range.location)
        if !document.code[lineIndex], case .heading = document.prefix(lineIndex).kind {
            let line = document.ranges[lineIndex]
            let prefix = document.prefix(lineIndex)
            let hadText = !document.text(lineIndex).dropFirst(prefix.marker.count).trimmingCharacters(in: .whitespaces).isEmpty
            let after = MarkdownLines(new)
            let afterIndex = after.index(at: caret)
            let afterText = after.text(afterIndex)
            if hadText, after.ranges[afterIndex].location == line.location, case .heading = after.prefix(afterIndex).kind,
               afterText.dropFirst(after.prefix(afterIndex).marker.count).trimmingCharacters(in: .whitespaces).isEmpty {
                new = (new as NSString).replacingCharacters(in: after.ranges[afterIndex], with: "")
                caret = line.location
            }
        }
        if new == (old as NSString).replacingCharacters(in: natural, with: ""), caret == natural.location { return nil }
        return MarkdownEdit.between(old, new, selection: NSRange(location: caret, length: 0))
    }

    /// Backspace right after a line's block marker.
    private static func removeBlockMarker(_ document: MarkdownLines, line index: Int, prefix: MarkdownLinePrefix, caret: Int) -> MarkdownEdit? {
        let line = document.ranges[index]
        switch prefix.kind {
        case .heading:
            return MarkdownEdit(range: NSRange(location: line.location, length: prefix.length), replacement: "",
                                selection: NSRange(location: line.location, length: 0))
        case .quote:
            let quote = prefix.quote as NSString
            // Remove the innermost level: "> > text" → "> text", "> text" → "text".
            let last = quote.range(of: ">", options: .backwards).location
            let replacement = last == NSNotFound ? "" : quote.substring(to: last)
            return MarkdownEdit(range: NSRange(location: line.location, length: quote.length), replacement: replacement,
                                selection: NSRange(location: line.location + (replacement as NSString).length, length: 0))
        case .bullet, .ordered, .task:
            guard var block = MarkdownListBlock(document, around: index) else { return nil }
            let local = index - block.first
            let parents = block.parents()
            if parents[local] != nil || prefix.indentColumns > 0 {
                return outdent(document, block: &block, items: [local], selection: NSRange(location: caret, length: 0))
            }
            // A top-level item becomes a paragraph (or a plain quote line inside a quote).
            let content = block.lines[local].content
            block.lines[local] = MarkdownListBlock.line(prefix.quote + content, quote: prefix.quote)
            // Its children stay where they are and keep their own list.
            block.renumber()
            return rewrite(document, block: block, selection: NSRange(location: line.location + (prefix.quote as NSString).length, length: 0), mapped: false)
        case .paragraph:
            return nil
        }
    }

    // MARK: Return

    /// Return.
    ///
    /// - In a list item with text: a new item follows with the same bullet, the next number or an
    ///   unchecked box; the text after the caret moves into it; following numbers are renumbered.
    /// - In an empty list item: a nested item moves out one level; a top-level item ends the list
    ///   (its marker goes).
    /// - In a quote: the next line continues the quote; on an empty quote line one level ends.
    /// - At the start of a heading's text: a new line opens above the heading, which stays whole.
    /// - In fenced code, or with a selection over several lines: nil (a plain newline).
    public static func insertNewline(in text: String, selection: NSRange) -> MarkdownEdit? {
        let original = MarkdownLines(text)
        guard selection.location != NSNotFound, NSMaxRange(selection) <= original.source.length else { return nil }
        let startLine = original.index(at: selection.location)
        guard original.index(at: NSMaxRange(selection)) == startLine, !original.code[startLine] else { return nil }
        // Work on the text without the selection; the result is compared with the original.
        let removed = original.source.replacingCharacters(in: selection, with: "")
        let document = MarkdownLines(removed)
        let caret = selection.location
        let index = document.index(at: caret)
        let line = document.ranges[index]
        let prefix = document.prefix(index)
        let lineText = document.text(index)
        guard prefix.length > 0, caret >= line.location + prefix.length else { return nil }
        let contentRange = NSRange(location: line.location + prefix.length, length: NSMaxRange(line) - line.location - prefix.length)
        let content = document.source.substring(with: contentRange)
        let empty = content.trimmingCharacters(in: .whitespaces).isEmpty

        func finish(_ new: String, caret: Int) -> MarkdownEdit {
            MarkdownEdit.between(text, new, selection: NSRange(location: caret, length: 0))
        }

        switch prefix.kind {
        case .heading:
            guard !empty, caret == line.location + prefix.length else { return nil }
            let new = (removed as NSString).replacingCharacters(in: NSRange(location: line.location, length: 0), with: "\n")
            return finish(new, caret: caret + 1)
        case .quote:
            if empty {
                guard let edit = removeBlockMarker(document, line: index, prefix: prefix, caret: caret) else { return nil }
                return finish(edit.applied(to: removed), caret: edit.selection.location)
            }
            let before = (lineText as NSString).substring(to: caret - line.location)
            let after = trimmingLeadingSpace((lineText as NSString).substring(from: caret - line.location))
            let new = (removed as NSString).replacingCharacters(in: line, with: before + "\n" + prefix.quote + after)
            return finish(new, caret: caret + 1 + (prefix.quote as NSString).length)
        case .bullet, .ordered, .task:
            guard var block = MarkdownListBlock(document, around: index) else { return nil }
            let local = index - block.first
            if empty {
                let parents = block.parents()
                if parents[local] != nil || prefix.indentColumns > 0 {
                    guard let edit = outdent(document, block: &block, items: [local], selection: NSRange(location: caret, length: 0)) else { return nil }
                    return finish(edit.applied(to: removed), caret: edit.selection.location)
                }
                guard let edit = removeBlockMarker(document, line: index, prefix: prefix, caret: line.location + prefix.length) else { return nil }
                return finish(edit.applied(to: removed), caret: edit.selection.location)
            }
            let split = caret - line.location - prefix.length
            let head = (content as NSString).substring(to: split)
            let tail = trimmingLeadingSpace((content as NSString).substring(from: split))
            block.lines[local].content = head
            var next = block.lines[local]
            next.prefix.marker = prefix.continuationMarker
            if case .task = prefix.kind { next.prefix.kind = .task(checked: false) }
            next.prefix.number = prefix.kind == .ordered ? Int(next.prefix.marker.prefix { $0.isNumber }) : nil
            next.content = tail
            let lineCount = block.lines.count
            block.lines.insert(next, at: local + 1)
            block.renumber()
            var offset = document.ranges[block.first].location
            for item in block.lines[...local] { offset += (item.text as NSString).length + 1 }
            let caretAfter = offset + block.lines[local + 1].head
            return finish(replacing(document, block, lineCount: lineCount), caret: caretAfter)
        case .paragraph:
            return nil
        }
    }

    /// Shift-Return: a new line without a new marker. In a list item the line is indented under
    /// the item's text (a continuation line); elsewhere it is a plain newline. Never nil, so the
    /// editor never inserts a Unicode line separator into the Markdown.
    public static func insertLineBreak(in text: String, selection: NSRange) -> MarkdownEdit {
        let document = MarkdownLines(text)
        let plain = MarkdownEdit(range: selection, replacement: "\n", selection: NSRange(location: selection.location + 1, length: 0))
        guard selection.location != NSNotFound, NSMaxRange(selection) <= document.source.length else { return plain }
        let index = document.index(at: selection.location)
        let prefix = document.prefix(index)
        guard prefix.isListItem, selection.location >= document.ranges[index].location + prefix.length else { return plain }
        let continuation = "\n" + prefix.quote + String(repeating: " ", count: prefix.childColumn)
        return MarkdownEdit(range: selection, replacement: continuation,
                            selection: NSRange(location: selection.location + (continuation as NSString).length, length: 0))
    }

    // MARK: Tab and Shift-Tab

    /// Tab in a list item (anywhere in it, empty or not; with a selection, every item it touches):
    /// the item and its children move one level in, under the previous item. A nested ordered
    /// item restarts at 1 and the old siblings are renumbered. The first item of a list has no
    /// item to nest under and stays (the key is still handled, so no tab character is typed).
    /// Returns nil outside lists, where Tab types a tab.
    public static func indent(in text: String, selection: NSRange) -> MarkdownEdit? {
        shiftItems(in: text, selection: selection, inward: true)
    }

    /// Shift-Tab in a list item: the item and its children move one level out and become a
    /// sibling of their parent; later siblings become its children; numbers follow. At the top
    /// level nothing changes. Returns nil outside lists.
    public static func outdent(in text: String, selection: NSRange) -> MarkdownEdit? {
        shiftItems(in: text, selection: selection, inward: false)
    }

    private static func shiftItems(in text: String, selection: NSRange, inward: Bool) -> MarkdownEdit? {
        let document = MarkdownLines(text)
        guard selection.location != NSNotFound, NSMaxRange(selection) <= document.source.length else { return nil }
        let firstLine = document.index(at: selection.location)
        var lastLine = document.index(at: NSMaxRange(selection))
        // A selection ending at the start of a line doesn't include that line.
        if lastLine > firstLine, NSMaxRange(selection) == document.ranges[lastLine].location { lastLine -= 1 }
        guard let anchor = (firstLine...lastLine).first(where: { !document.code[$0] && document.prefix($0).isListItem }),
              var block = MarkdownListBlock(document, around: anchor) else { return nil }
        let items = (firstLine...lastLine).filter { $0 >= block.first && $0 < block.first + block.lines.count && block.lines[$0 - block.first].isItem }
            .map { $0 - block.first }
        if inward { return indent(document, block: &block, items: items, selection: selection) }
        return outdent(document, block: &block, items: items, selection: selection)
            ?? MarkdownEdit(range: NSRange(location: selection.location, length: 0), replacement: "", selection: selection)
    }

    private static func indent(_ document: MarkdownLines, block: inout MarkdownListBlock, items: [Int], selection: NSRange) -> MarkdownEdit? {
        let unchanged = MarkdownEdit(range: NSRange(location: selection.location, length: 0), replacement: "", selection: selection)
        let original = block
        var moved = Set<Int>()
        for item in items where !moved.contains(item) {
            let parents = block.parents()
            guard let sibling = block.previousSibling(of: item, parents: parents) else {
                // The first item can't go in; with a selection, nothing moves.
                return unchanged
            }
            // Nest under the sibling: line up with its existing children, else its text.
            let child = block.lines.indices.first { $0 > sibling && $0 < item && parents[$0] == sibling }
            let target = child.map { block.lines[$0].columns } ?? block.lines[sibling].prefix.childColumn
            let end = block.subtreeEnd(of: item)
            block.shift(item...end, by: target - block.lines[item].columns)
            moved.formUnion(item...end)
        }
        block.renumber()
        return rewrite(document, block: block, original: original, selection: selection)
    }

    private static func outdent(_ document: MarkdownLines, block: inout MarkdownListBlock, items: [Int], selection: NSRange) -> MarkdownEdit? {
        let original = block
        var moved = Set<Int>()
        var changed = false
        for item in items where !moved.contains(item) {
            let parents = block.parents()
            let target = parents[item].map { block.lines[$0].columns } ?? 0
            let delta = target - block.lines[item].columns
            guard delta < 0 else { continue }
            let end = block.subtreeEnd(of: item)
            block.shift(item...end, by: delta)
            moved.formUnion(item...end)
            changed = true
        }
        guard changed else { return nil }
        block.renumber()
        return rewrite(document, block: block, original: original, selection: selection)
    }

    // MARK: Typing

    /// Typing `typed` (one keystroke, or text from an input method once committed).
    ///
    /// - With a selection on one line, `*`, `_`, `` ` ``, `[` and `(` wrap it instead of
    ///   replacing it; the selection stays on the wrapped text.
    /// - `(` and `[` before a space, punctuation or the line end add their closing bracket.
    /// - `)` and `]` step over the same bracket right after the caret when one is open.
    /// - A space after `[ ]`, `[x]` or `[]` at the start of a line (or after a bullet) makes a
    ///   checkbox, `- [ ] `.
    /// Returns nil for ordinary typing.
    public static func insertText(_ typed: String, in text: String, selection: NSRange, options: MarkdownEditingOptions) -> MarkdownEdit? {
        let document = MarkdownLines(text)
        let source = document.source
        guard selection.location != NSNotFound, NSMaxRange(selection) <= source.length else { return nil }
        let index = document.index(at: selection.location)
        guard !document.code[index] else { return nil }
        let line = document.ranges[index]
        if selection.length > 0 {
            let pairs = ["*": "*", "_": "_", "`": "`", "[": "]", "(": ")"]
            guard let close = pairs[typed], document.index(at: NSMaxRange(selection)) == index else { return nil }
            let selected = source.substring(with: selection)
            return MarkdownEdit(range: selection, replacement: typed + selected + close,
                                selection: NSRange(location: selection.location + 1, length: selection.length))
        }
        let caret = selection.location
        let next: unichar? = caret < NSMaxRange(line) ? source.character(at: caret) : nil
        if options.pairsBrackets, typed == "(" || typed == "[" {
            let closers = Set(" \t)]}.,;:!?".utf16)
            guard next == nil || closers.contains(next!) else { return nil }
            return MarkdownEdit(range: selection, replacement: typed + (typed == "(" ? ")" : "]"),
                                selection: NSRange(location: caret + 1, length: 0))
        }
        if options.pairsBrackets, typed == ")" || typed == "]", let next, next == (typed as NSString).character(at: 0) {
            // Step over the closing bracket only when one is open before the caret on this line.
            let before = source.substring(with: NSRange(location: line.location, length: caret - line.location))
            let open: Character = typed == ")" ? "(" : "["
            let close: Character = typed == ")" ? ")" : "]"
            if before.filter({ $0 == open }).count > before.filter({ $0 == close }).count {
                return MarkdownEdit(range: NSRange(location: caret, length: 0), replacement: "",
                                    selection: NSRange(location: caret + 1, length: 0))
            }
            return nil
        }
        if typed == " " {
            let typedText = source.replacingCharacters(in: selection, with: " ")
            if let format = autoFormat(in: typedText, caret: caret + 1) {
                return MarkdownEdit.between(text, format.applied(to: typedText), selection: format.selection)
            }
        }
        return nil
    }

    /// The input rule run after a space was typed at `caret` (the caret after the space): turns
    /// `[ ] `, `[x] ` or `[] ` at the start of a line, or after a bullet, into `- [ ] `. The Mac
    /// applies it as a second undo step, so the first Undo keeps what was typed.
    public static func autoFormat(in text: String, caret: Int) -> MarkdownEdit? {
        let document = MarkdownLines(text)
        guard caret > 0, caret <= document.source.length else { return nil }
        let index = document.index(at: caret)
        guard !document.code[index] else { return nil }
        let line = document.ranges[index]
        let before = document.source.substring(with: NSRange(location: line.location, length: caret - line.location))
        let pattern = try! NSRegularExpression(pattern: "^((?:> ?)*)([ \\t]*)([-*+] )?\\[([ xX]?)\\] $")
        guard let match = pattern.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) else { return nil }
        let value = before as NSString
        let quote = value.substring(with: match.range(at: 1))
        let indent = value.substring(with: match.range(at: 2))
        let bullet = match.range(at: 3).location == NSNotFound ? "- " : value.substring(with: match.range(at: 3))
        let state = value.substring(with: match.range(at: 4))
        let formatted = quote + indent + bullet + "[" + (state.isEmpty ? " " : state) + "] "
        guard formatted != before else { return nil }
        return MarkdownEdit(range: NSRange(location: line.location, length: value.length), replacement: formatted,
                            selection: NSRange(location: line.location + (formatted as NSString).length, length: 0))
    }

    // MARK: Paste

    /// Pasting plain text. Line endings become `\n`. Pasting list items, quote lines or a heading
    /// into an empty list item, quote line or heading replaces the empty marker rather than
    /// stacking a second one ("- " + "- a" is "- a", not "- - a"); pasted lines keep the item's
    /// indentation and quote. Returns nil when the editor's own paste is right.
    public static func paste(_ pasted: String, in text: String, selection: NSRange) -> MarkdownEdit? {
        let document = MarkdownLines(text)
        guard selection.location != NSNotFound, NSMaxRange(selection) <= document.source.length else { return nil }
        let normalized = pasted.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let plain = MarkdownEdit(range: selection, replacement: normalized,
                                 selection: NSRange(location: selection.location + (normalized as NSString).length, length: 0))
        let index = document.index(at: selection.location)
        guard !document.code[index], document.index(at: NSMaxRange(selection)) == index else {
            return normalized == pasted ? nil : plain
        }
        let line = document.ranges[index]
        let prefix = document.prefix(index)
        let content = document.text(index).dropFirst(prefix.marker.count + prefix.indent.count + prefix.quote.count)
        let pastedLines = normalized.components(separatedBy: "\n")
        let firstPasted = MarkdownLinePrefix.parse(pastedLines[0].trimmingCharacters(in: .whitespaces))
        guard prefix.length > 0, content.trimmingCharacters(in: .whitespaces).isEmpty, firstPasted.length > 0 else {
            return normalized == pasted ? nil : plain
        }
        // Pasted quote lines bring their own quote marks.
        let quote = firstPasted.quote.isEmpty ? prefix.quote : ""
        let lead = quote + prefix.indent
        let replaced = pastedLines.enumerated().map { offset, value in
            offset == 0 ? lead + value.trimmingCharacters(in: .whitespaces)
                : (value.isEmpty ? quote.trimmingCharacters(in: .whitespaces) : lead + value)
        }.joined(separator: "\n")
        let range = NSRange(location: line.location, length: line.length)
        return MarkdownEdit(range: range, replacement: replaced,
                            selection: NSRange(location: line.location + (replaced as NSString).length, length: 0))
    }

    // MARK: Rendering help

    /// Nesting depth (0 for top-level items) of every list item, keyed by the UTF-16 location of
    /// its line. The renderers indent nested items by depth instead of by raw spaces.
    public static func listDepths(in text: String) -> [Int: Int] {
        let document = MarkdownLines(text)
        var depths: [Int: Int] = [:]
        var stack: [Int] = []
        var quote: String?
        for index in 0..<document.count {
            guard !document.code[index] else { stack = []; continue }
            let prefix = document.prefix(index)
            if prefix.isListItem {
                if prefix.quote != quote { stack = []; quote = prefix.quote }
                while let top = stack.last, top >= prefix.indentColumns { stack.removeLast() }
                depths[document.ranges[index].location] = stack.count
                stack.append(prefix.indentColumns)
            } else if !document.isBlank(index) {
                let text = document.text(index)
                let rest = text.dropFirst(prefix.quote.count)
                if !(rest.first == " " || rest.first == "\t") { stack = [] }
            }
        }
        return depths
    }

    // MARK: Helpers

    private static func trimmingLeadingSpace(_ value: String) -> String {
        String(value.drop { $0 == " " || $0 == "\t" })
    }

    /// The text with the block's `lineCount` original lines replaced by its current lines.
    private static func replacing(_ document: MarkdownLines, _ block: MarkdownListBlock, lineCount: Int) -> String {
        let start = document.ranges[block.first].location
        let end = NSMaxRange(document.ranges[block.first + lineCount - 1])
        let joined = block.lines.map(\.text).joined(separator: "\n")
        return document.source.replacingCharacters(in: NSRange(location: start, length: end - start), with: joined)
    }

    /// Writes a block whose lines map one to one onto the document's (`original`), carrying the
    /// selection: a location in a line's text keeps its place in the text; one inside a marker
    /// keeps its distance from the text, so the caret never lands inside the new marker.
    private static func rewrite(_ document: MarkdownLines, block: MarkdownListBlock, original: MarkdownListBlock? = nil,
                                selection: NSRange, mapped: Bool = true) -> MarkdownEdit {
        let new = replacing(document, block, lineCount: block.lines.count)
        guard mapped, let original else { return MarkdownEdit.between(document.source as String, new, selection: selection) }
        let start = document.ranges[block.first].location
        let delta = (new as NSString).length - document.source.length
        func map(_ location: Int) -> Int {
            let index = document.index(at: location)
            guard index >= block.first, index < block.first + block.lines.count else {
                return location < start ? location : location + delta
            }
            let local = index - block.first
            var lineStart = start
            for line in block.lines[..<local] { lineStart += (line.text as NSString).length + 1 }
            let offset = location - document.ranges[index].location
            let oldHead = original.lines[local].head, newHead = block.lines[local].head
            if offset >= oldHead { return lineStart + newHead + offset - oldHead }
            return lineStart + max(0, newHead - (oldHead - offset))
        }
        let from = map(selection.location)
        let to = selection.length > 0 ? map(NSMaxRange(selection)) : from
        return MarkdownEdit.between(document.source as String, new, selection: NSRange(location: from, length: max(0, to - from)))
    }
}
