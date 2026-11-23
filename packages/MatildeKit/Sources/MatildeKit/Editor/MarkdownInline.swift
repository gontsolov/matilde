import Foundation

/// Inline spans whose markers the Mac editor hides: code, bold, italic and web links. The
/// patterns match the Mac renderer (`MarkdownStyler`), so a span is found here exactly when its
/// markers are invisible there.
enum MarkdownInline {
    struct Span: Equatable {
        /// The whole span, markers included.
        var range: NSRange
        /// The visible text between the markers.
        var content: NSRange
    }

    private static let code = try! NSRegularExpression(pattern: "`([^`\\n]+)`")
    private static let emphasis: [(NSRegularExpression, Int)] = [
        ("(?<![\\\\*])\\*\\*([^*\\n]+)\\*\\*", 2),
        ("(?<![\\\\_])__([^_\\n]+)__", 2),
        ("(?<![\\\\*])\\*([^*\\n]+)\\*(?!\\*)", 1),
        ("(?<![\\w\\\\_])_([^_\\n]+)_(?!\\w)", 1)
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
    private static let link = try! NSRegularExpression(pattern: #"(?<!!)\[((?:\\.|[^\]\\\n])+)\]\(([^\s)]+)\)"#)

    /// The hidden-marker spans on line `index` (none in code), in document locations.
    static func spans(_ document: MarkdownLines, line index: Int) -> [Span] {
        guard index < document.count, !document.code[index] else { return [] }
        let range = document.ranges[index]
        let text = document.text(index)
        let whole = NSRange(location: 0, length: range.length)
        var spans: [Span] = []
        var codeRanges: [NSRange] = []
        func overlapsCode(_ candidate: NSRange) -> Bool {
            codeRanges.contains { NSIntersectionRange($0, candidate).length > 0 }
        }
        for match in code.matches(in: text, range: whole) {
            codeRanges.append(match.range)
            spans.append(Span(range: match.range, content: match.range(at: 1)))
        }
        for (pattern, _) in emphasis {
            for match in pattern.matches(in: text, range: whole) where !overlapsCode(match.range) {
                spans.append(Span(range: match.range, content: match.range(at: 1)))
            }
        }
        let source = text as NSString
        for match in link.matches(in: text, range: whole) where !overlapsCode(match.range) {
            let destination = source.substring(with: match.range(at: 2))
            guard let scheme = URL(string: destination)?.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { continue }
            spans.append(Span(range: match.range, content: match.range(at: 1)))
        }
        return spans.map {
            Span(range: NSRange(location: $0.range.location + range.location, length: $0.range.length),
                 content: NSRange(location: $0.content.location + range.location, length: $0.content.length))
        }
    }

    /// Moving left from `location` past hidden markers: the place right after the visible
    /// character Backspace should delete.
    static func visibleBoundary(before location: Int, spans: [Span]) -> Int {
        var position = location
        var moved = true
        while moved {
            moved = false
            for span in spans {
                // After (or inside) a closing marker: to the end of the text.
                if position > NSMaxRange(span.content), position <= NSMaxRange(span.range) {
                    position = NSMaxRange(span.content); moved = true
                }
                // After (or inside) an opening marker: before the span.
                if position > span.range.location, position <= span.content.location {
                    position = span.range.location; moved = true
                }
            }
        }
        return position
    }

    /// Moving right from `location` past hidden markers: the place right before the visible
    /// character Delete should remove.
    static func visibleBoundary(after location: Int, spans: [Span]) -> Int {
        var position = location
        var moved = true
        while moved {
            moved = false
            for span in spans {
                if position >= span.range.location, position < span.content.location {
                    position = span.content.location; moved = true
                }
                if position >= NSMaxRange(span.content), position < NSMaxRange(span.range) {
                    position = NSMaxRange(span.range); moved = true
                }
            }
        }
        return position
    }

    /// `range` grown to cover every span whose whole text it deletes, so no empty markers stay.
    static func widen(_ range: NSRange, toSpansEmptiedIn spans: [Span]) -> NSRange {
        var result = range
        var grew = true
        while grew {
            grew = false
            for span in spans where span.content.length > 0 {
                let covered = span.content.location >= result.location && NSMaxRange(span.content) <= NSMaxRange(result)
                if covered, NSUnionRange(result, span.range) != result {
                    result = NSUnionRange(result, span.range); grew = true
                }
            }
        }
        return result
    }
}
