import XCTest
@testable import Matilde

@MainActor
final class UserCommentTests: XCTestCase {
    private let body = "Morning 🌱 light. The harbor was quiet and the boats waited. Evening came slowly."

    private func makeWorkspace() throws -> Workspace {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MatildeCommentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try Workspace(root: url)
    }
    private func range(of text: String, in body: String) -> NSRange { (body as NSString).range(of: text) }
    private func quote(_ comment: UserComment, in body: String) -> String { (body as NSString).substring(with: comment.range) }
    private func comment(_ text: String, in body: String) -> UserComment {
        CommentAnchor.refreshed(UserComment(id: UUID(), draftID: "d", text: "Note", location: 0, length: 0, quote: "", prefix: "", suffix: "",
                                            created: Date(), modified: Date()), range: range(of: text, in: body), in: body)
    }
    private func edit(_ comment: UserComment, _ old: String, _ new: String) -> UserComment {
        CommentAnchor.track(comment, edit: WritingEdit.between(old, new), in: new)
    }

    func testPersistsCommentsInWorkspaceDatabaseWithoutTouchingMarkdown() throws {
        let workspace = try makeWorkspace()
        let store = UserCommentStore()
        store.bind(workspace: workspace, draftID: "draft-1", body: body)
        let created = try XCTUnwrap(store.add(range: range(of: "harbor was quiet", in: body)))
        XCTAssertTrue(try workspace.userComments(draftID: "draft-1").isEmpty, "Empty new comments are not saved")
        store.update(created.id, text: "Describe the sound instead?")

        let reopened = UserCommentStore()
        reopened.bind(workspace: try Workspace(root: workspace.root), draftID: "draft-1", body: body)
        let saved = try XCTUnwrap(reopened.comments.first)
        XCTAssertEqual(reopened.comments.count, 1)
        XCTAssertEqual(saved.text, "Describe the sound instead?")
        XCTAssertEqual(quote(saved, in: body), "harbor was quiet")
        XCTAssertEqual(saved.range, range(of: "harbor was quiet", in: body))
        XCTAssertTrue(try workspace.userComments(draftID: "other").isEmpty)

        reopened.update(saved.id, text: "Edited")
        XCTAssertEqual(try workspace.userComments(draftID: "draft-1").first?.text, "Edited")
        reopened.remove(saved.id)
        XCTAssertTrue(reopened.comments.isEmpty)
        XCTAssertTrue(try workspace.userComments(draftID: "draft-1").isEmpty)
    }

    func testAbandonedEmptyCommentIsDiscarded() throws {
        let workspace = try makeWorkspace()
        let store = UserCommentStore()
        store.bind(workspace: workspace, draftID: "draft-1", body: body)
        let created = try XCTUnwrap(store.add(range: range(of: "boats", in: body)))
        store.finishEditing(created.id)
        XCTAssertTrue(store.comments.isEmpty)
        XCTAssertTrue(try workspace.userComments(draftID: "draft-1").isEmpty)
    }

    func testTracksUTF16RangesThroughEditsBeforeInsideAndAfter() {
        let original = comment("harbor was quiet", in: body)
        XCTAssertEqual(original.location, (body as NSString).range(of: "harbor").location)

        let before = body.replacingOccurrences(of: "Morning", with: "Early 🌊 morning")
        let moved = edit(original, body, before)
        XCTAssertEqual(quote(moved, in: before), "harbor was quiet")
        XCTAssertEqual(moved.location, original.location + ("Early 🌊 morning" as NSString).length - ("Morning" as NSString).length)

        let after = body.replacingOccurrences(of: "slowly", with: "late")
        XCTAssertEqual(edit(original, body, after).range, original.range)

        let inside = body.replacingOccurrences(of: "was quiet", with: "was very quiet")
        let grown = edit(original, body, inside)
        XCTAssertEqual(quote(grown, in: inside), "harbor was very quiet")
        XCTAssertEqual(grown.quote, "harbor was very quiet")

        let typedAtEnd = body.replacingOccurrences(of: "quiet and", with: "quiet, and")
        XCTAssertEqual(quote(edit(original, body, typedAtEnd), in: typedAtEnd), "harbor was quiet")

        let trimmed = body.replacingOccurrences(of: "The harbor", with: "A port")
        XCTAssertEqual(quote(edit(original, body, trimmed), in: trimmed), " was quiet")
    }

    func testDeletingPassageDetachesAndUndoReattaches() {
        let original = comment("harbor was quiet", in: body)
        let deleted = body.replacingOccurrences(of: "The harbor was quiet and the", with: "The")
        let detached = edit(original, body, deleted)
        XCTAssertFalse(detached.attached)
        XCTAssertEqual(detached.quote, "harbor was quiet")
        let restored = edit(detached, deleted, body)
        XCTAssertTrue(restored.attached)
        XCTAssertEqual(restored.range, original.range)
    }

    func testRelocatesAfterExternalChangesUsingQuoteAndContext() {
        let original = comment("quiet", in: body)
        // Repeated quote: context chooses the right occurrence.
        let repeated = "Quiet start, quiet end. " + body
        XCTAssertEqual(CommentAnchor.relocate(original, in: repeated),
                       NSRange(location: original.location + ("Quiet start, quiet end. " as NSString).length, length: 5))
        // The passage itself changed while its surroundings did not.
        let long = comment("was quiet", in: body)
        let rewritten = body.replacingOccurrences(of: "was quiet", with: "lay still")
        let located = CommentAnchor.relocate(long, in: rewritten)
        XCTAssertEqual(located.map { (rewritten as NSString).substring(with: $0) }, "lay still")
        XCTAssertNil(CommentAnchor.relocate(original, in: "Nothing here matches."))
    }

    func testStoreReanchorsOnReopenAfterTextChangedElsewhere() throws {
        let workspace = try makeWorkspace()
        let store = UserCommentStore()
        store.bind(workspace: workspace, draftID: "draft-1", body: body)
        let created = try XCTUnwrap(store.add(range: range(of: "boats waited", in: body)))
        store.update(created.id, text: "Which boats?")
        let external = "A new opening line.\n\n" + body
        let reopened = UserCommentStore()
        reopened.bind(workspace: workspace, draftID: "draft-1", body: external)
        XCTAssertEqual(reopened.comments.first.map { quote($0, in: external) }, "boats waited")
        reopened.changed(workspace: workspace, draftID: "draft-1", body: "Gone.")
        XCTAssertEqual(reopened.comments.first?.attached, false)
        XCTAssertEqual(reopened.comments.first?.text, "Which boats?")
        XCTAssertEqual(reopened.comment(containing: 0)?.id, nil)
    }
}
