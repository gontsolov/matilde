import XCTest
@testable import Matilde
import MatildeKit
import MatildeKitTesting

/// SYNC-07: two real (disposable) workspaces syncing through the in-memory server.
final class WorkspaceSyncTests: XCTestCase {
    private let fm = FileManager.default
    private var base: URL!
    private var trashed: [URL] = []

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("matilde-sync07-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { [base] in try? FileManager.default.removeItem(at: base!) }
    }

    private struct Mac {
        let workspace: Workspace
        let store: WorkspaceSyncStore
        let engine: SyncEngine
        var root: URL { workspace.root }
    }

    private func mac(_ name: String, server: FakeSyncServer, ring: AccountKeyRing) throws -> Mac {
        let root = base.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = try Workspace(root: root, storeBase: base.appendingPathComponent("store-\(name)", isDirectory: true))
        workspace.syncDeviceID = UUID().uuidString.lowercased()
        let store = try WorkspaceSyncStore(workspace: workspace)
        store.deviceName = "Mac \(name)"
        store.trashItem = { [weak self] url in
            self?.trashed.append(url)
            try FileManager.default.removeItem(at: url)
        }
        let transport = FakeSyncTransport(server: server, deviceId: workspace.syncDeviceID)
        return Mac(workspace: workspace, store: store, engine: SyncEngine(transport: transport, store: store, ring: ring))
    }

    private func pair() throws -> (FakeSyncServer, Mac, Mac) {
        let server = FakeSyncServer()
        let ring = try AccountKeyRing(userId: "0b6f1c2d-3e4a-4b5c-8d6e-7f8091a2b3c4", current: AccountKey.generate())
        return (server, try mac("A", server: server, ring: ring), try mac("B", server: server, ring: ring))
    }

    /// Every record the workspace yields, by id.
    private func snapshot(_ workspace: Workspace) throws -> [String: [String: JSONValue]] {
        var out: [String: [String: JSONValue]] = [:]
        for source in try workspace.syncSources() {
            guard case .present(_, let load) = source.state else { continue }
            out[source.id] = try load()
        }
        return out
    }

    private func text(_ mac: Mac, _ path: String) -> String? { try? String(contentsOf: mac.root.appendingPathComponent(path), encoding: .utf8) }

    func testAllRecordTypesConvergeAndDoNotEcho() async throws {
        let (_, a, b) = try pair()
        let w = a.workspace
        try w.createFolder(name: "Letters", parent: "")
        try w.createFolder(name: "Empty", parent: "")
        let letter = try w.create(name: "Letter", folder: "Letters", goal: "Say thanks", text: "Hello world")
        _ = try w.branch(letter, text: "Hello world")
        let gone = try w.create(name: "Old", folder: "", goal: "", text: "Bye")
        try w.trash(gone, move: { try FileManager.default.removeItem(at: $0) })
        let t0 = Date(timeIntervalSince1970: 1_763_500_000)
        try w.saveUserComments([UserComment(id: UUID(), draftID: letter.id, text: "Warmer?", location: 0, length: 5, quote: "Hello",
                                            prefix: "", suffix: " world", created: t0, modified: t0)])
        var thread = ReviewComment(id: UUID(), suggestion: ReviewSuggestion(quote: "world", prefix: "Hello ", suffix: "",
                                                                             explanation: "Be specific.", replacement: "friend"),
                                   location: 6, length: 5)
        thread.unread = true
        thread.messages = [ReviewMessage(role: "user", text: "Why?"), ReviewMessage(role: "assistant", text: "It is vague.")]
        try w.saveReview(WritingReview(id: UUID(), draftID: letter.id, created: t0, model: "m", revision: "r1", stale: false, comments: [thread]))
        try w.saveStash(letter.family, text: "Loose ideas", expected: "")
        let assets = try w.url(for: "Letters/.assets")
        try fm.createDirectory(at: assets, withIntermediateDirectories: true)
        let image = Data((0..<4000).map { UInt8(truncatingIfNeeded: $0) })
        try image.write(to: assets.appendingPathComponent("photo.png"))

        try await a.engine.sync()
        let report = try await b.engine.sync()
        XCTAssertEqual(report.unreadable, 0)
        XCTAssertEqual(try snapshot(b.workspace), try snapshot(a.workspace))
        XCTAssertEqual(text(b, "Letters/Letter.md"), "Hello world")
        XCTAssertEqual(try Data(contentsOf: b.root.appendingPathComponent("Letters/.assets/photo.png")), image)
        XCTAssertTrue(fm.fileExists(atPath: b.root.appendingPathComponent("Empty").path))
        XCTAssertEqual(try b.workspace.reviewHistory(draftID: letter.id).first?.comments.first?.messages?.map(\.text), ["Why?", "It is vague."])

        // Applying must not create local versions (no echo), on either side.
        XCTAssertEqual(try b.workspace.trackSyncChanges(), SyncTrackResult())
        let again = try await b.engine.sync()
        XCTAssertEqual(again.pushed, 0)
        let back = try await a.engine.sync()
        XCTAssertEqual(back.applied, 0)
        XCTAssertEqual(try a.workspace.trackSyncChanges(), SyncTrackResult())
    }

    func testEditsRenamesAndDeletesPropagate() async throws {
        let (_, a, b) = try pair()
        let draft = try a.workspace.create(name: "Plan", folder: "", goal: "", text: "v1")
        try await a.engine.sync()
        try await b.engine.sync()
        XCTAssertEqual(text(b, "Plan.md"), "v1")

        try "v2 from B".write(to: b.root.appendingPathComponent("Plan.md"), atomically: true, encoding: .utf8)
        try await b.engine.sync()
        try await a.engine.sync()
        XCTAssertEqual(text(a, "Plan.md"), "v2 from B")

        try a.workspace.rename(draft, name: "Plan final")
        try await a.engine.sync()
        try await b.engine.sync()
        XCTAssertNil(text(b, "Plan.md"))
        XCTAssertEqual(text(b, "Plan final.md"), "v2 from B")

        let moved = try XCTUnwrap(a.workspace.allDrafts().first { $0.id == draft.id })
        try a.workspace.trash(moved, move: { try FileManager.default.removeItem(at: $0) })
        try await a.engine.sync()
        try await b.engine.sync()
        XCTAssertTrue(try b.workspace.allDrafts().isEmpty)
        XCTAssertEqual(trashed.map(\.lastPathComponent), ["Plan final.md"], "deleted drafts go to the Trash")
        XCTAssertEqual(try b.workspace.trackSyncChanges(), SyncTrackResult())
    }

    func testConcurrentBodyEditsMakeABranchFromThisMac() async throws {
        let (_, a, b) = try pair()
        _ = try a.workspace.create(name: "Essay", folder: "", goal: "", text: "Start")
        try await a.engine.sync()
        try await b.engine.sync()
        try "Start, A".write(to: a.root.appendingPathComponent("Essay.md"), atomically: true, encoding: .utf8)
        try "Start, B".write(to: b.root.appendingPathComponent("Essay.md"), atomically: true, encoding: .utf8)
        try await a.engine.sync()
        let report = try await b.engine.sync()
        try await a.engine.sync()
        XCTAssertEqual(report.conflicts, 1)
        XCTAssertEqual(text(b, "Essay.md"), "Start, A")
        XCTAssertEqual(text(b, "Essay — from Mac B.md"), "Start, B")
        XCTAssertEqual(text(a, "Essay — from Mac B.md"), "Start, B")
        let branch = try XCTUnwrap(a.workspace.allDrafts().first { $0.path == "Essay — from Mac B.md" })
        let original = try XCTUnwrap(a.workspace.allDrafts().first { $0.path == "Essay.md" })
        XCTAssertEqual(branch.family, original.family)
        XCTAssertEqual(branch.parent, original.id)
    }

    func testFirstSyncKeepsBothWelcomeDocuments() async throws {
        let (_, a, b) = try pair()
        _ = try a.workspace.create(name: "Welcome", folder: "", goal: "", text: "Hi from A")
        _ = try b.workspace.create(name: "Welcome", folder: "", goal: "", text: "Hi from B")
        try await a.engine.sync()
        try await b.engine.sync()
        try await a.engine.sync()
        XCTAssertEqual(text(b, "Welcome.md"), "Hi from B")
        XCTAssertEqual(text(b, "Welcome 2.md"), "Hi from A")
        XCTAssertEqual(text(a, "Welcome 2.md"), "Hi from B")
        XCTAssertEqual(try a.workspace.trackSyncChanges(), SyncTrackResult())
        XCTAssertEqual(try b.workspace.trackSyncChanges(), SyncTrackResult())
    }

    func testUnsavedLocalEditIsNeverOverwritten() async throws {
        let (_, a, b) = try pair()
        _ = try a.workspace.create(name: "Note", folder: "", goal: "", text: "one")
        try await a.engine.sync()
        try await b.engine.sync()
        try "two".write(to: a.root.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)
        try await a.engine.sync()
        // B changes the file after its last tracking run, then a pulled version arrives.
        try b.workspace.trackSyncChanges()
        let local = b.root.appendingPathComponent("Note.md")
        try "local edit".write(to: local, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: local.path)
        let remote = try XCTUnwrap(a.workspace.syncRecord(id: SyncID.derived("body", a.workspace.allDrafts()[0].id.lowercased())))
        _ = try b.store.apply([.write(remote, server: remote.hlc)], blobs: [:])
        XCTAssertEqual(text(b, "Note.md"), "local edit")
        // The next sync turns it into a branch instead.
        try await b.engine.sync()
        XCTAssertEqual(text(b, "Note.md"), "two")
        XCTAssertEqual(text(b, "Note — from Mac B.md"), "local edit")
    }

    func testRecordsWaitForTheirParent() throws {
        let (_, a, b) = try pair()
        let draft = try a.workspace.create(name: "Late", folder: "", goal: "", text: "body first")
        try a.workspace.trackSyncChanges()
        let id = draft.id.lowercased()
        let body = try XCTUnwrap(a.workspace.syncRecord(id: SyncID.derived("body", id)))
        let meta = try XCTUnwrap(a.workspace.syncRecord(id: id))
        let first = try b.store.apply([.write(body, server: body.hlc)], blobs: [:])
        XCTAssertEqual(first.parked, 1)
        XCTAssertNil(text(b, "Late.md"))
        XCTAssertEqual(try b.workspace.trackSyncChanges(), SyncTrackResult(), "a parked record is not a local change")
        let second = try b.store.apply([.write(meta, server: meta.hlc)], blobs: [:])
        XCTAssertEqual(second.applied, 2)
        XCTAssertEqual(text(b, "Late.md"), "body first")
        XCTAssertEqual(try b.workspace.trackSyncChanges(), SyncTrackResult())
    }

    func testExistingWorkspaceIsFullyPendingAndAccountSwitchResends() async throws {
        let (_, a, _) = try pair()
        for index in 0..<5 { _ = try a.workspace.create(name: "D\(index)", folder: "", goal: "", text: "t\(index)") }
        let first = try await a.engine.sync()
        XCTAssertEqual(first.pushed, 10)
        let other = FakeSyncServer()
        let ring = try AccountKeyRing(userId: "2d3e4f5a-6b7c-4d8e-9fa0-b1c2d3e4f5a6", current: AccountKey.generate())
        let engine = SyncEngine(transport: FakeSyncTransport(server: other, deviceId: a.workspace.syncDeviceID), store: a.store, ring: ring)
        let second = try await engine.sync()
        XCTAssertEqual(second.pushed, 10)
        XCTAssertEqual(try a.store.cursor().userId, "2d3e4f5a-6b7c-4d8e-9fa0-b1c2d3e4f5a6")
    }
}
