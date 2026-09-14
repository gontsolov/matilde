import XCTest
@testable import Matilde

@MainActor
final class WritingAssistFollowupTests: XCTestCase {
    let input = ReviewInput(title: "Synthetic", goal: "Clarity", body: "First 🌱 claim. Another claim.")
    let configuration = LangdockConfiguration(baseURL: "https://api.langdock.com", region: "eu", model: "synthetic")
    func workspace() throws -> Workspace {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/assist-tests/\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try Workspace(root: root)
    }
    func suggestion(_ quote: String) -> ReviewSuggestion {
        ReviewSuggestion(quote: quote, prefix: "", suffix: "", explanation: "Be precise.", replacement: nil)
    }
    func testTracksUnicodeEditsAndOnlyInvalidatesOverlappingComment() throws {
        var run = try WritingReview.make(draftID: "a", input: input, model: "fake", suggestions: [suggestion("First 🌱 claim."), suggestion("Another claim.")])
        let prefixed = ReviewInput(title: input.title, goal: input.goal, body: "Intro 🐳. " + input.body)
        run.track(prefixed)
        XCTAssertTrue(run.comments.allSatisfy { $0.matches(prefixed.body) })
        XCTAssertEqual(run.comments[0].location, "Intro 🐳. ".utf16.count)
        let edited = ReviewInput(title: input.title, goal: input.goal, body: prefixed.body.replacingOccurrences(of: "First 🌱", with: "New"))
        run.track(edited)
        XCTAssertEqual(run.comments[0].status, "stale")
        XCTAssertEqual(run.comments[1].status, "open")
        XCTAssertTrue(run.comments[1].matches(edited.body))
        XCTAssertFalse(run.stale)
        let saved = try JSONEncoder().encode(run)
        XCTAssertEqual(try JSONDecoder().decode(WritingReview.self, from: saved).source, edited)
    }
    func testLegacyReviewLoadsAndGoalChangeInvalidatesContext() throws {
        let run = try WritingReview.make(draftID: "a", input: input, model: "fake", suggestions: [suggestion("Another claim.")])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(run)) as? [String: Any])
        json.removeValue(forKey: "source")
        let legacy = try JSONDecoder().decode(WritingReview.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.source)
        var changed = run
        changed.track(ReviewInput(title: input.title, goal: "Different purpose", body: input.body))
        XCTAssertTrue(changed.stale)
    }
    func testAutomaticReviewDebouncesDeduplicatesPausesAndCancelsOnSwitch() async throws {
        let previous = UserDefaults.standard.object(forKey: "writingAssist.paused")
        defer { UserDefaults.standard.set(previous, forKey: "writingAssist.paused") }
        UserDefaults.standard.set(false, forKey: "writingAssist.paused")
        let workspace = try workspace(), client = FollowupClient()
        let model = WritingReviewModel(client: client)
        model.automaticDelay = .milliseconds(35)
        model.automaticConfiguration = { self.configuration }
        model.automaticKey = { "test-only" }
        model.bind(workspace: workspace, draftID: "a", input: input)
        let changed = ReviewInput(title: input.title, goal: input.goal, body: input.body + " New sentence.")
        model.changed(workspace: workspace, draftID: "a", input: changed)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(client.reviews, 1)
        model.changed(workspace: workspace, draftID: "a", input: changed)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(client.reviews, 1)
        model.toggleAutomatic()
        model.changed(workspace: workspace, draftID: "a", input: input)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(client.reviews, 1)
        model.toggleAutomatic()
        model.bind(workspace: workspace, draftID: "b", input: input)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(client.reviews, 1)
        XCTAssertFalse(WritingReviewModel.meaningfulChange(from: input, to: ReviewInput(title: input.title, goal: input.goal, body: "**" + input.body + "**\n")))
    }
    func testReplyPersistsThreadAndOptionalRewriteWithoutApplyingText() async throws {
        let workspace = try workspace(), client = FollowupClient()
        let run = try WritingReview.make(draftID: "a", input: input, model: "fake", suggestions: [suggestion("Another claim.")])
        try workspace.saveReview(run)
        let model = WritingReviewModel(client: client)
        model.bind(workspace: workspace, draftID: "a", input: input)
        model.reply(runID: run.id, commentID: run.comments[0].id, text: "Can you explain?", input: input, configuration: configuration, key: "test-only")
        try await Task.sleep(for: .milliseconds(80))
        let stored = try XCTUnwrap(workspace.reviewHistory(draftID: "a").first?.comments.first)
        XCTAssertEqual(stored.messages?.map(\.role), ["user", "assistant"])
        XCTAssertEqual(stored.messages?.last?.text, "A more specific claim helps.")
        XCTAssertEqual(stored.suggestion.replacement, "A precise claim.")
        XCTAssertEqual(model.history.first?.source?.body, input.body)
        XCTAssertTrue(try workspace.reviewHistory(draftID: "b").isEmpty)
    }
    func testReplyIsDiscardedWhenDraftChanges() async throws {
        let workspace = try workspace(), client = FollowupClient()
        client.replyDelay = .milliseconds(60)
        let run = try WritingReview.make(draftID: "a", input: input, model: "fake", suggestions: [suggestion("Another claim.")])
        try workspace.saveReview(run)
        let model = WritingReviewModel(client: client)
        model.bind(workspace: workspace, draftID: "a", input: input)
        model.reply(runID: run.id, commentID: run.comments[0].id, text: "Explain", input: input, configuration: configuration, key: "test-only")
        model.invalidate(ReviewInput(title: input.title, goal: input.goal, body: input.body + " More context."))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(try workspace.reviewHistory(draftID: "a").first?.comments.first?.messages?.last?.delivery, "failed")
    }
    func testSelectionCreatesExactThreadAndOptimisticRetryDoesNotDuplicate() async throws {
        let workspace = try workspace(), client = FollowupClient()
        client.replyDelay = .milliseconds(80)
        let model = WritingReviewModel(client: client)
        let repeated = ReviewInput(title: "Test", goal: "", body: "Hello 🌱. Hello 🌱.")
        model.bind(workspace: workspace, draftID: "a", input: repeated)
        let range = (repeated.body as NSString).range(of: "Hello 🌱.", options: .backwards)
        model.beginSelection(range, input: repeated)
        let run = try XCTUnwrap(model.history.first), comment = try XCTUnwrap(run.comments.first)
        XCTAssertEqual(comment.range, range)
        XCTAssertEqual(comment.userInitiated, true)
        model.beginSelection(range, input: repeated)
        XCTAssertEqual(model.history.first?.comments.count, 1)
        model.reply(runID: run.id, commentID: comment.id, text: "Help", input: repeated, configuration: configuration, key: "test")
        XCTAssertEqual(model.history.first?.comments.first?.messages?.last?.delivery, "pending")
        XCTAssertEqual(model.replyingTo, comment.id)
        model.cancel()
        XCTAssertEqual(model.history.first?.comments.first?.messages?.last?.delivery, "failed")
        model.reply(runID: run.id, commentID: comment.id, text: "Help", input: repeated, configuration: configuration, key: "test")
        XCTAssertEqual(model.history.first?.comments.first?.messages?.count, 1)
        try await Task.sleep(for: .milliseconds(140))
        XCTAssertEqual(model.history.first?.comments.first?.messages?.map(\.role), ["user", "assistant"])
        XCTAssertEqual(model.history.first?.comments.first?.messages?.first?.delivery, "sent")
        XCTAssertNil(model.history.first?.comments.first?.replyError)
        XCTAssertEqual(model.history.first?.source?.body, repeated.body)
    }
    func testLineDifferencesIdentifyBothSidesAndUnicodeOffsets() {
        let left = "Same\nOld 🌱 line\nSame", right = "Same\nNew 🐳 line\nSame\nAdded"
        let diff = ComparisonDifferences.between(left, right)
        XCTAssertEqual(diff.left.map { (left as NSString).substring(with: $0) }, ["Old 🌱 line"])
        XCTAssertEqual(Set(diff.right.map { (right as NSString).substring(with: $0) }), Set(["New 🐳 line", "Added"]))
        XCTAssertTrue(ComparisonDifferences.between(left, left).left.isEmpty)
    }
}

@MainActor
private final class FollowupClient: LangdockServing {
    var reviews = 0
    var replyDelay: Duration = .zero
    func models(configuration: LangdockConfiguration, key: String) async throws -> [String] { [] }
    func review(_ input: ReviewInput, configuration: LangdockConfiguration, key: String) async throws -> [ReviewSuggestion] { reviews += 1; return [] }
    func reply(_ input: ReviewInput, suggestion: ReviewSuggestion, messages: [ReviewMessage], question: String, configuration: LangdockConfiguration, key: String) async throws -> ReviewReply {
        try await Task.sleep(for: replyDelay)
        return ReviewReply(answer: "A more specific claim helps.", replacement: "A precise claim.")
    }
}
