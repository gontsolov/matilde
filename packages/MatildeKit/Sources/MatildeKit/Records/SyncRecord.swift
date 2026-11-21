import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// SYNC-02: the portable, sync-ready record model. Foundation (+ CryptoKit for hashing) only:
// no AppKit, no networking. Contract: docs/sync-model.md; wire format: server/PROTOCOL.md.

/// Record types in the cleartext envelope. Raw values are the server's `type` integers
/// (server/PROTOCOL.md); the server accepts 1...63, so `folder` needs no server change.
public enum SyncRecordType: Int, CaseIterable, Codable, Comparable {
    case draft = 1
    case body = 2
    case snapshot = 3
    case stash = 4
    case asset = 5
    case comment = 6
    case thread = 7
    case message = 8
    case readMarker = 9
    case trashed = 10
    case settings = 11
    case folder = 12

    public var name: String {
        switch self {
        case .draft: "draft"
        case .body: "body"
        case .snapshot: "snapshot"
        case .stash: "stash"
        case .asset: "asset"
        case .comment: "comment"
        case .thread: "thread"
        case .message: "message"
        case .readMarker: "readMarker"
        case .trashed: "trashed"
        case .settings: "settings"
        case .folder: "folder"
        }
    }

    /// Body-like types use compare-and-swap on the server (push carries `baseHlc`);
    /// everything else is last-writer-wins by HLC.
    public var usesCompareAndSwap: Bool { self == .body || self == .stash }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Hybrid logical clock value `<ms:13>.<counter:5>.<deviceID>`. Fixed widths make
/// string order equal clock order, which is how the server compares them.
public struct HLC: Hashable, Comparable, Codable, CustomStringConvertible {
    public static let maxCounter = 99_999
    public let milliseconds: Int64
    public let counter: Int
    public let device: String

    public init(milliseconds: Int64, counter: Int, device: String) {
        precondition((0...9_999_999_999_999).contains(milliseconds) && (0...Self.maxCounter).contains(counter), "HLC out of range")
        precondition(SyncID.isCanonical(device), "HLC device must be a lowercase UUID")
        self.milliseconds = milliseconds
        self.counter = counter
        self.device = device
    }

    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 13, parts[1].count == 5,
              parts[0].allSatisfy(\.isASCIIDigit), parts[1].allSatisfy(\.isASCIIDigit),
              let ms = Int64(parts[0]), let counter = Int(parts[1]), SyncID.isCanonical(String(parts[2])) else { return nil }
        self.init(milliseconds: ms, counter: counter, device: String(parts[2]))
    }

    public var description: String {
        let ms = String(milliseconds), count = String(counter)
        return String(repeating: "0", count: 13 - ms.count) + ms + "." + String(repeating: "0", count: 5 - count.count) + count + "." + device
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.milliseconds, lhs.counter, lhs.device) < (rhs.milliseconds, rhs.counter, rhs.device)
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = HLC(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Malformed HLC"))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

/// Issues monotonically increasing HLCs for one device.
public struct HybridClock {
    public let device: String
    public private(set) var last: HLC?

    public init(device: String, last: HLC? = nil) {
        self.device = device
        self.last = last
    }

    /// A new local event. Never goes backwards, even if the wall clock does.
    public mutating func next(now: Date = Date()) -> HLC {
        let wall = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
        let value: HLC
        if let last, last.milliseconds >= wall {
            value = last.counter < HLC.maxCounter
                ? HLC(milliseconds: last.milliseconds, counter: last.counter + 1, device: device)
                : HLC(milliseconds: last.milliseconds + 1, counter: 0, device: device)
        } else {
            value = HLC(milliseconds: max(wall, 0), counter: 0, device: device)
        }
        last = value
        return value
    }

    /// Fold in a clock seen on another device (pulled or rejected rows), so the next
    /// local write orders after it.
    public mutating func observe(_ remote: HLC) {
        guard let last else {
            self.last = HLC(milliseconds: remote.milliseconds, counter: remote.counter, device: device)
            return
        }
        if (remote.milliseconds, remote.counter) > (last.milliseconds, last.counter) {
            self.last = HLC(milliseconds: remote.milliseconds, counter: remote.counter, device: device)
        }
    }
}

/// Record ids: lowercase canonical UUIDs (they are part of the encryption's associated data,
/// so they must be byte-identical everywhere).
public enum SyncID {
    /// Namespace for name-based ids (UUID version 5, RFC 9562).
    public static let namespace = UUID(uuidString: "6D61746C-6465-5379-6E63-2D7265636F72")!

    public static func isCanonical(_ value: String) -> Bool {
        guard value.count == 36, let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }

    /// An existing Matilde UUID (stored uppercase) as a record id; nil if it isn't a UUID.
    public static func canonical(_ value: String) -> String? {
        UUID(uuidString: value).map { $0.uuidString.lowercased() }
    }

    /// A deterministic id for records that have no UUID of their own (a draft's body, a family's
    /// stash, a file path). Two Macs migrating the same data derive the same id.
    public static func derived(_ kind: String, _ key: String) -> String {
        var bytes = withUnsafeBytes(of: namespace.uuid) { Array($0) }
        bytes += Array("\(kind):\(key)".precomposedStringWithCanonicalMapping.utf8)
        var hash = Array(Insecure.SHA1.hash(data: bytes).prefix(16))
        hash[6] = (hash[6] & 0x0F) | 0x50
        hash[8] = (hash[8] & 0x3F) | 0x80
        let uuid = UUID(uuid: (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7],
                               hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]))
        return uuid.uuidString.lowercased()
    }
}

/// A JSON value with a canonical encoding (sorted keys), used for record fields so that
/// hashing, field-level merging and decoding work the same for every record type.
public enum JSONValue: Codable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Canonical bytes: equal values always encode identically.
    public func canonicalData() throws -> Data { try Self.canonicalEncoder().encode(self) }

    /// Hex SHA-256 of the canonical encoding. Local only (change detection); never sent in clear.
    public func digest() throws -> String {
        SHA256.hash(data: try canonicalData()).map { String(format: "%02x", $0) }.joined()
    }

    /// The fields of an `Encodable` payload struct.
    public static func fields<T: Encodable>(of value: T) throws -> [String: JSONValue] {
        let data = try canonicalEncoder().encode(value)
        guard case .object(let fields) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw SyncModelError.invalidPayload
        }
        return fields
    }

    /// Decode fields back into a payload struct.
    public static func decode<T: Decodable>(_ type: T.Type, from fields: [String: JSONValue]) throws -> T {
        try JSONDecoder().decode(T.self, from: try JSONValue.object(fields).canonicalData())
    }
}

public enum SyncModelError: Error, Equatable {
    case invalidPayload
    case unsupportedSchema(Int)
    case missingFields
}

/// One version of one record: the cleartext envelope plus, unless it is a tombstone, the
/// fields that go into the encrypted plaintext.
public struct SyncRecord: Equatable {
    /// Bumped only for breaking changes to the plaintext layout; readers reject newer versions.
    public static let schemaVersion = 1

    public let id: String
    public let type: SyncRecordType
    public var hlc: HLC
    /// The server version this edit started from (CAS types); nil for a record the server has never seen.
    public var baseHlc: HLC?
    public var deleted: Bool
    public var schemaVersion: Int = SyncRecord.schemaVersion
    /// Payload fields; empty for tombstones.
    public var fields: [String: JSONValue]
    /// Per-field HLCs, so a later field-by-field merge can keep the newer side of each field.
    public var fieldHLCs: [String: HLC]

    public var deviceID: String { hlc.device }

    /// The bytes SYNC-06 encrypts into `ct`; nil for tombstones (they carry no ciphertext).
    /// Associated data for the encryption comes from `envelope` (id, type, hlc, deleted).
    public func plaintext() throws -> Data? {
        guard !deleted else { return nil }
        let body = SyncPlaintext(v: schemaVersion, fields: fields, fieldHlcs: fieldHLCs.mapValues(\.description))
        return try JSONValue.canonicalEncoder().encode(body)
    }

    /// Rebuild a record from a (decrypted) envelope and plaintext.
    public static func decode(id: String, type: SyncRecordType, hlc: HLC, deleted: Bool, plaintext: Data?) throws -> SyncRecord {
        guard !deleted else { return SyncRecord(id: id, type: type, hlc: hlc, deleted: true, fields: [:], fieldHLCs: [:]) }
        guard let plaintext else { throw SyncModelError.missingFields }
        let body = try JSONDecoder().decode(SyncPlaintext.self, from: plaintext)
        guard body.v <= schemaVersion else { throw SyncModelError.unsupportedSchema(body.v) }
        var clocks: [String: HLC] = [:]
        for (key, raw) in body.fieldHlcs {
            guard let value = HLC(raw) else { throw SyncModelError.invalidPayload }
            clocks[key] = value
        }
        return SyncRecord(id: id, type: type, hlc: hlc, deleted: false, schemaVersion: body.v, fields: body.fields, fieldHLCs: clocks)
    }

    /// Typed access to the payload.
    public func payload<T: Decodable>(_ type: T.Type) throws -> T { try JSONValue.decode(type, from: fields) }

    public var envelope: SyncEnvelope {
        SyncEnvelope(id: id, type: type.rawValue, hlc: hlc.description,
                     baseHlc: type.usesCompareAndSwap ? baseHlc?.description : nil, deleted: deleted)
    }

    public init(id: String, type: SyncRecordType, hlc: HLC, baseHlc: HLC? = nil, deleted: Bool, schemaVersion: Int = SyncRecord.schemaVersion, fields: [String: JSONValue], fieldHLCs: [String: HLC]) {
        self.id = id
        self.type = type
        self.hlc = hlc
        self.baseHlc = baseHlc
        self.deleted = deleted
        self.schemaVersion = schemaVersion
        self.fields = fields
        self.fieldHLCs = fieldHLCs
    }
}

/// Plaintext layout inside the ciphertext.
public struct SyncPlaintext: Codable, Equatable {
    public let v: Int
    public let fields: [String: JSONValue]
    public let fieldHlcs: [String: String]

    public init(v: Int, fields: [String: JSONValue], fieldHlcs: [String: String]) {
        self.v = v
        self.fields = fields
        self.fieldHlcs = fieldHlcs
    }
}

/// The cleartext part of a push change (server/PROTOCOL.md). SYNC-06 adds `keyId` and `ct`;
/// SYNC-07 adds `blobId` for assets once blobs upload.
public struct SyncEnvelope: Codable, Equatable {
    public let id: String
    public let type: Int
    public let hlc: String
    public let baseHlc: String?
    public let deleted: Bool

    public init(id: String, type: Int, hlc: String, baseHlc: String?, deleted: Bool) {
        self.id = id
        self.type = type
        self.hlc = hlc
        self.baseHlc = baseHlc
        self.deleted = deleted
    }
}
