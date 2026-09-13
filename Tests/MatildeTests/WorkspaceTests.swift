import XCTest
import AppKit
@testable import Matilde

final class WorkspaceTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("matilde-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testBranchSnapshotAndIndependentGoalsSurviveReopen() throws {
        let workspace = try Workspace(root: root)
        try workspace.createFolder(name: "Essays", parent: "")
        let original = try workspace.create(name: "A thought", folder: "Essays", goal: "Be clear", text: "Original **thought**.")
        let branch = try workspace.branch(original, text: "Original **thought**.")
        XCTAssertEqual(branch.parent, original.id)
        XCTAssertEqual(branch.family, original.family)
        XCTAssertEqual(branch.goal, original.goal)
        try workspace.save(original, text: "Original keeps evolving")
        try workspace.save(branch, text: "A different direction")
        try workspace.goal(branch, text: "Be surprising")
        try workspace.rename(branch, name: "Another way")
        let reopened = try Workspace(root: root)
        let drafts = try reopened.scan().drafts
        let restored = try XCTUnwrap(drafts.first { $0.id == branch.id })
        XCTAssertEqual(restored.path, "Essays/Another way.md")
        XCTAssertEqual(restored.goal, "Be surprising")
        XCTAssertEqual(try reopened.read(restored), "A different direction")
        XCTAssertEqual(try reopened.read(original), "Original keeps evolving")
        XCTAssertEqual(drafts.first { $0.id == original.id }?.goal, "Be clear")
        let snapshot = try XCTUnwrap(reopened.db.execute("SELECT path FROM snapshots").first?["path"])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(snapshot), encoding: .utf8), "Original **thought**.")
    }
    func testPositionAndWorkspaceStatePersist() throws {
        let workspace = try Workspace(root: root)
        let draft = try workspace.create(name: "Restore", folder: "", goal: "")
        try workspace.position(draft, cursor: 42, scroll: 211.5)
        try workspace.setState("active", draft.id)
        try workspace.setState("sidebar", "false")
        let reopened = try Workspace(root: root)
        XCTAssertEqual(try reopened.state("active"), draft.id)
        XCTAssertEqual(try reopened.state("sidebar"), "false")
        XCTAssertEqual(try reopened.allDrafts().first?.cursor, 42)
        XCTAssertEqual(try reopened.allDrafts().first?.scroll, 211.5)
    }
    func testExternalImportAndFileBoundaries() throws {
        let workspace = try Workspace(root: root)
        try "External".write(to: root.appendingPathComponent("Outside.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try workspace.scan().drafts.count, 1)
        XCTAssertEqual(try workspace.scan().drafts.count, 1)
        XCTAssertThrowsError(try workspace.create(name: "../escape", folder: "", goal: ""))
        XCTAssertThrowsError(try workspace.create(name: "Hidden", folder: ".matilde", goal: ""))
        XCTAssertThrowsError(try workspace.create(name: "Outside", folder: "", goal: ""))
        XCTAssertThrowsError(try workspace.url(for: "../escape.md"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Link"), withDestinationURL: root.deletingLastPathComponent())
        XCTAssertThrowsError(try workspace.url(for: "Link/escape.md"))
    }
    func testRepeatedBranchesGetUniqueNames() throws {
        let workspace = try Workspace(root: root)
        let source = try workspace.create(name: "Essay", folder: "", goal: "")
        let first = try workspace.branch(source, text: "one")
        let second = try workspace.branch(source, text: "two")
        XCTAssertNotEqual(first.path, second.path)
        XCTAssertEqual(try workspace.read(first), "one")
        XCTAssertEqual(try workspace.read(second), "two")
    }
}

final class MarkdownTests: XCTestCase {
    func testBundledNewsreaderIncludesFormattingFaces() {
        let font = Paper.body()
        XCTAssertTrue(font.familyName?.contains("Newsreader") == true)
        for trait in [NSFontTraitMask.boldFontMask, .italicFontMask] {
            let styled = Paper.emphasize(font, trait: trait)
            XCTAssertTrue(styled.familyName?.contains("Newsreader") == true)
            XCTAssertTrue(NSFontManager.shared.traits(of: styled).contains(trait))
        }
    }
    func testStylingIsLosslessAndConcealsSyntax() {
        let markdown = "# Heading\n\nSome **bold** and *italic* with [a link](https://example.com).\n- [ ] Task\n- Item\n1. Numbered\n> Quote\n```swift\nlet value = **literal**\n```\n"
        let storage = NSMutableAttributedString(string: markdown)
        MarkdownStyler.style(storage)
        XCTAssertEqual(storage.string, markdown)
        XCTAssertNotNil(storage.attribute(.concealed, at: 0, effectiveRange: nil))
        let bold = (markdown as NSString).range(of: "**bold**")
        XCTAssertNotNil(storage.attribute(.concealed, at: bold.location, effectiveRange: nil))
        let font = storage.attribute(.font, at: bold.location + 2, effectiveRange: nil) as! NSFont
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        let literal = (markdown as NSString).range(of: "**literal**")
        XCTAssertNil(storage.attribute(.concealed, at: literal.location, effectiveRange: nil))
        let link = (markdown as NSString).range(of: "a link")
        XCTAssertEqual((storage.attribute(.link, at: link.location, effectiveRange: nil) as? URL)?.absoluteString, "https://example.com")
        let checklist = (markdown as NSString).range(of: "- [ ]")
        XCTAssertEqual(storage.attribute(.replacement, at: checklist.location, effectiveRange: nil) as? String, "☐")
        MarkdownStyler.style(storage)
        XCTAssertEqual(storage.string, markdown)
    }
    func testUnicodeAndUnfinishedMarkdownRemainIntact() {
        let markdown = "## 日本語 🌱\nA **work in progress\n`**literal**` and snake_case_name"
        let storage = NSMutableAttributedString(string: markdown)
        MarkdownStyler.style(storage)
        XCTAssertEqual(storage.string, markdown)
        let range = (markdown as NSString).range(of: "**work")
        XCTAssertNil(storage.attribute(.concealed, at: range.location, effectiveRange: nil))
        let inline = (markdown as NSString).range(of: "**literal**")
        XCTAssertNil(storage.attribute(.concealed, at: inline.location, effectiveRange: nil))
    }
}
