import Foundation

/// A comment already on the draft, as a review sees it (AI-19). Reviews send these after the
/// draft so Ask Matilde doesn't raise points that are already covered, and `ReviewDeduplication`
/// drops any new suggestion that repeats one anyway.
public struct ExistingComment: Equatable {
    public enum Author: String, Encodable {
        case matilde, writer
        /// Another AI tool, through the MCP server's `add_comment`.
        case aiTool = "ai_tool"
    }
    public enum Kind: String, Encodable {
        /// A suggestion from an Ask Matilde review.
        case suggestion
        /// An Ask Matilde thread the writer started from a selection.
        case question
        /// A private comment (the writer's own, or one an AI tool left through the MCP server).
        case note
    }
    public enum Status: String, Encodable {
        case open
        /// Its rewrite was accepted.
        case resolved
        /// The writer archived it.
        case dismissed
    }
    public struct Reply: Encodable, Equatable {
        public let role: String
        public let text: String

        public init(role: String, text: String) {
            self.role = role
            self.text = text
        }
    }

    public let id: UUID
    public let author: Author
    public let kind: Kind
    public let status: Status
    /// The passage as it reads now (or as it read when it was set aside, if it can't be found).
    public let passage: String
    /// The passage when the comment was written, only when it has changed since.
    public let passageWhenCommented: String?
    public let comment: String
    public let suggestedRewrite: String?
    public let replies: [Reply]
    /// Where the passage is in the current body; nil when it can't be located.
    public let range: NSRange?
    /// The passage was reworded since the comment was made, so its point may be raised again.
    public let passageChanged: Bool

    public init(id: UUID, author: Author, kind: Kind, status: Status, passage: String, passageWhenCommented: String? = nil,
                comment: String, suggestedRewrite: String? = nil, replies: [Reply] = [], range: NSRange?, passageChanged: Bool = false) {
        self.id = id
        self.author = author
        self.kind = kind
        self.status = status
        self.passage = passage
        self.passageWhenCommented = passageWhenCommented
        self.comment = comment
        self.suggestedRewrite = suggestedRewrite
        self.replies = replies
        self.range = range
        self.passageChanged = passageChanged
    }
}

public enum ReviewContext {
    public static let maximumComments = 60
    public static let maximumBytes = 40_000
    static let passageLimit = 600
    static let commentLimit = 600
    static let replyLimit = 400
    static let repliesPerComment = 4

    /// Every comment the writer can still see or has decided on: open, resolved (accepted) and
    /// dismissed Ask Matilde comments with their replies, and private comments, archived ones as
    /// dismissed. `history` is newest first, as `Workspace.reviewHistory` returns it. Open threads
    /// carried into a newer review share their id; the newest copy wins. Comments whose passage was
    /// deleted, open comments of superseded reviews and empty notes are left out.
    public static func existingComments(history: [WritingReview], notes: [UserComment], archivedNotes: [UserComment] = [],
                                        body: String) -> [ExistingComment] {
        let source = body as NSString
        var seen = Set<UUID>()
        var result: [ExistingComment] = []
        for run in history {
            for comment in run.comments where !seen.contains(comment.id) {
                let status: ExistingComment.Status
                switch comment.status {
                case "open" where !run.stale && comment.matches(body): status = .open
                case "accepted": status = .resolved
                case "dismissed": status = .dismissed
                default: continue
                }
                seen.insert(comment.id)
                let range = status == .open ? comment.range : CommentAnchor.relocate(comment, in: body)
                let current = range.map { source.substring(with: $0) } ?? comment.quote
                let original = comment.reviewedQuote ?? comment.quote
                let changed = status != .resolved && !ReviewDeduplication.sameWording(current, original)
                let writerStarted = comment.userInitiated == true
                let messages = (comment.messages ?? []).filter { $0.delivery != "failed" && $0.delivery != "pending" }
                var explanation = comment.suggestion.explanation.trimmingCharacters(in: .whitespacesAndNewlines)
                var replies = messages
                if writerStarted, explanation.isEmpty, let first = messages.first, first.role == "user" {
                    explanation = first.text; replies = Array(messages.dropFirst())
                }
                guard !explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !replies.isEmpty else { continue }
                let rewrite = status == .resolved ? comment.suggestion.replacement : (comment.initialReplacement ?? comment.suggestion.replacement)
                result.append(ExistingComment(
                    id: comment.id, author: writerStarted ? .writer : .matilde, kind: writerStarted ? .question : .suggestion,
                    status: status, passage: current, passageWhenCommented: changed ? original : nil, comment: explanation,
                    suggestedRewrite: rewrite,
                    replies: replies.suffix(repliesPerComment).map { .init(role: $0.role == "assistant" ? "matilde" : "writer", text: $0.text) },
                    range: range, passageChanged: changed))
            }
        }
        for (note, archived) in notes.map({ ($0, false) }) + archivedNotes.map({ ($0, true) }) where !seen.contains(note.id) {
            let text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            seen.insert(note.id)
            let range = CommentAnchor.relocate(note, in: body)
            // A detached note's passage was deleted; archived ones keep their last quote.
            guard range != nil || archived else { continue }
            result.append(ExistingComment(id: note.id, author: note.author == nil ? .writer : .aiTool, kind: .note,
                                          status: archived ? .dismissed : .open,
                                          passage: range.map { source.substring(with: $0) } ?? note.quote,
                                          comment: text, range: range))
        }
        // Passage order keeps the message readable and its bytes deterministic.
        return result.enumerated().sorted {
            ($0.element.range?.location ?? Int.max, $0.offset) < ($1.element.range?.location ?? Int.max, $1.offset)
        }.map(\.element)
    }

    private struct Wire: Encodable {
        struct Comment: Encodable {
            let by: ExistingComment.Author
            let kind: ExistingComment.Kind
            let status: ExistingComment.Status
            let passage: String
            let passage_when_commented: String?
            let comment: String
            let suggested_rewrite: String?
            let replies: [ExistingComment.Reply]?
        }
        let existing_comments: [Comment]
    }

    /// The review's second user message, or nil when the draft has no comments. Sent after the
    /// draft message so the system prompt and draft stay a stable, cacheable prefix. Open comments
    /// come first when the list has to be cut; texts are scrubbed like the draft and shortened.
    public static func message(_ comments: [ExistingComment]) -> String? {
        func clip(_ text: String, _ limit: Int) -> String {
            let clean = ReplyPrompt.scrub(text.trimmingCharacters(in: .whitespacesAndNewlines))
            return clean.count > limit ? String(clean.prefix(limit)) + "…" : clean
        }
        let wire = comments.map { comment in
            Wire.Comment(by: comment.author, kind: comment.kind, status: comment.status,
                         passage: clip(comment.passage, passageLimit),
                         passage_when_commented: comment.passageWhenCommented.map { clip($0, passageLimit) },
                         comment: clip(comment.comment, commentLimit),
                         suggested_rewrite: comment.suggestedRewrite.map { clip($0, passageLimit) },
                         replies: comment.replies.isEmpty ? nil : comment.replies.map { .init(role: $0.role, text: clip($0.text, replyLimit)) })
        }
        // Open comments first when the list has to be cut; the kept ones stay in passage order.
        let prioritized = wire.indices.sorted { (comments[$0].status == .open ? 0 : 1, $0) < (comments[$1].status == .open ? 0 : 1, $1) }
        var kept = Set<Int>()
        var bytes = 0
        for index in prioritized where kept.count < maximumComments {
            let size = ReplyPrompt.encode(wire[index]).utf8.count + 1
            guard bytes + size <= maximumBytes else { continue }
            bytes += size; kept.insert(index)
        }
        let selected = wire.indices.filter { kept.contains($0) }.map { wire[$0] }
        return selected.isEmpty ? nil : ReplyPrompt.encode(Wire(existing_comments: selected))
    }

    /// The review request's messages in cache order: system prompt, whole draft, then the
    /// existing comments (the only part that changes between reviews of the same draft).
    public static func messages(input: ReviewInput, existing: [ExistingComment], guidance: String) -> [ReplyConversation.Message] {
        var messages = [ReplyConversation.Message(role: "system", content: WritingAssistPrompt.review(guidance: guidance)),
                        ReplyConversation.Message(role: "user", content: ReplyPrompt.encode(input.transmitted))]
        if let comments = message(existing) { messages.append(.init(role: "user", content: comments)) }
        return messages
    }
}

/// Deterministic safety net after a review: a new suggestion repeats an existing comment when it
/// sits on essentially the same passage, or overlaps it and makes a similar point. Comments whose
/// passage has since been reworded don't block anything.
public enum ReviewDeduplication {
    /// Share of the longer passage two ranges must have in common to count as the same passage.
    public static let samePassage = 0.6
    /// Share of the shorter comment's key words the other must contain to count as the same point.
    public static let similarPoint = 0.4

    public static func isDuplicate(_ comment: ReviewComment, of existing: [ExistingComment]) -> Bool {
        let range = comment.range
        guard range.length > 0 else { return false }
        let text = [comment.suggestion.explanation, comment.suggestion.replacement ?? ""].joined(separator: " ")
        return existing.contains { other in
            guard !other.passageChanged, let otherRange = other.range, otherRange.length > 0 else { return false }
            let shared = NSIntersectionRange(range, otherRange).length
            guard shared > 0 else { return false }
            if Double(shared) / Double(max(range.length, otherRange.length)) >= samePassage { return true }
            let otherText = ([other.comment, other.suggestedRewrite ?? ""] + other.replies.map(\.text)).joined(separator: " ")
            return similarWording(text, otherText)
        }
    }

    /// New suggestions minus the ones that repeat an existing comment.
    public static func filter(_ comments: [ReviewComment], against existing: [ExistingComment]) -> [ReviewComment] {
        comments.filter { !isDuplicate($0, of: existing) }
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "your", "this", "that", "with", "have", "has", "was", "were",
        "will", "would", "could", "should", "can", "may", "might", "here", "there", "what", "which", "who", "how", "why",
        "when", "where", "its", "it's", "than", "then", "them", "they", "their", "from", "into", "about", "more", "most",
        "some", "any", "all", "one", "also", "just", "very", "too", "does", "did", "make", "makes", "consider", "maybe",
        "perhaps", "sentence", "passage", "paragraph", "text", "reader", "readers", "here's", "need", "needs"
    ]
    static func keyWords(_ text: String) -> Set<String> {
        Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).compactMap { word in
            guard word.count >= 3, !stopWords.contains(word) else { return nil }
            for ending in ["ing", "ed", "ly", "s"] where word.count - ending.count >= 4 && word.hasSuffix(ending) {
                return String(word.dropLast(ending.count))
            }
            return word
        })
    }
    /// Two comments make a similar point: at least two key words in common, covering
    /// `similarPoint` of the shorter one's key words.
    public static func similarWording(_ a: String, _ b: String) -> Bool {
        let left = keyWords(a), right = keyWords(b)
        guard !left.isEmpty, !right.isEmpty else { return false }
        let shared = left.intersection(right).count
        return shared >= 2 && Double(shared) / Double(min(left.count, right.count)) >= similarPoint
    }
    /// A passage still says the same thing: at least 70% of its words in common (all words, so
    /// small edits like a changed number count).
    public static func sameWording(_ a: String, _ b: String) -> Bool {
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        }
        let left = words(a), right = words(b)
        if left == right { return true }
        let union = left.union(right).count
        return union > 0 && Double(left.intersection(right).count) / Double(union) >= 0.7
    }
}
