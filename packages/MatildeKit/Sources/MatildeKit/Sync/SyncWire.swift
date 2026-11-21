import Foundation

// SYNC-07: the JSON shapes of the sync server's API (server/PROTOCOL.md), shared by the real
// HTTPS transport and the in-memory fake used in tests. Nothing here holds plaintext: `ct` is
// always ciphertext produced by SyncCrypto.

/// One change in `POST /v1/sync/push`.
public struct SyncWireChange: Codable, Equatable, Sendable {
    public var id: String
    public var type: Int
    public var hlc: String
    /// The server version a compare-and-swap edit started from (body, stash); nil otherwise.
    public var baseHlc: String?
    public var deleted: Bool
    public var keyId: Int
    public var blobId: String?
    /// Base64 ciphertext; nil for tombstones.
    public var ct: String?

    /// Decoded ciphertext size, for batching against the server's limits.
    public var ciphertextBytes: Int { ct.map { $0.utf8.count / 4 * 3 } ?? 0 }

    public init(id: String, type: Int, hlc: String, baseHlc: String? = nil, deleted: Bool, keyId: Int, blobId: String? = nil, ct: String? = nil) {
        self.id = id
        self.type = type
        self.hlc = hlc
        self.baseHlc = baseHlc
        self.deleted = deleted
        self.keyId = keyId
        self.blobId = blobId
        self.ct = ct
    }
}

public struct SyncPushRequest: Encodable, Sendable {
    public var deviceId: String
    public var changes: [SyncWireChange]

    public init(deviceId: String, changes: [SyncWireChange]) {
        self.deviceId = deviceId
        self.changes = changes
    }
}

/// A stored record as the server returns it (pull rows, rejected push rows).
public struct SyncWireRow: Codable, Equatable, Sendable {
    public var id: String
    public var type: Int
    public var hlc: String
    public var deviceId: String
    public var deleted: Bool
    public var keyId: Int
    public var size: Int
    public var blobId: String?
    public var seq: Int
    public var ct: String?

    public init(id: String, type: Int, hlc: String, deviceId: String, deleted: Bool, keyId: Int, size: Int, blobId: String? = nil, seq: Int, ct: String? = nil) {
        self.id = id
        self.type = type
        self.hlc = hlc
        self.deviceId = deviceId
        self.deleted = deleted
        self.keyId = keyId
        self.size = size
        self.blobId = blobId
        self.seq = seq
        self.ct = ct
    }
}

public struct SyncPushResponse: Codable, Equatable, Sendable {
    public struct Accepted: Codable, Equatable, Sendable {
        public var id: String
        public var seq: Int

        public init(id: String, seq: Int) {
            self.id = id
            self.seq = seq
        }
    }
    public struct Rejected: Codable, Equatable, Sendable {
        public var id: String
        /// `stale`, `conflict`, `clock`, `blob_missing` or `quota`.
        public var reason: String
        public var row: SyncWireRow?

        public init(id: String, reason: String, row: SyncWireRow? = nil) {
            self.id = id
            self.reason = reason
            self.row = row
        }
    }
    public var accepted: [Accepted]
    public var rejected: [Rejected]
    public var maxSeq: Int
    public var epoch: String

    public init(accepted: [Accepted], rejected: [Rejected], maxSeq: Int, epoch: String) {
        self.accepted = accepted
        self.rejected = rejected
        self.maxSeq = maxSeq
        self.epoch = epoch
    }
}

public struct SyncPullResponse: Codable, Equatable, Sendable {
    public var rows: [SyncWireRow]
    public var hasMore: Bool
    public var maxSeq: Int
    public var nextSince: Int
    public var epoch: String
    public var resync: Bool

    public init(rows: [SyncWireRow], hasMore: Bool, maxSeq: Int, nextSince: Int, epoch: String, resync: Bool) {
        self.rows = rows
        self.hasMore = hasMore
        self.maxSeq = maxSeq
        self.nextSince = nextSince
        self.epoch = epoch
        self.resync = resync
    }
}

/// Messages on the change-nudge WebSocket (`GET /v1/sync/ws`).
public enum SyncLiveEvent: Equatable, Sendable {
    /// Sent on connect: the server's newest sequence number and store epoch.
    case hello(seq: Int, epoch: String)
    /// Another device pushed; pull if `seq` is above the local cursor.
    case changed(seq: Int)
    /// The socket closed. 4001: session revoked, 4002: account deleted; anything else: reconnect.
    case closed(code: Int)

    public static let sessionRevokedCode = 4001
    public static let accountDeletedCode = 4002

    /// Parses a text frame; nil for anything unknown (including `pong`).
    public static func parse(_ text: String) -> SyncLiveEvent? {
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
public struct SyncServerError: Error, Equatable, Sendable, CustomStringConvertible {
    public var status: Int
    public var code: String
    /// Seconds from `Retry-After` (429).
    public var retryAfter: TimeInterval?

    /// Try again later with backoff (rate limits, server errors).
    public var isTransient: Bool { status == 429 || status >= 500 }
    /// The session is gone: forget the tokens and show sign-in.
    public var endsSession: Bool {
        ["invalid_refresh_token", "refresh_token_reused", "session_revoked", "account_deleted"].contains(code)
    }
    /// The server no longer accepts this app build.
    public var needsUpgrade: Bool { status == 426 && code == "upgrade_required" }

    /// Never includes the server's message, which could echo request details.
    public var description: String { "SyncServerError(\(status), \(code))" }

    public struct Body: Decodable {
        public struct Inner: Decodable { var code: String }
        public var error: Inner

        public init(error: Inner) {
            self.error = error
        }
    }

    public static func from(status: Int, data: Data, retryAfter: String?) -> SyncServerError {
        let code = (try? JSONDecoder().decode(Body.self, from: data))?.error.code ?? (status >= 500 ? "internal_error" : "http_\(status)")
        return SyncServerError(status: status, code: code, retryAfter: retryAfter.flatMap(TimeInterval.init))
    }

    public init(status: Int, code: String, retryAfter: TimeInterval? = nil) {
        self.status = status
        self.code = code
        self.retryAfter = retryAfter
    }
}

/// The server limits the client batches against (server/src/limits.ts).
public enum SyncLimits {
    public static let pushMaxChanges = 200
    /// The server allows 4 MiB of decoded ciphertext per push; stay under it with room for rounding.
    public static let pushMaxCiphertextBytes = 3_800_000
    /// 3 MiB per record on the server. Larger records travel as a blob reference.
    public static let recordMaxCiphertextBytes = 3_000_000
    public static let pullPageSize = 500
    public static let blobMaxBytes = 64 * 1024 * 1024
}

/// The client side of the protocol. Implementations must be safe to call from any thread;
/// the engine never calls them on the main thread.
public protocol SyncTransport: Sendable {
    func push(_ changes: [SyncWireChange]) async throws -> SyncPushResponse
    func pull(since: Int, limit: Int) async throws -> SyncPullResponse
    /// `PUT /v1/blobs/{id}`; blobs are immutable, so re-uploading the same id is a no-op.
    func uploadBlob(id: String, data: Data) async throws
    func downloadBlob(id: String) async throws -> Data
    func keys() async throws -> SyncKeysResponse
    func putKeys(_ request: SyncPutKeysRequest) async throws
}
