import Foundation

// SYNC-07: deciding what a pulled (or push-rejected) server version means for the local copy.
// Pure: no I/O. The engine turns the result into `SyncStep`s for the local store.
//
// Rules (plans/cloud-sync.md §0, docs/sync-client.md):
// - Unknown locally, or no unpushed local change: take the server version.
// - Metadata (LWW types) with unpushed local changes: merge field by field, each field keeping the
//   side with the newer field clock. If the result differs from the server's, it becomes a new local
//   version (fresh HLC) that the next push sends with the server version as its base.
// - Bodies (CAS) with unpushed local changes: the server text stays the draft; the local text becomes
//   a conflict branch in the same family. Equal texts and an empty local text are not conflicts.
// - Delete vs edit: for bodies the delete stands and the edit survives as a conflict branch (an edit
//   is never silently resurrected or lost). Other types: last writer wins by HLC.
// - Stash (CAS) conflicts keep both texts: the server's, then the local one.

/// What this device knows about one record.
public struct SyncLocalState: Equatable {
    public var hlc: HLC
    /// The version the server last acknowledged or delivered.
    public var serverHLC: HLC?
    public var deleted: Bool
    /// The current version with its fields; nil when the entity can't be read right now.
    public var record: SyncRecord?
    public var pending: Bool { serverHLC != hlc }

    public init(hlc: HLC, serverHLC: HLC? = nil, deleted: Bool, record: SyncRecord? = nil) {
        self.hlc = hlc
        self.serverHLC = serverHLC
        self.deleted = deleted
        self.record = record
    }
}

/// One instruction for the local store.
public enum SyncStep: Equatable {
    /// Make the local entity match `record` (delete it for a tombstone) and remember `record.hlc` as
    /// the local version and `server` as the server's. A merge writes a record with a fresh HLC, so
    /// it stays pending.
    case write(SyncRecord, server: HLC)
    /// Only remember that the server now holds `server` (the local version stays pending and wins).
    case acknowledge(id: String, server: HLC)
    /// Keep this body's text as a new draft branched from the body's draft (a conflict branch).
    case conflictCopy(SyncRecord)

    public var recordID: String {
        switch self {
        case .write(let record, _): record.id
        case .acknowledge(let id, _): id
        case .conflictCopy(let record): record.id
        }
    }
}

public enum SyncMerge {
    public static let stashSeparator = "\n\n"

    public static func resolve(local: SyncLocalState?, remote: SyncRecord, newHLC: () throws -> HLC) rethrows -> [SyncStep] {
        guard let local else { return [.write(remote, server: remote.hlc)] }
        if local.hlc == remote.hlc { return local.serverHLC == remote.hlc ? [] : [.acknowledge(id: remote.id, server: remote.hlc)] }
        // A version we already know the server has (our pending edit builds on it): nothing new.
        if local.serverHLC == remote.hlc { return [] }
        guard local.pending else {
            // Newer server version: take it. Older (the server lost ours, e.g. after a restore): push ours again.
            return remote.hlc > local.hlc ? [.write(remote, server: remote.hlc)] : [.acknowledge(id: remote.id, server: remote.hlc)]
        }
        return remote.type.usesCompareAndSwap
            ? try resolveCompareAndSwap(local: local, remote: remote, newHLC: newHLC)
            : try resolveLastWriterWins(local: local, remote: remote, newHLC: newHLC)
    }

    private static func newerWins(_ local: SyncLocalState, _ remote: SyncRecord) -> [SyncStep] {
        remote.hlc > local.hlc ? [.write(remote, server: remote.hlc)] : [.acknowledge(id: remote.id, server: remote.hlc)]
    }

    private static func resolveLastWriterWins(local: SyncLocalState, remote: SyncRecord, newHLC: () throws -> HLC) rethrows -> [SyncStep] {
        guard !local.deleted, !remote.deleted else { return newerWins(local, remote) }
        guard let current = local.record else { return [.write(remote, server: remote.hlc)] }
        let merged = mergeFields(local: current, remote: remote)
        if merged.fields == remote.fields { return [.write(remote, server: remote.hlc)] }
        if merged.fields == current.fields, local.hlc > remote.hlc { return [.acknowledge(id: remote.id, server: remote.hlc)] }
        let record = SyncRecord(id: remote.id, type: remote.type, hlc: try newHLC(), baseHlc: remote.hlc, deleted: false,
                                fields: merged.fields, fieldHLCs: merged.clocks)
        return [.write(record, server: remote.hlc)]
    }

    private static func resolveCompareAndSwap(local: SyncLocalState, remote: SyncRecord, newHLC: () throws -> HLC) rethrows -> [SyncStep] {
        let isBody = remote.type == .body
        switch (local.deleted, remote.deleted) {
        case (true, true):
            return [.write(remote, server: remote.hlc)]
        case (false, true):
            // Deleted elsewhere, edited here.
            guard isBody else { return [.acknowledge(id: remote.id, server: remote.hlc)] }
            guard let current = local.record, !isEmptyText(current) else { return [.write(remote, server: remote.hlc)] }
            return [.conflictCopy(current), .write(remote, server: remote.hlc)]
        case (true, false):
            // Deleted here, edited elsewhere.
            guard isBody else { return [.write(remote, server: remote.hlc)] }
            return isEmptyText(remote) ? [.acknowledge(id: remote.id, server: remote.hlc)]
                : [.conflictCopy(remote), .acknowledge(id: remote.id, server: remote.hlc)]
        case (false, false):
            guard let current = local.record else { return [.write(remote, server: remote.hlc)] }
            if current.fields["text"] == remote.fields["text"] || isEmptyText(current) { return [.write(remote, server: remote.hlc)] }
            if isBody { return [.conflictCopy(current), .write(remote, server: remote.hlc)] }
            guard case .string(let mine)? = current.fields["text"], case .string(let theirs)? = remote.fields["text"] else {
                return [.write(remote, server: remote.hlc)]
            }
            if theirs.isEmpty || theirs.contains(mine) {
                return [.write(remote, server: remote.hlc)]
            }
            var fields = remote.fields
            fields["text"] = .string(mine.contains(theirs) ? mine : theirs + stashSeparator + mine)
            let hlc = try newHLC()
            var clocks = remote.fieldHLCs
            clocks["text"] = hlc
            return [.write(SyncRecord(id: remote.id, type: remote.type, hlc: hlc, baseHlc: remote.hlc, deleted: false,
                                      fields: fields, fieldHLCs: clocks), server: remote.hlc)]
        }
    }

    private static func isEmptyText(_ record: SyncRecord) -> Bool {
        guard case .string(let text)? = record.fields["text"] else { return true }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Field-level merge: every field keeps the side whose field clock is newer. A field missing on
    /// one side counts as removed at that side's record HLC.
    public static func mergeFields(local: SyncRecord, remote: SyncRecord) -> (fields: [String: JSONValue], clocks: [String: HLC]) {
        var fields: [String: JSONValue] = [:]
        var clocks: [String: HLC] = [:]
        for key in Set(local.fields.keys).union(remote.fields.keys) {
            let localClock = local.fields[key] == nil ? local.hlc : (local.fieldHLCs[key] ?? local.hlc)
            let remoteClock = remote.fields[key] == nil ? remote.hlc : (remote.fieldHLCs[key] ?? remote.hlc)
            let useRemote = remoteClock > localClock || (remoteClock == localClock && remote.hlc > local.hlc)
            let (value, clock) = useRemote ? (remote.fields[key], remoteClock) : (local.fields[key], localClock)
            if let value {
                fields[key] = value
                clocks[key] = clock
            }
        }
        return (fields, clocks)
    }
}
