import XCTest
import AppKit
@testable import Matilde

final class MatildeIconTests: XCTestCase {
    func testEveryIconLoadsFromTheBundleAsATemplateImage() throws {
        for icon in MatildeIcon.allCases {
            let url = try XCTUnwrap(MatildeResources.bundle.url(forResource: icon.rawValue, withExtension: "pdf", subdirectory: "Icons"),
                                    "Missing Icons/\(icon.rawValue).pdf for .\(icon)")
            let source = try XCTUnwrap(NSImage(contentsOf: url), "Unreadable \(icon.rawValue).pdf")
            XCTAssertTrue(source.representations.contains { $0 is NSPDFImageRep }, "\(icon.rawValue).pdf is not vector")
            XCTAssertEqual(source.size, NSSize(width: 24, height: 24), "\(icon.rawValue).pdf is off Tabler's grid")
            let image = icon.nsImage
            XCTAssertTrue(image.isTemplate, ".\(icon) is not a template image")
            XCTAssertNotNil(image.cgImage(forProposedRect: nil, context: nil, hints: nil), ".\(icon) does not render")
        }
    }

    func testSizedIconsStayTemplateAndDrawInk() throws {
        let small = MatildeIcon.search.nsImage(size: 14)
        XCTAssertEqual(small.size, NSSize(width: 14, height: 14))
        XCTAssertTrue(small.isTemplate)
        XCTAssertEqual(MatildeIcon.search.nsImage.size, NSSize(width: 24, height: 24), "Sizing must not mutate the cached default")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 48, bitsPerSample: 8,
                                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        MatildeIcon.search.nsImage.draw(in: NSRect(x: 0, y: 0, width: 48, height: 48))
        NSGraphicsContext.restoreGraphicsState()
        var inked = 0
        for x in 0..<48 { for y in 0..<48 where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { inked += 1 } }
        XCTAssertGreaterThan(inked, 40, "The search glyph should draw visible strokes")
        XCTAssertLessThan(inked, 48 * 48 / 2, "Outline glyphs should not fill the frame")
    }
}
