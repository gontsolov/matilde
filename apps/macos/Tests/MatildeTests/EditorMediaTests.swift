import XCTest
import AppKit
@testable import Matilde

final class EditorMediaTests: XCTestCase {
    func imageData() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 100,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.bitmapData?.initialize(repeating: 180, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func testLocalImageStorageBranchSharingAndBoundaries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try Workspace(root: root)
        try workspace.createFolder(name: "Notes", parent: "")
        let draft = try workspace.create(name: "First", folder: "Notes", goal: "")
        let reference = try workspace.importImage(imageData(), beside: draft)
        XCTAssertTrue(reference.hasPrefix(".assets/"))
        XCTAssertNotNil(workspace.image(at: reference, beside: draft))
        let branch = try workspace.branch(draft, text: "![Image](\(reference))")
        XCTAssertNotNil(workspace.image(at: reference, beside: branch))
        XCTAssertNil(workspace.image(at: "../outside.png", beside: draft))
        XCTAssertNil(workspace.image(at: "https://example.com/image.png", beside: draft))
        XCTAssertThrowsError(try workspace.importImage(Data("not an image".utf8), beside: draft))
        XCTAssertFalse(try workspace.scan().folders.contains { $0.contains(".assets") })
    }

    @MainActor
    func testImagePasteAndLayoutPreserveMarkdownAndCode() throws {
        let view = WritingTextView(frame: NSRect(x: 0, y: 0, width: 680, height: 500))
        let data = try imageData()
        view.saveImage = { _ in ".assets/test.png" }
        view.resolveImage = { _ in NSImage(data: data) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setData(data, forType: .png)
        XCTAssertTrue(view.pasteMedia(from: pasteboard))
        XCTAssertEqual(view.string, "![Image](.assets/test.png)\n\n")
        let original = view.string
        MarkdownStyler.style(view.textStorage!)
        view.styleImages()
        XCTAssertEqual(view.renderedImages.count, 1)
        XCTAssertEqual(view.string, original)
        XCTAssertLessThanOrEqual(view.renderedImages[0].size.width, 614)
        view.string = "```\n![Image](.assets/test.png)\n```"
        MarkdownStyler.style(view.textStorage!)
        view.styleImages()
        XCTAssertTrue(view.renderedImages.isEmpty)
    }

    @MainActor
    func testPastedURLWrapsSelectionAndBareURLsAreLinkedOutsideCode() throws {
        let view = WritingTextView(frame: .zero)
        view.string = "Read this"
        view.setSelectedRange(NSRange(location: 0, length: 9))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("https://example.com", forType: .string)
        XCTAssertTrue(view.pasteMedia(from: pasteboard))
        XCTAssertEqual(view.string, "[Read this](https://example.com)")
        let text = NSMutableAttributedString(string: "https://example.com\n`https://example.com`\n```\nhttps://example.com\n```")
        MarkdownStyler.style(text)
        XCTAssertNotNil(text.attribute(.link, at: 0, effectiveRange: nil))
        XCTAssertNil(text.attribute(.link, at: 22, effectiveRange: nil))
        XCTAssertNil(EditorLinks.destination("javascript:alert(1)"))
        XCTAssertNil(EditorLinks.destination("not a URL"))
        let escaped = EditorLinks.markdown(label: "Read [this]", destination: URL(string: "https://example.com/a(b)")!)
        let linked = NSMutableAttributedString(string: escaped)
        MarkdownStyler.style(linked)
        XCTAssertNotNil(linked.attribute(.link, at: 1, effectiveRange: nil))
        XCTAssertTrue(escaped.contains("%28b%29"))
    }
}
