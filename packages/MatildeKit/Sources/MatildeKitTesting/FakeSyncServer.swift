import Foundation
import MatildeKit

/// An in-memory sync server with the semantics of server/src/sync/UserSync.ts: one account,
/// a sequence number per accepted write, the latest version per record id, idempotent same-HLC
/// retries, `stale` / `conflict` (CAS on `baseHlc`) / `clock` / `blob_missing` rejections, epochs.
public actor FakeSyncServer {
    public private(set) var rows: [String: SyncWireRow] = [:]
    public private(set) var seq = 0
    public private(set) var epoch = UUID().uuidString.lowercased()
    public private(set) var blobs: [String: Data] = [:]
    public private(set) var pushes: [[SyncWireChange]] = []
    public var keys = SyncKeysResponse(keyId: nil, keyCheck: nil, slots: [])
    public var now: () -> Date = Date.init

    public init() {}

    public func push(_ changes: [SyncWireChange], deviceId: String) throws -> SyncPushResponse {
        precondition(changes.count <= 200, "push over the change limit")
        precondition(changes.reduce(0) { $0 + $1.ciphertextBytes } <= 4 * 1024 * 1024, "push over the byte limit")
        pushes.append(changes)
        var accepted: [SyncPushResponse.Accepted] = []
        var rejected: [SyncPushResponse.Rejected] = []
        let nowMs = Int64(now().timeIntervalSince1970 * 1000)
        for change in changes {
            precondition(change.ciphertextBytes <= 3 * 1024 * 1024, "record over the size limit")
            if let hlc = HLC(change.hlc), hlc.milliseconds > nowMs + 5 * 60 * 1000 {
                rejected.append(.init(id: change.id, reason: "clock", row: nil)); continue
            }
            let stored = rows[change.id]
            if let stored, stored.hlc == change.hlc { accepted.append(.init(id: change.id, seq: stored.seq)); continue }
            if let stored, stored.hlc > change.hlc { rejected.append(.init(id: change.id, reason: "stale", row: stored)); continue }
            if let stored, [2, 4].contains(change.type), change.baseHlc != stored.hlc {
                rejected.append(.init(id: change.id, reason: "conflict", row: stored)); continue
            }
            let blobId = change.deleted ? nil : change.blobId
            if let blobId, blobs[blobId] == nil { rejected.append(.init(id: change.id, reason: "blob_missing", row: nil)); continue }
            seq += 1
            rows[change.id] = SyncWireRow(id: change.id, type: change.type, hlc: change.hlc, deviceId: deviceId, deleted: change.deleted,
                                          keyId: change.keyId, size: change.ciphertextBytes, blobId: blobId, seq: seq,
                                          ct: change.deleted ? nil : change.ct)
            accepted.append(.init(id: change.id, seq: seq))
        }
        return SyncPushResponse(accepted: accepted, rejected: rejected, maxSeq: seq, epoch: epoch)
    }

    public func pull(since: Int, limit: Int) -> SyncPullResponse {
        if since > seq { return SyncPullResponse(rows: [], hasMore: false, maxSeq: seq, nextSince: 0, epoch: epoch, resync: true) }
        let all = rows.values.filter { $0.seq > since }.sorted { $0.seq < $1.seq }
        let page = Array(all.prefix(limit))
        return SyncPullResponse(rows: page, hasMore: all.count > page.count, maxSeq: seq,
                                nextSince: page.last?.seq ?? since, epoch: epoch, resync: false)
    }

    public func putBlob(_ id: String, _ data: Data) { if blobs[id] == nil { blobs[id] = data } }
    public func blob(_ id: String) throws -> Data {
        guard let data = blobs[id] else { throw SyncServerError(status: 404, code: "not_found") }
        return data
    }
    public func dropBlob(_ id: String) { blobs[id] = nil }

    // Test hooks.
    public func tamper(_ id: String) {
        guard var row = rows[id], let text = row.ct, var data = Data(base64Encoded: text) else { return }
        data[data.count - 1] ^= 0x01
        row.ct = data.base64EncodedString()
        rows[id] = row
    }
    public func insert(_ row: SyncWireRow) { seq += 1; var row = row; row.seq = seq; rows[row.id] = row }
    /// A restore from backup: a new epoch, and everything after `keepingThrough` is gone.
    public func restore(keepingThrough keep: Int) {
        rows = rows.filter { $0.value.seq <= keep }
        seq = keep
        epoch = UUID().uuidString.lowercased()
    }
    public func setNow(_ date: Date) { now = { date } }
}

/// A device's connection to a `FakeSyncServer`, with failure injection.
public final class FakeSyncTransport: SyncTransport, @unchecked Sendable {
    public let server: FakeSyncServer
    public let deviceId: String
    private let lock = NSLock()
    private var _offline = false
    private var _loseNextPushResponse = false
    private var _mainThreadCalls = 0
    private var _requests = 0
    private var _dropBlobsBeforeNextPush = false

    public init(server: FakeSyncServer, deviceId: String) {
        self.server = server
        self.deviceId = deviceId
    }

    public var offline: Bool { get { locked { _offline } } set { locked { _offline = newValue } } }
    /// The next push reaches the server but its response is lost (the client sees an error).
    public var loseNextPushResponse: Bool { get { locked { _loseNextPushResponse } } set { locked { _loseNextPushResponse = newValue } } }
    /// Blobs uploaded so far vanish right before the next push (expired on the server).
    public var dropBlobsBeforeNextPush: Bool { get { locked { _dropBlobsBeforeNextPush } } set { locked { _dropBlobsBeforeNextPush = newValue } } }
    public var mainThreadCalls: Int { locked { _mainThreadCalls } }
    public var requests: Int { locked { _requests } }

    private func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }

    private func enter() throws {
        try locked {
            _requests += 1
            if Thread.isMainThread { _mainThreadCalls += 1 }
            if _offline { throw URLError(.notConnectedToInternet) }
        }
    }

    public func push(_ changes: [SyncWireChange]) async throws -> SyncPushResponse {
        try enter()
        let drop = locked { () -> Bool in let value = _dropBlobsBeforeNextPush; _dropBlobsBeforeNextPush = false; return value }
        if drop { for id in await server.blobs.keys { await server.dropBlob(id) } }
        let response = try await server.push(changes, deviceId: deviceId)
        let lose = locked { () -> Bool in let value = _loseNextPushResponse; _loseNextPushResponse = false; return value }
        if lose { throw URLError(.networkConnectionLost) }
        return response
    }

    public func pull(since: Int, limit: Int) async throws -> SyncPullResponse {
        try enter()
        return await server.pull(since: since, limit: limit)
    }

    public func uploadBlob(id: String, data: Data) async throws {
        try enter()
        await server.putBlob(id, data)
    }

    public func downloadBlob(id: String) async throws -> Data {
        try enter()
        return try await server.blob(id)
    }

    public func keys() async throws -> SyncKeysResponse {
        try enter()
        return await server.keys
    }

    public func putKeys(_ request: SyncPutKeysRequest) async throws {
        try enter()
    }
}
