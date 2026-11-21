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

    func testTrashingDraftKeepsChildrenAndHistoryAndAllowsNameReuse() throws {
        let workspace = try Workspace(root: root)
        let original = try workspace.create(name: "Original", folder: "", goal: "Keep this", text: "Original text")
        let branch = try workspace.branch(original, text: "Original text")
        let child = try workspace.branch(branch, text: "Child text")
        let recovery = root.appendingPathComponent(".recovered.md")
        try workspace.trash(branch) { try FileManager.default.moveItem(at: $0, to: recovery) }
        let reopened = try Workspace(root: root)
        let drafts = try reopened.scan().drafts
        XCTAssertFalse(drafts.contains { $0.id == branch.id })
        XCTAssertEqual(drafts.first { $0.id == child.id }?.parent, original.id)
        XCTAssertEqual(try reopened.read(child), "Child text")
        XCTAssertEqual(try String(contentsOf: recovery, encoding: .utf8), "Child text")
        XCTAssertEqual(try reopened.db.execute("SELECT * FROM trashed_drafts WHERE id=?", [branch.id]).first?["goal"], "Keep this")
        XCTAssertEqual(try reopened.db.execute("SELECT * FROM snapshots").count, 2)
        _ = try reopened.create(name: branch.title, folder: "", goal: "", text: "New draft")
    }

    func testWelcomeSeedsOnceAndExplicitRecoveryPreservesEdits() throws {
        let workspace = try Workspace(root: root)
        let welcome = try XCTUnwrap(workspace.welcomeDocument())
        XCTAssertEqual(welcome.goal, WelcomeDocument.goal)
        XCTAssertEqual(try workspace.read(welcome), WelcomeDocument.text)
        XCTAssertNil(try workspace.welcomeDocument())
        try "My own opening".write(to: workspace.url(for: welcome.path), atomically: true, encoding: .utf8)
        XCTAssertEqual(try workspace.welcomeDocument(explicit: true)?.id, welcome.id)
        XCTAssertEqual(try workspace.read(welcome), "My own opening")
        try workspace.trash(welcome) { try FileManager.default.moveItem(at: $0, to: root.appendingPathComponent("removed.txt")) }
        XCTAssertNil(try workspace.welcomeDocument())
        XCTAssertNotNil(try workspace.welcomeDocument(explicit: true))
    }

    func testWelcomeDoesNotSeedExistingWriting() throws {
        let workspace = try Workspace(root: root)
        let draft = try workspace.create(name: WelcomeDocument.title, folder: "", goal: "", text: "Keep me")
        XCTAssertNil(try workspace.welcomeDocument())
        let welcome = try XCTUnwrap(workspace.welcomeDocument(explicit: true))
        XCTAssertNotEqual(welcome.path, draft.path)
        XCTAssertEqual(try workspace.read(draft), "Keep me")
    }

    func testFailedTrashLeavesDraftAndRelationshipsUntouched() throws {
        let workspace = try Workspace(root: root)
        let original = try workspace.create(name: "Original", folder: "", goal: "", text: "Keep me")
        let child = try workspace.branch(original, text: "Keep me")
        XCTAssertThrowsError(try workspace.trash(original) { _ in throw WorkspaceError.message("Trash unavailable") })
        XCTAssertEqual(try workspace.scan().drafts.count, 2)
        XCTAssertEqual(try workspace.read(original), "Keep me")
        XCTAssertEqual(try workspace.allDrafts().first { $0.id == child.id }?.parent, original.id)
        XCTAssertTrue(try workspace.db.execute("SELECT * FROM trashed_drafts").isEmpty)
    }

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
    func testBranchInheritsPositionAndThenPersistsIndependently() throws {
        let workspace = try Workspace(root: root)
        var source = try workspace.create(name: "Original", folder: "", goal: "")
        source.cursor = 12; source.scroll = 160
        try workspace.position(source, cursor: source.cursor, scroll: source.scroll)
        let branch = try workspace.branch(source, text: "A longer piece of writing")
        XCTAssertEqual(branch.cursor, 12)
        XCTAssertEqual(branch.scroll, 160)
        try workspace.position(branch, cursor: 20, scroll: 240)
        let reopened = try Workspace(root: root)
        let drafts = try reopened.allDrafts()
        XCTAssertEqual(drafts.first { $0.id == source.id }?.cursor, 12)
        XCTAssertEqual(drafts.first { $0.id == source.id }?.scroll, 160)
        XCTAssertEqual(drafts.first { $0.id == branch.id }?.cursor, 20)
        XCTAssertEqual(drafts.first { $0.id == branch.id }?.scroll, 240)
    }
    func testBoardPlacementPersistsAndNewBranchesDoNotMoveExistingSheets() throws {
        let workspace = try Workspace(root: root)
        let original = try workspace.create(name: "Original", folder: "", goal: "")
        let first = try workspace.branch(original, text: "A piece")
        let positions = try workspace.boardPositions(for: [first, original])
        XCTAssertEqual(positions[original.id], SheetPosition(x: 0, y: 0))
        XCTAssertGreaterThan(positions[first.id]!.x, positions[original.id]!.x)
        XCTAssertGreaterThan(positions[first.id]!.y, positions[original.id]!.y)
        let second = try workspace.branch(original, text: "Another direction")
        let reopened = try Workspace(root: root)
        let updated = try reopened.boardPositions(for: [second, original, first])
        XCTAssertEqual(updated[original.id], positions[original.id])
        XCTAssertEqual(updated[first.id], positions[first.id])
        XCTAssertNotEqual(updated[second.id], updated[first.id])
        XCTAssertEqual(try reopened.scan().drafts.count, 3)
    }
    func testBoardViewportIsPersistentAndScopedToFamily() throws {
        let workspace = try Workspace(root: root)
        let viewport = BoardViewport(x: 440, y: 230, zoom: 0.6)
        try workspace.saveBoardViewport(family: "family-a", viewport: viewport)
        let reopened = try Workspace(root: root)
        XCTAssertEqual(try reopened.boardViewport(family: "family-a"), viewport)
        XCTAssertNil(try reopened.boardViewport(family: "family-b"))
    }
    func testImmediateUntitledDocumentsDoNotOverwriteAndCanBeNamed() throws {
        let workspace = try Workspace(root: root)
        let first = try workspace.createUntitled(folder: "")
        try workspace.save(first, text: "Keep this writing")
        let second = try workspace.createUntitled(folder: "")
        XCTAssertEqual(first.path, "Untitled.md")
        XCTAssertEqual(second.path, "Untitled 2.md")
        XCTAssertEqual(try workspace.state("untitled:\(second.id)"), "true")
        try workspace.rename(second, name: "A new piece")
        try workspace.goal(second, text: "Explain the idea")
        let reopened = try Workspace(root: root)
        let named = try XCTUnwrap(reopened.scan().drafts.first { $0.id == second.id })
        XCTAssertEqual(named.path, "A new piece.md")
        XCTAssertEqual(named.goal, "Explain the idea")
        XCTAssertEqual(try reopened.read(first), "Keep this writing")
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

final class PageCurlTests: XCTestCase {
    func testPageStartsFlatBendsAndClearsTheEditor() {
        let size = CGSize(width: 900, height: 700)
        let flat = CurlMesh(size: size, progress: 0)
        XCTAssertTrue(flat.vertices.allSatisfy { abs($0.z) < 0.001 })
        XCTAssertEqual(flat.vertices.first!.x, -450, accuracy: 0.001)
        XCTAssertEqual(flat.vertices.last!.x, 450, accuracy: 0.001)
        let startingCurl = CurlMesh(size: size, progress: 0.2)
        // Mesh rows go bottom to top: the bottom-right corner must lift first.
        XCTAssertGreaterThan(startingCurl.vertices[120].z, 0)
        XCTAssertLessThan(startingCurl.vertices[120].x, flat.vertices[120].x)
        XCTAssertGreaterThan(startingCurl.vertices[120].y, flat.vertices[120].y)
        XCTAssertEqual(startingCurl.vertices.last!.z, 0, accuracy: 0.001)
        XCTAssertEqual(startingCurl.vertices.first!.z, 0, accuracy: 0.001)
        let curled = CurlMesh(size: size, progress: 0.4)
        XCTAssertTrue(curled.vertices.contains { $0.z > 40 })
        XCTAssertTrue(curled.normals.contains { $0.z < 0 })
        XCTAssertTrue(curled.normals.contains { $0.z > 0 })
        for normal in curled.normals {
            let length = sqrt(normal.x * normal.x + normal.y * normal.y + normal.z * normal.z)
            XCTAssertEqual(length, 1, accuracy: 0.001)
        }
        XCTAssertTrue(curled.indices.allSatisfy { $0 >= 0 && Int($0) < curled.vertices.count })
        let turned = CurlMesh(size: size, progress: 1)
        XCTAssertTrue(turned.vertices.allSatisfy { $0.x < -450 })
    }
}
