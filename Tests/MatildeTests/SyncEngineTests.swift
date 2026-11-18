import XCTest
@testable import Matilde

/// SYNC-07: the push/pull loop against an in-memory server with the real server's semantics.
final class SyncEngineTests: XCTestCase {
    private let userId = "0b6f1c2d-3e4a-4b5c-8d6e-7f8091a2b3c4"

    private struct Device {
        let store: MemorySyncStore
        let transport: FakeSyncTransport
        let engine: SyncEngine
    }

    private func makeRing(_ key: AccountKey? = nil, user: String? = nil) throws -> AccountKeyRing {
        try AccountKeyRing(userId: user ?? userId, current: key ?? AccountKey.generate())
    }

    private func device(_ server: FakeSyncServer, ring: AccountKeyRing, store: MemorySyncStore = MemorySyncStore()) -> Device {
        let transport = FakeSyncTransport(server: server, deviceId: store.device)
        return Device(store: store, transport: transport, engine: SyncEngine(transport: transport, store: store, ring: ring))
    }

    private func pair() throws -> (FakeSyncServer, Device, Device) {
        let server = FakeSyncServer()
        let ring = try makeRing()
        return (server, device(server, ring: ring), device(server, ring: ring))
    }

    private func visible(_ store: MemorySyncStore) -> [String: MemorySyncStore.Entity] { store.entities }

    // MARK: Convergence

    func testTwoDevicesConverge() async throws {
        let (_, a, b) = try pair()
        let letter = a.store.draft(path: "Letter.md", text: "Hello")
        b.store.draft(path: "Notes.md", text: "Ideas")
        try await a.engine.sync()
        try await b.engine.sync()
        try await a.engine.sync()
        XCTAssertEqual(visible(a.store), visible(b.store))
        XCTAssertEqual(b.store.text(of: letter), "Hello")
        XCTAssertEqual(a.store.pendingCount, 0)
        XCTAssertEqual(b.store.pendingCount, 0)

        a.store.setText("Hello again", of: letter)
        try await a.engine.sync()
        let report = try await b.engine.sync()
        XCTAssertEqual(b.store.text(of: letter), "Hello again")
        XCTAssertEqual(report.applied, 1)
        XCTAssertEqual(report.pushed, 0, "applying a remote change must not echo it back")
    }

    func testOnlyChangedRecordsAreSent() async throws {
        let (server, a, _) = try pair()
        var drafts: [String] = []
        for index in 0..<20 { drafts.append(a.store.draft(path: "D\(index).md", text: "Text \(index)")) }
        try await a.engine.sync()
        let before = await server.pushes.flatMap { $0 }.count
        XCTAssertEqual(before, 40)
        a.store.setText("Changed", of: drafts[3])
        let report = try await a.engine.sync()
        let sent = await server.pushes.flatMap { $0 }.suffix(from: before)
        XCTAssertEqual(sent.map(\.id), [SyncID.derived("body", drafts[3])])
        XCTAssertEqual(report.pushed, 1)
        let nothing = try await a.engine.sync()
        XCTAssertEqual(nothing.pushed, 0)
    }

    func testConcurrentMetadataEditsMergeByField() async throws {
        let (_, a, b) = try pair()
        let id = a.store.draft(path: "Plan.md", text: "x")
        try await a.engine.sync()
        try await b.engine.sync()
        // A changes the goal, B (offline, later) moves the draft.
        a.store.entities[id]?.fields["goal"] = .string("Finish")
        try await a.engine.sync()
        b.store.entities[id]?.fields["path"] = .string("Archive/Plan.md")
        try await b.engine.sync()
        try await a.engine.sync()
        for store in [a.store, b.store] {
            XCTAssertEqual(store.entities[id]?.fields["goal"], .string("Finish"))
            XCTAssertEqual(store.entities[id]?.fields["path"], .string("Archive/Plan.md"))
        }
        XCTAssertEqual(visible(a.store), visible(b.store))
    }

    func testSameFieldLastWriterWins() async throws {
        let (_, a, b) = try pair()
        let id = a.store.draft(path: "Plan.md", text: "x")
        try await a.engine.sync()
        try await b.engine.sync()
        a.store.entities[id]?.fields["goal"] = .string("A")
        try a.store.track()
        try await Task.sleep(nanoseconds: 5_000_000)
        b.store.entities[id]?.fields["goal"] = .string("B")
        try b.store.track()
        try await a.engine.sync()
        try await b.engine.sync()
        try await a.engine.sync()
        XCTAssertEqual(a.store.entities[id]?.fields["goal"], .string("B"))
        XCTAssertEqual(b.store.entities[id]?.fields["goal"], .string("B"))
    }

    func testConcurrentBodyEditsBecomeAConflictBranch() async throws {
        let (_, a, b) = try pair()
        let id = a.store.draft(path: "Essay.md", text: "Start")
        try await a.engine.sync()
        try await b.engine.sync()
        a.store.setText("Start, from A", of: id)
        b.store.setText("Start, from B", of: id)
        try await a.engine.sync()
        let report = try await b.engine.sync()
        try await a.engine.sync()
        XCTAssertEqual(report.conflicts, 1)
        XCTAssertEqual(a.store.text(of: id), "Start, from A", "the version the server took first stays the draft")
        XCTAssertEqual(b.store.text(of: id), "Start, from A")
        let branches = b.store.entities.filter { $0.value.type == .draft && $0.value.fields["parent"] == .string(id) }
        XCTAssertEqual(branches.count, 1)
        XCTAssertEqual(b.store.text(of: branches.first!.key), "Start, from B", "no edit is lost")
        XCTAssertEqual(visible(a.store), visible(b.store), "the branch reaches the other Mac too")
    }

    func testEqualBodyEditsAreNotAConflict() async throws {
        let (_, a, b) = try pair()
        let id = a.store.draft(path: "Essay.md", text: "Start")
        try await a.engine.sync()
        try await b.engine.sync()
        a.store.setText("Same", of: id)
        b.store.setText("Same", of: id)
        try await a.engine.sync()
        let report = try await b.engine.sync()
        XCTAssertEqual(report.conflicts, 0)
        XCTAssertEqual(b.store.pendingCount, 0)
    }

    func testDeleteVersusEditKeepsTheEdit() async throws {
        let (_, a, b) = try pair()
        let id = a.store.draft(path: "Essay.md", text: "Start")
        try await a.engine.sync()
        try await b.engine.sync()
        a.store.remove(id)
        a.store.remove(SyncID.derived("body", id))
        b.store.setText("Edited offline", of: id)
        try await a.engine.sync()
        let report = try await b.engine.sync()
        try await a.engine.sync()
        XCTAssertEqual(report.conflicts, 1)
        XCTAssertNil(b.store.entities[id], "the delete stands")
        let texts = b.store.entities.values.compactMap { entity -> String? in
            guard entity.type == .body, case .string(let text)? = entity.fields["text"] else { return nil }
            return text
        }
        XCTAssertEqual(texts, ["Edited offline"], "the edit survives as a branch")
        XCTAssertEqual(visible(a.store), visible(b.store))
    }

    func testStashConflictKeepsBothTexts() async throws {
        let (_, a, b) = try pair()
        let id = SyncID.derived("stash", "fam")
        a.store.put(id, .stash, ["family": .string("fam"), "text": .string("one")])
        try await a.engine.sync()
        try await b.engine.sync()
        a.store.entities[id]?.fields["text"] = .string("one\ntwo")
        b.store.entities[id]?.fields["text"] = .string("one\nthree")
        try await a.engine.sync()
        try await b.engine.sync()
        try await a.engine.sync()
        XCTAssertEqual(a.store.entities[id]?.fields["text"], .string("one\ntwo\n\none\nthree"))
        XCTAssertEqual(visible(a.store), visible(b.store))
    }

    // MARK: Failures

    func testOfflineEditsQueueAndRetry() async throws {
        let (_, a, b) = try pair()
        a.transport.offline = true
        let id = a.store.draft(path: "Train.md", text: "Written offline")
        do { try await a.engine.sync(); XCTFail("expected an error") } catch {}
        XCTAssertEqual(a.store.pendingCount, 2)
        a.transport.offline = false
        try await a.engine.sync()
        XCTAssertEqual(a.store.pendingCount, 0)
        try await b.engine.sync()
        XCTAssertEqual(b.store.text(of: id), "Written offline")
    }

    func testLostPushResponseIsRetriedIdempotently() async throws {
        let (server, a, b) = try pair()
        let id = a.store.draft(path: "Doc.md", text: "v1")
        a.transport.loseNextPushResponse = true
        do { try await a.engine.sync(); XCTFail("expected an error") } catch {}
        XCTAssertEqual(a.store.pendingCount, 2, "not acknowledged yet")
        let report = try await a.engine.sync()
        XCTAssertEqual(report.conflicts, 0, "the same HLC again is not a conflict")
        XCTAssertEqual(a.store.pendingCount, 0)
        let seq = await server.seq
        XCTAssertEqual(seq, 2, "stored once")
        try await b.engine.sync()
        XCTAssertEqual(b.store.text(of: id), "v1")
    }

    func testClockRejectionsAreSkippedNotLooped() async throws {
        let (server, a, _) = try pair()
        a.store.now = { Date().addingTimeInterval(3600) }
        a.store.draft(path: "Future.md", text: "x")
        let report = try await a.engine.sync()
        XCTAssertEqual(report.clockRejected, 2)
        XCTAssertLessThanOrEqual(report.requests, 3)
        let seq = await server.seq
        XCTAssertEqual(seq, 0)
    }

    // MARK: Encryption

    func testServerSeesOnlyCiphertext() async throws {
        let (server, a, _) = try pair()
        a.store.draft(path: "Secret plans.md", text: "The password is swordfish")
        try await a.engine.sync()
        let rows = await server.rows.values
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            let ct = Data(base64Encoded: row.ct ?? "") ?? Data()
            XCTAssertNil(String(data: ct, encoding: .utf8).flatMap { $0.contains("swordfish") ? $0 : nil })
            XCTAssertFalse(ct.range(of: Data("swordfish".utf8)) != nil)
            XCTAssertFalse(ct.range(of: Data("Secret".utf8)) != nil)
        }
    }

    func testTamperedRowIsRejected() async throws {
        let (server, a, b) = try pair()
        let id = a.store.draft(path: "Doc.md", text: "Original")
        try await a.engine.sync()
        await server.tamper(SyncID.derived("body", id))
        let report = try await b.engine.sync()
        XCTAssertEqual(report.unreadable, 1)
        XCTAssertNil(b.store.text(of: id), "a tampered body never reaches the local data")
        XCTAssertNotNil(b.store.entities[id])
    }

    func testRowsMovedBetweenRecordsAreRejected() async throws {
        let (server, a, b) = try pair()
        let one = a.store.draft(path: "One.md", text: "first")
        let two = a.store.draft(path: "Two.md", text: "second")
        try await a.engine.sync()
        // A malicious server swaps the ciphertext of two records.
        let rows = await server.rows
        var moved = rows[SyncID.derived("body", one)]!
        moved.ct = rows[SyncID.derived("body", two)]!.ct
        await server.insert(moved)
        let report = try await b.engine.sync()
        XCTAssertEqual(report.unreadable, 1)
        XCTAssertNil(b.store.text(of: one))
        XCTAssertEqual(b.store.text(of: two), "second")
    }

    func testWrongKeyOrAccountCannotRead() async throws {
        let server = FakeSyncServer()
        let a = device(server, ring: try makeRing())
        a.store.draft(path: "Doc.md", text: "Private")
        try await a.engine.sync()
        // Same key id, different key bytes.
        let stranger = device(server, ring: try makeRing())
        let report = try await stranger.engine.sync()
        XCTAssertEqual(report.unreadable, 2)
        XCTAssertTrue(stranger.store.entities.isEmpty)
        // Same key, another account id (associated data differs).
        let key = await a.engine.ring
        let other = device(server, ring: try AccountKeyRing(userId: "1c2d3e4f-5a6b-4c7d-8e9f-a0b1c2d3e4f5", current: key.current))
        let otherReport = try await other.engine.sync()
        XCTAssertEqual(otherReport.unreadable, 2)
    }

    func testUnknownKeyEpochAsksForKeys() async throws {
        let server = FakeSyncServer()
        let newer = try AccountKey.generate(id: 2)
        let a = device(server, ring: try makeRing(newer))
        a.store.draft(path: "Doc.md", text: "x")
        try await a.engine.sync()
        let old = device(server, ring: try makeRing(try AccountKey.generate(id: 1)))
        do { try await old.engine.sync(); XCTFail("expected unknownKey") }
        catch SyncEngineError.unknownKey(let id) { XCTAssertEqual(id, 2) }
        await old.engine.updateRing(try makeRing(newer))
        try await old.engine.sync()
        XCTAssertEqual(old.store.entities.count, 2)
    }

    // MARK: Server state

    func testEpochChangeRequeuesWhatTheServerLost() async throws {
        let (server, a, b) = try pair()
        let first = a.store.draft(path: "First.md", text: "1")
        try await a.engine.sync()
        let keep = await server.seq
        let second = a.store.draft(path: "Second.md", text: "2")
        try await a.engine.sync()
        await server.restore(keepingThrough: keep)
        try await a.engine.sync()
        try await b.engine.sync()
        XCTAssertEqual(b.store.text(of: first), "1")
        XCTAssertEqual(b.store.text(of: second), "2", "re-uploaded after the restore")
    }

    func testAccountSwitchUploadsEverythingAgain() async throws {
        let serverOne = FakeSyncServer()
        let store = MemorySyncStore()
        let one = device(serverOne, ring: try makeRing(), store: store)
        store.draft(path: "Doc.md", text: "x")
        try await one.engine.sync()
        XCTAssertEqual(store.pendingCount, 0)
        let serverTwo = FakeSyncServer()
        let two = device(serverTwo, ring: try makeRing(user: "2d3e4f5a-6b7c-4d8e-9fa0-b1c2d3e4f5a6"), store: store)
        let report = try await two.engine.sync()
        XCTAssertEqual(report.pushed, 2)
        let cursor = try store.cursor()
        XCTAssertEqual(cursor.userId, "2d3e4f5a-6b7c-4d8e-9fa0-b1c2d3e4f5a6")
    }

    func testFirstSyncOfTwoExistingWorkspacesMerges() async throws {
        let (_, a, b) = try pair()
        // The same draft (same UUID, e.g. copied workspace) with different text, plus one unique draft each.
        let shared = UUID().uuidString.lowercased()
        a.store.draft(shared, path: "Shared.md", text: "Mac A text")
        b.store.draft(shared, path: "Shared.md", text: "Mac B text")
        a.store.draft(path: "OnlyA.md", text: "a")
        b.store.draft(path: "OnlyB.md", text: "b")
        try await a.engine.sync()
        let report = try await b.engine.sync()
        try await a.engine.sync()
        XCTAssertEqual(report.conflicts, 1)
        XCTAssertEqual(visible(a.store), visible(b.store))
        XCTAssertEqual(a.store.entities.values.filter { $0.type == .draft }.count, 4)
    }

    // MARK: Blobs

    func testAssetsTravelAsEncryptedBlobs() async throws {
        let (server, a, b) = try pair()
        let id = SyncID.derived("asset", "Letters/.assets/photo.png")
        let image = Data((0..<50_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        a.store.put(id, .asset, ["path": .string("Letters/.assets/photo.png"), "size": .number(Double(image.count))])
        a.store.assets[id] = image
        let report = try await a.engine.sync()
        XCTAssertEqual(report.blobsUploaded, 1)
        let blobs = await server.blobs
        XCTAssertEqual(blobs.count, 1)
        XCTAssertNil(blobs.values.first!.range(of: image.prefix(64)), "blobs are encrypted")
        let row = await server.rows[id]
        XCTAssertEqual(row?.blobId, blobs.keys.first)
        try await b.engine.sync()
        XCTAssertEqual(b.store.assets[id], image)
        XCTAssertEqual(b.store.entities[id], a.store.entities[id], "transport fields are stripped")
    }

    func testMissingBlobIsUploadedAgain() async throws {
        let (server, a, b) = try pair()
        let id = SyncID.derived("asset", "x/.assets/a.png")
        a.store.put(id, .asset, ["path": .string("x/.assets/a.png"), "size": .number(3)])
        a.store.assets[id] = Data([1, 2, 3])
        a.transport.dropBlobsBeforeNextPush = true
        let report = try await a.engine.sync()
        XCTAssertEqual(report.blobsUploaded, 2, "uploaded again after blob_missing")
        XCTAssertEqual(a.store.pendingCount, 0)
        let blobs = await server.blobs
        XCTAssertEqual(blobs.count, 1)
        try await b.engine.sync()
        XCTAssertEqual(b.store.assets[id], Data([1, 2, 3]))
    }

    func testOversizeBodyTravelsAsBlobReference() async throws {
        let (server, a, b) = try pair()
        var generator = SystemRandomNumberGenerator()
        // Random text doesn't compress, so it stays over the record limit.
        let big = String((0..<3_500_000).map { _ in Character(UnicodeScalar(UInt8.random(in: 97...122, using: &generator))) })
        let id = a.store.draft(path: "Big.md", text: big)
        try await a.engine.sync()
        let row = await server.rows[SyncID.derived("body", id)]
        XCTAssertNotNil(row?.blobId)
        XCTAssertLessThan(row?.size ?? .max, 4096)
        try await b.engine.sync()
        XCTAssertEqual(b.store.text(of: id), big)
    }

    func testCompressionShrinksText() throws {
        try XCTSkipUnless(SyncCompression.isAvailable, "DEFLATE needs the Compression framework (macOS)")
        let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 200)
        let record = SyncRecord(id: UUID().uuidString.lowercased(), type: .body, hlc: HLC(milliseconds: 1, counter: 0, device: UUID().uuidString.lowercased()),
                                deleted: false, fields: ["text": .string(text)], fieldHLCs: [:])
        let plain = try record.plaintext()!
        let framed = SyncCodec.frame(plain)
        XCTAssertEqual(framed.first, SyncFrame.deflate)
        XCTAssertLessThan(framed.count, plain.count / 5)
        XCTAssertEqual(try SyncCodec.unframe(framed), plain)
    }

    func testFramesReadBothWays() throws {
        let small = Data("{\"v\":1}".utf8)
        XCTAssertEqual(SyncCodec.frame(small), small, "small plaintext stays as is")
        XCTAssertEqual(try SyncCodec.unframe(small), small)
        XCTAssertThrowsError(try SyncCodec.unframe(Data([0x07, 1, 2])))
        let reference = SyncBlobReference(blob: UUID().uuidString.lowercased(), key: .generate(), size: 10)
        XCTAssertEqual(try SyncCodec.reference(in: try SyncCodec.referenceFrame(reference)), reference)
        XCTAssertNil(try SyncCodec.reference(in: small))
    }

    // MARK: Performance

    func testLargeWorkspaceSyncsInFewRequestsOffTheMainThread() async throws {
        let (_, a, b) = try pair()
        let count = 1_000
        for index in 0..<count { a.store.draft(path: "Draft \(index).md", text: String(repeating: "Some words here. ", count: 40)) }
        let start = Date()
        let pushed = try await a.engine.sync()
        let pushTime = Date().timeIntervalSince(start)
        XCTAssertEqual(pushed.pushed, 2 * count)
        XCTAssertLessThanOrEqual(pushed.requests, 1 + (2 * count + 199) / 200, "one pull plus full batches")
        let pullStart = Date()
        let pulled = try await b.engine.sync()
        let pullTime = Date().timeIntervalSince(pullStart)
        XCTAssertEqual(pulled.applied, 2 * count)
        XCTAssertEqual(pulled.requests, (2 * count + 499) / 500)
        XCTAssertEqual(a.store.mainThreadCalls + b.store.mainThreadCalls, 0)
        XCTAssertEqual(a.transport.mainThreadCalls + b.transport.mainThreadCalls, 0)
        print("SYNC-07 perf: push \(2 * count) records in \(String(format: "%.2f", pushTime)) s (\(pushed.requests) requests), pull+apply in \(String(format: "%.2f", pullTime)) s (\(pulled.requests) requests)")
        XCTAssertLessThan(pushTime, 30)
        XCTAssertLessThan(pullTime, 30)
    }
}
