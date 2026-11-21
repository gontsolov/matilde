import XCTest
import AppKit
@testable import Matilde
import MatildeKit

/// Comments stay on their passages: only deleting the whole passage, or the comment itself, hides them.
@MainActor
final class CommentAnchoringTests: XCTestCase {
    private let input = ReviewInput(title: "Harbor", goal: "Clarity", body: "Morning 🌱 light. The harbor was very quiet. Evening came.")
    private var suggestion: ReviewSuggestion {
        ReviewSuggestion(quote: "harbor was very quiet", prefix: "The ", suffix: ".", explanation: "Show it.", replacement: "harbor lay still")
    }
    private func makeReview() throws -> WritingReview {
        try WritingReview.make(draftID: "a", input: input, model: "fake", suggestions: [suggestion])
    }
    private func body(_ old: String, _ new: String) -> ReviewInput {
        ReviewInput(title: input.title, goal: input.goal, body: input.body.replacingOccurrences(of: old, with: new))
    }
    private func quote(_ comment: ReviewComment, in input: ReviewInput) -> String {
        (input.body as NSString).substring(with: comment.range)
    }
    private func makeWorkspace() throws -> Workspace {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MatildeAnchorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try Workspace(root: url)
    }

    func testAICommentGrowsWithEditInsidePassage() throws {
        var review = try makeReview()
        let edited = body("very quiet", "very, very quiet")
        review.track(edited)
        let comment = review.comments[0]
        XCTAssertEqual(comment.status, "open")
        XCTAssertEqual(quote(comment, in: edited), "harbor was very, very quiet")
        XCTAssertEqual(comment.suggestion.quote, "harbor was very, very quiet")
        XCTAssertTrue(comment.matches(edited.body))
        XCTAssertFalse(comment.rewriteApplies, "A rewrite written for the old passage must not overwrite the edit")
        XCTAssertEqual(comment.rewriteQuote, "harbor was very quiet")
        review.track(input)
        XCTAssertTrue(review.comments[0].rewriteApplies)
    }

    func testAICommentShiftsWithEditBeforePassage() throws {
        var review = try makeReview()
        let edited = body("Morning 🌱", "Early 🐳 morning")
        review.track(edited)
        let comment = review.comments[0]
        XCTAssertEqual(comment.status, "open")
        XCTAssertEqual(quote(comment, in: edited), "harbor was very quiet")
        XCTAssertTrue(comment.rewriteApplies)
        let after = ReviewInput(title: edited.title, goal: edited.goal, body: edited.body.replacingOccurrences(of: "Evening", with: "Night"))
        review.track(after)
        XCTAssertEqual(review.comments[0].range, comment.range)
    }

    func testAICommentShrinksWhenPartOfPassageIsDeleted() throws {
        var review = try makeReview()
        let edited = body("The harbor was", "It was")
        review.track(edited)
        XCTAssertEqual(review.comments[0].status, "open")
        XCTAssertEqual(quote(review.comments[0], in: edited), " was very quiet")
        let tail = body("very quiet. Evening", "very. Evening")
        var other = try makeReview()
        other.track(tail)
        XCTAssertEqual(quote(other.comments[0], in: tail), "harbor was very")
    }

    func testAICommentDisappearsOnlyWhenWholePassageIsDeletedAndUndoRestoresIt() throws {
        var review = try makeReview()
        let original = review.comments[0].range
        let deleted = body("The harbor was very quiet. ", "")
        review.track(deleted)
        XCTAssertEqual(review.comments[0].status, "removed")
        XCTAssertFalse(review.comments[0].matches(deleted.body))
        review.track(input)
        XCTAssertEqual(review.comments[0].status, "open")
        XCTAssertEqual(review.comments[0].range, original)
    }

    func testTitleAndGoalChangesKeepAICommentsAndAcceptStillWorks() throws {
        let workspace = try makeWorkspace()
        let saved = try makeReview()
        try workspace.saveReview(saved)
        let model = WritingReviewModel()
        model.bind(workspace: workspace, draftID: "a", input: input)
        let renamed = ReviewInput(title: "Port", goal: "Mood", body: "Intro. " + input.body)
        model.invalidate(renamed)
        XCTAssertFalse(model.history[0].stale)
        XCTAssertEqual(model.history[0].comments[0].status, "open")
        let editor = WritingTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        editor.string = renamed.body
        model.accept(runID: saved.id, commentID: saved.comments[0].id, input: renamed, editor: editor)
        XCTAssertEqual(editor.string, "Intro. Morning 🌱 light. The harbor lay still. Evening came.")
        XCTAssertEqual(model.history[0].comments[0].status, "accepted")
    }

    func testReopenedReviewFollowsTextChangedWhileClosed() throws {
        let workspace = try makeWorkspace()
        try workspace.saveReview(try makeReview())
        let external = ReviewInput(title: input.title, goal: input.goal, body: "New first line.\n\n" + input.body)
        let model = WritingReviewModel()
        model.bind(workspace: workspace, draftID: "a", input: external)
        XCTAssertEqual(model.history[0].comments[0].status, "open")
        XCTAssertEqual(quote(model.history[0].comments[0], in: external), "harbor was very quiet")
        let stored = try XCTUnwrap(workspace.reviewHistory(draftID: "a").first)
        XCTAssertEqual(stored.comments[0].location, model.history[0].comments[0].location)
        XCTAssertEqual(stored.source, external)
    }

    func testExplicitDeleteRemovesAICommentFromSavedHistory() throws {
        let workspace = try makeWorkspace()
        let saved = try makeReview()
        try workspace.saveReview(saved)
        let model = WritingReviewModel()
        model.bind(workspace: workspace, draftID: "a", input: input)
        model.delete(runID: saved.id, commentID: saved.comments[0].id)
        XCTAssertTrue(model.history[0].comments.isEmpty)
        XCTAssertEqual(try workspace.reviewHistory(draftID: "a").first?.comments.count, 0)
    }

    func testLegacyStaleCommentIsReanchored() throws {
        var review = try makeReview()
        review.comments[0].status = "stale"
        review.track(body("Evening", "Night"))
        XCTAssertEqual(review.comments[0].status, "open")
    }

    // MARK: Private comments

    private func userComment(_ text: String, in body: String) -> UserComment {
        CommentAnchor.refreshed(UserComment(id: UUID(), draftID: "a", text: "Note", location: 0, length: 0, quote: "", prefix: "", suffix: "",
                                            created: Date(), modified: Date()), range: (body as NSString).range(of: text), in: body)
    }

    func testUserCommentFollowsEditsAndOnlyFullDeletionHidesIt() throws {
        let workspace = try makeWorkspace()
        let text = input.body
        let store = UserCommentStore()
        store.bind(workspace: workspace, draftID: "a", body: text)
        let created = try XCTUnwrap(store.add(range: (text as NSString).range(of: "harbor was very quiet")))
        store.update(created.id, text: "Which sounds?")
        func quote() -> String? { store.comments.first.flatMap { $0.attached ? (store.body as NSString).substring(with: $0.range) : nil } }

        store.changed(workspace: workspace, draftID: "a", body: text.replacingOccurrences(of: "very quiet", with: "so very quiet"))
        XCTAssertEqual(quote(), "harbor was so very quiet")
        store.changed(workspace: workspace, draftID: "a", body: "Intro. " + store.body)
        XCTAssertEqual(quote(), "harbor was so very quiet")
        store.changed(workspace: workspace, draftID: "a", body: store.body.replacingOccurrences(of: "The harbor was", with: "It was"))
        XCTAssertEqual(quote(), " was so very quiet")
        let beforeDeletion = store.body
        store.changed(workspace: workspace, draftID: "a", body: beforeDeletion.replacingOccurrences(of: " was so very quiet", with: ""))
        XCTAssertNil(quote())
        XCTAssertNil(store.comment(containing: (store.body as NSString).range(of: "It.").location))
        store.changed(workspace: workspace, draftID: "a", body: beforeDeletion)
        XCTAssertEqual(quote(), " was so very quiet")
        XCTAssertEqual(store.comments.first?.text, "Which sounds?")
        store.remove(created.id)
        XCTAssertTrue(store.comments.isEmpty)
        XCTAssertTrue(try workspace.userComments(draftID: "a").isEmpty)
    }

    func testReplacingExactlyThePassageKeepsTheComment() {
        let text = "Alpha beta gamma."
        let comment = userComment("beta", in: text)
        let replaced = "Alpha zzz gamma."
        let tracked = CommentAnchor.track(comment, edit: WritingEdit.between(text, replaced), in: replaced)
        XCTAssertEqual((replaced as NSString).substring(with: tracked.range), "zzz")
    }

    // MARK: Ask Matilde shortcut

    func testAskUsesSelectionOrCurrentParagraph() {
        let editor = WritingTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        editor.string = "First 🌱 paragraph.\n\n  Second one here.  \n\nThird."
        let source = editor.string as NSString
        editor.setSelectedRange(NSRange(location: source.range(of: "one").location, length: 0))
        XCTAssertEqual(editor.askRange.map(source.substring(with:)), "Second one here.")
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertEqual(editor.askRange.map(source.substring(with:)), "First 🌱 paragraph.")
        let selection = source.range(of: "Third")
        editor.setSelectedRange(selection)
        XCTAssertEqual(editor.askRange, selection)
        editor.setSelectedRange(NSRange(location: source.range(of: "\n\n").location + 1, length: 0))
        XCTAssertNil(editor.askRange, "An empty line falls back to reviewing the draft")
        var asked: NSRange?
        editor.onAskSelection = { asked = $0 }
        editor.setSelectedRange(NSRange(location: source.length, length: 0))
        editor.askAboutSelection()
        XCTAssertEqual(asked.map(source.substring(with:)), "Third.")
    }
}
