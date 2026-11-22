import Foundation

/// A private note on a passage. Stored only in workspace SQLite; the Markdown file is never touched.
public struct UserComment: Identifiable, Equatable {
    public let id: UUID
    public let draftID: String
    public var text: String
    /// UTF-16 range in the draft body. A zero length means the passage was removed and the
    /// comment is detached until its quoted text and context reappear (for example after undo).
    public var location: Int
    public var length: Int
    public var quote: String
    public var prefix: String
    public var suffix: String
    public let created: Date
    public var modified: Date
    /// Set when an AI tool wrote the comment through the MCP server ("From Claude"); nil for the user's own.
    public var author: String?
    public var range: NSRange { NSRange(location: location, length: length) }
    public var attached: Bool { length > 0 }

    public init(id: UUID, draftID: String, text: String, location: Int, length: Int, quote: String, prefix: String, suffix: String, created: Date, modified: Date, author: String? = nil) {
        self.id = id
        self.draftID = draftID
        self.text = text
        self.location = location
        self.length = length
        self.quote = quote
        self.prefix = prefix
        self.suffix = suffix
        self.created = created
        self.modified = modified
        self.author = author
    }
}

/// A highlighted passage: a UTF-16 range plus the quote and context used to find it again.
/// A zero length means the passage was deleted; the quote is kept so undo can restore it.
public protocol AnchoredPassage {
    var location: Int { get set }
    var length: Int { get set }
    var quote: String { get set }
    var prefix: String { get set }
    var suffix: String { get set }
}

extension UserComment: AnchoredPassage {}

/// Keeps private and Ask Matilde comments on their passages. Native edits move or resize the
/// range directly (via `WritingEdit`); unknown changes fall back to the saved quote plus
/// surrounding context.
public enum CommentAnchor {
    public static let contextLength = 40

    public static func context(of range: NSRange, in text: String) -> (quote: String, prefix: String, suffix: String) {
        let source = text as NSString
        var start = max(0, range.location - contextLength)
        if start > 0, start < source.length {
            let character = source.rangeOfComposedCharacterSequence(at: start)
            if character.location < start { start = min(NSMaxRange(character), range.location) }
        }
        var end = min(source.length, NSMaxRange(range) + contextLength)
        if end < source.length {
            let character = source.rangeOfComposedCharacterSequence(at: end)
            if character.location < end { end = max(character.location, NSMaxRange(range)) }
        }
        return (source.substring(with: range),
                source.substring(with: NSRange(location: start, length: range.location - start)),
                source.substring(with: NSRange(location: NSMaxRange(range), length: end - NSMaxRange(range))))
    }

    public static func refreshed<T: AnchoredPassage>(_ comment: T, range: NSRange, in text: String) -> T {
        var comment = comment
        let parts = Self.context(of: range, in: text)
        comment.location = range.location; comment.length = range.length
        comment.quote = parts.quote; comment.prefix = parts.prefix; comment.suffix = parts.suffix
        return comment
    }

    private static func occurrences(of needle: String, in source: NSString, limit: Int = 500) -> [NSRange] {
        guard !needle.isEmpty else { return [] }
        var result: [NSRange] = []
        var search = NSRange(location: 0, length: source.length)
        while search.length > 0, result.count < limit {
            let found = source.range(of: needle, options: .literal, range: search)
            if found.location == NSNotFound { break }
            result.append(found)
            let next = found.location + 1
            search = NSRange(location: next, length: source.length - next)
        }
        return result
    }

    /// Context score for a quote occurrence: 2 when both prefix and suffix match.
    private static func score<T: AnchoredPassage>(_ found: NSRange, _ comment: T, in source: NSString) -> Int {
        let prefix = comment.prefix as NSString, suffix = comment.suffix as NSString
        let before = prefix.length == 0 ? found.location == 0
            : found.location >= prefix.length && source.substring(with: NSRange(location: found.location - prefix.length, length: prefix.length)) == comment.prefix
        let after = suffix.length == 0 ? NSMaxRange(found) == source.length
            : NSMaxRange(found) + suffix.length <= source.length && source.substring(with: NSRange(location: NSMaxRange(found), length: suffix.length)) == comment.suffix
        return (before ? 1 : 0) + (after ? 1 : 0)
    }

    private static func nearest(_ ranges: [NSRange], to location: Int) -> NSRange? {
        ranges.min { abs($0.location - location) < abs($1.location - location) }
    }

    /// Exact quote with both context sides intact. Safe to apply on every keystroke.
    public static func strictMatch<T: AnchoredPassage>(_ comment: T, in text: String) -> NSRange? {
        let source = text as NSString
        return nearest(occurrences(of: comment.quote, in: source).filter { score($0, comment, in: source) == 2 }, to: comment.location)
    }

    /// Full re-anchoring for reopened drafts and external changes: the saved range if it still
    /// holds the quote, then the best context match, a unique quote, or the text between
    /// a unique prefix and suffix when the passage itself was edited.
    public static func relocate<T: AnchoredPassage>(_ comment: T, in text: String) -> NSRange? {
        let source = text as NSString
        let saved = NSRange(location: comment.location, length: comment.length)
        if comment.length > 0, comment.location >= 0, NSMaxRange(saved) <= source.length,
           source.substring(with: saved) == comment.quote { return saved }
        let found = occurrences(of: comment.quote, in: source)
        let scored = found.map { ($0, score($0, comment, in: source)) }
        if let best = scored.map({ $0.1 }).max(), best > 0 {
            return nearest(scored.filter { $0.1 == best }.map { $0.0 }, to: comment.location)
        }
        if found.count == 1 { return found[0] }
        let prefix = comment.prefix as NSString, suffix = comment.suffix as NSString
        guard prefix.length >= 8, suffix.length >= 8 else { return nil }
        var matches: [NSRange] = []
        for start in occurrences(of: comment.prefix, in: source) {
            let after = NSMaxRange(start)
            let window = min(source.length - after, max((comment.quote as NSString).length * 3, 400))
            guard window > 0 else { continue }
            let end = source.range(of: comment.suffix, options: .literal, range: NSRange(location: after, length: window))
            guard end.location != NSNotFound, end.location > after else { continue }
            matches.append(NSRange(location: after, length: end.location - after))
            if matches.count > 1 { return nil }
        }
        return matches.first
    }

    /// Apply one replacement edit. Edits before a passage shift it; text typed inside extends
    /// it; deleting part of it shrinks it to what remains; replacing exactly the passage keeps the
    /// comment on the new text. Only deleting all of it detaches the comment (hidden), keeping
    /// its quote so undo reattaches it.
    public static func track<T: AnchoredPassage>(_ comment: T, edit: WritingEdit, in text: String) -> T {
        var comment = comment
        guard comment.length > 0 else {
            if let range = strictMatch(comment, in: text) { return refreshed(comment, range: range, in: text) }
            return comment
        }
        let e = edit.range, r = NSRange(location: comment.location, length: comment.length)
        if NSMaxRange(e) <= r.location {
            comment.location += edit.delta
            return refreshed(comment, range: NSRange(location: comment.location, length: comment.length), in: text)
        }
        if e.location >= NSMaxRange(r) { return refreshed(comment, range: r, in: text) }
        if let range = strictMatch(comment, in: text) { return refreshed(comment, range: range, in: text) }
        var location = r.location, end = NSMaxRange(r)
        if e.location >= r.location && NSMaxRange(e) <= end {
            end += edit.delta
        } else if e.location < r.location && NSMaxRange(e) < end {
            location = e.location + edit.insertedLength
            end = location + (NSMaxRange(r) - NSMaxRange(e))
        } else if e.location > r.location && NSMaxRange(e) >= end {
            end = e.location
        } else {
            end = location
        }
        guard end > location, end <= (text as NSString).length else {
            comment.location = min(e.location, (text as NSString).length); comment.length = 0
            return comment
        }
        return refreshed(comment, range: NSRange(location: location, length: end - location), in: text)
    }
}

extension Workspace {
    public func ensureUserComments() throws {
        try db.execute("CREATE TABLE IF NOT EXISTS user_comments (id TEXT PRIMARY KEY, draft_id TEXT NOT NULL, body TEXT NOT NULL, location INTEGER NOT NULL, length INTEGER NOT NULL, quote TEXT NOT NULL, prefix TEXT NOT NULL, suffix TEXT NOT NULL, created REAL NOT NULL, modified REAL NOT NULL)")
        try db.execute("CREATE INDEX IF NOT EXISTS user_comments_draft ON user_comments (draft_id)")
        // Archived comments are kept but no longer shown (added after the first comment release).
        if !(try db.execute("PRAGMA table_info(user_comments)")).contains(where: { $0["name"] == "archived" }) {
            try db.execute("ALTER TABLE user_comments ADD COLUMN archived INTEGER NOT NULL DEFAULT 0")
        }
        // The AI tool that wrote a comment through the MCP server (AI-18); NULL for the user's own.
        if !(try db.execute("PRAGMA table_info(user_comments)")).contains(where: { $0["name"] == "author" }) {
            try db.execute("ALTER TABLE user_comments ADD COLUMN author TEXT")
        }
    }
    public func userComments(draftID: String) throws -> [UserComment] {
        try ensureUserComments()
        return try db.execute("SELECT * FROM user_comments WHERE draft_id = ? AND archived = 0 ORDER BY location, created", [draftID]).compactMap { row in
            guard let id = row["id"].flatMap(UUID.init(uuidString:)), let location = row["location"].flatMap({ Int($0) }),
                  let length = row["length"].flatMap({ Int($0) }), location >= 0, length >= 0 else { return nil }
            return UserComment(id: id, draftID: draftID, text: row["body"] ?? "", location: location, length: length,
                               quote: row["quote"] ?? "", prefix: row["prefix"] ?? "", suffix: row["suffix"] ?? "",
                               created: Date(timeIntervalSince1970: row["created"].flatMap { Double($0) } ?? 0),
                               modified: Date(timeIntervalSince1970: row["modified"].flatMap { Double($0) } ?? 0),
                               author: row["author"].flatMap { $0.isEmpty ? nil : $0 })
        }
    }
    public func saveUserComments(_ comments: [UserComment]) throws {
        guard !comments.isEmpty else { return }
        try ensureUserComments()
        try db.execute("BEGIN IMMEDIATE")
        do {
            for comment in comments {
                try db.execute("INSERT OR REPLACE INTO user_comments (id, draft_id, body, location, length, quote, prefix, suffix, created, modified, author) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                               [comment.id.uuidString, comment.draftID, comment.text, String(comment.location), String(comment.length),
                                comment.quote, comment.prefix, comment.suffix,
                                String(comment.created.timeIntervalSince1970), String(comment.modified.timeIntervalSince1970), comment.author])
            }
            try db.execute("COMMIT")
        } catch {
            _ = try? db.execute("ROLLBACK")
            throw error
        }
    }
    /// Copies a draft's comments onto a branch created from `text`, anchored to the same passages.
    /// Each copy has its own id, so editing, archiving or deleting it in one draft leaves the other
    /// alone. Comments whose passage was removed stay hidden in the copy; archived and empty ones
    /// are not copied. Runs inside the caller's transaction.
    public func copyUserComments(from source: String, to target: String, text: String) throws {
        for comment in try userComments(draftID: source)
        where !comment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var copy = UserComment(id: UUID(), draftID: target, text: comment.text, location: comment.location, length: comment.length,
                                   quote: comment.quote, prefix: comment.prefix, suffix: comment.suffix,
                                   created: comment.created, modified: comment.modified, author: comment.author)
            if copy.attached {
                if let range = CommentAnchor.relocate(copy, in: text) { copy = CommentAnchor.refreshed(copy, range: range, in: text) }
                else { copy.length = 0 }
            }
            try db.execute("INSERT INTO user_comments (id, draft_id, body, location, length, quote, prefix, suffix, created, modified, author) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                           [copy.id.uuidString, copy.draftID, copy.text, String(copy.location), String(copy.length),
                            copy.quote, copy.prefix, copy.suffix,
                            String(copy.created.timeIntervalSince1970), String(copy.modified.timeIntervalSince1970), copy.author])
        }
    }
    public func archiveUserComment(_ id: UUID) throws {
        try ensureUserComments()
        try db.execute("UPDATE user_comments SET archived = 1 WHERE id = ?", [id.uuidString])
    }
    public func deleteUserComment(_ id: UUID) throws {
        try ensureUserComments()
        try db.execute("DELETE FROM user_comments WHERE id = ?", [id.uuidString])
    }
}
