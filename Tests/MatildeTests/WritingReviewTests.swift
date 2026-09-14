import XCTest
import AppKit
@testable import Matilde

@MainActor
final class WritingReviewTests: XCTestCase {
    private let input = ReviewInput(title: "Example", goal: "Be clear", body: "Hello 🌱. It is very fast.")
    private let suggestion = ReviewSuggestion(quote: "very fast", prefix: "It is ", suffix: ".", explanation: "Use a precise comparison.", replacement: "twice as fast")
    private let configuration = LangdockConfiguration(baseURL: "https://api.langdock.com", region: "eu", model: "test-chat")

    func testStreamedReplyTransportUsesJSONModeAndDeliversText() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReviewURLProtocol.self]
        let client = LangdockClient(session: URLSession(configuration: config))
        ReviewURLProtocol.status = 200
        func event(_ text: String, finish: String? = nil) throws -> String {
            var choice: [String: Any] = ["index": 0, "delta": ["content": text]]
            if let finish { choice["finish_reason"] = finish }
            return "data: " + String(decoding: try JSONSerialization.data(withJSONObject: ["choices": [choice]]), as: UTF8.self) + "\n\n"
        }
        ReviewURLProtocol.body = Data((try event(#"{"answer":"Hello"#) + event(#" there","replacement":null}"#, finish: "stop") + "data: [DONE]\n\n").utf8)
        var updates: [String] = []
        let answer = try await client.streamReply(input, suggestion: suggestion, messages: [], question: "Explain",
            configuration: configuration, key: "synthetic-key") { updates.append($0) }
        XCTAssertEqual(answer.answer, "Hello there")
        XCTAssertEqual(updates.first, "Hello")
        XCTAssertEqual(updates.last, "Hello there")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: ReviewURLProtocol.requestBody) as? [String: Any])
        XCTAssertEqual(payload["stream"] as? Bool, true)
        XCTAssertEqual((payload["response_format"] as? [String: String])?["type"], "json_object")
    }

    func testAnchorsUseUTF16AndRejectAmbiguityAndOverlap() throws {
        let anchor = try XCTUnwrap(WritingReview.anchor(suggestion, in: input.body))
        XCTAssertEqual((input.body as NSString).substring(with: anchor), "very fast")
        XCTAssertEqual(anchor.location, 16)
        let ambiguous = ReviewSuggestion(quote: "word", prefix: "", suffix: "", explanation: "Why?", replacement: nil)
        XCTAssertNil(WritingReview.anchor(ambiguous, in: "word and word"))
        let contextual = ReviewSuggestion(quote: "word", prefix: "and ", suffix: "", explanation: "Why?", replacement: nil)
        XCTAssertEqual(WritingReview.anchor(contextual, in: "word and word")?.location, 9)
        XCTAssertThrowsError(try WritingReview.make(draftID: "one", input: input, model: "test", suggestions: [suggestion, suggestion]))
    }

    func testPersistedHistoryIsIndependentForBranches() throws {
        let workspace = try makeWorkspace()
        let root = try workspace.create(name: "Example", folder: "", goal: input.goal)
        try workspace.save(root, text: input.body)
        let run = try WritingReview.make(draftID: root.id, input: input, model: "test", suggestions: [suggestion])
        try workspace.saveReview(run)
        let branch = try workspace.branch(root, text: input.body)
        XCTAssertTrue(try workspace.reviewHistory(draftID: branch.id).isEmpty)
        let reopened = try Workspace(root: workspace.root)
        XCTAssertEqual(try reopened.reviewHistory(draftID: root.id).first?.comments.first?.suggestion, suggestion)
    }

    func testAcceptanceIsUndoableAndStaleReviewCannotApply() throws {
        let workspace = try makeWorkspace()
        let run = try WritingReview.make(draftID: "one", input: input, model: "test", suggestions: [suggestion])
        try workspace.saveReview(run)
        let model = WritingReviewModel(client: ImmediateReviewClient(suggestions: [suggestion]))
        model.bind(workspace: workspace, draftID: "one", input: input)
        let editor = WritingTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        editor.string = input.body; editor.allowsUndo = true
        let delegate = ReviewUndoDelegate(); editor.delegate = delegate
        delegate.undo.beginUndoGrouping()
        model.accept(runID: run.id, commentID: run.comments[0].id, input: input, editor: editor)
        delegate.undo.endUndoGrouping()
        XCTAssertEqual(editor.string, "Hello 🌱. It is twice as fast.")
        XCTAssertEqual(model.history[0].comments[0].status, "accepted")
        XCTAssertFalse(model.history[0].stale)
        delegate.undo.undo()
        XCTAssertEqual(editor.string, input.body)
        let updated = ReviewInput(title: input.title, goal: input.goal, body: input.body + " Changed.")
        editor.string = updated.body
        model.accept(runID: run.id, commentID: run.comments[0].id, input: updated, editor: editor)
        XCTAssertEqual(editor.string, updated.body)
        XCTAssertNotNil(model.error)
    }

    func testLateResponseAfterEditOrDraftSwitchIsDiscarded() async throws {
        let workspace = try makeWorkspace()
        let client = DelayedReviewClient()
        let model = WritingReviewModel(client: client)
        model.bind(workspace: workspace, draftID: "one", input: input)
        model.start(input: input, configuration: configuration, key: "synthetic-key")
        while client.pending == nil { await Task.yield() }
        model.changed(workspace: workspace, draftID: "one", input: ReviewInput(title: input.title, goal: input.goal, body: input.body + " More."))
        client.pending?.resume(returning: [suggestion]); client.pending = nil
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(model.isRunning)
        XCTAssertTrue(model.history.isEmpty)
        XCTAssertTrue(try workspace.reviewHistory(draftID: "one").isEmpty)

        model.start(input: input, configuration: configuration, key: "synthetic-key")
        while client.pending == nil { await Task.yield() }
        model.bind(workspace: workspace, draftID: "two", input: input)
        client.pending?.resume(returning: [suggestion]); client.pending = nil
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(model.history.isEmpty)
        XCTAssertTrue(try workspace.reviewHistory(draftID: "two").isEmpty)
    }

    func testSuccessfulReviewDismissalAndReopen() async throws {
        let workspace = try makeWorkspace()
        let model = WritingReviewModel(client: ImmediateReviewClient(suggestions: [suggestion]))
        model.bind(workspace: workspace, draftID: "one", input: input)
        model.start(input: input, configuration: configuration, key: "synthetic-key")
        while model.isRunning { await Task.yield() }
        let run = try XCTUnwrap(model.history.first)
        model.dismiss(runID: run.id, commentID: run.comments[0].id)
        let reopened = WritingReviewModel()
        reopened.bind(workspace: workspace, draftID: "one", input: input)
        XCTAssertEqual(reopened.history[0].comments[0].status, "dismissed")
        model.changed(workspace: workspace, draftID: "two", input: ReviewInput(title: "Other", goal: "", body: "Other text"))
        XCTAssertFalse(try XCTUnwrap(workspace.reviewHistory(draftID: "one").first).stale, "Switching drafts must not stale the previous draft's history")
    }

    func testPayloadRedactsImagesAndLocalPathsAndHashIncludesGoal() {
        let source = ReviewInput(title: "Example", goal: "Describe it", body: "![alt](.assets/private.png)\nSee /Users/example/secret.md and file:///private/tmp/test.md")
        XCTAssertFalse(source.transmitted.body.contains("private.png"))
        XCTAssertFalse(source.transmitted.body.contains("secret.md"))
        XCTAssertFalse(source.transmitted.body.contains("test.md"))
        XCTAssertNotEqual(WritingReview.revision(input), WritingReview.revision(ReviewInput(title: input.title, goal: "Different", body: input.body)))
    }

    private func makeWorkspace() throws -> Workspace {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MatildeReviewTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try Workspace(root: url)
    }
}

private final class ReviewUndoDelegate: NSObject, NSTextViewDelegate {
    let undo = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { undo }
}
private struct ImmediateReviewClient: LangdockServing {
    let suggestions: [ReviewSuggestion]
    func models(configuration: LangdockConfiguration, key: String) async throws -> [String] { ["test-chat"] }
    func review(_ input: ReviewInput, configuration: LangdockConfiguration, key: String) async throws -> [ReviewSuggestion] { suggestions }
}
private final class DelayedReviewClient: LangdockServing {
    var pending: CheckedContinuation<[ReviewSuggestion], Error>?
    func models(configuration: LangdockConfiguration, key: String) async throws -> [String] { [] }
    func review(_ input: ReviewInput, configuration: LangdockConfiguration, key: String) async throws -> [ReviewSuggestion] {
        try await withCheckedThrowingContinuation { pending = $0 }
    }
}

final class LangdockClientTests: XCTestCase {
    func testEndpointValidationAndDedicatedPaths() throws {
        XCTAssertEqual(try LangdockConfiguration(baseURL: "https://example.com/api/public", region: "eu", model: "").endpoint("models").absoluteString, "https://example.com/api/public/openai/eu/v1/models")
        for base in ["http://example.com", "https://user:password@example.com", "https://example.com?key=secret"] {
            XCTAssertThrowsError(try LangdockConfiguration(baseURL: base, region: "eu", model: "").endpoint("models"))
        }
    }
    func testRejectsTruncationMalformedOutputAndUnboundedComments() throws {
        func envelope(_ content: String, reason: String = "stop") throws -> Data {
            try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": reason, "message": ["content": content]]]])
        }
        XCTAssertEqual(try LangdockClient.decode(envelope("{\"comments\":[]}")), [])
        XCTAssertThrowsError(try LangdockClient.decode(envelope("{\"comments\":[]}", reason: "length")))
        XCTAssertThrowsError(try LangdockClient.decode(envelope("```json\n{}\n```")))
        XCTAssertThrowsError(try LangdockClient.decode(envelope("{\"comments\":[{\"quote\":\"\"}]}")))
    }
    func testCompletionRequestIncludesOnlyReviewContextAndValidatesOutput() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReviewURLProtocol.self]
        let client = LangdockClient(session: URLSession(configuration: config))
        ReviewURLProtocol.status = 200
        ReviewURLProtocol.body = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": "{\"comments\":[]}"]]]])
        let input = ReviewInput(title: "Synthetic", goal: "Explain clearly", body: "A synthetic draft. ![image](.assets/test.png)")
        let comments = try await client.review(input, configuration: LangdockConfiguration(baseURL: "https://api.langdock.com", region: "eu", model: "test-chat"), key: "synthetic-key")
        XCTAssertTrue(comments.isEmpty)
        let request = try XCTUnwrap(ReviewURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/openai/eu/v1/chat/completions")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: ReviewURLProtocol.requestBody) as? [String: Any])
        XCTAssertEqual(payload["model"] as? String, "test-chat")
        let messages = try XCTUnwrap(payload["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages[1]["content"]?.contains("Explain clearly") == true)
        XCTAssertFalse(messages[1]["content"]?.contains("test.png") == true)
    }

    func testHTTPClientUsesExpectedRequestAndDoesNotEchoProviderErrors() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReviewURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = LangdockClient(session: session)
        ReviewURLProtocol.status = 200
        ReviewURLProtocol.body = Data("{\"data\":[{\"id\":\"chat-test\"}]}".utf8)
        let connection = LangdockConfiguration(baseURL: "https://api.langdock.com", region: "eu", model: "chat-test")
        let models = try await client.models(configuration: connection, key: "synthetic-key")
        XCTAssertEqual(models, ["chat-test"])
        XCTAssertEqual(ReviewURLProtocol.lastRequest?.url?.path, "/openai/eu/v1/models")
        XCTAssertEqual(ReviewURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
        ReviewURLProtocol.status = 401
        ReviewURLProtocol.body = Data("private upstream detail".utf8)
        do { _ = try await client.models(configuration: connection, key: "synthetic-key"); XCTFail("Expected authorization failure") }
        catch { XCTAssertFalse(error.localizedDescription.contains("private upstream detail")) }
    }
}
private final class ReviewURLProtocol: URLProtocol {
    static var status = 200
    static var body = Data()
    static var lastRequest: URLRequest?
    static var requestBody = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        Self.requestBody = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                Self.requestBody.append(contentsOf: buffer.prefix(count))
            }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
