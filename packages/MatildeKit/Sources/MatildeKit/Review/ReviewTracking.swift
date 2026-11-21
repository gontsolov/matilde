import Foundation

public struct ReviewMessage: Codable, Identifiable, Equatable {
    public var id = UUID()
    public let role: String
    public let text: String
    public var delivery: String? = nil
    /// A rewrite proposed with this assistant reply, kept where it was offered in the thread.
    public var replacement: String? = nil
    /// For user messages: the exact chat content sent (question, focus, draft edits), replayed
    /// unchanged on later turns so the request prefix stays identical. Nil in older threads.
    public var prompt: String? = nil

    public init(id: UUID = UUID(), role: String, text: String, delivery: String? = nil, replacement: String? = nil, prompt: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.delivery = delivery
        self.replacement = replacement
        self.prompt = prompt
    }
}

extension ReviewSuggestion {
    public func with(quote: String, prefix: String, suffix: String) -> Self {
        Self(quote: quote, prefix: prefix, suffix: suffix, explanation: explanation, replacement: replacement)
    }
}

extension ReviewComment: AnchoredPassage {
    public var quote: String {
        get { suggestion.quote }
        set { suggestion = suggestion.with(quote: newValue, prefix: suggestion.prefix, suffix: suggestion.suffix) }
    }
    public var prefix: String {
        get { suggestion.prefix }
        set { suggestion = suggestion.with(quote: suggestion.quote, prefix: newValue, suffix: suggestion.suffix) }
    }
    public var suffix: String {
        get { suggestion.suffix }
        set { suggestion = suggestion.with(quote: suggestion.quote, prefix: suggestion.prefix, suffix: newValue) }
    }
    public func matches(_ text: String) -> Bool {
        let source = text as NSString
        return status != "stale" && status != "removed" && length > 0 && range.location >= 0 && NSMaxRange(range) <= source.length
            && source.substring(with: range) == suggestion.quote
    }
    /// A rewrite replaces the passage it was written for, never text the writer has since changed.
    public var rewriteApplies: Bool { suggestion.replacement != nil && (rewriteQuote ?? suggestion.quote) == suggestion.quote }
}

/// A native edit is one replacement. Find its UTF-16 span without splitting Unicode characters.
public struct WritingEdit {
    public let range: NSRange
    public let insertedLength: Int
    public var delta: Int { insertedLength - range.length }
    public static func between(_ old: String, _ new: String) -> Self {
        let before = Array(old), after = Array(new)
        var prefix = 0
        while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(before.count, after.count) - prefix,
              before[before.count - suffix - 1] == after[after.count - suffix - 1] { suffix += 1 }
        return Self(range: NSRange(location: String(before.prefix(prefix)).utf16.count,
                                   length: String(before[prefix..<(before.count - suffix)]).utf16.count),
                    insertedLength: String(after[prefix..<(after.count - suffix)]).utf16.count)
    }

    public init(range: NSRange, insertedLength: Int) {
        self.range = range
        self.insertedLength = insertedLength
    }
}

extension WritingReview {
    /// Keep comments on their passages through any change. A comment leaves the margin only when
    /// all of its passage is deleted (status "removed"; undo restores it) or it is deleted explicitly.
    /// Title and goal changes never hide comments.
    public mutating func track(_ input: ReviewInput) {
        let edit = source.map { WritingEdit.between($0.body, input.body) }
        for i in comments.indices {
            let before = comments[i]
            guard ["open", "removed", "stale"].contains(before.status) else { continue }
            if let edit, before.status != "stale" {
                if edit.range.length > 0 || edit.insertedLength > 0 {
                    comments[i] = CommentAnchor.track(before, edit: edit, in: input.body)
                }
            } else if let range = CommentAnchor.relocate(before, in: input.body) {
                // No saved source, or a review saved before passages were tracked.
                comments[i] = CommentAnchor.refreshed(before, range: range, in: input.body)
            } else {
                comments[i].length = 0
            }
            comments[i].status = comments[i].length > 0 ? "open" : "removed"
            if before.rewriteQuote == nil, before.suggestion.replacement != nil, comments[i].quote != before.quote {
                comments[i].rewriteQuote = before.quote
            }
        }
        source = input
        revision = Self.revision(input)
    }
}
