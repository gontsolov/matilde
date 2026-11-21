import Foundation

// SYNC-07: the push/pull loop. Runs off the main thread (an actor); talks to the server through a
// `SyncTransport` and to the local data through a `SyncLocalStore`. Holds no plaintext beyond one
// batch at a time and logs nothing (the caller logs the counts in `SyncReport`).
//
// One `sync()`:
// 1. Bind the account: a different user than last time forgets every server acknowledgement and the
//    cursor, so the new account gets a full upload and a full download (merged by id and HLC).
// 2. Pull pages since the cursor until `hasMore` is false. Each row is decrypted (rows that fail
//    authentication are skipped and counted, never applied), resolved against the local copy with
//    `SyncMerge`, and applied. The cursor is saved after each page, so an interrupted pull resumes.
//    A new store epoch or `resync` restarts from 0 and re-queues anything the server no longer has.
// 3. Push every pending record in batches (200 changes / ~4 MiB). Accepted versions are marked; a
//    `stale` or `conflict` rejection carries the server's row, which is resolved like a pulled row
//    (merged metadata or a conflict branch), and the merged result goes out in the next round.

/// The device-local sync position.
public struct SyncCursor: Equatable, Sendable {
    public var userId: String?
    public var since: Int = 0
    public var epoch: String?

    public init(userId: String? = nil, since: Int = 0, epoch: String? = nil) {
        self.userId = userId
        self.since = since
        self.epoch = epoch
    }
}

public struct SyncApplyReport: Equatable {
    public var applied = 0
    public var conflicts = 0
    /// Records kept aside until what they belong to arrives (e.g. a body before its draft).
    public var parked = 0

    public init() {}
}

/// The local side of sync. Calls are synchronous and may block (database, files); the engine
/// calls them from its own executor, never the main thread.
public protocol SyncLocalStore: AnyObject {
    /// Bring the change ledger up to date with the local data.
    func track() throws
    /// Records whose current version the server hasn't acknowledged, oldest first.
    func pendingRecords(limit: Int) throws -> [SyncRecord]
    /// What this device knows about these records (missing ids are unknown locally).
    func localStates(ids: [String]) throws -> [String: SyncLocalState]
    /// Apply resolved steps. `blobs` holds decrypted asset files by record id.
    func apply(_ steps: [SyncStep], blobs: [String: Data]) throws -> SyncApplyReport
    func markAccepted(_ versions: [(id: String, hlc: HLC)]) throws
    func observeClock(_ remote: HLC) throws
    /// A fresh local HLC (for merged versions).
    func nextHLC() throws -> HLC
    func cursor() throws -> SyncCursor
    func saveCursor(_ cursor: SyncCursor) throws
    /// Forget every server acknowledgement (all records become pending) and the cursor. For a
    /// different account, local tombstones are dropped too (the new account never had those records).
    func resetServerState(userId: String, accountChanged: Bool) throws
    /// The file behind an asset record; nil if it can't be read right now.
    func assetData(for record: SyncRecord) throws -> Data?
    /// The blob already uploaded for this version of a record, so retries don't re-upload.
    func cachedBlob(recordId: String, hlc: HLC) throws -> SyncBlobReference?
    func cacheBlob(_ reference: SyncBlobReference, recordId: String, hlc: HLC) throws
    func forgetBlob(recordId: String) throws
}

public struct SyncReport: Equatable, Sendable {
    public var pushed = 0
    public var pulled = 0
    public var applied = 0
    public var conflicts = 0
    /// Rows that failed authentication (tampered, wrong key, another account): skipped.
    public var unreadable = 0
    /// Records the server refused for a clock too far ahead; retried next time.
    public var clockRejected = 0
    public var requests = 0
    public var blobsUploaded = 0
    public var blobsDownloaded = 0
    public var quotaExceeded = false

    public init() {}

    public static func + (lhs: SyncReport, rhs: SyncReport) -> SyncReport {
        var out = lhs
        out.pushed += rhs.pushed; out.pulled += rhs.pulled; out.applied += rhs.applied; out.conflicts += rhs.conflicts
        out.unreadable += rhs.unreadable; out.clockRejected += rhs.clockRejected; out.requests += rhs.requests
        out.blobsUploaded += rhs.blobsUploaded; out.blobsDownloaded += rhs.blobsDownloaded
        out.quotaExceeded = lhs.quotaExceeded || rhs.quotaExceeded
        return out
    }
}

public enum SyncEngineError: Error, Equatable {
    /// A row uses an account-key epoch this device doesn't have: fetch `GET /v1/keys` and rebuild the ring.
    case unknownKey(Int)
}

public actor SyncEngine {
    public static let maxPushRounds = 10
    /// Records loaded per push round; each round is split into server-sized batches.
    public static let pushWindow = 5_000

    public let transport: SyncTransport
    public let store: SyncLocalStore
    public private(set) var ring: AccountKeyRing
    private var report = SyncReport()

    public init(transport: SyncTransport, store: SyncLocalStore, ring: AccountKeyRing) {
        self.transport = transport
        self.store = store
        self.ring = ring
    }

    public func updateRing(_ ring: AccountKeyRing) { self.ring = ring }

    /// Pull, then push. Throws transport errors as they come (the caller backs off and retries);
    /// whatever was applied or acknowledged before the error stays.
    @discardableResult
    public func sync() async throws -> SyncReport {
        report = SyncReport()
        try bindAccount()
        try await pullAll()
        try await pushAll()
        return report
    }

    @discardableResult
    public func pullOnly() async throws -> SyncReport {
        report = SyncReport()
        try bindAccount()
        try await pullAll()
        return report
    }

    private func bindAccount() throws {
        let cursor = try store.cursor()
        if cursor.userId != ring.userId { try store.resetServerState(userId: ring.userId, accountChanged: true) }
    }

    // MARK: Pull

    private func pullAll() async throws {
        try store.track()
        var cursor = try store.cursor()
        var restarted = false
        while true {
            let page = try await transport.pull(since: cursor.since, limit: SyncLimits.pullPageSize)
            report.requests += 1
            let epochChanged = cursor.epoch != nil && cursor.epoch != page.epoch
            if (page.resync || epochChanged) && !restarted {
                // The server's store was reset or restored: read everything again and re-send what it lost.
                restarted = true
                try store.resetServerState(userId: ring.userId, accountChanged: false)
                cursor = SyncCursor(userId: ring.userId, since: 0, epoch: page.epoch)
                try store.saveCursor(cursor)
                continue
            }
            if !page.rows.isEmpty {
                try store.track()
                try await applyRows(page.rows)
            }
            cursor = SyncCursor(userId: ring.userId, since: page.nextSince, epoch: page.epoch)
            try store.saveCursor(cursor)
            if !page.hasMore { break }
        }
    }

    /// A decrypted row, ready to resolve.
    private struct Decoded {
        var record: SyncRecord
        /// The asset's blob (asset records only).
        var asset: SyncBlobReference?
    }

    private func applyRows(_ rows: [SyncWireRow], pulled: Bool = true) async throws {
        // The newest row per id wins (a page never holds two, but rejected rows can repeat).
        var latest: [String: SyncWireRow] = [:]
        for row in rows where latest[row.id].map({ $0.hlc < row.hlc }) ?? true { latest[row.id] = row }
        let ordered = rows.filter { latest[$0.id] == $0 }
        let states = try store.localStates(ids: ordered.map(\.id))
        var steps: [SyncStep] = []
        var assets: [String: SyncBlobReference] = [:]
        if let newest = ordered.compactMap({ HLC($0.hlc) }).max() { try store.observeClock(newest) }
        for row in ordered {
            guard let type = SyncRecordType(rawValue: row.type), let hlc = HLC(row.hlc) else { report.unreadable += 1; continue }
            if pulled { report.pulled += 1 }
            let state = states[row.id]
            // Our own version coming back: no need to decrypt it.
            if let state, state.hlc == hlc {
                if state.serverHLC != hlc { steps.append(.acknowledge(id: row.id, server: hlc)) }
                continue
            }
            if let state, state.serverHLC == hlc { continue }
            guard let decoded = try await decode(row, type: type, hlc: hlc) else { continue }
            if let asset = decoded.asset { assets[row.id] = asset }
            steps += try SyncMerge.resolve(local: state, remote: decoded.record, newHLC: { try store.nextHLC() })
        }
        guard !steps.isEmpty else { return }
        var blobs: [String: Data] = [:]
        for step in steps {
            guard case .write(let record, _) = step, record.type == .asset, !record.deleted, let reference = assets[record.id] else { continue }
            if let data = try await downloadBlob(reference) { blobs[record.id] = data }
        }
        let applied = try store.apply(steps, blobs: blobs)
        report.applied += applied.applied
        report.conflicts += applied.conflicts
    }

    /// Decrypts a row. Nil (counted as unreadable) when it fails authentication or doesn't parse:
    /// a tampered or foreign row must never reach the local data.
    private func decode(_ row: SyncWireRow, type: SyncRecordType, hlc: HLC) async throws -> Decoded? {
        do {
            guard !row.deleted else {
                return Decoded(record: try SyncRecord.decode(id: row.id, type: type, hlc: hlc, deleted: true, plaintext: nil))
            }
            guard var framed = try SyncCodec.open(row, type: type, hlc: hlc, ring: ring) else { return nil }
            if let reference = try SyncCodec.reference(in: framed) {
                guard row.blobId == reference.blob, let data = try await downloadBlob(reference) else { report.unreadable += 1; return nil }
                framed = data
            }
            var record = try SyncRecord.decode(id: row.id, type: type, hlc: hlc, deleted: false, plaintext: try SyncCodec.unframe(framed))
            var asset: SyncBlobReference?
            if type == .asset {
                let blob = record.fields.removeValue(forKey: SyncCodec.blobField)
                let key = record.fields.removeValue(forKey: SyncCodec.blobKeyField)
                record.fieldHLCs[SyncCodec.blobField] = nil
                record.fieldHLCs[SyncCodec.blobKeyField] = nil
                if case .string(let id)? = blob, case .string(let keyText)? = key, id == row.blobId,
                   let keyData = Data(base64Encoded: keyText), let blobKey = try? SyncBlobKey(bytes: keyData) {
                    asset = SyncBlobReference(blob: id, key: blobKey, size: (try? record.payload(AssetPayload.self).size) ?? 0)
                }
            }
            return Decoded(record: record, asset: asset)
        } catch SyncCryptoError.unknownKey(let id) {
            throw SyncEngineError.unknownKey(id)
        } catch is SyncCryptoError, is SyncModelError, is SyncCodecError, is DecodingError {
            report.unreadable += 1
            return nil
        }
    }

    /// Nil when the blob is gone from the server (counted unreadable); other errors propagate.
    private func downloadBlob(_ reference: SyncBlobReference) async throws -> Data? {
        let sealed: Data
        do {
            sealed = try await transport.downloadBlob(id: reference.blob)
            report.requests += 1
        } catch let error as SyncServerError where error.status == 404 {
            report.requests += 1
            report.unreadable += 1
            return nil
        }
        report.blobsDownloaded += 1
        do { return try SyncBlobCrypto.open(sealed, blobId: reference.blob, key: reference.key) }
        catch { report.unreadable += 1; return nil }
    }

    // MARK: Push

    private struct Outgoing {
        var record: SyncRecord
        var change: SyncWireChange
    }

    private func pushAll() async throws {
        var skipped = Set<String>()
        for _ in 0..<Self.maxPushRounds {
            let records = try store.pendingRecords(limit: Self.pushWindow).filter { !skipped.contains($0.id) }
            if records.isEmpty { return }
            var batch: [Outgoing] = []
            var bytes = 0
            var progressed = false
            for record in records {
                guard let outgoing = try await prepare(record) else { skipped.insert(record.id); continue }
                let size = outgoing.change.ciphertextBytes
                if !batch.isEmpty, batch.count >= SyncLimits.pushMaxChanges || bytes + size > SyncLimits.pushMaxCiphertextBytes {
                    if try await send(batch, skipped: &skipped) { progressed = true }
                    batch = []
                    bytes = 0
                }
                batch.append(outgoing)
                bytes += size
            }
            if !batch.isEmpty, try await send(batch, skipped: &skipped) { progressed = true }
            if !progressed && records.allSatisfy({ skipped.contains($0.id) }) { return }
        }
    }

    /// Encrypts one record (uploading its blob first for assets and oversize records). Nil when it
    /// can't be sent right now (an asset file that can't be read).
    private func prepare(_ record: SyncRecord) async throws -> Outgoing? {
        guard !record.deleted else {
            return Outgoing(record: record, change: try SyncCodec.change(for: record, framed: nil, blobId: nil, ring: ring))
        }
        var sending = record
        var blobId: String?
        if record.type == .asset {
            let reference: SyncBlobReference
            if let cached = try store.cachedBlob(recordId: record.id, hlc: record.hlc) {
                reference = cached
            } else {
                guard let data = try store.assetData(for: record), data.count <= SyncLimits.blobMaxBytes - 64 * 1024 else { return nil }
                reference = try await uploadBlob(data)
                try store.cacheBlob(reference, recordId: record.id, hlc: record.hlc)
            }
            sending.fields[SyncCodec.blobField] = .string(reference.blob)
            sending.fields[SyncCodec.blobKeyField] = .string(reference.key.key.syncBytes.base64EncodedString())
            sending.fieldHLCs[SyncCodec.blobField] = record.hlc
            sending.fieldHLCs[SyncCodec.blobKeyField] = record.hlc
            blobId = reference.blob
        }
        guard let plaintext = try sending.plaintext() else { return nil }
        var framed = SyncCodec.frame(plaintext)
        // Envelope overhead is small; keep a margin under the server's per-record limit.
        if framed.count > SyncLimits.recordMaxCiphertextBytes - 64 * 1024 {
            guard framed.count <= SyncLimits.blobMaxBytes - 64 * 1024 else { return nil }
            let reference: SyncBlobReference
            if let cached = try store.cachedBlob(recordId: record.id, hlc: record.hlc) {
                reference = cached
            } else {
                reference = try await uploadBlob(framed)
                try store.cacheBlob(reference, recordId: record.id, hlc: record.hlc)
            }
            framed = try SyncCodec.referenceFrame(reference)
            blobId = reference.blob
        }
        return Outgoing(record: record, change: try SyncCodec.change(for: record, framed: framed, blobId: blobId, ring: ring))
    }

    private func uploadBlob(_ data: Data) async throws -> SyncBlobReference {
        let id = UUID().uuidString.lowercased()
        let key = SyncBlobKey.generate()
        try await transport.uploadBlob(id: id, data: try SyncBlobCrypto.seal(data, blobId: id, key: key))
        report.requests += 1
        report.blobsUploaded += 1
        return SyncBlobReference(blob: id, key: key, size: data.count)
    }

    /// Sends one batch. True if anything was accepted or resolved (so another round makes sense).
    private func send(_ batch: [Outgoing], skipped: inout Set<String>) async throws -> Bool {
        let response = try await transport.push(batch.map(\.change))
        report.requests += 1
        let sent = Dictionary(batch.map { ($0.record.id, $0.record) }, uniquingKeysWith: { first, _ in first })
        let accepted = response.accepted.compactMap { item in sent[item.id].map { (id: $0.id, hlc: $0.hlc) } }
        try store.markAccepted(accepted)
        report.pushed += accepted.count
        var rows: [SyncWireRow] = []
        for rejection in response.rejected {
            switch rejection.reason {
            case "stale", "conflict":
                if let row = rejection.row { rows.append(row) } else { skipped.insert(rejection.id) }
            case "blob_missing":
                // The blob expired or never arrived: upload it again next round.
                try store.forgetBlob(recordId: rejection.id)
            case "clock":
                report.clockRejected += 1
                skipped.insert(rejection.id)
            case "quota":
                report.quotaExceeded = true
                skipped.insert(rejection.id)
            default:
                skipped.insert(rejection.id)
            }
        }
        if !rows.isEmpty {
            try store.track()
            try await applyRows(rows, pulled: false)
        }
        return !accepted.isEmpty || !rows.isEmpty || response.rejected.contains { $0.reason == "blob_missing" }
    }
}
