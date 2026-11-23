import Foundation

/// The block syntax at the start of one Markdown line, as the Matilde editors understand it:
/// an optional quote (`> `, `> > `), then for list items their indentation and marker
/// (`- `, `* `, `+ `, `12. `, `3) `, `- [ ] `, `- [x] `), or a heading's `#` marks (only at the
/// very start of a line, like the renderers). Everything after the prefix is the line's content.
public struct MarkdownLinePrefix: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case paragraph
        case heading(Int)
        case quote
        case bullet
        case ordered
        case task(checked: Bool)
    }

    public var kind: Kind
    /// Quote marks, e.g. `"> "` or `"> > "`; empty outside quotes.
    public var quote: String
    /// Whitespace between the quote and a list marker; empty for other kinds.
    public var indent: String
    /// The marker including its trailing space: `"- "`, `"12. "`, `"- [ ] "`, `"## "`.
    public var marker: String
    /// An ordered item's number, nil when it doesn't fit an `Int`.
    public var number: Int?

    /// UTF-16 length of the whole prefix: the content starts here.
    public var length: Int { (quote as NSString).length + (indent as NSString).length + (marker as NSString).length }
    public var isListItem: Bool {
        switch kind {
        case .bullet, .ordered, .task: return true
        default: return false
        }
    }
    /// Visual columns of the indentation (a tab advances to the next multiple of four).
    public var indentColumns: Int { MarkdownLinePrefix.columns(of: indent) }
    /// Where a child item's marker goes: after the bullet or number and its space. For a task
    /// that is after `- `, as in CommonMark and GitHub.
    public var childColumn: Int {
        switch kind {
        case .task: return indentColumns + 2
        default: return indentColumns + (marker as NSString).length
        }
    }
    /// The bullet or number with its delimiter, e.g. `-` or `3.`.
    var bulletOrNumber: String {
        switch kind {
        case .task: return String(marker.prefix(1))
        default: return marker.trimmingCharacters(in: .whitespaces)
        }
    }
    /// `.` or `)` for ordered items.
    var delimiter: Character? { kind == .ordered ? marker.trimmingCharacters(in: .whitespaces).last : nil }

    static func columns(of whitespace: String) -> Int {
        var columns = 0
        for character in whitespace {
            if character == "\t" { columns += 4 - columns % 4 } else { columns += 1 }
        }
        return columns
    }

    private static let headingPattern = try! NSRegularExpression(pattern: "^(#{1,6}) ")
    private static let quotePattern = try! NSRegularExpression(pattern: "^(?:> ?)+")
    private static let listPattern = try! NSRegularExpression(
        pattern: "^([ \\t]*)(?:([-*+]) \\[([ xX])\\] |([-*+]) |([0-9]+)([.)]) )")

    /// Parses `line` (one line, without its newline).
    public static func parse(_ line: String) -> MarkdownLinePrefix {
        let source = line as NSString
        let whole = NSRange(location: 0, length: source.length)
        if let heading = headingPattern.firstMatch(in: line, range: whole) {
            return MarkdownLinePrefix(kind: .heading(heading.range(at: 1).length), quote: "", indent: "",
                                      marker: source.substring(with: heading.range), number: nil)
        }
        var quote = ""
        if let match = quotePattern.firstMatch(in: line, range: whole) { quote = source.substring(with: match.range) }
        let rest = source.substring(from: (quote as NSString).length)
        let restSource = rest as NSString
        if let list = listPattern.firstMatch(in: rest, range: NSRange(location: 0, length: restSource.length)) {
            let indent = restSource.substring(with: list.range(at: 1))
            let marker = restSource.substring(with: NSRange(location: NSMaxRange(list.range(at: 1)),
                                                            length: NSMaxRange(list.range) - NSMaxRange(list.range(at: 1))))
            if list.range(at: 2).location != NSNotFound {
                let checked = restSource.substring(with: list.range(at: 3)) != " "
                return MarkdownLinePrefix(kind: .task(checked: checked), quote: quote, indent: indent, marker: marker, number: nil)
            }
            if list.range(at: 4).location != NSNotFound {
                return MarkdownLinePrefix(kind: .bullet, quote: quote, indent: indent, marker: marker, number: nil)
            }
            let number = Int(restSource.substring(with: list.range(at: 5)))
            return MarkdownLinePrefix(kind: .ordered, quote: quote, indent: indent, marker: marker, number: number)
        }
        if !quote.isEmpty {
            return MarkdownLinePrefix(kind: .quote, quote: quote, indent: "", marker: "", number: nil)
        }
        return MarkdownLinePrefix(kind: .paragraph, quote: "", indent: "", marker: "", number: nil)
    }

    /// The marker for the next item after this one: the same bullet, the next number, an
    /// unchecked box.
    var continuationMarker: String {
        switch kind {
        case .task: return String(marker.prefix(1)) + " [ ] "
        case .ordered:
            guard let number else { return marker }
            let next = number.addingReportingOverflow(1)
            return next.overflow ? marker : MarkdownLinePrefix.renumbered(marker, to: next.partialValue)
        default: return marker
        }
    }

    static func renumbered(_ marker: String, to number: Int) -> String {
        let digits = marker.prefix { $0.isNumber }
        return String(number) + marker.dropFirst(digits.count)
    }
}

/// The text split into lines, with fenced code marked, for the editing rules.
struct MarkdownLines {
    let source: NSString
    /// Each line's range without its newline.
    let ranges: [NSRange]
    /// True for fence lines (```` ``` ````, `~~~`) and the lines between them: no Markdown rules apply there.
    let code: [Bool]

    init(_ text: String) {
        source = text as NSString
        var ranges: [NSRange] = []
        var start = 0
        for index in 0..<source.length where source.character(at: index) == 10 {
            ranges.append(NSRange(location: start, length: index - start))
            start = index + 1
        }
        ranges.append(NSRange(location: start, length: source.length - start))
        self.ranges = ranges
        var code: [Bool] = []
        var fence: String?
        for range in ranges {
            let trimmed = source.substring(with: range).trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))
                if fence == nil { fence = marker } else if fence == marker { fence = nil }
                code.append(true)
            } else {
                code.append(fence != nil)
            }
        }
        self.code = code
    }

    var count: Int { ranges.count }
    func text(_ index: Int) -> String { source.substring(with: ranges[index]) }
    func prefix(_ index: Int) -> MarkdownLinePrefix {
        code[index] ? MarkdownLinePrefix(kind: .paragraph, quote: "", indent: "", marker: "", number: nil)
            : MarkdownLinePrefix.parse(text(index))
    }
    func isBlank(_ index: Int) -> Bool { text(index).trimmingCharacters(in: .whitespaces).isEmpty }

    /// The line containing `location`; a location at a line's end belongs to that line.
    func index(at location: Int) -> Int {
        var low = 0, high = ranges.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if ranges[middle].location <= location { low = middle } else { high = middle - 1 }
        }
        return low
    }
}

/// A run of list lines (items, their continuation lines and blank lines between them) that
/// indent, outdent and renumbering work on.
struct MarkdownListBlock {
    struct Line {
        var prefix: MarkdownLinePrefix
        /// The line's text after its prefix (for continuation lines: after the quote and leading whitespace).
        var content: String
        /// Leading whitespace of a continuation line (after the quote).
        var leading: String
        var isItem: Bool { prefix.isListItem }
        var isBlank: Bool { !isItem && content.trimmingCharacters(in: .whitespaces).isEmpty }
        var columns: Int { isItem ? prefix.indentColumns : MarkdownLinePrefix.columns(of: leading) }
        var text: String { prefix.quote + (isItem ? prefix.indent + prefix.marker : leading) + content }
        /// UTF-16 offset of the content in `text`.
        var head: Int { (text as NSString).length - (content as NSString).length }
    }

    let first: Int
    var lines: [Line]

    /// The block around line `index`, which must be a list item outside code.
    init?(_ document: MarkdownLines, around index: Int) {
        let prefix = document.prefix(index)
        guard prefix.isListItem else { return nil }
        let quote = prefix.quote
        func belongs(_ line: Int) -> Bool {
            guard !document.code[line] else { return false }
            let other = document.prefix(line)
            if other.isListItem { return other.quote == quote }
            let text = document.text(line)
            guard text.hasPrefix(quote) else { return false }
            let rest = String(text.dropFirst(quote.count))
            if case .heading = other.kind { return false }
            if rest.trimmingCharacters(in: .whitespaces).isEmpty { return true }
            // Continuation lines are indented under their item.
            return rest.first == " " || rest.first == "\t"
        }
        var start = index, end = index
        while start > 0, belongs(start - 1) { start -= 1 }
        while end < document.count - 1, belongs(end + 1) { end += 1 }
        while start < index, document.isBlank(start) { start += 1 }
        while end > index, document.isBlank(end) { end -= 1 }
        first = start
        lines = (start...end).map { MarkdownListBlock.line(document.text($0), quote: quote) }
    }

    static func line(_ text: String, quote: String) -> Line {
        let prefix = MarkdownLinePrefix.parse(text)
        if prefix.isListItem {
            return Line(prefix: prefix, content: String((text as NSString).substring(from: prefix.length)), leading: "")
        }
        let rest = String(text.dropFirst(text.hasPrefix(quote) ? quote.count : 0))
        let leading = String(rest.prefix { $0 == " " || $0 == "\t" })
        let bare = MarkdownLinePrefix(kind: quote.isEmpty ? .paragraph : .quote, quote: text.hasPrefix(quote) ? quote : "",
                                      indent: "", marker: "", number: nil)
        return Line(prefix: bare, content: String(rest.dropFirst(leading.count)), leading: leading)
    }

    /// The parent item of each line (nil at the top level or for lines that aren't items).
    func parents() -> [Int?] {
        var stack: [Int] = []
        var result: [Int?] = []
        for (index, line) in lines.enumerated() {
            guard line.isItem else { result.append(nil); continue }
            while let top = stack.last, lines[top].columns >= line.columns { stack.removeLast() }
            result.append(stack.last)
            stack.append(index)
        }
        return result
    }

    func previousSibling(of index: Int, parents: [Int?]) -> Int? {
        var candidate = index - 1
        while candidate >= 0 {
            if lines[candidate].isItem {
                if parents[candidate] == parents[index] { return candidate }
                // Reaching the parent itself means there's no earlier sibling.
                if candidate == parents[index] { return nil }
                if let parent = parents[index], candidate < parent { return nil }
                if parents[index] == nil, lines[candidate].columns < lines[index].columns { return nil }
            }
            candidate -= 1
        }
        return nil
    }

    /// The last line that belongs to the item at `index`: its children and continuation lines.
    func subtreeEnd(of index: Int) -> Int {
        let columns = lines[index].columns
        var end = index
        var probe = index + 1
        while probe < lines.count {
            let line = lines[probe]
            if line.isBlank { probe += 1; continue }
            guard line.columns > columns else { break }
            end = probe
            probe += 1
        }
        return end
    }

    /// Moves lines `range` by `delta` columns (indentation rewritten with spaces).
    mutating func shift(_ range: ClosedRange<Int>, by delta: Int) {
        for index in range where !lines[index].isBlank {
            let columns = max(0, lines[index].columns + delta)
            let whitespace = String(repeating: " ", count: columns)
            if lines[index].isItem { lines[index].prefix.indent = whitespace } else { lines[index].leading = whitespace }
        }
    }

    /// Numbers ordered items one after another within each run of siblings. A nested run starts
    /// at 1; a top-level run keeps the number it starts with.
    mutating func renumber() {
        let parents = parents()
        for index in lines.indices where lines[index].isItem && lines[index].prefix.kind == .ordered {
            let prefix = lines[index].prefix
            var number: Int?
            if let previous = previousSibling(of: index, parents: parents),
               lines[previous].prefix.kind == .ordered, lines[previous].prefix.delimiter == prefix.delimiter {
                if let value = lines[previous].prefix.number {
                    let next = value.addingReportingOverflow(1)
                    number = next.overflow ? value : next.partialValue
                }
            } else if parents[index] != nil {
                number = 1
            }
            guard let number, number != prefix.number else { continue }
            lines[index].prefix.marker = MarkdownLinePrefix.renumbered(prefix.marker, to: number)
            lines[index].prefix.number = number
        }
    }
}
