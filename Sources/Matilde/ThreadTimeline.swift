import Foundation

/// A rewrite Matilde offered in a thread: the review's own, before any chat, or one that came
/// with a reply.
struct ThreadSuggestion: Equatable {
    /// The assistant message it came with; `nil` for the review's own suggestion.
    let messageID: UUID?
    let replacement: String
    /// Only the latest rewrite can be accepted; earlier ones stay in place as history.
    let isCurrent: Bool
}

enum ThreadTimelineItem: Equatable, Identifiable {
    case suggestion(ThreadSuggestion)
    /// `index` is the message's position in the thread, for speaker labels.
    case message(index: Int, ReviewMessage)

    var id: String {
        switch self {
        case let .suggestion(suggestion): "suggestion-" + (suggestion.messageID?.uuidString ?? "review")
        case let .message(_, message): "message-" + message.id.uuidString
        }
    }
}

/// One chronological list of a thread's messages and suggested rewrites, so each rewrite shows
/// where it was offered instead of above the conversation.
enum ThreadTimeline {
    static func items(for comment: ReviewComment) -> [ThreadTimelineItem] {
        let messages = comment.messages ?? []
        let current = comment.suggestion.replacement
        // A reply that is no longer in the thread can't place its rewrite; it then goes first.
        let currentMessage = comment.rewriteMessageID.flatMap { id in messages.contains { $0.id == id } ? id : nil }
        var items: [ThreadTimelineItem] = []
        if let initial = currentMessage == nil ? current : comment.initialReplacement {
            items.append(.suggestion(ThreadSuggestion(messageID: nil, replacement: initial, isCurrent: currentMessage == nil)))
        }
        for (index, message) in messages.enumerated() {
            items.append(.message(index: index, message))
            guard message.role == "assistant" else { continue }
            let isCurrent = message.id == currentMessage
            if let replacement = isCurrent ? current : message.replacement {
                items.append(.suggestion(ThreadSuggestion(messageID: message.id, replacement: replacement, isCurrent: isCurrent)))
            }
        }
        return items
    }

    /// What a collapsed card shows: Matilde's latest words, else the review's note, else the
    /// writer's last message.
    static func preview(for comment: ReviewComment) -> String? {
        let messages = comment.messages ?? []
        if let reply = messages.last(where: { $0.role == "assistant" }) { return reply.text }
        if !comment.suggestion.explanation.isEmpty { return comment.suggestion.explanation }
        return messages.last?.text
    }
}

extension ReviewComment {
    /// Threads saved before rewrites were tied to replies only know the latest rewrite. In a
    /// thread the writer started, it can only have come from a reply: place it after Matilde's
    /// latest reply. Review threads keep it first, where it was always shown. Idempotent.
    mutating func attachLegacyRewrite() {
        guard rewriteMessageID == nil, userInitiated == true, let replacement = suggestion.replacement,
              var thread = messages, let index = thread.lastIndex(where: { $0.role == "assistant" }) else { return }
        thread[index].replacement = replacement
        messages = thread
        rewriteMessageID = thread[index].id
    }
}
