import XCTest
import Combine
@testable import Matilde

@MainActor
final class ThreadTimelineTests: XCTestCase {
    private let input = ReviewInput(title: "Synthetic", goal: "Clarity", body: "First 🌱 claim. Another claim.")
    private let configuration = LangdockConfiguration(baseURL: "https://api.langdock.com", region: "eu", model: "synthetic")

    private func comment(replacement: String? = nil, explanation: String = "", messages: [ReviewMessage]? = nil,
                         userInitiated: Bool? = nil) -> ReviewComment {
        var comment = ReviewComment(id: UUID(), suggestion: ReviewSuggestion(quote: "Another claim.", prefix: "", suffix: "",
                                    explanation: explanation, replacement: replacement), location: 16, length: 14)
        comment.messages = messages
        comment.userInitiated = userInitiated
        return comment
    }
    private func user(_ text: String) -> ReviewMessage { ReviewMessage(role: "user", text: text) }
    private func assistant(_ text: String, replacement: String? = nil) -> ReviewMessage {
        var message = ReviewMessage(role: "assistant", text: text)
        message.replacement = replacement
        return message
    }
    /// A compact picture of the timeline: message texts, and rewrites as `[text]` (current) or `(text)` (earlier).
    private func shape(_ items: [ThreadTimelineItem]) -> [String] {
        items.map {
            switch $0 {
            case let .message(_, message): message.text
            case let .suggestion(suggestion): suggestion.isCurrent ? "[\(suggestion.replacement)]" : "(\(suggestion.replacement))"
            }
        }
    }
    private func workspace() throws -> Workspace {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/timeline-tests/\(UUID())")
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

    func testReviewSuggestionComesFirstBeforeAnyChat() {
        let items = ThreadTimeline.items(for: comment(replacement: "A sharper claim.", explanation: "Be precise."))
        XCTAssertEqual(shape(items), ["[A sharper claim.]"])
        let chatted = comment(replacement: "A sharper claim.", messages: [user("Why?"), assistant("Because.")])
        XCTAssertEqual(shape(ThreadTimeline.items(for: chatted)), ["[A sharper claim.]", "Why?", "Because."])
    }

    func testReplyRewriteSitsAfterItsMessageAndEarlierOnesStayInPlace() {
        let first = assistant("Try this.", replacement: "One claim.")
        let second = assistant("Or this.", replacement: "Two claims.")
        var thread = comment(replacement: "Two claims.", messages: [user("Q1"), assistant("A1"), user("Q2"), first,
                                                                     user("Q3"), second, user("Q4"), assistant("A4")])
        thread.rewriteMessageID = second.id
        thread.initialReplacement = "Review claim."
        XCTAssertEqual(shape(ThreadTimeline.items(for: thread)),
                       ["(Review claim.)", "Q1", "A1", "Q2", "Try this.", "(One claim.)", "Q3", "Or this.", "[Two claims.]", "Q4", "A4"])
        let indices = ThreadTimeline.items(for: thread).compactMap { item -> Int? in
            if case let .message(index, _) = item { index } else { nil }
        }
        XCTAssertEqual(indices, Array(0..<8), "Messages keep their thread positions for speaker labels")
        XCTAssertEqual(Set(ThreadTimeline.items(for: thread).map(\.id)).count, 11, "Every item has its own identity")
    }

    func testCurrentRewriteWithAMissingMessageFallsBackToTheTop() {
        var thread = comment(replacement: "Two claims.", messages: [user("Q1"), assistant("A1")])
        thread.rewriteMessageID = UUID()
        XCTAssertEqual(shape(ThreadTimeline.items(for: thread)), ["[Two claims.]", "Q1", "A1"])
    }

    func testPreviewShowsTheLatestAssistantContent() {
        XCTAssertEqual(ThreadTimeline.preview(for: comment(explanation: "Be precise.")), "Be precise.")
        XCTAssertNil(ThreadTimeline.preview(for: comment()))
        XCTAssertEqual(ThreadTimeline.preview(for: comment(messages: [user("Why?")])), "Why?")
        let thread = comment(explanation: "Be precise.", messages: [user("Why?"), assistant("Because.", replacement: "X."), user("Thanks")])
        XCTAssertEqual(ThreadTimeline.preview(for: thread), "Because.")
    }

    func testLegacyThreadsGetASensiblePlaceAndMigrationIsIdempotent() throws {
        let reply = UUID(), later = UUID(), ask = UUID(), review = UUID()
        // Saved before rewrites were tied to replies: no `replacement`, `rewriteMessageID` or `initialReplacement` keys.
        func legacy(_ id: UUID, userInitiated: Bool) -> String {
            #"""
            {"id":"\#(id)","suggestion":{"quote":"Another claim.","prefix":"","suffix":"","explanation":"","replacement":"Two claims."},
             "location":16,"length":14,"status":"open","userInitiated":\#(userInitiated),
             "messages":[{"id":"\#(UUID())","role":"user","text":"Q1","delivery":"sent"},
                         {"id":"\#(reply)","role":"assistant","text":"A1"},
                         {"id":"\#(UUID())","role":"user","text":"Q2","delivery":"sent"},
                         {"id":"\#(later)","role":"assistant","text":"A2"}]}
            """#
        }
        let payload = #"""
        {"id":"\#(UUID())","draftID":"a","created":0,"model":"synthetic","revision":"\#(WritingReview.revision(input))","stale":false,
         "comments":[\#(legacy(ask, userInitiated: true)),\#(legacy(review, userInitiated: false))]}
        """#
        let decoded = try JSONDecoder().decode(WritingReview.self, from: Data(payload.utf8))
        XCTAssertNil(decoded.comments[0].rewriteMessageID)
        XCTAssertNil(decoded.comments[0].messages?[1].replacement)

        let workspace = try workspace()
        try workspace.saveReview(decoded)
        let loaded = try XCTUnwrap(workspace.reviewHistory(draftID: "a").first)
        XCTAssertEqual(loaded.comments[0].rewriteMessageID, later, "An Ask Matilde rewrite came from a reply: attach it to the latest one")
        XCTAssertEqual(shape(ThreadTimeline.items(for: loaded.comments[0])), ["Q1", "A1", "Q2", "A2", "[Two claims.]"])
        XCTAssertNil(loaded.comments[1].rewriteMessageID, "A review thread's rewrite may be the review's own, so it stays first")
        XCTAssertEqual(shape(ThreadTimeline.items(for: loaded.comments[1])), ["[Two claims.]", "Q1", "A1", "Q2", "A2"])
        XCTAssertTrue(loaded.comments[0].rewriteApplies)

        var again = loaded.comments[0]
        again.attachLegacyRewrite()
        XCTAssertEqual(again.messages, loaded.comments[0].messages)
        XCTAssertEqual(again.rewriteMessageID, later)
        try workspace.saveReview(loaded)
        XCTAssertEqual(try workspace.reviewHistory(draftID: "a").first?.comments[0].messages, loaded.comments[0].messages)
    }

    func testRepliesRecordWhereEachRewriteCameFromAndKeepTheReviewsOwn() async throws {
        let workspace = try workspace()
        let client = TimelineClient()
        client.reviewReplacement = "Review claim."
        let model = WritingReviewModel(client: client)
        model.bind(workspace: workspace, draftID: "a", input: input)
        model.start(input: input, configuration: configuration, key: "test-only")
        await waitUntilIdle(model)
        let run = try XCTUnwrap(model.history.first)
        let id = try XCTUnwrap(run.comments.first?.id)

        for (question, replacement) in [("Q1", nil), ("Q2", "One claim."), ("Q3", "Two claims."), ("Q4", nil)] as [(String, String?)] {
            client.replacement = replacement
            model.reply(runID: run.id, commentID: id, text: question, input: input, configuration: configuration, key: "test-only")
            await waitUntilIdle(model)
        }
        let expected = ["(Review claim.)", "Q1", "Re: Q1", "Q2", "Re: Q2", "(One claim.)", "Q3", "Re: Q3", "[Two claims.]", "Q4", "Re: Q4"]
        let live = try XCTUnwrap(model.history.first?.comments.first)
        XCTAssertEqual(shape(ThreadTimeline.items(for: live)), expected)
        XCTAssertEqual(live.suggestion.replacement, "Two claims.", "Accept still targets the latest rewrite")
        XCTAssertTrue(live.rewriteApplies)
        XCTAssertEqual(client.lastSuggestion?.replacement, "Two claims.", "Replies still see the current rewrite as context")

        let reopened = WritingReviewModel()
        reopened.bind(workspace: workspace, draftID: "a", input: input)
        XCTAssertEqual(shape(ThreadTimeline.items(for: try XCTUnwrap(reopened.history.first?.comments.first))), expected)
    }

    func testFollowingThreadCatchesUpWhenContentGrowsButNotAfterScrollingUp() {
        let viewport: CGFloat = 300
        var follower = BottomFollower()
        XCTAssertFalse(follower.observe(contentTop: viewport - 800, contentHeight: 800, viewportHeight: viewport))
        // A rewrite card lays out below the reply: the end moves 90 points below the viewport.
        XCTAssertTrue(follower.observe(contentTop: viewport - 800, contentHeight: 890, viewportHeight: viewport))
        XCTAssertFalse(follower.observe(contentTop: viewport - 890, contentHeight: 890, viewportHeight: viewport))

        follower.observe(contentTop: viewport - 890 + 200, contentHeight: 890, viewportHeight: viewport)
        XCTAssertFalse(follower.following)
        XCTAssertFalse(follower.observe(contentTop: viewport - 890 + 200, contentHeight: 980, viewportHeight: viewport),
                       "A reader who scrolled up is not pulled down")
        XCTAssertFalse(follower.observe(contentTop: 0, contentHeight: 200, viewportHeight: viewport), "Short threads need no scrolling")
    }
}

@MainActor
private final class TimelineClient: LangdockServing {
    var reviewReplacement: String?
    var replacement: String?
    var lastSuggestion: ReviewSuggestion?
    func models(configuration: LangdockConfiguration, key: String) async throws -> [String] { [] }
    func review(_ input: ReviewInput, configuration: LangdockConfiguration, key: String) async throws -> [ReviewSuggestion] {
        [ReviewSuggestion(quote: "Another claim.", prefix: "", suffix: "", explanation: "Be precise.", replacement: reviewReplacement)]
    }
    func reply(_ input: ReviewInput, suggestion: ReviewSuggestion, messages: [ReviewMessage], question: String, configuration: LangdockConfiguration, key: String) async throws -> ReviewReply {
        lastSuggestion = suggestion
        try await Task.sleep(for: .milliseconds(5))
        return ReviewReply(answer: "Re: " + question, replacement: replacement)
    }
}
