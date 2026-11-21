import XCTest
import AppKit
@testable import Matilde

@MainActor
final class TypographyTests: XCTestCase {
    private func style(at location: Int, in text: NSAttributedString) throws -> NSParagraphStyle {
        try XCTUnwrap(text.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)
    }

    private func styled(_ source: String, textSize: CGFloat = 19, lineSpacing: CGFloat = 9) -> NSMutableAttributedString {
        let text = NSMutableAttributedString(string: source)
        MarkdownStyler.style(text, textSize: textSize, lineSpacing: lineSpacing)
        XCTAssertEqual(text.string, source, "styling must not change the Markdown")
        return text
    }

    /// Top of the line fragment holding `character`, after laying the text out.
    private func lineTop(of character: Int, in text: NSAttributedString) -> CGFloat {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 600, height: 100_000))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        return layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: character), effectiveRange: nil).minY
    }

    func testHeadingSizesFormAModularScaleBelowTheTitle() {
        let sizes = (1...6).map { Typography.headingSize(level: $0, textSize: 19) }
        XCTAssertEqual(sizes, [27, 24, 21.5, 19, 19, 19])
        XCTAssertLessThan(sizes[0], 31, "H1 stays below the 31-point document title")
        for (larger, smaller) in zip(sizes, sizes.dropFirst()) { XCTAssertGreaterThanOrEqual(larger, smaller) }
        XCTAssertEqual(Typography.headingSize(level: 1, textSize: 24), 34)
        let text = styled("# One\n## Two\n### Three")
        XCTAssertEqual((text.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)?.pointSize, 27)
        XCTAssertEqual((text.attribute(.font, at: 9, effectiveRange: nil) as? NSFont)?.pointSize, 24)
        XCTAssertEqual((text.attribute(.font, at: 17, effectiveRange: nil) as? NSFont)?.pointSize, 21.5)
    }

    func testHeadingsHaveMoreSpaceAboveThanBelowAndLargerHeadingsMore() {
        var previousBefore = CGFloat.greatestFiniteMagnitude
        for level in 1...6 {
            let spacing = Typography.spacing(for: .heading(level))
            XCTAssertGreaterThan(spacing.before, spacing.after * 2, "H\(level) binds to the content below it")
            XCTAssertLessThanOrEqual(spacing.before, previousBefore)
            previousBefore = spacing.before
            XCTAssertLessThan(Typography.lineSpacing(for: .heading(level), bodyLineSpacing: 9, textSize: 19), 9,
                              "headings are set tighter than body text")
        }
    }

    func testGapsBetweenBlocksUseOneScale() {
        func gap(_ a: Typography.Block, _ b: Typography.Block) -> CGFloat { Typography.gap(after: a, before: b, textSize: 19) }
        XCTAssertEqual(gap(.paragraph, .heading(1)), 38)
        XCTAssertEqual(gap(.paragraph, .heading(2)), 30)
        XCTAssertEqual(gap(.paragraph, .heading(3)), 25)
        XCTAssertEqual(gap(.paragraph, .heading(4)), 21)
        XCTAssertEqual(gap(.heading(1), .paragraph), 11)
        XCTAssertEqual(gap(.heading(2), .list), 10)
        XCTAssertEqual(gap(.paragraph, .paragraph), 16)
        XCTAssertEqual(gap(.paragraph, .list), 16)
        XCTAssertEqual(gap(.list, .paragraph), 16)
        XCTAssertEqual(gap(.list, .list), 6)
        XCTAssertEqual(gap(.quote, .quote), 3)
        XCTAssertEqual(gap(.code, .code), 0)
        XCTAssertEqual(gap(.paragraph, .divider), 19)
        XCTAssertEqual(gap(.image, .paragraph), 16)
        // Adjacent headings collapse to the larger space rather than adding up.
        XCTAssertEqual(gap(.heading(1), .heading(2)), 30)
        XCTAssertEqual(gap(.heading(2), .heading(1)), 38)
        XCTAssertEqual(gap(.heading(2), .heading(2)), 30)
        // The scale follows the writing size.
        XCTAssertEqual(Typography.gap(after: .paragraph, before: .heading(1), textSize: 24), 48)
    }

    func testBlankLinesCountTowardTheGapInsteadOfAddingToIt() {
        func spacings(_ blocks: [Typography.Block?]) -> [CGFloat] {
            Typography.paragraphSpacings(for: blocks, textSize: 19, blankLineHeight: 19)
        }
        XCTAssertEqual(spacings([.paragraph, .heading(1)]), [38, 11])
        XCTAssertEqual(spacings([.paragraph, nil, .heading(1)]), [19, 0, 11])
        XCTAssertEqual(spacings([.paragraph, nil, nil, .heading(1)]), [0, 0, 0, 11])
        XCTAssertEqual(spacings([.paragraph, nil, nil, nil, .heading(1)]), [0, 0, 0, 0, 11])
        XCTAssertEqual(spacings([.paragraph, nil, .paragraph]), [0, 0, 16])
        XCTAssertEqual(spacings([.heading(1), .heading(2), .paragraph]), [30, 10, 16])
        XCTAssertEqual(spacings([nil, nil, .heading(1), .paragraph]), [0, 0, 11, 16])
        XCTAssertEqual(spacings([]), [])
    }

    func testStyledHeadingAfterParagraphAndAtDocumentStart() throws {
        let text = styled("Intro\n# Title\nBody")
        XCTAssertEqual(try style(at: 0, in: text).paragraphSpacing, 38)
        XCTAssertEqual(try style(at: 6, in: text).paragraphSpacing, 11)
        XCTAssertLessThan(try style(at: 6, in: text).lineSpacing, 9)
        XCTAssertEqual(try style(at: 14, in: text).lineSpacing, 9)
        for location in 0..<text.length { XCTAssertEqual(try style(at: location, in: text).paragraphSpacingBefore, 0) }

        // Nothing is added above the first block: a heading first in the document starts at
        // the very top of the text, exactly like a paragraph would.
        let headingFirst = styled("# Title\nBody")
        XCTAssertEqual(try style(at: 0, in: headingFirst).paragraphSpacingBefore, 0)
        XCTAssertEqual(lineTop(of: 2, in: headingFirst), 0)
        XCTAssertEqual(lineTop(of: 0, in: styled("Body")), 0)
    }

    func testOneBlankLineLandsAHeadingWhereItWouldBeWithoutOne() throws {
        let tight = styled("Intro\n# Title")
        let loose = styled("Intro\n\n# Title")
        XCTAssertEqual(lineTop(of: 8, in: tight), lineTop(of: 9, in: loose), accuracy: 0.5)
        let blank = try style(at: 6, in: loose)
        XCTAssertEqual(blank.paragraphSpacing, 0)
        XCTAssertEqual(blank.lineSpacing, 0)
        XCTAssertGreaterThan(blank.minimumLineHeight, 0)
        // More blank lines only add space once they exceed the gap, one plain line each.
        let line = blank.minimumLineHeight
        let many = styled("Intro\n\n\n\n# Title")
        XCTAssertEqual(try style(at: 0, in: many).paragraphSpacing, max(0, 38 - 3 * line), accuracy: 0.01)
        XCTAssertEqual(lineTop(of: 11, in: many) - lineTop(of: 9, in: loose), max(3 * line, 38) - 38, accuracy: 0.5)
    }

    func testListsQuotesAndCodeKeepTightInnerSpacing() throws {
        let text = styled("Lead\n- one\n  - nested\n- [ ] task\nAfter\n> quote\n> more\n```\nlet a = 1\nlet b = 2\n```\nEnd")
        let source = text.string as NSString
        func spacing(_ line: String) throws -> CGFloat { try style(at: source.range(of: line).location, in: text).paragraphSpacing }
        XCTAssertEqual(try spacing("Lead"), 16)
        XCTAssertEqual(try spacing("- one"), 6)
        XCTAssertEqual(try spacing("  - nested"), 6)
        XCTAssertEqual(try spacing("- [ ] task"), 16)
        XCTAssertEqual(try spacing("> quote"), 3)
        XCTAssertEqual(try spacing("> more"), 16)
        XCTAssertEqual(try spacing("let a"), 0)
        XCTAssertEqual(try style(at: source.range(of: "let a").location, in: text).lineSpacing, 4)
        XCTAssertGreaterThan(try style(at: source.range(of: "  - nested").location, in: text).headIndent, 0)
        XCTAssertEqual(try style(at: source.range(of: "> quote").location, in: text).headIndent, 24)
    }

    func testImageLineKeepsItsBlockSpacing() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 100,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let image = NSImage(size: NSSize(width: 200, height: 100))
        image.addRepresentation(bitmap)
        let view = WritingTextView(frame: NSRect(x: 0, y: 0, width: 680, height: 500))
        view.resolveImage = { _ in image }
        view.string = "![Image](.assets/test.png)\n## Next"
        MarkdownStyler.style(view.textStorage!)
        view.styleImages()
        XCTAssertEqual(view.renderedImages.count, 1)
        let style = try XCTUnwrap(view.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.paragraphSpacing, 30)
        XCTAssertEqual(style.minimumLineHeight, 112)
    }
}
