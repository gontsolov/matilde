import Foundation

// SYNC-02: the plaintext fields of each record type. Everything here ends up inside the
// ciphertext (SYNC-06); the server only ever sees the envelope. Ids that point at other
// records are record ids (lowercase UUIDs). Times are milliseconds since 1970 (UTC).
// Optional fields are omitted when nil. Adding a field is backward compatible; renaming or
// removing one needs `SyncRecord.schemaVersion` + 1. Device-local state (cursor, scroll,
// board positions, comparison and window state) is deliberately not part of any record.

/// A draft's identity, place and metadata. Its text is a separate `body` record.
struct DraftPayload: Codable, Equatable {
    var path: String
    var family: String
    var parent: String?
    var goal: String
    var created: Double?
}

/// A draft's Markdown text (compare-and-swap on the server; conflicts become conflict branches).
struct BodyPayload: Codable, Equatable {
    var draft: String
    var text: String
    var edited: Double?
}

/// The immutable text a branch was created from.
struct SnapshotPayload: Codable, Equatable {
    var source: String
    var child: String
    var text: String
    var created: Double?
}

/// A draft family's stash notes (compare-and-swap).
struct StashPayload: Codable, Equatable {
    var family: String
    var text: String
}

/// An image in a `.assets` folder. The encrypted file itself becomes a blob in SYNC-07.
struct AssetPayload: Codable, Equatable {
    var path: String
    var size: Int
}

/// A private user comment (`user_comments`). Archived comments stay records with `archived: true`.
struct CommentPayload: Codable, Equatable {
    var draft: String
    var body: String
    var location: Int
    var length: Int
    var quote: String
    var prefix: String
    var suffix: String
    var created: Double
    var modified: Double
    var archived: Bool
}

/// One Ask Matilde thread: a comment of a `writing_reviews` review, normalised out of the review's
/// JSON. The review's own fields travel with each of its threads. Messages and unread state are
/// separate records. Not synced: the review's `source` snapshot (comment anchors fall back to
/// quote/context matching without it) and transient reply errors.
struct ThreadPayload: Codable, Equatable {
    var review: String
    var draft: String
    var reviewCreated: Double
    var model: String
    var revision: String
    var stale: Bool
    var quote: String
    var prefix: String
    var suffix: String
    var explanation: String
    var replacement: String?
    var location: Int
    var length: Int
    var status: String
    var userInitiated: Bool?
    var rewriteQuote: String?
    var rewriteMessage: String?
    var initialReplacement: String?
}

/// One message in a thread, in order. Append-only in practice.
struct MessagePayload: Codable, Equatable {
    var thread: String
    var index: Int
    var role: String
    var text: String
    var delivery: String?
    var replacement: String?
}

/// Whether a thread has been read. Kept apart from the thread so reading on one Mac never
/// races an edit of the thread on another.
struct ReadMarkerPayload: Codable, Equatable {
    var thread: String
    var unread: Bool
}

/// The archived metadata of a draft moved to the Trash (`trashed_drafts`).
struct TrashedPayload: Codable, Equatable {
    var draft: String
    var path: String
    var family: String
    var parent: String?
    var goal: String
    var trashedAt: Double?
}

/// A workspace folder, so empty folders survive too. Identified by its path.
struct FolderPayload: Codable, Equatable {
    var path: String
}
