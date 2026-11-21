import Foundation

// SYNC-02: the plaintext fields of each record type. Everything here ends up inside the
// ciphertext (SYNC-06); the server only ever sees the envelope. Ids that point at other
// records are record ids (lowercase UUIDs). Times are milliseconds since 1970 (UTC).
// Optional fields are omitted when nil. Adding a field is backward compatible; renaming or
// removing one needs `SyncRecord.schemaVersion` + 1. Device-local state (cursor, scroll,
// board positions, comparison and window state) is deliberately not part of any record.

/// A draft's identity, place and metadata. Its text is a separate `body` record.
public struct DraftPayload: Codable, Equatable {
    public var path: String
    public var family: String
    public var parent: String?
    public var goal: String
    public var created: Double?

    public init(path: String, family: String, parent: String? = nil, goal: String, created: Double? = nil) {
        self.path = path
        self.family = family
        self.parent = parent
        self.goal = goal
        self.created = created
    }
}

/// A draft's Markdown text (compare-and-swap on the server; conflicts become conflict branches).
public struct BodyPayload: Codable, Equatable {
    public var draft: String
    public var text: String
    public var edited: Double?

    public init(draft: String, text: String, edited: Double? = nil) {
        self.draft = draft
        self.text = text
        self.edited = edited
    }
}

/// The immutable text a branch was created from.
public struct SnapshotPayload: Codable, Equatable {
    public var source: String
    public var child: String
    public var text: String
    public var created: Double?

    public init(source: String, child: String, text: String, created: Double? = nil) {
        self.source = source
        self.child = child
        self.text = text
        self.created = created
    }
}

/// A draft family's stash notes (compare-and-swap).
public struct StashPayload: Codable, Equatable {
    public var family: String
    public var text: String

    public init(family: String, text: String) {
        self.family = family
        self.text = text
    }
}

/// An image in a `.assets` folder. The encrypted file itself becomes a blob in SYNC-07.
public struct AssetPayload: Codable, Equatable {
    public var path: String
    public var size: Int

    public init(path: String, size: Int) {
        self.path = path
        self.size = size
    }
}

/// A private user comment (`user_comments`). Archived comments stay records with `archived: true`.
public struct CommentPayload: Codable, Equatable {
    public var draft: String
    public var body: String
    public var location: Int
    public var length: Int
    public var quote: String
    public var prefix: String
    public var suffix: String
    public var created: Double
    public var modified: Double
    public var archived: Bool

    public init(draft: String, body: String, location: Int, length: Int, quote: String, prefix: String, suffix: String, created: Double, modified: Double, archived: Bool) {
        self.draft = draft
        self.body = body
        self.location = location
        self.length = length
        self.quote = quote
        self.prefix = prefix
        self.suffix = suffix
        self.created = created
        self.modified = modified
        self.archived = archived
    }
}

/// One Ask Matilde thread: a comment of a `writing_reviews` review, normalised out of the review's
/// JSON. The review's own fields travel with each of its threads. Messages and unread state are
/// separate records. Not synced: the review's `source` snapshot (comment anchors fall back to
/// quote/context matching without it) and transient reply errors.
public struct ThreadPayload: Codable, Equatable {
    public var review: String
    public var draft: String
    public var reviewCreated: Double
    public var model: String
    public var revision: String
    public var stale: Bool
    public var quote: String
    public var prefix: String
    public var suffix: String
    public var explanation: String
    public var replacement: String?
    public var location: Int
    public var length: Int
    public var status: String
    public var userInitiated: Bool?
    public var rewriteQuote: String?
    public var rewriteMessage: String?
    public var initialReplacement: String?

    public init(review: String, draft: String, reviewCreated: Double, model: String, revision: String, stale: Bool, quote: String, prefix: String, suffix: String, explanation: String, replacement: String? = nil, location: Int, length: Int, status: String, userInitiated: Bool? = nil, rewriteQuote: String? = nil, rewriteMessage: String? = nil, initialReplacement: String? = nil) {
        self.review = review
        self.draft = draft
        self.reviewCreated = reviewCreated
        self.model = model
        self.revision = revision
        self.stale = stale
        self.quote = quote
        self.prefix = prefix
        self.suffix = suffix
        self.explanation = explanation
        self.replacement = replacement
        self.location = location
        self.length = length
        self.status = status
        self.userInitiated = userInitiated
        self.rewriteQuote = rewriteQuote
        self.rewriteMessage = rewriteMessage
        self.initialReplacement = initialReplacement
    }
}

/// One message in a thread, in order. Append-only in practice.
public struct MessagePayload: Codable, Equatable {
    public var thread: String
    public var index: Int
    public var role: String
    public var text: String
    public var delivery: String?
    public var replacement: String?

    public init(thread: String, index: Int, role: String, text: String, delivery: String? = nil, replacement: String? = nil) {
        self.thread = thread
        self.index = index
        self.role = role
        self.text = text
        self.delivery = delivery
        self.replacement = replacement
    }
}

/// Whether a thread has been read. Kept apart from the thread so reading on one Mac never
/// races an edit of the thread on another.
public struct ReadMarkerPayload: Codable, Equatable {
    public var thread: String
    public var unread: Bool

    public init(thread: String, unread: Bool) {
        self.thread = thread
        self.unread = unread
    }
}

/// The archived metadata of a draft moved to the Trash (`trashed_drafts`).
public struct TrashedPayload: Codable, Equatable {
    public var draft: String
    public var path: String
    public var family: String
    public var parent: String?
    public var goal: String
    public var trashedAt: Double?

    public init(draft: String, path: String, family: String, parent: String? = nil, goal: String, trashedAt: Double? = nil) {
        self.draft = draft
        self.path = path
        self.family = family
        self.parent = parent
        self.goal = goal
        self.trashedAt = trashedAt
    }
}

/// A workspace folder, so empty folders survive too. Identified by its path.
public struct FolderPayload: Codable, Equatable {
    public var path: String

    public init(path: String) {
        self.path = path
    }
}
