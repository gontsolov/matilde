import XCTest
import Combine
@testable import Matilde
import MatildeKit

@MainActor
final class UnreadThreadTests: XCTestCase {
    private let input = ReviewInput(title: "Synthetic", goal: "Clarity", body: "First 🌱 claim. Another claim.")
    private let configuration = LangdockConfiguration(baseURL: "https://api.langdock.com", region: "eu", model: "synthetic")
    private func suggestion(_ quote: String) -> ReviewSuggestion {
        ReviewSuggestion(quote: quote, prefix: "", suffix: "", explanation: "Be precise.", replacement: nil)
    }
    private func workspace() throws -> Workspace {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/unread-tests/\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try Workspace(root: root)
    }
    private func waitUntilIdle(_ model: WritingReviewModel) async {
        let completed = expectation(description: "Request finishes")
        let observation = model.$isRunning.filter { !$0 }.first().sink { _ in completed.fulfill() }
        await fulfillment(of: [completed], timeout: 5)
        withExtendedLifetime(observation) {}
    }

    func testNewSuggestionsArriveUnreadAndOpeningMarksThemReadDurably() async throws {
        let workspace = try workspace()
        let model = WritingReviewModel(client: UnreadClient(suggestions: [suggestion("Another claim.")]))
        model.bind(workspace: workspace, draftID: "a", input: input)
        model.start(input: input, configuration: configuration, key: "test-only")
        await waitUntilIdle(model)
        let comment = try XCTUnwrap(model.history.first?.comments.first)
        XCTAssertTrue(comment.isUnread)
        XCTAssertEqual(try workspace.reviewHistory(draftID: "a").first?.comments.first?.isUnread, true)

        model.threadOpened(comment.id)
        XCTAssertEqual(model.openThreadID, comment.id)
        XCTAssertFalse(try XCTUnwrap(model.history.first?.comments.first).isUnread)
        let reopened = WritingReviewModel()
        reopened.bind(workspace: workspace, draftID: "a", input: input)
        XCTAssertFalse(try XCTUnwrap(reopened.history.first?.comments.first).isUnread)
    }

    func testCarriedThreadsKeepTheirStateAndOnlyNewOnesAreUnread() async throws {
        let workspace = try workspace()
        let client = UnreadClient(suggestions: [suggestion("Another claim.")])
        let model = WritingReviewModel(client: client)
        model.bind(workspace: workspace, draftID: "a", input: input)
        model.start(input: input, configuration: configuration, key: "test-only")
        await waitUntilIdle(model)
        let first = try XCTUnwrap(model.history.first?.comments.first)
        model.threadOpened(first.id); model.threadOpened(nil)

        client.suggestions = [suggestion("First 🌱 claim.")]
        model.start(input: input, configuration: configuration, key: "test-only")
        await waitUntilIdle(model)
        let comments = try XCTUnwrap(model.history.first?.comments)
        XCTAssertEqual(comments.count, 2)
        XCTAssertFalse(try XCTUnwrap(comments.first { $0.id == first.id }).isUnread, "An opened thread stays read when carried forward")
        XCTAssertTrue(try XCTUnwrap(comments.first { $0.id != first.id }).isUnread)
    }

    func testSelfStartedThreadIsReadAndRepliesAreUnreadOnlyWhileClosed() async throws {
        let workspace = try workspace()
        let model = WritingReviewModel(client: UnreadClient(suggestions: []))
        model.bind(workspace: workspace, draftID: "a", input: input)
        model.beginSelection((input.body as NSString).range(of: "Another claim."), input: input)
        let run = try XCTUnwrap(model.history.first), comment = try XCTUnwrap(run.comments.first)
        XCTAssertFalse(comment.isUnread)

        model.threadOpened(comment.id)
        model.reply(runID: run.id, commentID: comment.id, text: "Help", input: input, configuration: configuration, key: "test-only")
        await waitUntilIdle(model)
        XCTAssertFalse(try XCTUnwrap(model.history.first?.comments.first).isUnread, "A reply into the open thread is read")

        model.reply(runID: run.id, commentID: comment.id, text: "More", input: input, configuration: configuration, key: "test-only")
        model.threadOpened(nil)
        await waitUntilIdle(model)
        XCTAssertTrue(try XCTUnwrap(model.history.first?.comments.first).isUnread, "A reply arriving after closing is unread")
        XCTAssertEqual(try workspace.reviewHistory(draftID: "a").first?.comments.first?.isUnread, true)

        model.threadOpened(comment.id)
        XCTAssertFalse(try XCTUnwrap(model.history.first?.comments.first).isUnread)
        XCTAssertEqual(try workspace.reviewHistory(draftID: "a").first?.comments.first?.isUnread, false)
    }

    func testFailedReplyDoesNotMarkUnread() async throws {
        let workspace = try workspace()
        let client = UnreadClient(suggestions: []); client.failReplies = true
        let model = WritingReviewModel(client: client)
        model.bind(workspace: workspace, draftID: "a", input: input)
        model.beginSelection((input.body as NSString).range(of: "Another claim."), input: input)
        let run = try XCTUnwrap(model.history.first), comment = try XCTUnwrap(run.comments.first)
        model.reply(runID: run.id, commentID: comment.id, text: "Help", input: input, configuration: configuration, key: "test-only")
        await waitUntilIdle(model)
        XCTAssertNotNil(model.history.first?.comments.first?.replyError)
        XCTAssertFalse(try XCTUnwrap(model.history.first?.comments.first).isUnread)
    }

    func testSwitchingDraftsClosesTheOpenThread() throws {
        let workspace = try workspace()
        let model = WritingReviewModel(client: UnreadClient(suggestions: []))
        model.bind(workspace: workspace, draftID: "a", input: input)
        model.threadOpened(UUID())
        model.bind(workspace: workspace, draftID: "b", input: input)
        XCTAssertNil(model.openThreadID)
    }

    func testReviewsSavedBeforeUnreadTrackingLoadAsRead() throws {
        let workspace = try workspace()
        let run = try WritingReview.make(draftID: "a", input: input, model: "fake", suggestions: [suggestion("Another claim.")])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(run)) as? [String: Any])
        var comments = try XCTUnwrap(json["comments"] as? [[String: Any]])
        comments[0].removeValue(forKey: "unread")
        json["comments"] = comments
        let legacy = try JSONDecoder().decode(WritingReview.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.comments[0].unread)
        XCTAssertFalse(legacy.comments[0].isUnread)

        // Stored the same way the app wrote reviews before this change.
        try workspace.saveReview(legacy)
        let model = WritingReviewModel()
        model.bind(workspace: workspace, draftID: "a", input: input)
        XCTAssertFalse(try XCTUnwrap(model.history.first?.comments.first).isUnread)

        var marked = run
        marked.comments[0].unread = true
        let decoded = try JSONDecoder().decode(WritingReview.self, from: JSONEncoder().encode(marked))
        XCTAssertTrue(decoded.comments[0].isUnread)
        let readJSON = try XCTUnwrap(String(data: JSONEncoder().encode(run), encoding: .utf8))
        XCTAssertFalse(readJSON.contains("unread"), "Read threads keep the saved payload unchanged")
    }

    func testUnreadStateStaysOutOfTheMarkdown() async throws {
        let workspace = try workspace()
        let draft = try workspace.create(name: "Synthetic", folder: "", goal: input.goal)
        try workspace.save(draft, text: input.body)
        let model = WritingReviewModel(client: UnreadClient(suggestions: [suggestion("Another claim.")]))
        model.bind(workspace: workspace, draftID: draft.id, input: input)
        model.start(input: input, configuration: configuration, key: "test-only")
        await waitUntilIdle(model)
        XCTAssertEqual(model.history.first?.comments.first?.isUnread, true)
        XCTAssertEqual(try workspace.read(draft), input.body)
    }
}

@MainActor
private final class UnreadClient: LangdockServing {
    var suggestions: [ReviewSuggestion]
    var failReplies = false
    init(suggestions: [ReviewSuggestion]) { self.suggestions = suggestions }
    func models(configuration: LangdockConfiguration, key: String) async throws -> [String] { [] }
    func review(_ input: ReviewInput, configuration: LangdockConfiguration, key: String) async throws -> [ReviewSuggestion] {
        try await Task.sleep(for: .milliseconds(10))
        return suggestions
    }
    func reply(_ input: ReviewInput, suggestion: ReviewSuggestion, messages: [ReviewMessage], question: String, configuration: LangdockConfiguration, key: String) async throws -> ReviewReply {
        try await Task.sleep(for: .milliseconds(20))
        if failReplies { throw ReviewError.message("Synthetic failure.") }
        return ReviewReply(answer: "A clearer claim.", replacement: nil)
    }
}
