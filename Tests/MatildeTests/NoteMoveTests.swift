import XCTest
@testable import Matilde

final class NoteMoveTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("matilde-move-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testMovingNoteIntoFolderKeepsFamilyGoalSnapshotsAndPosition() throws {
        let workspace = try Workspace(root: root)
        try workspace.createFolder(name: "Essays", parent: "")
        let original = try workspace.create(name: "Letter", folder: "", goal: "Say thanks", text: "Dear friend")
        try workspace.position(original, cursor: 4, scroll: 120)
        let branch = try workspace.branch(original, text: "Dear friend")
        try workspace.setState("familyActive:\(original.family)", branch.id)

        let note = try workspace.movableNote(family: original.family, folder: "")
        XCTAssertEqual(Set(note.map(\.id)), [original.id, branch.id])
        let moved = try workspace.move(note, to: "Essays")
        XCTAssertEqual(moved[original.id], "Essays/Letter.md")
        XCTAssertEqual(moved[branch.id], "Essays/Letter — Alternative 1.md")

        let reopened = try Workspace(root: root)
        let drafts = try reopened.scan().drafts
        XCTAssertEqual(drafts.count, 2)
        let movedOriginal = try XCTUnwrap(drafts.first { $0.id == original.id })
        let movedBranch = try XCTUnwrap(drafts.first { $0.id == branch.id })
        XCTAssertEqual(movedOriginal.folder, "Essays")
        XCTAssertEqual(movedOriginal.goal, "Say thanks")
        XCTAssertEqual(movedOriginal.cursor, 4)
        XCTAssertEqual(movedOriginal.scroll, 120)
        XCTAssertEqual(movedBranch.family, original.family)
        XCTAssertEqual(movedBranch.parent, original.id)
        XCTAssertEqual(try reopened.read(movedOriginal), "Dear friend")
        XCTAssertEqual(try reopened.db.execute("SELECT * FROM snapshots WHERE source=? AND child=?", [original.id, branch.id]).count, 1)
        XCTAssertEqual(try reopened.state("familyActive:\(original.family)"), branch.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Letter.md").path))
    }

    func testNameCollisionPicksFreeNameAndNeverOverwrites() throws {
        let workspace = try Workspace(root: root)
        try workspace.createFolder(name: "Archive", parent: "")
        let existing = try workspace.create(name: "Notes", folder: "Archive", goal: "", text: "Already here")
        let second = try workspace.create(name: "Notes 2", folder: "Archive", goal: "", text: "Also here")
        let incoming = try workspace.create(name: "Notes", folder: "", goal: "Incoming goal", text: "Moving in")

        let moved = try workspace.move([incoming], to: "Archive")
        XCTAssertEqual(moved[incoming.id], "Archive/Notes 3.md")
        let drafts = try workspace.scan().drafts
        XCTAssertEqual(try workspace.read(try XCTUnwrap(drafts.first { $0.id == existing.id })), "Already here")
        XCTAssertEqual(try workspace.read(try XCTUnwrap(drafts.first { $0.id == second.id })), "Also here")
        let movedIncoming = try XCTUnwrap(drafts.first { $0.id == incoming.id })
        XCTAssertEqual(movedIncoming.path, "Archive/Notes 3.md")
        XCTAssertEqual(movedIncoming.goal, "Incoming goal")
        XCTAssertEqual(try workspace.read(movedIncoming), "Moving in")
    }

    func testMovingBackToRootAndIntoSameFolderIsSafe() throws {
        let workspace = try Workspace(root: root)
        try workspace.createFolder(name: "Drafts", parent: "")
        let draft = try workspace.create(name: "Plan", folder: "Drafts", goal: "", text: "Steps")
        XCTAssertTrue(try workspace.move([draft], to: "Drafts").isEmpty)
        XCTAssertEqual(try workspace.move([draft], to: "")[draft.id], "Plan.md")
        XCTAssertEqual(try workspace.scan().drafts.first?.path, "Plan.md")
    }

    func testMovingCopiesReferencedAssetsAndKeepsOriginals() throws {
        let workspace = try Workspace(root: root)
        try workspace.createFolder(name: "Travel", parent: "")
        let assets = root.appendingPathComponent(".assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let image = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        try image.write(to: assets.appendingPathComponent("photo.png"))
        let text = "Intro\n\n![](.assets/photo.png)\n\n![missing](.assets/gone.png)\n![remote](https://example.com/a.png)"
        let draft = try workspace.create(name: "Trip", folder: "", goal: "", text: text)
        let sibling = try workspace.create(name: "Other", folder: "", goal: "", text: "![](.assets/photo.png)")

        try workspace.move([draft], to: "Travel")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Travel/.assets/photo.png")), image)
        XCTAssertEqual(try Data(contentsOf: assets.appendingPathComponent("photo.png")), image)
        let moved = try XCTUnwrap(try workspace.scan().drafts.first { $0.id == draft.id })
        XCTAssertEqual(try workspace.read(moved), text)
        XCTAssertEqual(try workspace.read(sibling), "![](.assets/photo.png)")
        XCTAssertEqual(Workspace.assetReferences(in: text), [".assets/photo.png", ".assets/gone.png"])
    }

    func testConflictingAssetOrFailedMoveChangesNothing() throws {
        let workspace = try Workspace(root: root)
        try workspace.createFolder(name: "Box", parent: "")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent(".assets"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Box/.assets"), withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent(".assets/a.png"))
        try Data([2]).write(to: root.appendingPathComponent("Box/.assets/a.png"))
        let draft = try workspace.create(name: "Pictures", folder: "", goal: "", text: "![](.assets/a.png)")
        XCTAssertThrowsError(try workspace.move([draft], to: "Box"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Box/.assets/a.png")), Data([2]))
        XCTAssertEqual(try workspace.scan().drafts.first { $0.id == draft.id }?.path, "Pictures.md")

        let plain = try workspace.create(name: "Plain", folder: "", goal: "", text: "Keep")
        XCTAssertThrowsError(try workspace.move([plain], to: "Box") { _, _ in throw WorkspaceError.message("Move failed") })
        XCTAssertEqual(try workspace.scan().drafts.first { $0.id == plain.id }?.path, "Plain.md")
        XCTAssertEqual(try workspace.read(plain), "Keep")
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("Box/Plain.md").path))
    }

    func testMoveRejectsHiddenAndMissingFolders() throws {
        let workspace = try Workspace(root: root)
        let draft = try workspace.create(name: "Stay", folder: "", goal: "", text: "")
        XCTAssertThrowsError(try workspace.move([draft], to: ".matilde"))
        XCTAssertThrowsError(try workspace.move([draft], to: ".assets"))
        XCTAssertThrowsError(try workspace.move([draft], to: "Nowhere"))
        XCTAssertEqual(try workspace.scan().drafts.first?.path, "Stay.md")
    }
}
