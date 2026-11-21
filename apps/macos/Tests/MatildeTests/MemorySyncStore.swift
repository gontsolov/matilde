import Foundation
@testable import Matilde

/// A `SyncLocalStore` over in-memory entities with a small change ledger that follows the rules of
/// `Workspace.trackSyncChanges()` (per-field clocks, tombstones, `server_hlc`). Lets the engine be
/// tested end to end (and on Linux) without a workspace.
final class MemorySyncStore: SyncLocalStore {
    struct Entity: Equatable {
        var type: SyncRecordType
        var fields: [String: JSONValue]
    }
    struct Entry {
        var type: SyncRecordType
        var hlc: HLC
        var serverHLC: HLC?
        var deleted: Bool
        var fields: [String: JSONValue]
        var clocks: [String: HLC]
        var pending: Bool { serverHLC != hlc }
    }

    let device: String
    private(set) var clock: HybridClock
    var entities: [String: Entity] = [:]
    var assets: [String: Data] = [:]
    private(set) var ledger: [String: Entry] = [:]
    private var cursorValue = SyncCursor()
    private var blobCache: [String: (hlc: HLC, reference: SyncBlobReference)] = [:]
    private(set) var mainThreadCalls = 0
    private(set) var conflictCopies: [SyncRecord] = []
    var now: () -> Date = Date.init

    init(device: String = UUID().uuidString.lowercased()) {
        self.device = device
        clock = HybridClock(device: device)
    }

    private func check() { if Thread.isMainThread { mainThreadCalls += 1 } }

    // MARK: Local edits (what the app would do)

    func put(_ id: String, _ type: SyncRecordType, _ fields: [String: JSONValue]) { entities[id] = Entity(type: type, fields: fields) }
    func remove(_ id: String) { entities[id] = nil }

    @discardableResult
    func draft(_ id: String = UUID().uuidString.lowercased(), path: String, text: String) -> String {
        put(id, .draft, ["path": .string(path), "family": .string(id), "goal": .string("")])
        put(SyncID.derived("body", id), .body, ["draft": .string(id), "text": .string(text)])
        return id
    }

    func text(of draft: String) -> String? {
        guard case .string(let text)? = entities[SyncID.derived("body", draft)]?.fields["text"] else { return nil }
        return text
    }

    func setText(_ text: String, of draft: String) { entities[SyncID.derived("body", draft)]?.fields["text"] = .string(text) }

    var pendingCount: Int { ledger.values.filter(\.pending).count }

    // MARK: SyncLocalStore

    func track() throws {
        check()
        for (id, entity) in entities.sorted(by: { $0.key < $1.key }) {
            if let entry = ledger[id], !entry.deleted, entry.fields == entity.fields { continue }
            let hlc = clock.next(now: now())
            var clocks: [String: HLC] = [:]
            for (key, value) in entity.fields {
                if let entry = ledger[id], !entry.deleted, entry.fields[key] == value, let old = entry.clocks[key] { clocks[key] = old }
                else { clocks[key] = hlc }
            }
            ledger[id] = Entry(type: entity.type, hlc: hlc, serverHLC: ledger[id]?.serverHLC, deleted: false, fields: entity.fields, clocks: clocks)
        }
        for (id, entry) in ledger where !entry.deleted && entities[id] == nil {
            ledger[id] = Entry(type: entry.type, hlc: clock.next(now: now()), serverHLC: entry.serverHLC, deleted: true, fields: [:], clocks: [:])
        }
    }

    private func record(_ id: String, _ entry: Entry) -> SyncRecord {
        SyncRecord(id: id, type: entry.type, hlc: entry.hlc, baseHlc: entry.serverHLC, deleted: entry.deleted,
                   fields: entry.fields, fieldHLCs: entry.clocks)
    }

    func pendingRecords(limit: Int) throws -> [SyncRecord] {
        try track()
        return ledger.filter { $0.value.pending }.sorted { $0.value.hlc < $1.value.hlc }.prefix(limit).map { record($0.key, $0.value) }
    }

    func localStates(ids: [String]) throws -> [String: SyncLocalState] {
        check()
        var out: [String: SyncLocalState] = [:]
        for id in ids {
            guard let entry = ledger[id] else { continue }
            out[id] = SyncLocalState(hlc: entry.hlc, serverHLC: entry.serverHLC, deleted: entry.deleted, record: record(id, entry))
        }
        return out
    }

    func apply(_ steps: [SyncStep], blobs: [String: Data]) throws -> SyncApplyReport {
        check()
        var report = SyncApplyReport()
        for step in steps {
            guard case .conflictCopy(let copy) = step else { continue }
            conflictCopies.append(copy)
            guard case .string(let draft)? = copy.fields["draft"] ?? ledger[copy.id]?.fields["draft"] else { continue }
            let original = entities[draft]?.fields ?? ledger[draft]?.fields ?? [:]
            var path = "Recovered.md"
            if case .string(let value)? = original["path"] { path = value.replacingOccurrences(of: ".md", with: "") + " (conflict).md" }
            let id = UUID().uuidString.lowercased()
            put(id, .draft, ["path": .string(path), "family": original["family"] ?? .string(draft), "parent": .string(draft), "goal": .string("")])
            put(SyncID.derived("body", id), .body, ["draft": .string(id), "text": copy.fields["text"] ?? .string("")])
            report.conflicts += 1
        }
        for step in steps {
            switch step {
            case .write(let record, let server):
                if record.deleted { entities[record.id] = nil } else {
                    entities[record.id] = Entity(type: record.type, fields: record.fields)
                    if let data = blobs[record.id] { assets[record.id] = data }
                }
                ledger[record.id] = Entry(type: record.type, hlc: record.hlc, serverHLC: server, deleted: record.deleted,
                                          fields: record.fields, clocks: record.fieldHLCs)
                clock.observe(record.hlc)
                report.applied += 1
            case .acknowledge(let id, let server):
                ledger[id]?.serverHLC = server
            case .conflictCopy:
                break
            }
        }
        return report
    }

    func markAccepted(_ versions: [(id: String, hlc: HLC)]) throws {
        check()
        for version in versions where ledger[version.id]?.hlc == version.hlc { ledger[version.id]?.serverHLC = version.hlc }
    }

    func observeClock(_ remote: HLC) throws { check(); clock.observe(remote) }
    func nextHLC() throws -> HLC { check(); return clock.next(now: now()) }
    func cursor() throws -> SyncCursor { check(); return cursorValue }
    func saveCursor(_ cursor: SyncCursor) throws { check(); cursorValue = cursor }

    func resetServerState(userId: String, accountChanged: Bool) throws {
        check()
        if accountChanged { ledger = ledger.filter { !$0.value.deleted } }
        for id in ledger.keys { ledger[id]?.serverHLC = nil }
        cursorValue = SyncCursor(userId: userId, since: 0, epoch: nil)
        blobCache = [:]
    }

    func assetData(for record: SyncRecord) throws -> Data? { check(); return assets[record.id] }

    func cachedBlob(recordId: String, hlc: HLC) throws -> SyncBlobReference? {
        check()
        guard let cached = blobCache[recordId], cached.hlc == hlc else { return nil }
        return cached.reference
    }

    func cacheBlob(_ reference: SyncBlobReference, recordId: String, hlc: HLC) throws { check(); blobCache[recordId] = (hlc, reference) }
    func forgetBlob(recordId: String) throws { check(); blobCache[recordId] = nil }
}
