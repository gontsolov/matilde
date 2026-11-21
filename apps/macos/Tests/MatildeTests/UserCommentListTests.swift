import XCTest
@testable import Matilde

/// EDIT-22: the writer's own comments in the comment margin next to Ask Matilde threads, and
/// comments carried onto new branches.
@MainActor
final class UserCommentListTests: XCTestCase {
    private let body = "Morning 🌱 light. The harbor was quiet and the boats waited. Evening came slowly."

    private func makeWorkspace() throws -> Workspace {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MatildeCommentListTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try Workspace(root: url)
    }
    private func range(of text: String, in body: String) -> NSRange { (body as NSString).range(of: text) }
    private func note(_ quote: String, text: String = "Note") -> UserComment {
        CommentAnchor.refreshed(UserComment(id: UUID(), draftID: "d", text: text, location: 0, length: 0, quote: "", prefix: "", suffix: "",
                                            created: Date(), modified: Date()), range: range(of: quote, in: body), in: body)
    }
    private func ids(_ items: [MarginItem]) -> [UUID] { items.map(\.id) }
    private func archived(_ id: UUID, in workspace: Workspace) throws -> String? {
        try workspace.db.execute("SELECT archived FROM user_comments WHERE id = ?", [id.uuidString]).first?["archived"]
    }
    /// Adds a comment through the store, as ⇧⌘K and the margin composer do.
    private func addComment(_ store: UserCommentStore, on quote: String, text: String, in body: String) throws -> UserComment {
        let created = try XCTUnwrap(store.add(range: range(of: quote, in: body)))
        store.update(created.id, text: text)
        return try XCTUnwrap(store.comments.first { $0.id == created.id })
    }

    // MARK: Listing

    func testMarginListsOwnCommentsWithThreadsInPassageOrder() throws {
        let input = ReviewInput(title: "Harbor", goal: "", body: body)
        let run = try WritingReview.make(draftID: "d", input: input, model: "test", suggestions: [
            ReviewSuggestion(quote: "boats waited", prefix: "and the ", suffix: ". Evening", explanation: "Waited for what?", replacement: nil),
            ReviewSuggestion(quote: "Morning", prefix: "", suffix: " 🌱", explanation: "Time of day?", replacement: nil),
        ])
        let quiet = note("harbor was quiet"), evening = note("Evening came")
        let items = MarginItem.items(run: run, notes: [evening, quiet], editing: nil)
        XCTAssertEqual(ids(items), [run.comments[1].id, quiet.id, run.comments[0].id, evening.id])
        XCTAssertEqual(items.map(\.isReview), [true, false, true, false])
        XCTAssertEqual(items.map(\.range), [range(of: "Morning", in: body), quiet.range, range(of: "boats waited", in: body), evening.range])

        var stale = run; stale.stale = true
        XCTAssertEqual(ids(MarginItem.items(run: stale, notes: [quiet], editing: nil)), [quiet.id], "Comments stay when the review goes stale")
        var dismissed = run; dismissed.comments[0].status = "dismissed"
        XCTAssertEqual(ids(MarginItem.items(run: dismissed, notes: [], editing: nil)), [run.comments[1].id])
    }

    func testMarginHidesDetachedAndUnwrittenComments() {
        var detached = note("harbor was quiet"); detached.length = 0
        let empty = note("boats", text: " \n")
        XCTAssertTrue(MarginItem.items(run: nil, notes: [detached, empty], editing: nil).isEmpty)
        XCTAssertEqual(ids(MarginItem.items(run: nil, notes: [detached, empty], editing: empty.id)), [empty.id],
                       "A new comment shows while it is being written")
        XCTAssertTrue(MarginItem.items(run: nil, notes: [detached], editing: detached.id).isEmpty)
    }

    func testListFollowsStoreThroughEditsDetachUndoArchiveAndDelete() throws {
        let workspace = try makeWorkspace()
        let store = UserCommentStore()
        store.bind(workspace: workspace, draftID: "draft-1", body: body)
        let quiet = try addComment(store, on: "harbor was quiet", text: "Sound?", in: body)
        let boats = try addComment(store, on: "boats waited", text: "Which boats?", in: body)
        XCTAssertEqual(ids(MarginItem.items(run: nil, notes: store.comments, editing: nil)), [quiet.id, boats.id])

        store.update(quiet.id, text: "Describe the sound")
        XCTAssertEqual(try workspace.userComments(draftID: "draft-1").first { $0.id == quiet.id }?.text, "Describe the sound")

        // Removing the whole passage hides the comment; bringing it back (undo) shows it again.
        let deleted = body.replacingOccurrences(of: "The harbor was quiet and the", with: "The")
        store.changed(workspace: workspace, draftID: "draft-1", body: deleted)
        XCTAssertEqual(ids(MarginItem.items(run: nil, notes: store.comments, editing: nil)), [boats.id])
        XCTAssertEqual(try workspace.userComments(draftID: "draft-1").first { $0.id == quiet.id }?.attached, false,
                       "Hidden comments stay in the database")
        store.changed(workspace: workspace, draftID: "draft-1", body: body)
        let restored = MarginItem.items(run: nil, notes: store.comments, editing: nil)
        XCTAssertEqual(ids(restored), [quiet.id, boats.id])
        XCTAssertEqual(restored.first?.range, range(of: "harbor was quiet", in: body))

        // Archive keeps the row but leaves the margin; clearing the note deletes it for good.
        store.archive(quiet.id)
        XCTAssertEqual(ids(MarginItem.items(run: nil, notes: store.comments, editing: nil)), [boats.id])
        XCTAssertEqual(try archived(quiet.id, in: workspace), "1")
        store.update(boats.id, text: "")
        store.finishEditing(boats.id)
        XCTAssertTrue(MarginItem.items(run: nil, notes: store.comments, editing: nil).isEmpty)
        XCTAssertNil(try archived(boats.id, in: workspace))
    }

    // MARK: Branches

    func testBranchCarriesCommentsToTheSamePassages() throws {
        let workspace = try makeWorkspace()
        let source = try workspace.create(name: "Harbor", folder: "", goal: "")
        let store = UserCommentStore()
        store.bind(workspace: workspace, draftID: source.id, body: body)
        let quiet = try addComment(store, on: "harbor was quiet", text: "Sound?", in: body)
        let evening = try addComment(store, on: "Evening", text: "Which evening?", in: body)

        let child = try workspace.branch(source, text: body)
        let copies = try workspace.userComments(draftID: child.id)
        XCTAssertEqual(copies.map(\.text), ["Sound?", "Which evening?"])
        XCTAssertEqual(copies.map(\.range), [quiet.range, evening.range])
        XCTAssertEqual(copies.map { (body as NSString).substring(with: $0.range) }, ["harbor was quiet", "Evening"])
        XCTAssertEqual(copies.map(\.prefix), [quiet.prefix, evening.prefix])
        XCTAssertTrue(copies.allSatisfy { $0.draftID == child.id })
        XCTAssertTrue(Set(copies.map(\.id)).isDisjoint(with: [quiet.id, evening.id]), "Copies are separate comments")
        XCTAssertEqual(try workspace.userComments(draftID: source.id).count, 2)

        // Opening the branch shows the copies on their passages.
        let opened = UserCommentStore()
        opened.bind(workspace: workspace, draftID: child.id, body: try workspace.read(child))
        XCTAssertEqual(MarginItem.items(run: nil, notes: opened.comments, editing: nil).map(\.range), [quiet.range, evening.range])
    }

    func testBranchCommentsAreIndependent() throws {
        let workspace = try makeWorkspace()
        let source = try workspace.create(name: "Harbor", folder: "", goal: "")
        let sourceStore = UserCommentStore()
        sourceStore.bind(workspace: workspace, draftID: source.id, body: body)
        let quiet = try addComment(sourceStore, on: "harbor was quiet", text: "Sound?", in: body)
        let boats = try addComment(sourceStore, on: "boats waited", text: "Which boats?", in: body)
        let child = try workspace.branch(source, text: body)

        let childStore = UserCommentStore()
        childStore.bind(workspace: workspace, draftID: child.id, body: body)
        let childQuiet = try XCTUnwrap(childStore.comments.first { $0.quote == "harbor was quiet" })
        let childBoats = try XCTUnwrap(childStore.comments.first { $0.quote == "boats waited" })
        childStore.update(childQuiet.id, text: "Branch note")
        childStore.archive(childBoats.id)
        let edited = body.replacingOccurrences(of: "Morning", with: "Early morning")
        childStore.changed(workspace: workspace, draftID: child.id, body: edited)

        let sourceSaved = try workspace.userComments(draftID: source.id)
        XCTAssertEqual(sourceSaved.map(\.text), ["Sound?", "Which boats?"])
        XCTAssertEqual(sourceSaved.map(\.range), [quiet.range, boats.range])

        sourceStore.remove(quiet.id)
        let childSaved = try workspace.userComments(draftID: child.id)
        XCTAssertEqual(childSaved.map(\.text), ["Branch note"])
        XCTAssertEqual(childSaved.first.map(\.range), range(of: "harbor was quiet", in: edited))
        XCTAssertEqual(try archived(childBoats.id, in: workspace), "1")
        XCTAssertEqual(try archived(boats.id, in: workspace), "0")
    }

    func testBranchKeepsHiddenCommentsHiddenAndSkipsArchivedOnes() throws {
        let workspace = try makeWorkspace()
        let source = try workspace.create(name: "Harbor", folder: "", goal: "")
        let store = UserCommentStore()
        store.bind(workspace: workspace, draftID: source.id, body: body)
        let quiet = try addComment(store, on: "harbor was quiet", text: "Sound?", in: body)
        let boats = try addComment(store, on: "boats waited", text: "Which boats?", in: body)
        let evening = try addComment(store, on: "Evening", text: "Archived", in: body)
        store.archive(evening.id)
        _ = try XCTUnwrap(store.add(range: range(of: "light", in: body)), "An unwritten comment")

        // The passage was deleted just before branching: the comment is hidden, not gone.
        let deleted = body.replacingOccurrences(of: "The harbor was quiet and the", with: "The")
        store.changed(workspace: workspace, draftID: source.id, body: deleted)
        let child = try workspace.branch(source, text: deleted)

        let copies = try workspace.userComments(draftID: child.id)
        XCTAssertEqual(Set(copies.map(\.text)), ["Sound?", "Which boats?"], "Archived and unwritten comments are not copied")
        let hidden = try XCTUnwrap(copies.first { $0.text == "Sound?" })
        XCTAssertFalse(hidden.attached)
        XCTAssertEqual(hidden.quote, "harbor was quiet")
        XCTAssertEqual(copies.first { $0.text == "Which boats?" }?.range, range(of: "boats waited", in: deleted))

        let childStore = UserCommentStore()
        childStore.bind(workspace: workspace, draftID: child.id, body: deleted)
        XCTAssertEqual(MarginItem.items(run: nil, notes: childStore.comments, editing: nil).map(\.range), [range(of: "boats waited", in: deleted)])

        // Restoring the passage in the branch shows its copy there; the source copy stays hidden.
        childStore.changed(workspace: workspace, draftID: child.id, body: body)
        XCTAssertEqual(MarginItem.items(run: nil, notes: childStore.comments, editing: nil).map(\.range), [quiet.range, boats.range])
        XCTAssertEqual(try workspace.userComments(draftID: source.id).first { $0.id == quiet.id }?.attached, false)
    }
}
