import Foundation
import UIKit
import CoreText

/// IOS-05: how the editor dresses Markdown, close to the Mac editor (apps/macos
/// MarkdownEditor.swift) but simpler: the Markdown stays visible and editable; syntax marks are
/// faded rather than hidden, headings use Newsreader at the Mac's sizes, emphasis is bold or
/// italic, code is monospaced and quotes are indented.
///
/// `spans(in:)` is pure so tests can check it; `apply(to:)` turns spans into attributes.
enum MarkdownStyle {
    enum Kind: Equatable {
        case heading(Int)
        case bold
        case italic
        case code
        case quote
        case listMarker
        case link
        /// Syntax characters (`#`, `**`, `` ` ``, `>`, link brackets): drawn faded.
        case mark
    }

    struct Span: Equatable {
        let kind: Kind
        let range: NSRange
    }

    static let textSize: CGFloat = 19

    /// Heading sizes on the Mac's modular scale (Typography.headingSize), for 19 pt text.
    static func headingSize(level: Int) -> CGFloat {
        let steps: [CGFloat] = [3, 2, 1, 0, 0, 0]
        let ratio: CGFloat = 1.125
        let step = steps[min(6, max(1, level)) - 1]
        return (textSize * pow(ratio, step) * 2).rounded() / 2
    }

    static func spans(in text: String) -> [Span] {
        let source = text as NSString
        var spans: [Span] = []
        var code: [NSRange] = []
        var fenced = false
        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length), options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            let line = source.substring(with: lineRange)
            let offset = lineRange.location
            if line.hasPrefix("```") {
                fenced.toggle()
                spans.append(Span(kind: .mark, range: lineRange)); code.append(lineRange)
                return
            }
            if fenced {
                spans.append(Span(kind: .code, range: lineRange)); code.append(lineRange)
                return
            }
            if let match = first("^(#{1,6}) ", in: line) {
                spans.append(Span(kind: .heading(match.range(at: 1).length), range: lineRange))
                spans.append(Span(kind: .mark, range: NSRange(location: offset, length: match.range.length)))
            } else if let match = first("^> ?", in: line) {
                spans.append(Span(kind: .quote, range: lineRange))
                spans.append(Span(kind: .mark, range: NSRange(location: offset, length: match.range.length)))
            } else if let match = first("^\\s*(?:[-*+] \\[[ xX]\\]|[-*+]|[0-9]+[.)]) ", in: line) {
                spans.append(Span(kind: .listMarker, range: NSRange(location: offset, length: match.range.length)))
            }
        }
        for match in matches("`([^`\\n]+)`", in: text) where !intersects(match.range, code) {
            spans.append(Span(kind: .code, range: match.range(at: 1)))
            spans.append(Span(kind: .mark, range: NSRange(location: match.range.location, length: 1)))
            spans.append(Span(kind: .mark, range: NSRange(location: NSMaxRange(match.range) - 1, length: 1)))
            code.append(match.range)
        }
        for (pattern, kind, marker) in [
            ("(?<![\\\\*])\\*\\*([^*\\n]+)\\*\\*", Kind.bold, 2),
            ("(?<![\\\\_])__([^_\\n]+)__", .bold, 2),
            ("(?<![\\\\*])\\*([^*\\n]+)\\*(?!\\*)", .italic, 1),
            ("(?<![\\w\\\\_])_([^_\\n]+)_(?!\\w)", .italic, 1)
        ] {
            for match in matches(pattern, in: text) where !intersects(match.range, code) {
                // `**bold**` also matches the italic pattern's inner stars; skip those.
                if kind == .italic, spans.contains(where: { $0.kind == .bold && NSIntersectionRange($0.range, match.range).length > 0 }) { continue }
                spans.append(Span(kind: kind, range: match.range(at: 1)))
                spans.append(Span(kind: .mark, range: NSRange(location: match.range.location, length: marker)))
                spans.append(Span(kind: .mark, range: NSRange(location: NSMaxRange(match.range) - marker, length: marker)))
            }
        }
        for match in matches("\\[([^\\]\\n]+)\\]\\(([^)\\s]+)\\)", in: text) where !intersects(match.range, code) {
            let label = match.range(at: 1)
            spans.append(Span(kind: .link, range: label))
            spans.append(Span(kind: .mark, range: NSRange(location: match.range.location, length: 1)))
            spans.append(Span(kind: .mark, range: NSRange(location: NSMaxRange(label), length: NSMaxRange(match.range) - NSMaxRange(label))))
        }
        return spans
    }

    // MARK: Attributes

    /// Newsreader is a variable font: weight and optical size are set on its axes, as on the Mac
    /// (Paper.body), then scaled with Dynamic Type.
    static func bodyFont(_ size: CGFloat = textSize, bold: Bool = false, italic: Bool = false) -> UIFont {
        guard let base = UIFont(name: italic ? Paper.italicFace : Paper.regularFace, size: size) else {
            return UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: size, weight: bold ? .semibold : .regular))
        }
        let axes: [NSNumber: NSNumber] = [
            NSNumber(value: 0x77676874): NSNumber(value: bold ? 600 : 400),   // wght
            NSNumber(value: 0x6F70737A): NSNumber(value: Double(size))      // opsz
        ]
        let descriptor = base.fontDescriptor.addingAttributes([UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): axes])
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont(descriptor: descriptor, size: size))
    }

    static func isBold(_ font: UIFont) -> Bool {
        let key = UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
        let axes = font.fontDescriptor.fontAttributes[key] as? [NSNumber: NSNumber]
        return (axes?[NSNumber(value: 0x77676874)]?.doubleValue ?? 400) >= 600 || font.fontDescriptor.symbolicTraits.contains(.traitBold)
    }

    static func baseAttributes() -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6
        paragraph.paragraphSpacing = 8
        return [.font: bodyFont(), .foregroundColor: UIColor(Paper.ink), .paragraphStyle: paragraph]
    }

    /// Restyles all of `storage`. Only attributes change, never characters, so undo and the
    /// selection are untouched.
    static func apply(to storage: NSTextStorage) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(baseAttributes(), range: full)
        let muted = UIColor(Paper.muted)
        for span in spans(in: storage.string) where NSMaxRange(span.range) <= storage.length {
            switch span.kind {
            case .heading(let level):
                storage.addAttribute(.font, value: bodyFont(headingSize(level: level), bold: true), range: span.range)
            case .bold, .italic:
                storage.enumerateAttribute(.font, in: span.range) { value, range, _ in
                    let font = value as? UIFont ?? bodyFont()
                    let bold = span.kind == .bold || isBold(font)
                    let italic = span.kind == .italic || font.fontDescriptor.symbolicTraits.contains(.traitItalic) || font.fontName.contains("Italic")
                    // Scaled fonts are rebuilt from the unscaled size so Dynamic Type isn't applied twice.
                    let size = UIFontMetrics(forTextStyle: .body).scaledValue(for: 1) > 0 ? font.pointSize / UIFontMetrics(forTextStyle: .body).scaledValue(for: 1) : font.pointSize
                    storage.addAttribute(.font, value: bodyFont(size, bold: bold, italic: italic), range: range)
                }
            case .code:
                storage.addAttribute(.font, value: UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 15, weight: .regular)), range: span.range)
            case .quote:
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = 6; paragraph.paragraphSpacing = 8
                paragraph.firstLineHeadIndent = 14; paragraph.headIndent = 14
                storage.addAttributes([.paragraphStyle: paragraph, .foregroundColor: muted], range: span.range)
            case .listMarker:
                storage.addAttribute(.foregroundColor, value: muted, range: span.range)
            case .link:
                storage.addAttributes([.foregroundColor: UIColor(Paper.accent), .underlineStyle: NSUnderlineStyle.single.rawValue], range: span.range)
            case .mark:
                storage.addAttribute(.foregroundColor, value: muted.withAlphaComponent(0.55), range: span.range)
            }
        }
        storage.endEditing()
    }

    // MARK: Helpers

    private static func intersects(_ range: NSRange, _ ranges: [NSRange]) -> Bool {
        ranges.contains { NSIntersectionRange($0, range).length > 0 }
    }
    private static func first(_ pattern: String, in string: String) -> NSTextCheckingResult? { matches(pattern, in: string).first }
    private static func matches(_ pattern: String, in string: String) -> [NSTextCheckingResult] {
        (try? NSRegularExpression(pattern: pattern))?.matches(in: string, range: NSRange(location: 0, length: (string as NSString).length)) ?? []
    }
}
