import Foundation

// SYNC-07: the JSON shapes of the sync server's API (server/PROTOCOL.md), shared by the real
// HTTPS transport and the in-memory fake used in tests. Nothing here holds plaintext: `ct` is
// always ciphertext produced by SyncCrypto.

/// One change in `POST /v1/sync/push`.
struct SyncWireChange: Codable, Equatable, Sendable {
    var id: String
    var type: Int
    var hlc: String
    /// The server version a compare-and-swap edit started from (body, stash); nil otherwise.
    var baseHlc: String?
    var deleted: Bool
    var keyId: Int
    var blobId: String?
    /// Base64 ciphertext; nil for tombstones.
    var ct: String?

    /// Decoded ciphertext size, for batching against the server's limits.
    var ciphertextBytes: Int { ct.map { $0.utf8.count / 4 * 3 } ?? 0 }
}

struct SyncPushRequest: Encodable, Sendable {
    var deviceId: String
    var changes: [SyncWireChange]
}

/// A stored record as the server returns it (pull rows, rejected push rows).
struct SyncWireRow: Codable, Equatable, Sendable {
    var id: String
    var type: Int
    var hlc: String
    var deviceId: String
    var deleted: Bool
    var keyId: Int
    var size: Int
    var blobId: String?
    var seq: Int
    var ct: String?
}

struct SyncPushResponse: Codable, Equatable, Sendable {
    struct Accepted: Codable, Equatable, Sendable {
        var id: String
        var seq: Int
    }
    struct Rejected: Codable, Equatable, Sendable {
        var id: String
        /// `stale`, `conflict`, `clock`, `blob_missing` or `quota`.
        var reason: String
        var row: SyncWireRow?
    }
    var accepted: [Accepted]
    var rejected: [Rejected]
    var maxSeq: Int
    var epoch: String
}

struct SyncPullResponse: Codable, Equatable, Sendable {
    var rows: [SyncWireRow]
    var hasMore: Bool
    var maxSeq: Int
    var nextSince: Int
    var epoch: String
    var resync: Bool
}

/// Messages on the change-nudge WebSocket (`GET /v1/sync/ws`).
enum SyncLiveEvent: Equatable, Sendable {
    /// Sent on connect: the server's newest sequence number and store epoch.
    case hello(seq: Int, epoch: String)
    /// Another device pushed; pull if `seq` is above the local cursor.
    case changed(seq: Int)
    /// The socket closed. 4001: session revoked, 4002: account deleted; anything else: reconnect.
    case closed(code: Int)

    static let sessionRevokedCode = 4001
    static let accountDeletedCode = 4002

    /// Parses a text frame; nil for anything unknown (including `pong`).
    static func parse(_ text: String) -> SyncLiveEvent? {
        struct Frame: Decodable { var type: String; var seq: Int?; var epoch: String? }
        guard let frame = try? JSONDecoder().decode(Frame.self, from: Data(text.utf8)) else { return nil }
        switch frame.type {
        case "hello": return frame.seq.map { .hello(seq: $0, epoch: frame.epoch ?? "") }
        case "changed": return frame.seq.map { .changed(seq: $0) }
        default: return nil
        }
    }
}

/// `{ "error": { "code", "message" } }` with its HTTP status. Clients act on `code`.
struct SyncServerError: Error, Equatable, Sendable, CustomStringConvertible {
    var status: Int
    var code: String
    /// Seconds from `Retry-After` (429).
    var retryAfter: TimeInterval?

    /// Try again later with backoff (rate limits, server errors).
    var isTransient: Bool { status == 429 || status >= 500 }
    /// The session is gone: forget the tokens and show sign-in.
    var endsSession: Bool {
        ["invalid_refresh_token", "refresh_token_reused", "session_revoked", "account_deleted"].contains(code)
    }
    /// The server no longer accepts this app build.
    var needsUpgrade: Bool { status == 426 && code == "upgrade_required" }

    /// Never includes the server's message, which could echo request details.
    var description: String { "SyncServerError(\(status), \(code))" }

    struct Body: Decodable {
        struct Inner: Decodable { var code: String }
        var error: Inner
    }

    static func from(status: Int, data: Data, retryAfter: String?) -> SyncServerError {
        let code = (try? JSONDecoder().decode(Body.self, from: data))?.error.code ?? (status >= 500 ? "internal_error" : "http_\(status)")
        return SyncServerError(status: status, code: code, retryAfter: retryAfter.flatMap(TimeInterval.init))
    }
}

/// The server limits the client batches against (server/src/limits.ts).
enum SyncLimits {
    static let pushMaxChanges = 200
    /// The server allows 4 MiB of decoded ciphertext per push; stay under it with room for rounding.
    static let pushMaxCiphertextBytes = 3_800_000
    /// 3 MiB per record on the server. Larger records travel as a blob reference.
    static let recordMaxCiphertextBytes = 3_000_000
    static let pullPageSize = 500
    static let blobMaxBytes = 64 * 1024 * 1024
}

/// The client side of the protocol. Implementations must be safe to call from any thread;
/// the engine never calls them on the main thread.
protocol SyncTransport: Sendable {
    func push(_ changes: [SyncWireChange]) async throws -> SyncPushResponse
    func pull(since: Int, limit: Int) async throws -> SyncPullResponse
    /// `PUT /v1/blobs/{id}`; blobs are immutable, so re-uploading the same id is a no-op.
    func uploadBlob(id: String, data: Data) async throws
    func downloadBlob(id: String) async throws -> Data
    func keys() async throws -> SyncKeysResponse
    func putKeys(_ request: SyncPutKeysRequest) async throws
}
