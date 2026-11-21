import Foundation

// SYNC-07: turning a `SyncRecord` into a push change and a pulled row back into a record.
//
// The bytes SyncCrypto encrypts (the "framed plaintext") start with one byte that says how to read
// the rest. Canonical JSON always starts with `{`, so plaintext from SYNC-02 is valid as is:
//
//   `{`…            the record's canonical JSON (`SyncRecord.plaintext()`), uncompressed
//   0x01 | data     raw DEFLATE (RFC 1951) of that JSON; used when it saves at least 10 %
//   0x02 | json     a blob reference `{"blob","key","size"}`: the framed plaintext (`{` or 0x01) is
//                   too large for a record (3 MiB) and was uploaded as an encrypted blob instead
//
// Compression happens before encryption (ciphertext doesn't compress) and before padding. Raw
// DEFLATE is what Apple's Compression framework calls ZLIB and what browsers call `deflate-raw`, so
// a web client can read it too.
//
// Asset records carry their image as a blob: the plaintext then has two extra fields, `blob` (the
// blob id, also in the cleartext envelope so the server can collect garbage) and `blobKey` (the
// random per-file key, base64). The engine adds and strips them; the local store never sees them.

public enum SyncFrame {
    public static let deflate: UInt8 = 0x01
    public static let blobReference: UInt8 = 0x02
    public static let json = UInt8(ascii: "{")
    /// Below this the DEFLATE header costs more than it saves.
    public static let compressionThreshold = 256
    /// Refuse to inflate past this (a record's plaintext is at most a few MiB; blobs at most 64 MiB).
    public static let maxInflatedBytes = 96 * 1024 * 1024
}

public enum SyncCodecError: Error, Equatable {
    case malformedFrame
    case compressionUnavailable
    case blobMismatch
}

/// A blob that holds a record's framed plaintext because it is too large for a record.
public struct SyncBlobReference: Codable, Equatable {
    public var blob: String
    public var key: SyncBlobKey
    public var size: Int

    public init(blob: String, key: SyncBlobKey, size: Int) {
        self.blob = blob
        self.key = key
        self.size = size
    }
}

/// Raw DEFLATE through the system's Compression framework. Not available on Linux, where test
/// runs simply store records uncompressed (the format allows both).
public enum SyncCompression {
    public static var isAvailable: Bool {
        #if canImport(Darwin)
        return true
        #else
        return false
        #endif
    }

    public static func deflate(_ data: Data) -> Data? {
        #if canImport(Darwin)
        return try? (data as NSData).compressed(using: .zlib) as Data
        #else
        return nil
        #endif
    }

    public static func inflate(_ data: Data) throws -> Data {
        #if canImport(Darwin)
        guard let out = try? (data as NSData).decompressed(using: .zlib) as Data else { throw SyncCodecError.malformedFrame }
        guard out.count <= SyncFrame.maxInflatedBytes else { throw SyncCodecError.malformedFrame }
        return out
        #else
        throw SyncCodecError.compressionUnavailable
        #endif
    }
}

public enum SyncCodec {
    public static let blobField = "blob"
    public static let blobKeyField = "blobKey"

    /// Frames a plaintext, compressing it when that pays off.
    public static func frame(_ plaintext: Data, compress: Bool = true) -> Data {
        if compress, plaintext.count >= SyncFrame.compressionThreshold, let packed = SyncCompression.deflate(plaintext),
           packed.count + 1 < plaintext.count - plaintext.count / 10 {
            return Data([SyncFrame.deflate]) + packed
        }
        return plaintext
    }

    /// Reads a `{` or 0x01 frame back into the record's JSON.
    public static func unframe(_ framed: Data) throws -> Data {
        guard let first = framed.first else { throw SyncCodecError.malformedFrame }
        switch first {
        case SyncFrame.json: return framed
        case SyncFrame.deflate: return try SyncCompression.inflate(framed.dropFirst())
        default: throw SyncCodecError.malformedFrame
        }
    }

    public static func referenceFrame(_ reference: SyncBlobReference) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Data([SyncFrame.blobReference]) + (try encoder.encode(reference))
    }

    /// The blob reference in a 0x02 frame, or nil for an inline frame.
    public static func reference(in framed: Data) throws -> SyncBlobReference? {
        guard framed.first == SyncFrame.blobReference else { return nil }
        guard let reference = try? JSONDecoder().decode(SyncBlobReference.self, from: framed.dropFirst()) else { throw SyncCodecError.malformedFrame }
        try SyncIdentifiers.validate(reference.blob, "blob")
        return reference
    }

    public static func context(userId: String, id: String, type: SyncRecordType, hlc: HLC, deleted: Bool) -> SyncRecordContext {
        SyncRecordContext(userId: userId, recordId: id, type: type.rawValue, hlc: hlc.description, deleted: deleted)
    }

    /// Seals a framed plaintext into the push change for `record`. Tombstones carry no ciphertext.
    public static func change(for record: SyncRecord, framed: Data?, blobId: String?, ring: AccountKeyRing) throws -> SyncWireChange {
        let envelope = record.envelope
        var ct: String?
        if let framed, !record.deleted {
            let context = context(userId: ring.userId, id: record.id, type: record.type, hlc: record.hlc, deleted: false)
            ct = try SyncRecordCrypto.seal(framed, context: context, key: ring.current).base64EncodedString()
        }
        return SyncWireChange(id: envelope.id, type: envelope.type, hlc: envelope.hlc, baseHlc: envelope.baseHlc,
                              deleted: record.deleted, keyId: ring.current.id, blobId: record.deleted ? nil : blobId, ct: ct)
    }

    /// Decrypts a row's ciphertext into its framed plaintext (nil for tombstones).
    public static func open(_ row: SyncWireRow, type: SyncRecordType, hlc: HLC, ring: AccountKeyRing) throws -> Data? {
        guard !row.deleted else { return nil }
        guard let text = row.ct, let ct = Data(base64Encoded: text) else { throw SyncCryptoError.malformed }
        let context = context(userId: ring.userId, id: row.id, type: type, hlc: hlc, deleted: false)
        return try SyncRecordCrypto.open(ct, context: context, keyId: row.keyId, ring: ring)
    }
}
