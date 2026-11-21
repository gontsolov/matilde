import XCTest
@testable import MatildeKit
import MatildeKit

/// SYNC-02: change tracking, tombstones, the outbox and the migration of existing data.
final class SyncLedgerTests: XCTestCase {
    private var root: URL!
    private let device = "6f1c2d3e-4a5b-4c6d-8e7f-0a1b2c3d4e5f"
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("matilde-sync-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { [root] in try? FileManager.default.removeItem(at: root!) }
    }

    private func open() throws -> Workspace {
        let workspace = try Workspace(root: root)
        workspace.syncDeviceID = device
        return workspace
    }

    private func entries(_ workspace: Workspace) throws -> [String: SyncLedgerEntry] {
        Dictionary(uniqueKeysWithValues: try workspace.syncLedgerEntries().map { ($0.id, $0) })
    }

    private func id(_ value: String) -> String { value.lowercased() }

    private let t0 = Date(timeIntervalSince1970: 1_763_500_000)

    /// A workspace with one of everything, made the way the app makes it.
    private func populate(_ workspace: Workspace) throws -> (letter: Draft, branch: Draft, comment: UserComment, review: WritingReview) {
        try workspace.createFolder(name: "Letters", parent: "")
        try workspace.createFolder(name: "Empty", parent: "")
        let letter = try workspace.create(name: "Letter", folder: "Letters", goal: "Say thanks", text: "Hello world")
        let branch = try workspace.branch(letter, text: "Hello world")
        let comment = UserComment(id: UUID(), draftID: letter.id, text: "Warmer opening?", location: 0, length: 5, quote: "Hello",
                                  prefix: "", suffix: " world", created: t0, modified: t0)
        try workspace.saveUserComments([comment])
        var thread = ReviewComment(id: UUID(), suggestion: ReviewSuggestion(quote: "world", prefix: "Hello ", suffix: "",
                                                                             explanation: "Be specific.", replacement: "friend"),
                                   location: 6, length: 5)
        thread.unread = true
        thread.messages = [ReviewMessage(role: "user", text: "Why?"), ReviewMessage(role: "assistant", text: "It is vague.")]
        let review = WritingReview(id: UUID(), draftID: letter.id, created: t0, model: "test-model", revision: "r1", stale: false,
                                   comments: [thread], source: ReviewInput(title: "Letter", goal: "Say thanks", body: "Hello world"))
        try workspace.saveReview(review)
        try workspace.saveStash(letter.family, text: "Loose ideas", expected: "")
        let assets = try workspace.url(for: "Letters/.assets")
        try fm.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: assets.appendingPathComponent("\(UUID().uuidString).png"))
        _ = try workspace.scan()
        return (letter, branch, comment, review)
    }

    func testFirstRunGivesExistingDataRecordsAndIsIdempotent() throws {
        let workspace = try open()
        let made = try populate(workspace)
        let result = try workspace.trackSyncChanges(now: t0)
        let all = try entries(workspace)
        XCTAssertEqual(result, SyncTrackResult(updated: all.count, tombstoned: 0))
        let byType = Dictionary(grouping: all.values, by: \.type).mapValues(\.count)
        XCTAssertEqual(byType, [.draft: 2, .body: 2, .snapshot: 1, .stash: 1, .asset: 1, .comment: 1,
                                .thread: 1, .message: 2, .readMarker: 1, .folder: 2])
        XCTAssertTrue(all.values.allSatisfy { $0.pending && !$0.deleted && $0.hlc.device == device })
        XCTAssertNotNil(all[id(made.letter.id)])
        XCTAssertNotNil(all[SyncID.derived("body", id(made.letter.id))])
        XCTAssertNotNil(all[SyncID.derived("stash", id(made.letter.family))])
        XCTAssertNotNil(all[id(made.comment.id.uuidString)])
        XCTAssertNotNil(all[id(made.review.comments[0].id.uuidString)])
        XCTAssertNotNil(all[SyncID.derived("folder", "Empty")])
        XCTAssertEqual(Set(all.values.map(\.hlc)).count, all.count, "every version has its own HLC")

        XCTAssertEqual(try workspace.trackSyncChanges(now: t0.addingTimeInterval(60)), SyncTrackResult())
        XCTAssertEqual(try entries(workspace), all)
        let reopened = try open()
        XCTAssertEqual(try reopened.trackSyncChanges(), SyncTrackResult())
    }

    func testTrackingNeverTouchesMarkdownOrTheAppTables() throws {
        let workspace = try open()
        let made = try populate(workspace)
        let file = try workspace.url(for: made.letter.path)
        let before = try Data(contentsOf: file)
        let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let tables = ["drafts", "user_comments", "writing_reviews", "snapshots", "state"]
        func dump() throws -> [[[String: String]]] { try tables.map { try workspace.db.execute("SELECT * FROM \($0) ORDER BY rowid") } }
        let rows = try dump()
        try workspace.trackSyncChanges()
        _ = try workspace.pendingSyncRecords()
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified)
        XCTAssertEqual(try dump(), rows)
        XCTAssertFalse(String(decoding: before, as: UTF8.self).contains("Warmer opening?"), "review data stays out of Markdown")
    }

    func testOnlyChangedRecordsAndFieldsGetNewVersions() throws {
        let workspace = try open()
        let made = try populate(workspace)
        try workspace.trackSyncChanges(now: t0)
        let before = try entries(workspace)
        let draftID = id(made.letter.id), bodyID = SyncID.derived("body", draftID)

        try workspace.goal(made.letter, text: "Say thanks warmly")
        try workspace.save(made.letter, text: "Hello dear world")
        try workspace.position(made.letter, cursor: 4, scroll: 120)   // device-local: no new version
        XCTAssertEqual(try workspace.trackSyncChanges(now: t0.addingTimeInterval(1)), SyncTrackResult(updated: 2, tombstoned: 0))
        let after = try entries(workspace)
        for (key, entry) in before where key != draftID && key != bodyID { XCTAssertEqual(after[key], entry) }

        let draft = try XCTUnwrap(after[draftID]), old = try XCTUnwrap(before[draftID])
        XCTAssertGreaterThan(draft.hlc, old.hlc)
        XCTAssertEqual(draft.fields["goal"]?.t, draft.hlc.description)
        XCTAssertEqual(draft.fields["path"], old.fields["path"], "unchanged fields keep their clock")
        XCTAssertNil(draft.fields["cursor"])
        XCTAssertNil(draft.fields["scroll"])
        let body = try XCTUnwrap(try workspace.syncRecord(id: bodyID))
        XCTAssertEqual(try body.payload(BodyPayload.self).text, "Hello dear world")
        XCTAssertEqual(try body.payload(BodyPayload.self).draft, draftID)
    }

    func testDeletionsBecomeTombstonesAndReturnsResurrect() throws {
        let workspace = try open()
        let made = try populate(workspace)
        try workspace.trackSyncChanges(now: t0)
        let commentID = id(made.comment.id.uuidString)

        try workspace.deleteUserComment(made.comment.id)
        XCTAssertEqual(try workspace.trackSyncChanges(now: t0.addingTimeInterval(1)), SyncTrackResult(updated: 0, tombstoned: 1))
        let tombstone = try XCTUnwrap(try workspace.syncRecord(id: commentID))
        XCTAssertTrue(tombstone.deleted)
        XCTAssertTrue(tombstone.fields.isEmpty)
        XCTAssertNil(try tombstone.plaintext())
        XCTAssertEqual(try workspace.trackSyncChanges(), SyncTrackResult(), "a tombstone is issued once")

        try workspace.saveUserComments([made.comment])   // undo re-inserts the same comment
        XCTAssertEqual(try workspace.trackSyncChanges(now: t0.addingTimeInterval(2)), SyncTrackResult(updated: 1, tombstoned: 0))
        let back = try XCTUnwrap(try workspace.syncRecord(id: commentID))
        XCTAssertFalse(back.deleted)
        XCTAssertGreaterThan(back.hlc, tombstone.hlc)
        XCTAssertEqual(try back.payload(CommentPayload.self).body, "Warmer opening?")

        try workspace.archiveUserComment(made.comment.id)
        try workspace.trackSyncChanges()
        XCTAssertEqual(try workspace.syncRecord(id: commentID)?.payload(CommentPayload.self).archived, true, "archived stays a record")
    }

    func testTrashingADraftTombstonesItAndRecordsTheArchive() throws {
        let workspace = try open()
        let made = try populate(workspace)
        try workspace.trackSyncChanges(now: t0)
        try workspace.trash(made.branch) { try FileManager.default.moveItem(at: $0, to: self.root.appendingPathComponent("trashed.txt")) }
        let result = try workspace.trackSyncChanges(now: t0.addingTimeInterval(1))
        XCTAssertEqual(result.tombstoned, 2)
        let all = try entries(workspace)
        let branchID = id(made.branch.id)
        XCTAssertEqual(all[branchID]?.deleted, true)
        XCTAssertEqual(all[SyncID.derived("body", branchID)]?.deleted, true)
        let trashed = try XCTUnwrap(try workspace.syncRecord(id: SyncID.derived("trashed", branchID)))
        let payload = try trashed.payload(TrashedPayload.self)
        XCTAssertEqual(payload.draft, branchID)
        XCTAssertEqual(payload.parent, id(made.letter.id))
        XCTAssertEqual(payload.goal, "Say thanks")
        XCTAssertNotNil(payload.trashedAt)
    }

    func testAMissingOrEvictedFileIsNeverTombstoned() throws {
        let workspace = try open()
        let made = try populate(workspace)
        try workspace.trackSyncChanges(now: t0)
        let file = try workspace.url(for: made.letter.path)
        let assets = try workspace.url(for: "Letters/.assets")
        let image = try XCTUnwrap(fm.contentsOfDirectory(atPath: assets.path).first)
        // iCloud Drive evicts files to `.name.icloud` placeholders.
        try fm.moveItem(at: file, to: file.deletingLastPathComponent().appendingPathComponent(".Letter.md.icloud"))
        try fm.moveItem(at: assets.appendingPathComponent(image), to: assets.appendingPathComponent(".\(image).icloud"))
        XCTAssertEqual(try workspace.trackSyncChanges(now: t0.addingTimeInterval(1)), SyncTrackResult())
        XCTAssertEqual(try entries(workspace)[SyncID.derived("body", id(made.letter.id))]?.deleted, false)
        XCTAssertEqual(try entries(workspace)[SyncID.derived("asset", "Letters/.assets/\(image)")]?.deleted, false)
    }

    func testOutboxDrainsOnAcknowledgementAndCarriesTheServerBase() throws {
        let workspace = try open()
        let made = try populate(workspace)
        let pending = try workspace.pendingSyncRecords()
        XCTAssertEqual(pending.count, try workspace.syncLedgerEntries().count)
        XCTAssertEqual(pending.map(\.hlc), pending.map(\.hlc).sorted(), "oldest first")
        XCTAssertTrue(pending.allSatisfy { $0.baseHlc == nil && $0.deviceID == device })
        XCTAssertTrue(try pending.allSatisfy { try $0.plaintext() != nil })
        XCTAssertEqual(try workspace.pendingSyncRecords(limit: 3).count, 3)

        try workspace.markSyncAccepted(pending.map { ($0.id, $0.hlc) })
        XCTAssertEqual(try workspace.pendingSyncRecords(), [])

        let bodyID = SyncID.derived("body", id(made.letter.id))
        let acknowledged = try XCTUnwrap(pending.first { $0.id == bodyID }?.hlc)
        try workspace.save(made.letter, text: "Hello again")
        let next = try workspace.pendingSyncRecords()
        XCTAssertEqual(next.map(\.id), [bodyID])
        XCTAssertEqual(next.first?.baseHlc, acknowledged)
        XCTAssertEqual(next.first?.envelope.baseHlc, acknowledged.description)
        XCTAssertEqual(next.first?.envelope.type, SyncRecordType.body.rawValue)

        // An acknowledgement of an older version leaves the newer one pending.
        try workspace.markSyncAccepted([(bodyID, acknowledged)])
        XCTAssertEqual(try workspace.pendingSyncRecords().map(\.id), [bodyID])
    }

    func testReviewsAreNormalisedIntoThreadsMessagesAndReadMarkers() throws {
        let workspace = try open()
        let made = try populate(workspace)
        try workspace.trackSyncChanges(now: t0)
        let comment = made.review.comments[0]
        let threadID = id(comment.id.uuidString)
        let thread = try XCTUnwrap(try workspace.syncRecord(id: threadID)).payload(ThreadPayload.self)
        XCTAssertEqual(thread.review, id(made.review.id.uuidString))
        XCTAssertEqual(thread.draft, id(made.letter.id))
        XCTAssertEqual(thread.quote, "world")
        XCTAssertEqual(thread.replacement, "friend")
        XCTAssertEqual(thread.status, "open")
        let messages = try comment.messages!.map { try XCTUnwrap(try workspace.syncRecord(id: id($0.id.uuidString))).payload(MessagePayload.self) }
        XCTAssertEqual(messages.map(\.index), [0, 1])
        XCTAssertEqual(messages.map(\.role), ["user", "assistant"])
        XCTAssertTrue(messages.allSatisfy { $0.thread == threadID })
        let markerID = SyncID.derived("read", threadID)
        XCTAssertEqual(try workspace.syncRecord(id: markerID)?.payload(ReadMarkerPayload.self).unread, true)

        // Reading the thread changes only its read marker.
        var read = made.review
        read.comments[0].unread = nil
        try workspace.saveReview(read)
        let before = try entries(workspace)
        XCTAssertEqual(try workspace.trackSyncChanges(now: t0.addingTimeInterval(1)), SyncTrackResult(updated: 1, tombstoned: 0))
        XCTAssertEqual(try workspace.syncRecord(id: markerID)?.payload(ReadMarkerPayload.self).unread, false)
        XCTAssertEqual(try entries(workspace)[threadID], before[threadID])
    }

    func testClockStaysAheadOfTheLedgerAndObservedServerClocks() throws {
        let workspace = try open()
        let made = try populate(workspace)
        try workspace.trackSyncChanges(now: t0)
        let newest = try XCTUnwrap(try workspace.syncLedgerEntries().map(\.hlc).max())
        try workspace.save(made.letter, text: "Earlier wall clock")
        try workspace.trackSyncChanges(now: t0.addingTimeInterval(-3600))
        let body = try XCTUnwrap(try entries(workspace)[SyncID.derived("body", id(made.letter.id))])
        XCTAssertGreaterThan(body.hlc, newest)

        let remote = HLC(milliseconds: body.hlc.milliseconds + 60_000, counter: 3, device: "00000000-0000-4000-8000-000000000001")
        try workspace.observeSyncClock(remote)
        try workspace.goal(made.letter, text: "After the server")
        try workspace.trackSyncChanges(now: t0)
        let draft = try XCTUnwrap(try entries(workspace)[id(made.letter.id)])
        XCTAssertGreaterThan(draft.hlc, remote)
        XCTAssertEqual(draft.hlc.device, device)
    }

    func testRecordsOfASecondMacMigratingTheSameDataShareIds() throws {
        let workspace = try open()
        let made = try populate(workspace)
        try workspace.trackSyncChanges(now: t0)
        let ids = Set(try workspace.syncLedgerEntries().map(\.id))
        // Derived ids depend only on the data, not on the device or the time.
        let expected: Set<String> = [SyncID.derived("body", id(made.letter.id)), SyncID.derived("stash", id(made.letter.family)),
                                     SyncID.derived("read", id(made.review.comments[0].id.uuidString)), SyncID.derived("folder", "Letters")]
        XCTAssertTrue(expected.isSubset(of: ids))
        XCTAssertTrue(ids.allSatisfy(SyncID.isCanonical))
    }

    func testDeviceIdIsCreatedOnceAndLowercase() throws {
        let suite = "matilde-sync-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let first = SyncDevice.current(defaults)
        XCTAssertTrue(SyncID.isCanonical(first))
        XCTAssertEqual(SyncDevice.current(defaults), first)
        defaults.set("NOT-A-UUID", forKey: SyncDevice.defaultsKey)
        XCTAssertNotEqual(SyncDevice.current(defaults), "NOT-A-UUID")
    }
}
