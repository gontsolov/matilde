import Foundation

public struct LangdockConfiguration: Equatable {
    public var baseURL: String
    public var region: String
    public var model: String
    /// Editable behaviour guidance; the fixed task and response format are added per request.
    public var guidance: String = WritingAssistPrompt.defaultGuidance
    public static var current: Self {
        let defaults = UserDefaults.standard
        return Self(baseURL: defaults.string(forKey: "langdock.baseURL") ?? "https://api.langdock.com",
                    region: defaults.string(forKey: "langdock.region") ?? "eu",
                    model: defaults.string(forKey: "langdock.model") ?? "",
                    guidance: WritingAssistPrompt.guidance(defaults))
    }
    public func endpoint(_ path: String) throws -> URL {
        guard var url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, ["eu", "us"].contains(region) else {
            throw ReviewError.message("Enter a valid HTTPS Langdock API address in Settings.")
        }
        url.appendPathComponent("openai/\(region)/v1/\(path)")
        return url
    }

    public init(baseURL: String, region: String, model: String, guidance: String = WritingAssistPrompt.defaultGuidance) {
        self.baseURL = baseURL
        self.region = region
        self.model = model
        self.guidance = guidance
    }
}

public enum ReviewError: LocalizedError {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let text): return text } }
}

public struct ReviewInput: Codable, Equatable {
    public let title: String
    public let goal: String
    public let body: String
    public var transmitted: Self {
        func scrub(_ text: String) -> String {
            var value = text.replacingOccurrences(of: #"!\[[^\]\n]*\]\([^\n]*?\)"#, with: "[Image omitted]", options: .regularExpression)
            value = value.replacingOccurrences(of: #"(?:file://[^\s)]+|/(?:Users|home|private|Volumes|var|tmp)/[^\s)]+)"#, with: "[Local path omitted]", options: .regularExpression)
            return value
        }
        return Self(title: scrub(title), goal: scrub(goal), body: scrub(body))
    }

    public init(title: String, goal: String, body: String) {
        self.title = title
        self.goal = goal
        self.body = body
    }
}

public struct ReviewSuggestion: Codable, Equatable {
    public let quote: String
    public let prefix: String
    public let suffix: String
    public let explanation: String
    public let replacement: String?

    public init(quote: String, prefix: String, suffix: String, explanation: String, replacement: String?) {
        self.quote = quote
        self.prefix = prefix
        self.suffix = suffix
        self.explanation = explanation
        self.replacement = replacement
    }
}

public struct ReviewReply: Codable {
    public let answer: String
    public let replacement: String?

    public init(answer: String, replacement: String?) {
        self.answer = answer
        self.replacement = replacement
    }
}

public protocol LangdockServing {
    func streamReply(_ input: ReviewInput, suggestion: ReviewSuggestion, messages: [ReviewMessage], question: String, configuration: LangdockConfiguration, key: String, onText: @escaping @MainActor (String) -> Void) async throws -> ReviewReply
    func reply(_ input: ReviewInput, suggestion: ReviewSuggestion, messages: [ReviewMessage], question: String, configuration: LangdockConfiguration, key: String) async throws -> ReviewReply
    /// Chat reply laid out for prompt caching (see `ReplyContext`).
    func streamReply(_ conversation: ReplyConversation, configuration: LangdockConfiguration, key: String, onText: @escaping @MainActor (String) -> Void) async throws -> ReviewReply
    func models(configuration: LangdockConfiguration, key: String) async throws -> [String]
    func review(_ input: ReviewInput, configuration: LangdockConfiguration, key: String) async throws -> [ReviewSuggestion]
}

extension LangdockServing {
    public func streamReply(_ conversation: ReplyConversation, configuration: LangdockConfiguration, key: String, onText: @escaping @MainActor (String) -> Void) async throws -> ReviewReply {
        try await streamReply(conversation.input, suggestion: conversation.suggestion, messages: conversation.history,
                              question: conversation.question, configuration: configuration, key: key, onText: onText)
    }
    public func streamReply(_ input: ReviewInput, suggestion: ReviewSuggestion, messages: [ReviewMessage], question: String, configuration: LangdockConfiguration, key: String, onText: @escaping @MainActor (String) -> Void) async throws -> ReviewReply {
        let answer = try await reply(input, suggestion: suggestion, messages: messages, question: question, configuration: configuration, key: key)
        await onText(answer.answer)
        return answer
    }
    public func reply(_ input: ReviewInput, suggestion: ReviewSuggestion, messages: [ReviewMessage], question: String,
               configuration: LangdockConfiguration, key: String) async throws -> ReviewReply {
        throw ReviewError.message("Replies are unavailable for this provider.")
    }
}

// The HTTPS client streams with URLSession.bytes, which Linux Foundation lacks; the request and
// response types above stay platform-neutral so Linux tests still cover them.
#if canImport(Darwin)
/// No cookies, disk cache, redirects, or logging of credentials/writing.
private final class LangdockRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public final class LangdockClient: NSObject, LangdockServing {
    private var session: URLSession!
    public override init() {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 90
        config.httpCookieStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: LangdockRedirectBlocker(), delegateQueue: nil)
    }
    public init(session: URLSession) { super.init(); self.session = session }
    deinit { session.invalidateAndCancel() }

    private func request(_ path: String, body: Data? = nil, configuration: LangdockConfiguration, key: String, onText: (@MainActor (String) -> Void)? = nil) async throws -> Data {
        guard !key.isEmpty else { throw ReviewError.message("Add your Langdock API key in Settings → Connections.") }
        var request = URLRequest(url: try configuration.endpoint(path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        for attempt in 0...1 {
            try Task.checkCancellation()
            do {
                let (bytes, response) = try await session.bytes(for: request)
                guard let response = response as? HTTPURLResponse else { throw ReviewError.message("Langdock returned an invalid response.") }
                if response.statusCode == 429, attempt == 0 {
                    // Bounded wait; cancellation remains effective during backoff.
                    let delay = min(max(Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 2, 1), 10)
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }
                switch response.statusCode {
                case 200...299: break
                case 401, 403: throw ReviewError.message("Langdock could not authorize this key. Check its Completion API access in Settings.")
                case 429: throw ReviewError.message("Langdock is busy. Try reviewing again shortly.")
                case 400, 404, 422: throw ReviewError.message("Langdock could not use this model or request. Check the API address and choose a chat model with JSON support in Settings.")
                default: throw ReviewError.message("Langdock is unavailable (HTTP \(response.statusCode)). Try again later.")
                }
                if let onText {
                    defer { bytes.task.cancel() }
                    var stream = LangdockReplyStream()
                    var line = Data()
                    var count = 0
                    var lastUpdate = Date.distantPast
                    var displayed = ""
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        count += 1
                        guard count <= 1_048_576 else { throw ReviewError.message("Langdock’s response was too large.") }
                        if byte == 10 {
                            try stream.consume(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .newlines))
                            line.removeAll(keepingCapacity: true)
                            if Date().timeIntervalSince(lastUpdate) >= 0.04 || stream.done {
                                let text = stream.answer
                                if text != displayed { await onText(text); displayed = text; lastUpdate = Date() }
                            }
                            if stream.done { return try stream.completedResponse() }
                        } else { line.append(byte) }
                    }
                    if !line.isEmpty { try stream.consume(String(decoding: line, as: UTF8.self)) }
                    return try stream.completedResponse()
                }
                var data = Data()
                for try await byte in bytes {
                    if data.count >= 1_048_576 { throw ReviewError.message("Langdock’s response was too large.") }
                    data.append(byte)
                }
                try Task.checkCancellation()
                return data
            } catch is CancellationError { throw CancellationError() }
            catch let error as ReviewError { throw error }
            catch let error as URLError where error.code == .cancelled { throw CancellationError() }
            catch { throw ReviewError.message("Couldn’t reach Langdock. Check your connection and try again.") }
        }
        throw ReviewError.message("Langdock is busy. Try again shortly.")
    }

    public func models(configuration: LangdockConfiguration, key: String) async throws -> [String] {
        struct Models: Decodable { struct Model: Decodable { let id: String }; let data: [Model] }
        let data = try await request("models", configuration: configuration, key: key)
        guard let response = try? JSONDecoder().decode(Models.self, from: data) else { throw ReviewError.message("Langdock returned an unreadable model list.") }
        return Array(Set(response.data.map(\.id))).sorted()
    }

    public func review(_ input: ReviewInput, configuration: LangdockConfiguration, key: String) async throws -> [ReviewSuggestion] {
        guard !configuration.model.isEmpty else { throw ReviewError.message("Choose a Langdock model in Settings → Connections.") }
        guard input.body.utf8.count <= 100_000, input.title.utf8.count + input.goal.utf8.count <= 10_000 else {
            throw ReviewError.message("This draft is too long for a review. The current limit is 100 KB of writing and 10 KB of title and goal.")
        }
        struct Message: Encodable { let role: String; let content: String }
        struct Request: Encodable {
            public let model: String
            public let messages: [Message]
            public let response_format = ["type": "json_object"]
            public let max_completion_tokens = 4000
            public let stream = false
        }
        let context = ReplyPrompt.encode(input.transmitted)
        let body = try Self.encoder.encode(Request(model: configuration.model, messages: [
            Message(role: "system", content: WritingAssistPrompt.review(guidance: configuration.guidance)), Message(role: "user", content: context)
        ]))
        return try Self.decode(try await request("chat/completions", body: body, configuration: configuration, key: key))
    }

    public func reply(_ input: ReviewInput, suggestion: ReviewSuggestion, messages: [ReviewMessage], question: String,
               configuration: LangdockConfiguration, key: String) async throws -> ReviewReply {
        try await performReply(ReplyPrompt.prepare(input: input, suggestion: suggestion, context: nil, prior: messages, question: question),
                               configuration: configuration, key: key)
    }
    public func streamReply(_ input: ReviewInput, suggestion: ReviewSuggestion, messages: [ReviewMessage], question: String, configuration: LangdockConfiguration, key: String, onText: @escaping @MainActor (String) -> Void) async throws -> ReviewReply {
        try await performReply(ReplyPrompt.prepare(input: input, suggestion: suggestion, context: nil, prior: messages, question: question),
                               configuration: configuration, key: key, onText: onText)
    }
    public func streamReply(_ conversation: ReplyConversation, configuration: LangdockConfiguration, key: String, onText: @escaping @MainActor (String) -> Void) async throws -> ReviewReply {
        try await performReply(conversation, configuration: configuration, key: key, onText: onText)
    }
    /// Sorted keys keep request bytes deterministic.
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
    private func performReply(_ conversation: ReplyConversation, configuration: LangdockConfiguration, key: String,
                              onText: (@MainActor (String) -> Void)? = nil) async throws -> ReviewReply {
        let input = conversation.input
        guard !configuration.model.isEmpty, input.body.utf8.count <= 100_000,
              input.title.utf8.count + input.goal.utf8.count <= 10_000, conversation.question.utf8.count <= 8000 else {
            throw ReviewError.message("Choose a model and keep the draft and reply within the review limits.")
        }
        struct Request: Encodable {
            public let model: String
            public let messages: [ReplyConversation.Message]
            public let response_format = ["type": "json_object"]
            public let max_completion_tokens = 4000
            public let stream: Bool
        }
        let body = try Self.encoder.encode(Request(model: configuration.model,
            messages: conversation.messages(system: WritingAssistPrompt.reply(guidance: configuration.guidance)), stream: onText != nil))
        return try Self.decodeReply(try await request("chat/completions", body: body, configuration: configuration, key: key, onText: onText))
    }
    public static func decodeReply(_ data: Data) throws -> ReviewReply {
        struct Response: Decodable {
            public struct Choice: Decodable { struct Message: Decodable { let content: String?; let refusal: String? }; let message: Message; let finish_reason: String }
            public let choices: [Choice]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), let choice = response.choices.first,
              choice.finish_reason == "stop", choice.message.refusal == nil, let text = choice.message.content,
              let reply = try? JSONDecoder().decode(ReviewReply.self, from: Data(text.utf8)),
              !reply.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              reply.answer.utf8.count <= 8000, (reply.replacement?.utf8.count ?? 0) <= 16000 else {
            throw ReviewError.message("Langdock didn’t return a complete reply in the expected format.")
        }
        return reply
    }

    public static func decode(_ data: Data) throws -> [ReviewSuggestion] {
        struct Response: Decodable {
            public struct Choice: Decodable { struct Message: Decodable { let content: String?; let refusal: String? }; let message: Message; let finish_reason: String }
            public let choices: [Choice]
        }
        struct Payload: Decodable { let comments: [ReviewSuggestion] }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), let choice = response.choices.first,
              choice.finish_reason == "stop", choice.message.refusal == nil,
              let content = choice.message.content, let payload = try? JSONDecoder().decode(Payload.self, from: Data(content.utf8)),
              payload.comments.count <= 3,
              payload.comments.allSatisfy({ !$0.quote.isEmpty && $0.quote.utf8.count <= 8000 && !$0.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.explanation.utf8.count <= 4000 && ($0.replacement?.utf8.count ?? 0) <= 16000 && $0.prefix.utf8.count <= 1000 && $0.suffix.utf8.count <= 1000 }) else {
            throw ReviewError.message("Langdock didn’t return a complete review in the expected format. Try again or choose another model.")
        }
        return payload.comments
    }
}
#endif
