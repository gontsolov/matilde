import Foundation

/// Per-thread prompt state for Ask Matilde chats, saved with the comment in SQLite.
///
/// Chat requests are laid out so a provider's automatic prefix cache can reuse as much as
/// possible between turns (Langdock's OpenAI-compatible endpoint caches long shared prefixes
/// automatically and has no explicit breakpoints):
///
/// 1. system: guidance + fixed task/format (`WritingAssistPrompt.reply`), identical for every thread
/// 2. user: the whole draft as it was when the thread started (`document`)
/// 3. user: the comment being discussed (`thread`)
/// 4. the earlier turns, replayed byte for byte from what was sent (`ReviewMessage.prompt`)
/// 5. user: the newest turn: question, focus passage and any draft edits since the previous turn
///
/// Everything before the newest turn is frozen once sent, so consecutive turns share it exactly.
struct ReplyContext: Codable, Equatable {
    /// Exact content of the draft message.
    var document: String
    /// Exact content of the thread-start message.
    var thread: String
    /// The scrubbed draft as the conversation last described it; the next update is relative to it.
    var known: ReviewInput
    /// Messages up to and including this one were folded into `thread` when the context was rebuilt.
    var replayAfter: UUID? = nil
}

/// Everything one chat request needs. `context` is committed to the comment only after success.
struct ReplyConversation {
    let context: ReplyContext
    /// Delivered messages replayed after the thread-start message.
    let history: [ReviewMessage]
    /// Exact content of the newest user message, stored as its `prompt`.
    let turn: String
    // Plain values for providers that don't build their own prompt.
    let input: ReviewInput
    let suggestion: ReviewSuggestion
    let question: String

    struct Message: Codable, Equatable {
        let role: String
        let content: String
    }

    /// The chat messages in cache order.
    func messages(system: String) -> [Message] {
        var result = [Message(role: "system", content: system),
                      Message(role: "user", content: context.document),
                      Message(role: "user", content: context.thread)]
        result += history.map { message in
            message.role == "assistant"
                ? Message(role: "assistant", content: ReplyPrompt.assistant(message))
                : Message(role: "user", content: message.prompt ?? ReplyPrompt.legacyTurn(message.text))
        }
        result.append(Message(role: "user", content: turn))
        return result
    }
}

enum ReplyPrompt {
    /// Replayed turns plus the newest one may use this many bytes before the context is rebuilt
    /// from the current draft (one cache miss, then append-only again).
    static let historyBudget = 120_000
    /// Larger body edits are sent as the full new body instead of a removed/inserted pair.
    static let editBudget = 16_000
    static let contextLength = 80
    static let foldedMessages = 12

    /// Sorted keys and fixed escaping: the same values always produce the same bytes.
    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(value)) ?? Data("null".utf8), as: UTF8.self)
    }

    static func scrub(_ text: String) -> String { ReviewInput(title: "", goal: "", body: text).transmitted.body }

    private struct DocumentBlock: Encodable { let draft: ReviewInput }
    private struct ThreadBlock: Encodable {
        struct Comment: Encodable {
            let started_by: String
            let explanation: String?
            let quote: String
            let replacement: String?
        }
        struct Earlier: Encodable { let role: String; let text: String }
        let comment: Comment
        let earlier_messages: [Earlier]?
    }
    struct Focus: Encodable, Equatable {
        let before: String
        let passage: String
        let after: String
    }
    struct BodyEdit: Encodable, Equatable {
        let before: String
        let removed: String
        let inserted: String
        let after: String
    }
    struct DraftUpdate: Encodable, Equatable {
        var title: String? = nil
        var goal: String? = nil
        var body_edit: BodyEdit? = nil
        var body: String? = nil
    }
    private struct Turn: Encodable {
        let draft_update: DraftUpdate?
        let focus: Focus
        let question: String
    }
    private struct LegacyTurn: Encodable { let question: String }

    static func legacyTurn(_ text: String) -> String { encode(LegacyTurn(question: scrub(text))) }

    /// Assistant replies are replayed in the shape they were requested in, answer first.
    static func assistant(_ message: ReviewMessage) -> String {
        "{\"answer\":" + encode(scrub(message.text)) + ",\"replacement\":" + (message.replacement.map { encode(scrub($0)) } ?? "null") + "}"
    }

    static func document(_ draft: ReviewInput) -> String { encode(DocumentBlock(draft: draft)) }

    /// Prepare the next request of a thread. `prior` are its delivered messages, oldest first.
    static func prepare(input: ReviewInput, suggestion: ReviewSuggestion, writerStarted: Bool = false,
                        initialReplacement: String? = nil, context: ReplyContext?, prior: [ReviewMessage],
                        question: String) -> ReplyConversation {
        let current = input.transmitted
        let focus = Focus(before: scrub(suggestion.prefix), passage: scrub(suggestion.quote), after: scrub(suggestion.suffix))
        let cleanQuestion = scrub(question)
        func threadBlock(earlier: [ReviewMessage]) -> String {
            let explanation = scrub(suggestion.explanation)
            return encode(ThreadBlock(comment: .init(started_by: writerStarted ? "writer" : "review",
                                                     explanation: explanation.isEmpty ? nil : explanation,
                                                     quote: focus.passage, replacement: initialReplacement.map(scrub)),
                                      earlier_messages: earlier.isEmpty ? nil : earlier.map { .init(role: $0.role, text: scrub($0.text)) }))
        }
        func fresh(earlier: [ReviewMessage], replayAfter: UUID?) -> ReplyContext {
            ReplyContext(document: document(current), thread: threadBlock(earlier: earlier), known: current, replayAfter: replayAfter)
        }
        func replayed(_ context: ReplyContext) -> [ReviewMessage] {
            guard let marker = context.replayAfter else { return prior }
            guard let index = prior.firstIndex(where: { $0.id == marker }) else { return [] }
            return Array(prior[(index + 1)...])
        }
        func turn(_ update: DraftUpdate?) -> String { encode(Turn(draft_update: update, focus: focus, question: cleanQuestion)) }

        var context = context ?? fresh(earlier: [], replayAfter: nil)
        var history = replayed(context)
        var content = turn(update(from: context.known, to: current))
        let size = history.reduce(content.utf8.count) { total, message in
            total + (message.role == "assistant" ? assistant(message) : message.prompt ?? legacyTurn(message.text)).utf8.count
        }
        if size > historyBudget {
            // Rebuild once from the current draft, keeping the latest messages as plain text.
            context = fresh(earlier: Array(prior.suffix(foldedMessages)), replayAfter: prior.last?.id)
            history = []
            content = turn(nil)
        }
        return ReplyConversation(context: context, history: history, turn: content,
                                 input: input, suggestion: suggestion, question: question)
    }

    /// What changed between two scrubbed drafts, or nil when nothing did.
    static func update(from old: ReviewInput, to new: ReviewInput) -> DraftUpdate? {
        var update = DraftUpdate()
        if old.title != new.title { update.title = new.title }
        if old.goal != new.goal { update.goal = new.goal }
        if old.body != new.body {
            let before = Array(old.body), after = Array(new.body)
            var prefix = 0
            while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
            var suffix = 0
            while suffix < min(before.count, after.count) - prefix,
                  before[before.count - suffix - 1] == after[after.count - suffix - 1] { suffix += 1 }
            let removed = String(before[prefix..<(before.count - suffix)])
            let inserted = String(after[prefix..<(after.count - suffix)])
            if removed.utf8.count + inserted.utf8.count > editBudget {
                update.body = new.body
            } else {
                update.body_edit = BodyEdit(before: String(after[max(0, prefix - contextLength)..<prefix]), removed: removed, inserted: inserted,
                                            after: String(after[(after.count - suffix)..<min(after.count, after.count - suffix + contextLength)]))
            }
        }
        return update == DraftUpdate() ? nil : update
    }
}

extension ReviewComment {
    /// The next chat request for this thread, given its delivered messages.
    func replyConversation(input: ReviewInput, prior: [ReviewMessage], question: String) -> ReplyConversation {
        ReplyPrompt.prepare(input: input, suggestion: suggestion, writerStarted: userInitiated == true,
                            initialReplacement: rewriteMessageID == nil ? suggestion.replacement : initialReplacement,
                            context: replyContext, prior: prior, question: question)
    }
}
