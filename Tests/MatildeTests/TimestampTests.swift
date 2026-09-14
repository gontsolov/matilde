import XCTest
@testable import Matilde

final class TimestampTests: XCTestCase {
    func testRelativeDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 12))!
        XCTAssertEqual(DraftDateFormat.relative(now, now: now, calendar: calendar), "Just now")
        XCTAssertEqual(DraftDateFormat.relative(now.addingTimeInterval(100), now: now, calendar: calendar), "Just now")
        XCTAssertEqual(DraftDateFormat.relative(now.addingTimeInterval(-300), now: now, calendar: calendar), "5m ago")
        XCTAssertEqual(DraftDateFormat.relative(now.addingTimeInterval(-7200), now: now, calendar: calendar), "2h ago")
        XCTAssertEqual(DraftDateFormat.relative(now.addingTimeInterval(-86400), now: now, calendar: calendar), "Yesterday")
    }

    func testImportedDatesSurviveEditingAndNavigation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("matilde-dates-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Example.md")
        try "Original".write(to: file, atomically: true, encoding: .utf8)
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        let workspace = try Workspace(root: root)
        let draft = try XCTUnwrap(workspace.scan().drafts.first)
        XCTAssertEqual(try XCTUnwrap(draft.editedAt).timeIntervalSince1970, old.timeIntervalSince1970, accuracy: 1)
        try workspace.position(draft, cursor: 3, scroll: 20)
        try workspace.save(draft, text: "Original")
        try workspace.goal(draft, text: "")
        XCTAssertEqual(try workspace.allDrafts().first?.editedAt, draft.editedAt)
        let child = try workspace.branch(draft, text: "Original")
        XCTAssertGreaterThan(try XCTUnwrap(child.editedAt), old)
        XCTAssertEqual(try workspace.allDrafts().first { $0.id == draft.id }?.editedAt, draft.editedAt)
        try workspace.save(draft, text: "Changed")
        var updated = try XCTUnwrap(workspace.allDrafts().first { $0.id == draft.id })
        XCTAssertEqual(updated.createdAt, draft.createdAt)
        XCTAssertGreaterThan(try XCTUnwrap(updated.editedAt), old)
        try workspace.rename(updated, name: "Renamed")
        updated = try XCTUnwrap(workspace.allDrafts().first { $0.id == draft.id })
        try workspace.goal(updated, text: "New goal")
        let reopened = try Workspace(root: root)
        XCTAssertEqual(try reopened.allDrafts().first { $0.id == draft.id }?.createdAt, draft.createdAt)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: try reopened.url(for: updated.path).path)
        XCTAssertGreaterThan(try XCTUnwrap(reopened.allDrafts().first { $0.id == draft.id }?.editedAt), try XCTUnwrap(updated.editedAt))
    }
}
