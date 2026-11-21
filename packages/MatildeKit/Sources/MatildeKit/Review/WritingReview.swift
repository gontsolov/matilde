import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public struct ReviewComment: Codable, Identifiable {
    public let id: UUID
    public var suggestion: ReviewSuggestion
    public var location: Int
    public var length: Int
    /// "open", "removed" (passage deleted; undo restores it), "accepted", "dismissed";
    /// "stale" only in reviews saved before passages were tracked.
    public var status: String = "open"
    public var messages: [ReviewMessage]? = nil
    public var replyError: String? = nil
    public var userInitiated: Bool? = nil
    /// The passage a suggested rewrite was written for, once the writer has edited it.
    public var rewriteQuote: String? = nil
    /// Set while a suggestion or assistant reply hasn't been opened. Kept with the review in the
    /// database, never in the Markdown; reviews saved before this existed decode as read.
    public var unread: Bool? = nil
    /// The assistant message whose rewrite is `suggestion.replacement`; `nil` while it is still the
    /// review's own suggestion (or, for threads saved before this existed, unknown: see `ThreadTimeline`).
    public var rewriteMessageID: UUID? = nil
    /// The review's own rewrite, kept once a reply replaces it, so it stays first in the thread.
    public var initialReplacement: String? = nil
    /// Frozen chat prefix for this thread (see `ReplyContext`); nil until its first delivered reply.
    public var replyContext: ReplyContext? = nil
    public var range: NSRange { NSRange(location: location, length: length) }
    public var isUnread: Bool { unread == true }

    public init(id: UUID, suggestion: ReviewSuggestion, location: Int, length: Int, status: String = "open", messages: [ReviewMessage]? = nil, replyError: String? = nil, userInitiated: Bool? = nil, rewriteQuote: String? = nil, unread: Bool? = nil, rewriteMessageID: UUID? = nil, initialReplacement: String? = nil, replyContext: ReplyContext? = nil) {
        self.id = id
        self.suggestion = suggestion
        self.location = location
        self.length = length
        self.status = status
        self.messages = messages
        self.replyError = replyError
        self.userInitiated = userInitiated
        self.rewriteQuote = rewriteQuote
        self.unread = unread
        self.rewriteMessageID = rewriteMessageID
        self.initialReplacement = initialReplacement
        self.replyContext = replyContext
    }
}

public struct WritingReview: Codable, Identifiable {
    public let id: UUID
    public let draftID: String
    public let created: Date
    public let model: String
    public var revision: String
    public var stale: Bool
    public var comments: [ReviewComment]
    public var source: ReviewInput? = nil

    public static func revision(_ input: ReviewInput) -> String {
        let data = try! JSONEncoder().encode([input.title, input.goal, input.body])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func anchor(_ suggestion: ReviewSuggestion, in text: String) -> NSRange? {
        let source = text as NSString
        guard !suggestion.quote.isEmpty else { return nil }
        var search = NSRange(location: 0, length: source.length)
        var found: NSRange?
        while search.length > 0 {
            let range = source.range(of: suggestion.quote, options: .literal, range: search)
            if range.location == NSNotFound { break }
            let before = source.substring(to: range.location)
            let after = source.substring(from: NSMaxRange(range))
            if before.hasSuffix(suggestion.prefix), after.hasPrefix(suggestion.suffix) {
                if found != nil { return nil }
                found = range
            }
            let next = range.location + 1
            search = NSRange(location: next, length: source.length - next)
        }
        return found
    }
    public static func make(draftID: String, input: ReviewInput, model: String, suggestions: [ReviewSuggestion]) throws -> Self {
        var comments: [ReviewComment] = []
        for suggestion in suggestions {
            guard let range = anchor(suggestion, in: input.body),
                  !comments.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else {
                throw ReviewError.message("The review couldn’t be matched reliably to this draft. Please review again.")
            }
            let comment = ReviewComment(id: UUID(), suggestion: suggestion, location: range.location, length: range.length)
            comments.append(CommentAnchor.refreshed(comment, range: range, in: input.body))
        }
        return Self(id: UUID(), draftID: draftID, created: Date(), model: model, revision: revision(input), stale: false, comments: comments, source: input)
    }

    public init(id: UUID, draftID: String, created: Date, model: String, revision: String, stale: Bool, comments: [ReviewComment], source: ReviewInput? = nil) {
        self.id = id
        self.draftID = draftID
        self.created = created
        self.model = model
        self.revision = revision
        self.stale = stale
        self.comments = comments
        self.source = source
    }
}

extension Workspace {
    public func reviewHistory(draftID: String) throws -> [WritingReview] {
        try db.execute("CREATE TABLE IF NOT EXISTS writing_reviews (id TEXT PRIMARY KEY, draft_id TEXT NOT NULL, created REAL NOT NULL, payload TEXT NOT NULL)")
        return try db.execute("SELECT payload FROM writing_reviews WHERE draft_id = ? ORDER BY created DESC", [draftID]).map { row in
            guard let payload = row["payload"] else { throw ReviewError.message("A saved review could not be read.") }
            var review = try JSONDecoder().decode(WritingReview.self, from: Data(payload.utf8))
            for index in review.comments.indices { review.comments[index].attachLegacyRewrite() }
            return review
        }
    }
    public func saveReview(_ review: WritingReview) throws {
        try db.execute("CREATE TABLE IF NOT EXISTS writing_reviews (id TEXT PRIMARY KEY, draft_id TEXT NOT NULL, created REAL NOT NULL, payload TEXT NOT NULL)")
        let payload = String(decoding: try JSONEncoder().encode(review), as: UTF8.self)
        try db.execute("INSERT OR REPLACE INTO writing_reviews (id, draft_id, created, payload) VALUES (?, ?, ?, ?)",
                       [review.id.uuidString, review.draftID, String(review.created.timeIntervalSince1970), payload])
    }
}
