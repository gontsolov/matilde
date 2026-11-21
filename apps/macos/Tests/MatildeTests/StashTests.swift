import XCTest
@testable import Matilde

final class StashTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/stash-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testSharedOwnershipAndOrphanRetention() throws {
        let workspace = try Workspace(root: root)
        let draft = try workspace.create(name: "Test", folder: "", goal: "", text: "Body")
        XCTAssertEqual(try workspace.readStash(draft.family), "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try workspace.stashURL(draft.family).path))
        let before = try workspace.allDrafts().first!
        try workspace.saveStash(draft.family, text: "- 日本語 👩🏽‍💻\n", expected: "")
        XCTAssertEqual(try workspace.allDrafts().first!.editedAt, before.editedAt)
        let branch = try workspace.branch(draft, text: "Body")
        try workspace.rename(draft, name: "Renamed")
        let renamed = try workspace.allDrafts().first { $0.id == draft.id }!
        try workspace.trash(renamed) { try FileManager.default.moveItem(at: $0, to: root.appendingPathComponent("removed.txt")) }
        XCTAssertEqual(try workspace.readStash(branch.family), "- 日本語 👩🏽‍💻\n")
        XCTAssertEqual(try workspace.scan().drafts.count, 1)
        try workspace.trash(branch) { try FileManager.default.moveItem(at: $0, to: root.appendingPathComponent("removed2.txt")) }
        XCTAssertEqual(try Workspace(root: root).readStash(draft.family), "- 日本語 👩🏽‍💻\n")
    }
    func testExternalConflictAndSymlinkProtection() throws {
        let workspace = try Workspace(root: root)
        let family = UUID().uuidString
        try workspace.saveStash(family, text: "External", expected: "")
        XCTAssertThrowsError(try workspace.saveStash(family, text: "Local", expected: ""))
        XCTAssertEqual(try workspace.readStash(family), "External")
        XCTAssertThrowsError(try workspace.readStash("../escape"))
        let linked = UUID().uuidString
        try FileManager.default.createSymbolicLink(at: workspace.stashURL(linked), withDestinationURL: workspace.stashURL(family))
        XCTAssertThrowsError(try workspace.readStash(linked))
        XCTAssertThrowsError(try workspace.saveStash(linked, text: "Overwrite", expected: ""))
    }
    @MainActor func testSessionFlushSwitchPositionAndFailedClose() throws {
        let workspace = try Workspace(root: root)
        let family = UUID().uuidString
        let stash = StashModel()
        try stash.load(workspace: workspace, family: family)
        stash.isOpen = true
        stash.edited("- A note")
        stash.cursor = 8; stash.scroll = 12
        try stash.load(workspace: workspace, family: family)
        XCTAssertTrue(stash.isOpen)
        try stash.close(restoreFocus: false)
        let reopened = StashModel()
        try reopened.load(workspace: workspace, family: family)
        XCTAssertEqual(reopened.text, "- A note")
        XCTAssertEqual(reopened.cursor, 8)
        XCTAssertEqual(reopened.scroll, 12)
        stash.isOpen = true
        stash.edited("Local change")
        try workspace.saveStash(family, text: "External change", expected: "- A note")
        XCTAssertThrowsError(try stash.close())
        XCTAssertTrue(stash.isOpen)
        XCTAssertEqual(stash.text, "Local change")
        XCTAssertThrowsError(try stash.load(workspace: workspace, family: UUID().uuidString))
        XCTAssertEqual(stash.family, family)
        XCTAssertEqual(try workspace.readStash(family), "External change")
    }
    @MainActor func testWriteFailureKeepsBufferVisible() throws {
        let workspace = try Workspace(root: root)
        let stash = StashModel()
        try stash.load(workspace: workspace, family: UUID().uuidString)
        stash.isOpen = true
        stash.edited("Unsaved notes")
        // A regular file obstructs directory creation, without relying on permissions.
        try "obstruction".write(to: workspace.stashDirectory(), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try stash.close())
        XCTAssertTrue(stash.isOpen)
        XCTAssertEqual(stash.text, "Unsaved notes")
    }

}
