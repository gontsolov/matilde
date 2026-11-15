import AppKit

/// The editor's single type and spacing scale. Every block the Markdown styler renders takes
/// its size, line spacing and vertical space from here. Spacing is measured in ems of the
/// writing size, so the rhythm follows the Text size preference.
///
/// Space between blocks always comes from paragraph styles, never from inserted characters,
/// and is applied as `paragraphSpacing` on the earlier block: the later block's own line
/// fragments keep their top edge, so caret, highlight, image and margin-card geometry that is
/// anchored to a line's top or baseline is unaffected.
enum Typography {
    enum Block: Equatable {
        case paragraph, heading(Int), list, quote, code, divider, image
    }

    /// Space a block wants above and below it (in ems, beyond its own line spacing), and the
    /// space between consecutive lines of the same kind of block (list items, quote lines,
    /// code lines). `nil` means consecutive blocks of that kind collapse like any other pair.
    struct Spacing: Equatable {
        let before: CGFloat
        let after: CGFloat
        let within: CGFloat?
    }

    /// Heading sizes follow a major-second modular scale (1.125) on the writing size:
    /// H1 = body × 1.125³, H2 × 1.125², H3 × 1.125, H4–H6 at body size (told apart by weight).
    static let ratio: CGFloat = 1.125
    private static let headingSteps: [CGFloat] = [3, 2, 1, 0, 0, 0]

    static func headingSize(level: Int, textSize: CGFloat) -> CGFloat {
        let step = headingSteps[min(6, max(1, level)) - 1]
        return (textSize * pow(ratio, step) * 2).rounded() / 2
    }

    static func spacing(for block: Block) -> Spacing {
        switch block {
        case .heading(let level):
            switch level {
            case 1: return Spacing(before: 2.0, after: 0.6, within: nil)
            case 2: return Spacing(before: 1.6, after: 0.5, within: nil)
            case 3: return Spacing(before: 1.3, after: 0.4, within: nil)
            default: return Spacing(before: 1.1, after: 0.3, within: nil)
            }
        case .paragraph: return Spacing(before: 0, after: 0.85, within: 0.85)
        case .list: return Spacing(before: 0, after: 0.85, within: 0.3)
        case .quote: return Spacing(before: 0, after: 0.85, within: 0.15)
        case .code: return Spacing(before: 0, after: 0.85, within: 0)
        case .divider: return Spacing(before: 1.0, after: 1.0, within: nil)
        case .image: return Spacing(before: 0, after: 0.85, within: nil)
        }
    }

    static func points(_ ems: CGFloat, textSize: CGFloat) -> CGFloat { (ems * textSize).rounded() }

    /// Space between two adjacent blocks, in points. Blocks of the same kind use their
    /// `within` spacing; otherwise the larger of the earlier block's space below and the later
    /// block's space above wins, like collapsing margins.
    static func gap(after previous: Block, before next: Block, textSize: CGFloat) -> CGFloat {
        let above = spacing(for: previous), below = spacing(for: next)
        if previous == next, let within = above.within { return points(within, textSize: textSize) }
        return points(max(above.after, below.before), textSize: textSize)
    }

    /// Headings and code are set tighter than running text; other blocks use the writing
    /// line spacing preference.
    static func lineSpacing(for block: Block, bodyLineSpacing: CGFloat, textSize: CGFloat) -> CGFloat {
        switch block {
        case .heading(let level):
            return min(bodyLineSpacing, (headingSize(level: level, textSize: textSize) * 0.2).rounded())
        case .code:
            return min(bodyLineSpacing, (textSize * 0.2).rounded())
        default:
            return bodyLineSpacing
        }
    }

    /// Height of an empty line the writer typed: exactly one line of the body font, with no
    /// line or paragraph spacing of its own.
    static func blankLineHeight(textSize: CGFloat) -> CGFloat {
        NSLayoutManager().defaultLineHeight(for: Paper.body(textSize))
    }

    /// `paragraphSpacing` for each line, given each line's block (`nil` for an empty line).
    /// Leading blank lines and the first block get nothing above them. Empty lines between two
    /// blocks count toward the gap instead of adding to it, so one blank line between a
    /// paragraph and a heading lands the heading where it would sit without one, and extra
    /// blank lines only add space once they exceed the gap.
    static func paragraphSpacings(for blocks: [Block?], textSize: CGFloat, blankLineHeight: CGFloat) -> [CGFloat] {
        var result = blocks.map { block in block.map { points(spacing(for: $0).after, textSize: textSize) } ?? 0 }
        var previous: Int?
        var blanks = 0
        for (index, block) in blocks.enumerated() {
            guard let block else { blanks += 1; continue }
            if let previous, let earlier = blocks[previous] {
                let space = gap(after: earlier, before: block, textSize: textSize)
                result[previous] = max(0, space - CGFloat(blanks) * blankLineHeight)
            }
            previous = index
            blanks = 0
        }
        return result
    }
}
