import XCTest
@testable import Matilde

final class SidebarActionsTests: XCTestCase {
    var root: URL!
    var outside: URL!
    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("matilde-sidebar-actions-\(UUID().uuidString)")
        root = base.appendingPathComponent("Workspace")
        outside = base.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    private func draft(_ path: String, family: String, parent: String? = nil, id: String? = nil) -> Draft {
        Draft(id: id ?? path, path: path, family: family, parent: parent, goal: "", cursor: 0, scroll: 0)
    }

    // MARK: Pure logic

    func testFolderContentsIncludeSubfoldersButNotSimilarNames() {
        let drafts = [
            draft("Top.md", family: "a"),
            draft("Essays/One.md", family: "b"),
            draft("Essays/One — Alternative 1.md", family: "b"),
            draft("Essays/Old/Two.md", family: "c"),
            draft("Essays Extra/Three.md", family: "d"),
        ]
        XCTAssertEqual(Set(SidebarActions.drafts(in: "Essays", among: drafts).map(\.path)),
                       ["Essays/One.md", "Essays/One — Alternative 1.md", "Essays/Old/Two.md"])
        XCTAssertEqual(SidebarActions.noteCount(in: "Essays", among: drafts), 2)
        XCTAssertEqual(SidebarActions.noteCount(in: "Essays/Old", among: drafts), 1)
        XCTAssertEqual(SidebarActions.noteCount(in: "Empty", among: drafts), 0)
    }

    func testNoteCountCountsAFamilySplitAcrossFoldersOncePerFolder() {
        let drafts = [draft("Essays/A.md", family: "x"), draft("Essays/Sub/B.md", family: "x")]
        XCTAssertEqual(SidebarActions.noteCount(in: "Essays", among: drafts), 2)
    }

    func testMoveTargetsStartWithDocumentsAndSkipTheCurrentFolder() {
        let folders = ["", "Essays", "Essays/Old", "Letters"]
        XCTAssertEqual(SidebarActions.moveTargets(folders: folders, from: ""), ["Essays", "Essays/Old", "Letters"])
        XCTAssertEqual(SidebarActions.moveTargets(folders: folders, from: "Essays"), ["", "Essays/Old", "Letters"])
        XCTAssertEqual(SidebarActions.moveTargets(folders: [""], from: ""), [])
    }

    func testSuccessorPrefersNextThenPreviousRemainingNote() {
        let order = ["a", "b", "c", "d"]
        XCTAssertEqual(SidebarActions.successor(of: "b", removing: ["b"], in: order), "c")
        XCTAssertEqual(SidebarActions.successor(of: "b", removing: ["b", "c"], in: order), "d")
        XCTAssertEqual(SidebarActions.successor(of: "d", removing: ["d"], in: order), "c")
        XCTAssertEqual(SidebarActions.successor(of: "c", removing: ["c", "d"], in: order), "b")
        XCTAssertEqual(SidebarActions.successor(of: "b", removing: ["a"], in: order), "b")
        XCTAssertNil(SidebarActions.successor(of: "a", removing: Set(order), in: order))
        XCTAssertEqual(SidebarActions.successor(of: "hidden", removing: ["a"], in: order), "b")
        XCTAssertNil(SidebarActions.successor(of: nil, removing: [], in: []))
    }

    func testFolderRenamePaths() {
        XCTAssertEqual(SidebarActions.renamedFolder("Essays", to: "Pieces"), "Pieces")
        XCTAssertEqual(SidebarActions.renamedFolder("Essays/Old", to: "Archive"), "Essays/Archive")
        XCTAssertEqual(SidebarActions.path("Essays/Old/A.md", movingFolder: "Essays", to: "Pieces"), "Pieces/Old/A.md")
        XCTAssertEqual(SidebarActions.path("Essays", movingFolder: "Essays", to: "Pieces"), "Pieces")
        XCTAssertEqual(SidebarActions.path("Essays Extra/A.md", movingFolder: "Essays", to: "Pieces"), "Essays Extra/A.md")
    }

    // MARK: Workspace

    func testTrashingFolderArchivesItsDraftsAndReconnectsOutsideChildren() throws {
        let workspace = try Workspace(root: root)
        try workspace.createFolder(name: "Essays", parent: "")
        try workspace.createFolder(name: "Old", parent: "Essays")
        let first = try workspace.create(name: "First", folder: "Essays", goal: "Keep", text: "One")
        let second = try workspace.branch(first, text: "One")
        let third = try workspace.branch(second, text: "One")
        let nested = try workspace.create(name: "Nested", folder: "Essays/Old", goal: "", text: "Two")
        let keep = try workspace.create(name: "Keep", folder: "", goal: "", text: "Three")
        // Move the deepest branch out so it must reconnect past two removed ancestors.
        try workspace.move([third], to: "")

        let removed = try workspace.trashFolder("Essays") { url in
            try FileManager.default.moveItem(at: url, to: self.outside.appendingPathComponent(url.lastPathComponent))
        }
        XCTAssertEqual(Set(removed.map(\.id)), [first.id, second.id, nested.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("Essays/Old/Nested.md").path))

        let reopened = try Workspace(root: root)
        let contents = try reopened.scan()
        XCTAssertEqual(Set(contents.drafts.map(\.id)), [third.id, keep.id])
        XCTAssertEqual(contents.folders, [""])
        XCTAssertNil(try XCTUnwrap(contents.drafts.first { $0.id == third.id }).parent)
        XCTAssertEqual(try reopened.db.execute("SELECT * FROM trashed_drafts").count, 3)
        XCTAssertEqual(try reopened.db.execute("SELECT goal FROM trashed_drafts WHERE id=?", [first.id]).first?["goal"], "Keep")
        XCTAssertFalse(try reopened.db.execute("SELECT * FROM snapshots WHERE source=?", [first.id]).isEmpty)
    }

    func testFailedFolderTrashChangesNothing() throws {
        let workspace = try Workspace(root: root)
        try workspace.createFolder(name: "Box", parent: "")
        let draft = try workspace.create(name: "Inside", folder: "Box", goal: "", text: "Safe")
        XCTAssertThrowsError(try workspace.trashFolder("Box") { _ in throw WorkspaceError.message("Trash unavailable") })
        XCTAssertEqual(try workspace.scan().drafts.map(\.id), [draft.id])
        XCTAssertEqual(try workspace.read(draft), "Safe")
        XCTAssertTrue(try workspace.db.execute("SELECT * FROM trashed_drafts").isEmpty)
        XCTAssertThrowsError(try workspace.trashFolder(""))
        XCTAssertThrowsError(try workspace.trashFolder(".matilde"))
    }

    func testRenamingFolderKeepsIdentityAndRefusesExistingNames() throws {
        let workspace = try Workspace(root: root)
        try workspace.createFolder(name: "Essays", parent: "")
        try workspace.createFolder(name: "Old", parent: "Essays")
        try workspace.createFolder(name: "Letters", parent: "")
        let note = try workspace.create(name: "Note", folder: "Essays/Old", goal: "Goal", text: "Body")
        let branch = try workspace.branch(note, text: "Body")

        XCTAssertThrowsError(try workspace.renameFolder("Essays", to: "Letters"))
        XCTAssertThrowsError(try workspace.renameFolder("Essays", to: "a/b"))
        XCTAssertEqual(try workspace.renameFolder("Essays", to: "Pieces"), "Pieces")
        let contents = try workspace.scan()
        XCTAssertEqual(contents.folders, ["", "Letters", "Pieces", "Pieces/Old"])
        let moved = try XCTUnwrap(contents.drafts.first { $0.id == note.id })
        XCTAssertEqual(moved.path, "Pieces/Old/Note.md")
        XCTAssertEqual(moved.goal, "Goal")
        XCTAssertEqual(try workspace.read(moved), "Body")
        XCTAssertEqual(contents.drafts.first { $0.id == branch.id }?.parent, note.id)
        XCTAssertEqual(contents.drafts.count, 2)

        XCTAssertThrowsError(try workspace.renameFolder("Pieces", to: "Again") { _, _ in throw WorkspaceError.message("Move failed") })
        XCTAssertEqual(try workspace.scan().drafts.first { $0.id == note.id }?.path, "Pieces/Old/Note.md")
    }

    func testDuplicateCreatesIndependentNoteBesideOriginal() throws {
        let workspace = try Workspace(root: root)
        let original = try workspace.create(name: "Plan", folder: "", goal: "Ship", text: "Steps")
        let copy = try workspace.duplicate(original, text: "Steps")
        let again = try workspace.duplicate(original, text: "Steps")
        XCTAssertEqual(copy.path, "Plan copy.md")
        XCTAssertEqual(again.path, "Plan copy 2.md")
        XCTAssertNotEqual(copy.family, original.family)
        XCTAssertNil(copy.parent)
        XCTAssertEqual(copy.goal, "Ship")
        XCTAssertEqual(try workspace.read(copy), "Steps")
        XCTAssertEqual(try workspace.read(original), "Steps")
    }
}
