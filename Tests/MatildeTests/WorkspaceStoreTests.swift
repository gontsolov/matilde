import XCTest
@testable import Matilde

/// SYNC-01: the live database moves from `.matilde/workspace.sqlite` to Application Support.
final class WorkspaceStoreTests: XCTestCase {
    private var root: URL!
    private var base: URL!
    private let fm = FileManager.default
    private var metadata: URL { root.appendingPathComponent(".matilde", isDirectory: true) }
    private var legacy: URL { metadata.appendingPathComponent("workspace.sqlite") }
    private var migrated: URL { metadata.appendingPathComponent("workspace.sqlite.migrated") }

    override func setUpWithError() throws {
        let scratch = fm.temporaryDirectory.appendingPathComponent("matilde-store-tests-\(UUID().uuidString)", isDirectory: true)
        root = scratch.appendingPathComponent("Writing", isDirectory: true)
        base = scratch.appendingPathComponent("Application Support/Matilde/workspaces", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: scratch) }
    }

    private func comment(_ draftID: String, _ text: String) -> UserComment {
        UserComment(id: UUID(), draftID: draftID, text: text, location: 0, length: 5, quote: "Hello", prefix: "", suffix: " world",
                    created: Date(timeIntervalSince1970: 1_700_000_000), modified: Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// Build a workspace the way Matilde 0.1.19 left it: the live database inside `.matilde`, no workspace ID.
    @discardableResult
    private func makeLegacyWorkspace(at folder: URL? = nil) throws -> (draft: Draft, comment: UserComment) {
        let folder = folder ?? root!
        let scratchBase = base.deletingLastPathComponent().appendingPathComponent("legacy-\(UUID().uuidString)", isDirectory: true)
        var result: (draft: Draft, comment: UserComment)?
        var database: URL?
        do {
            let workspace = try Workspace(root: folder, storeBase: scratchBase)
            let draft = try workspace.create(name: "Letter", folder: "", goal: "Say thanks", text: "Hello world")
            let note = comment(draft.id, "Warmer opening?")
            try workspace.saveUserComments([note])
            try workspace.setState("active", draft.id)
            result = (draft, note)
            database = workspace.store.databaseURL
        }
        let folderMetadata = folder.appendingPathComponent(".matilde", isDirectory: true)
        try fm.moveItem(at: XCTUnwrap(database), to: folderMetadata.appendingPathComponent("workspace.sqlite"))
        try fm.removeItem(at: folderMetadata.appendingPathComponent("workspace.json"))
        try fm.removeItem(at: scratchBase)
        return try XCTUnwrap(result)
    }

    private func assertHasLegacyData(_ workspace: Workspace, _ expected: (draft: Draft, comment: UserComment), file: StaticString = #filePath, line: UInt = #line) throws {
        let drafts = try workspace.scan().drafts
        XCTAssertEqual(drafts.first { $0.id == expected.draft.id }?.goal, "Say thanks", file: file, line: line)
        XCTAssertEqual(try workspace.userComments(draftID: expected.draft.id).map(\.text), ["Warmer opening?"], file: file, line: line)
        XCTAssertEqual(try workspace.state("active"), expected.draft.id, file: file, line: line)
    }

    private func storeDatabase(_ id: String) -> URL {
        base.appendingPathComponent(id, isDirectory: true).appendingPathComponent("workspace.sqlite")
    }

    func testNewWorkspaceKeepsItsDatabaseOutsideTheWorkspace() throws {
        let workspace = try Workspace(root: root, storeBase: base)
        XCTAssertEqual(workspace.store.origin, .fresh)
        XCTAssertNotNil(UUID(uuidString: workspace.workspaceID))
        XCTAssertEqual(try WorkspaceStore.existingIdentity(metadata: metadata), workspace.workspaceID)
        XCTAssertEqual(workspace.store.databaseURL, storeDatabase(workspace.workspaceID))
        XCTAssertTrue(fm.fileExists(atPath: workspace.store.databaseURL.path))
        XCTAssertFalse(fm.fileExists(atPath: legacy.path))
        let draft = try workspace.create(name: "Note", folder: "", goal: "Goal", text: "Text")

        let reopened = try Workspace(root: root, storeBase: base)
        XCTAssertEqual(reopened.store.origin, .existing)
        XCTAssertEqual(reopened.workspaceID, workspace.workspaceID)
        XCTAssertEqual(try reopened.scan().drafts.map(\.id), [draft.id])
        XCTAssertFalse(fm.fileExists(atPath: legacy.path))
    }

    func testMigratesLegacyDatabaseOnceAndRenamesTheOldFile() throws {
        let expected = try makeLegacyWorkspace()
        let workspace = try Workspace(root: root, storeBase: base)
        XCTAssertEqual(workspace.store.origin, .migratedLegacy)
        try assertHasLegacyData(workspace, expected)
        XCTAssertFalse(fm.fileExists(atPath: legacy.path), "No live database may remain in the workspace")
        XCTAssertTrue(fm.fileExists(atPath: migrated.path), "The old file is kept, renamed")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Letter.md"), encoding: .utf8), "Hello world",
                       "Markdown is untouched")

        // Idempotent: a second launch uses the store and does not touch the renamed copy.
        try workspace.saveUserComments([comment(expected.draft.id, "Second note")])
        let reopened = try Workspace(root: root, storeBase: base)
        XCTAssertEqual(reopened.store.origin, .existing)
        XCTAssertEqual(try reopened.userComments(draftID: expected.draft.id).count, 2)
        XCTAssertFalse(fm.fileExists(atPath: legacy.path))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: metadata.path).filter { $0.hasPrefix("workspace.sqlite") }, ["workspace.sqlite.migrated"])
    }

    func testMigrationIncludesUncheckpointedWriteAheadLog() throws {
        try fm.createDirectory(at: metadata, withIntermediateDirectories: true)
        let scratch = base.deletingLastPathComponent()
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let source = scratch.appendingPathComponent("wal-source.sqlite")
        let writer = try Database(url: source)
        XCTAssertEqual(try writer.execute("PRAGMA journal_mode = WAL").first?["journal_mode"], "wal")
        try writer.execute("INSERT INTO state VALUES ('only-in-wal', 'kept')")
        // Copy while the writer is still open, so the row exists only in the -wal file.
        try fm.copyItem(at: source, to: legacy)
        try fm.copyItem(at: URL(fileURLWithPath: source.path + "-wal"), to: URL(fileURLWithPath: legacy.path + "-wal"))
        withExtendedLifetime(writer) {}

        let workspace = try Workspace(root: root, storeBase: base)
        XCTAssertEqual(workspace.store.origin, .migratedLegacy)
        XCTAssertEqual(try workspace.state("only-in-wal"), "kept")
        for suffix in ["", "-wal", "-shm"] {
            XCTAssertFalse(fm.fileExists(atPath: legacy.path + suffix), "workspace.sqlite\(suffix) left in the workspace")
        }
        XCTAssertFalse(fm.fileExists(atPath: workspace.store.databaseURL.path + "-wal"))
        XCTAssertTrue(fm.fileExists(atPath: migrated.path))
        XCTAssertEqual(try workspace.db.execute("PRAGMA journal_mode").first?["journal_mode"], "delete")
    }

    func testInterruptedCopyIsDiscardedAndRetried() throws {
        let expected = try makeLegacyWorkspace()
        // A crash during the copy leaves only a temporary file; the old database is untouched.
        let id = try WorkspaceStore.identity(metadata: metadata)
        let directory = base.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appendingPathComponent("workspace.sqlite.incoming-\(UUID().uuidString)")
        try Data("partial".utf8).write(to: partial)

        let workspace = try Workspace(root: root, storeBase: base)
        XCTAssertEqual(workspace.workspaceID, id)
        XCTAssertEqual(workspace.store.origin, .migratedLegacy)
        try assertHasLegacyData(workspace, expected)
        XCTAssertFalse(fm.fileExists(atPath: partial.path))
    }

    func testCrashAfterCopyFinishesByRenamingOldFileWithoutOverwritingStore() throws {
        let expected = try makeLegacyWorkspace()
        let legacyBytes = try Data(contentsOf: legacy)
        // Simulate a crash between "copy in place" and "rename the old file".
        let id = try WorkspaceStore.identity(metadata: metadata)
        try fm.createDirectory(at: storeDatabase(id).deletingLastPathComponent(), withIntermediateDirectories: true)
        try WorkspaceStore.copyVerified(from: legacy, to: storeDatabase(id))
        do {
            let database = try Database(url: storeDatabase(id))
            try database.execute("INSERT INTO state VALUES ('only-in-store', 'yes')")
        }

        let workspace = try Workspace(root: root, storeBase: base)
        XCTAssertEqual(workspace.store.origin, .existing)
        try assertHasLegacyData(workspace, expected)
        XCTAssertEqual(try workspace.state("only-in-store"), "yes", "The store is used as is, never overwritten by the old file")
        XCTAssertFalse(fm.fileExists(atPath: legacy.path))
        XCTAssertEqual(try Data(contentsOf: migrated), legacyBytes)
    }

    func testRetiringNeverOverwritesAnEarlierMigratedCopy() throws {
        let expected = try makeLegacyWorkspace()
        try Data("older copy".utf8).write(to: migrated)
        let workspace = try Workspace(root: root, storeBase: base)
        try assertHasLegacyData(workspace, expected)
        XCTAssertEqual(try Data(contentsOf: migrated), Data("older copy".utf8))
        let copies = try fm.contentsOfDirectory(atPath: metadata.path).filter { $0.hasPrefix("workspace.sqlite.migrated") }
        XCTAssertEqual(copies.count, 2)
        XCTAssertFalse(fm.fileExists(atPath: legacy.path))
    }

    func testAnotherMacImportsTheMigratedCopyAndLeavesItInPlace() throws {
        // Mac A migrated a shared (synced) workspace: only the workspace ID and the
        // renamed copy arrive on Mac B, which has no store yet.
        let expected = try makeLegacyWorkspace()
        let macA = base.deletingLastPathComponent().appendingPathComponent("mac-a", isDirectory: true)
        let id: String
        do {
            let first = try Workspace(root: root, storeBase: macA)
            XCTAssertEqual(first.store.origin, .migratedLegacy)
            id = first.workspaceID
        }

        let macB = try Workspace(root: root, storeBase: base)
        XCTAssertEqual(macB.store.origin, .importedMigratedCopy)
        XCTAssertEqual(macB.workspaceID, id)
        try assertHasLegacyData(macB, expected)
        XCTAssertTrue(fm.fileExists(atPath: migrated.path))
        XCTAssertFalse(fm.fileExists(atPath: legacy.path))
    }

    func testMissingOldDatabaseStartsFresh() throws {
        try fm.createDirectory(at: metadata, withIntermediateDirectories: true)
        try "Draft".write(to: root.appendingPathComponent("Draft.md"), atomically: true, encoding: .utf8)
        let workspace = try Workspace(root: root, storeBase: base)
        XCTAssertEqual(workspace.store.origin, .fresh)
        XCTAssertEqual(try workspace.scan().drafts.map(\.title), ["Draft"])
    }

    func testUnreadableOldDatabaseIsLeftUntouched() throws {
        try fm.createDirectory(at: metadata, withIntermediateDirectories: true)
        let garbage = Data(repeating: 0x5A, count: 8192)
        try garbage.write(to: legacy)
        XCTAssertThrowsError(try Workspace(root: root, storeBase: base))
        XCTAssertEqual(try Data(contentsOf: legacy), garbage, "A failed migration must not change or remove the old file")
        XCTAssertFalse(fm.fileExists(atPath: migrated.path))
        let id = try XCTUnwrap(WorkspaceStore.existingIdentity(metadata: metadata))
        XCTAssertFalse(fm.fileExists(atPath: storeDatabase(id).path))
        let leftovers = try fm.contentsOfDirectory(atPath: storeDatabase(id).deletingLastPathComponent().path)
        XCTAssertTrue(leftovers.allSatisfy { !$0.hasPrefix("workspace.sqlite") }, "\(leftovers)")
    }

    func testMovedWorkspaceKeepsItsStore() throws {
        let expected = try makeLegacyWorkspace()
        let id = try Workspace(root: root, storeBase: base).workspaceID
        let moved = root.deletingLastPathComponent().appendingPathComponent("Moved", isDirectory: true)
        try fm.moveItem(at: root, to: moved)
        root = moved

        let workspace = try Workspace(root: moved, storeBase: base)
        XCTAssertEqual(workspace.workspaceID, id)
        XCTAssertEqual(workspace.store.origin, .existing)
        try assertHasLegacyData(workspace, expected)
    }

    func testCopiedWorkspaceGetsItsOwnIDAndAStartingCopyOfTheData() throws {
        let expected = try makeLegacyWorkspace()
        let original = try Workspace(root: root, storeBase: base)
        let copy = root.deletingLastPathComponent().appendingPathComponent("Writing copy", isDirectory: true)
        try fm.copyItem(at: root, to: copy)

        let duplicate = try Workspace(root: copy, storeBase: base)
        XCTAssertNotEqual(duplicate.workspaceID, original.workspaceID)
        XCTAssertEqual(duplicate.store.origin, .forked)
        XCTAssertEqual(try WorkspaceStore.existingIdentity(metadata: copy.appendingPathComponent(".matilde")), duplicate.workspaceID)
        try assertHasLegacyData(duplicate, expected)

        // From now on the two are independent.
        try duplicate.saveUserComments([comment(expected.draft.id, "Only in the copy")])
        XCTAssertEqual(try Workspace(root: root, storeBase: base).userComments(draftID: expected.draft.id).count, 1)
        XCTAssertEqual(try Workspace(root: copy, storeBase: base).userComments(draftID: expected.draft.id).count, 2)
        XCTAssertEqual(try Workspace(root: root, storeBase: base).workspaceID, original.workspaceID)
    }

    func testRejectsMalformedWorkspaceID() throws {
        try fm.createDirectory(at: metadata, withIntermediateDirectories: true)
        try Data(#"{"id": "../../escape"}"#.utf8).write(to: metadata.appendingPathComponent("workspace.json"))
        let workspace = try Workspace(root: root, storeBase: base)
        XCTAssertNotNil(UUID(uuidString: workspace.workspaceID))
        XCTAssertTrue(workspace.store.databaseURL.path.hasPrefix(base.path + "/"))
    }
}
