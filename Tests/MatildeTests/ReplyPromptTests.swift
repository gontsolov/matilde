import XCTest
import Combine
@testable import Matilde

/// Ask Matilde chat requests: whole draft as context, marked focus, cache-stable prefix.
@MainActor
final class ReplyPromptTests: XCTestCase {
    private let system = WritingAssistPrompt.reply(guidance: WritingAssistPrompt.defaultGuidance)
    private let configuration = LangdockConfiguration(baseURL: "https://api.langdock.com", region: "eu", model: "synthetic")

    private func longDraft(_ marker: String = "") -> ReviewInput {
        let sections = (1...30).map { "## Section \($0)\n\nSynthetic paragraph \($0) about tides and 🌊 currents.\(marker)" }
        return ReviewInput(title: "Synthetic", goal: "Explain tides", body: sections.joined(separator: "\n\n"))
    }
    private func focus(in input: ReviewInput, _ quote: String) -> ReviewSuggestion {
        let range = (input.body as NSString).range(of: quote)
        let comment = CommentAnchor.refreshed(ReviewComment(id: UUID(), suggestion: ReviewSuggestion(quote: quote, prefix: "", suffix: "", explanation: "", replacement: nil),
                                                            location: range.location, length: range.length), range: range, in: input.body)
        return comment.suggestion
    }
    private func render(_ messages: [ReplyConversation.Message]) -> String {
        messages.map { "\($0.role)\u{0}\($0.content)\u{0}" }.joined()
    }

    func testWholeDocumentIsSentAndSelectionIsMarkedAsFocus() throws {
        let input = longDraft()
        let quote = "Synthetic paragraph 17 about tides"
        let conversation = ReplyPrompt.prepare(input: input, suggestion: focus(in: input, quote), writerStarted: true,
                                               context: nil, prior: [], question: "Is this clear?")
        let messages = conversation.messages(system: system)
        XCTAssertEqual(messages.map(\.role), ["system", "user", "user", "user"])
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(messages[1].content.utf8)) as? [String: Any])
        let draft = try XCTUnwrap(document["draft"] as? [String: String])
        XCTAssertEqual(draft["body"], input.body)
        XCTAssertEqual(draft["title"], input.title)
        XCTAssertEqual(draft["goal"], input.goal)
        let turn = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(messages[3].content.utf8)) as? [String: Any])
        let marked = try XCTUnwrap(turn["focus"] as? [String: String])
        XCTAssertEqual(marked["passage"], quote)
        XCTAssertTrue(input.body.contains((marked["before"] ?? "") + quote + (marked["after"] ?? "")))
        XCTAssertFalse(marked["before"]?.isEmpty ?? true)
        XCTAssertEqual(turn["question"] as? String, "Is this clear?")
        XCTAssertNil(turn["draft_update"])
        XCTAssertTrue(messages[2].content.contains("\"started_by\":\"writer\""))
        // The draft message is the same for every thread on this draft, so threads share it too.
        let other = ReplyPrompt.prepare(input: input, suggestion: focus(in: input, "Section 3"), context: nil, prior: [], question: "Why?")
        XCTAssertEqual(other.messages(system: system)[1], messages[1])
    }

    func testPrefixIsByteIdenticalAndHistoryAppendOnlyAcrossTurns() throws {
        var input = longDraft()
        let suggestion = focus(in: input, "Synthetic paragraph 5 about tides")
        var context: ReplyContext?
        var prior: [ReviewMessage] = []
        var previous: [ReplyConversation.Message] = []
        for turn in 1...4 {
            if turn == 3 { input = ReviewInput(title: input.title, goal: input.goal, body: input.body.replacingOccurrences(of: "paragraph 20", with: "passage twenty")) }
            let conversation = ReplyPrompt.prepare(input: input, suggestion: suggestion, context: context, prior: prior, question: "Question \(turn)")
            // Same inputs, same bytes.
            let again = ReplyPrompt.prepare(input: input, suggestion: suggestion, context: context, prior: prior, question: "Question \(turn)")
            XCTAssertEqual(again.messages(system: system), conversation.messages(system: system))
            let messages = conversation.messages(system: system)
            XCTAssertTrue(render(messages).hasPrefix(render(previous)), "turn \(turn) rewrote earlier messages")
            XCTAssertEqual(Array(messages.prefix(previous.count)), previous)
            XCTAssertEqual(messages.count, previous.count + (turn == 1 ? 4 : 1))
            if turn == 3 {
                let update = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(messages.last!.content.utf8)) as? [String: Any])
                let edit = try XCTUnwrap((update["draft_update"] as? [String: Any])?["body_edit"] as? [String: String])
                XCTAssertEqual(edit["removed"].map { $0.count < 20 }, true)
                XCTAssertTrue((edit["inserted"] ?? "").contains("twenty") || (edit["inserted"] ?? "").contains("ssage"))
                // The document block still holds the draft from the thread start.
                XCTAssertTrue(messages[1].content.contains("paragraph 20"))
            } else {
                XCTAssertFalse(messages.last!.content.contains("draft_update"))
            }
            // Commit as the model does after a delivered reply.
            var committed = conversation.context
            committed.known = input.transmitted
            context = committed
            prior.append(ReviewMessage(role: "user", text: "Question \(turn)", delivery: "sent", prompt: conversation.turn))
            var reply = ReviewMessage(role: "assistant", text: "Answer \(turn)")
            reply.replacement = turn == 2 ? "A rewrite." : nil
            prior.append(reply)
            previous = messages + [ReplyConversation.Message(role: "assistant", content: ReplyPrompt.assistant(reply))]
        }
        // No message IDs leak into the prompt.
        for id in prior.map(\.id) { XCTAssertFalse(render(previous).contains(id.uuidString)) }
    }

    func testOversizedHistoryRebuildsOnceThenStaysAppendOnly() throws {
        let input = longDraft()
        let suggestion = focus(in: input, "Synthetic paragraph 2 about tides")
        let big = String(repeating: "word ", count: 1500)
        var prior: [ReviewMessage] = []
        for index in 0..<40 {
            prior.append(ReviewMessage(role: index.isMultiple(of: 2) ? "user" : "assistant", text: "\(index) " + big, delivery: "sent"))
        }
        let first = ReplyPrompt.prepare(input: input, suggestion: suggestion, context: nil, prior: prior, question: "Next?")
        XCTAssertTrue(first.history.isEmpty)
        XCTAssertEqual(first.context.replayAfter, prior.last?.id)
        XCTAssertTrue(first.context.thread.contains("earlier_messages"))
        XCTAssertTrue(first.context.document.contains(input.body.replacingOccurrences(of: "\n", with: "\\n")))
        var committed = first.context
        committed.known = input.transmitted
        let sent = ReviewMessage(role: "user", text: "Next?", delivery: "sent", prompt: first.turn)
        let answer = ReviewMessage(role: "assistant", text: "Fine.")
        let second = ReplyPrompt.prepare(input: input, suggestion: suggestion, context: committed, prior: prior + [sent, answer], question: "And?")
        XCTAssertEqual(second.history.map(\.id), [sent.id, answer.id])
        XCTAssertEqual(Array(second.messages(system: system).prefix(4)), first.messages(system: system))
    }

    func testLargeEditsSendTheFullBodyAndScrubbedDraftUpdates() throws {
        let old = ReviewInput(title: "A", goal: "B", body: "Start. End.")
        let small = ReviewInput(title: "A2", goal: "B", body: "Start. Middle ![x](/Users/x/a.png). End.").transmitted
        let update = try XCTUnwrap(ReplyPrompt.update(from: old, to: small))
        XCTAssertEqual(update.title, "A2")
        XCTAssertNil(update.goal)
        XCTAssertEqual(update.body_edit?.before, "Start. ")
        XCTAssertTrue(update.body_edit?.inserted.contains("[Image omitted]") == true)
        XCTAssertFalse(ReplyPrompt.encode(update).contains("/Users/"))
        let large = ReviewInput(title: "A", goal: "B", body: String(repeating: "New text. ", count: 3000))
        XCTAssertEqual(ReplyPrompt.update(from: old, to: large)?.body, large.body)
        XCTAssertNil(ReplyPrompt.update(from: old, to: old))
    }

    func testModelPersistsTurnsAndReplaysThemUnchanged() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/reply-prompt-tests/\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let workspace = try Workspace(root: root)
        let client = CapturingClient()
        let model = WritingReviewModel(client: client)
        var input = longDraft()
        model.bind(workspace: workspace, draftID: "a", input: input)
        model.beginSelection((input.body as NSString).range(of: "Synthetic paragraph 9 about tides"), input: input)
        let run = try XCTUnwrap(model.history.first), comment = try XCTUnwrap(run.comments.first)
        model.reply(runID: run.id, commentID: comment.id, text: "First?", input: input, configuration: configuration, key: "test-only")
        await waitUntilIdle(model)
        input = ReviewInput(title: input.title, goal: input.goal, body: input.body + "\n\nA new closing line.")
        model.invalidate(input)
        model.reply(runID: run.id, commentID: comment.id, text: "Second?", input: input, configuration: configuration, key: "test-only")
        await waitUntilIdle(model)
        model.reply(runID: run.id, commentID: comment.id, text: "Third?", input: input, configuration: configuration, key: "test-only")
        await waitUntilIdle(model)

        XCTAssertEqual(client.conversations.count, 3)
        let requests = client.conversations.map { $0.messages(system: system) }
        for (earlier, later) in zip(requests, requests.dropFirst()) {
            XCTAssertEqual(Array(later.prefix(earlier.count)), earlier)
            XCTAssertEqual(later.count, earlier.count + 2)
        }
        XCTAssertTrue(requests[1].last!.content.contains("A new closing line."))
        XCTAssertFalse(requests[2].last!.content.contains("draft_update"))
        // Survives a reload from SQLite.
        let stored = try XCTUnwrap(workspace.reviewHistory(draftID: "a").first?.comments.first)
        XCTAssertNotNil(stored.replyContext)
        XCTAssertEqual(stored.replyContext?.known, input.transmitted)
        XCTAssertEqual(stored.messages?.filter { $0.role == "user" }.compactMap(\.prompt), client.conversations.map(\.turn))
    }

    func testLegacyCommentsAndMessagesStillDecode() throws {
        let message = try JSONDecoder().decode(ReviewMessage.self, from: Data(#"{"id":"\#(UUID().uuidString)","role":"user","text":"Old"}"#.utf8))
        XCTAssertNil(message.prompt)
        let run = try WritingReview.make(draftID: "a", input: longDraft(), model: "fake", suggestions: [])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(run)) as? [String: Any])
        json["comments"] = [["id": UUID().uuidString, "suggestion": ["quote": "Section 1", "prefix": "", "suffix": "", "explanation": "Why?"], "location": 3, "length": 9, "status": "open"]]
        let decoded = try JSONDecoder().decode(WritingReview.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.comments.first?.replyContext)
    }

    private func waitUntilIdle(_ model: WritingReviewModel) async {
        let completed = expectation(description: "Request finishes")
        let observation = model.$isRunning.filter { !$0 }.first().sink { _ in completed.fulfill() }
        await fulfillment(of: [completed], timeout: 5)
        withExtendedLifetime(observation) {}
    }
}

@MainActor
private final class CapturingClient: LangdockServing {
    var conversations: [ReplyConversation] = []
    func models(configuration: LangdockConfiguration, key: String) async throws -> [String] { [] }
    func review(_ input: ReviewInput, configuration: LangdockConfiguration, key: String) async throws -> [ReviewSuggestion] { [] }
    func streamReply(_ conversation: ReplyConversation, configuration: LangdockConfiguration, key: String, onText: @escaping @MainActor (String) -> Void) async throws -> ReviewReply {
        conversations.append(conversation)
        return ReviewReply(answer: "Answer \(conversations.count)", replacement: conversations.count == 1 ? "A rewrite." : nil)
    }
}
