import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// A random per-file key. It travels inside the (encrypted) asset record that references the blob,
/// so rotating the account key never requires re-uploading images.
public struct SyncBlobKey: Equatable, Codable {
    public let key: SymmetricKey

    public init(key: SymmetricKey) { self.key = key }

    public init(bytes: Data) throws {
        guard bytes.count == SyncCryptoConstants.keySize else { throw SyncCryptoError.malformed }
        key = SymmetricKey(data: bytes)
    }

    public static func generate() -> SyncBlobKey { SyncBlobKey(key: SymmetricKey(size: .bits256)) }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let data = Data(base64Encoded: text) else { throw SyncCryptoError.malformed }
        try self.init(bytes: data)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(key.syncBytes.base64EncodedString())
    }
}

extension SyncBlobKey: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "SyncBlobKey(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Blob format v1 (uploaded to `PUT /v1/blobs/{blobId}`), chunked so it can be streamed later:
/// `version(1)=0x01 | chunkSize(4, big-endian) | noncePrefix(8)` then chunks of `ciphertext | tag(16)`.
/// The Padmé-padded plaintext is split into `chunkSize` pieces (the last may be shorter, never empty).
/// Chunk i uses nonce `noncePrefix | i (4, big-endian)` and associated data
/// fields("matilde/v1/blob", blobId, i, final ? "1" : "0"), so chunks can't be reordered, dropped,
/// truncated or moved to another blob.
public enum SyncBlobCrypto {
    public static let defaultChunkSize = 64 * 1024
    public static let headerSize = 1 + 4 + 8
    public static let allowedChunkSizes = 1024...(1024 * 1024)

    public static func seal(_ plaintext: Data, blobId: String, key: SyncBlobKey, chunkSize: Int = defaultChunkSize) throws -> Data {
        try seal(plaintext, blobId: blobId, key: key, chunkSize: chunkSize, noncePrefix: SyncBytes.random(8))
    }

    public static func seal(_ plaintext: Data, blobId: String, key: SyncBlobKey, chunkSize: Int, noncePrefix: Data) throws -> Data {
        try SyncIdentifiers.validate(blobId, "blobId")
        guard allowedChunkSizes.contains(chunkSize), noncePrefix.count == 8 else { throw SyncCryptoError.malformed }
        let padded = SyncPadding.pad(plaintext)
        var out = Data([SyncCryptoConstants.formatVersion])
        out.append(SyncBytes.uint32(chunkSize))
        out.append(noncePrefix)
        let count = (padded.count + chunkSize - 1) / chunkSize
        for index in 0..<count {
            let start = index * chunkSize
            let chunk = SyncBytes.slice(padded, start, min(chunkSize, padded.count - start))
            out.append(try SyncAEAD.seal(chunk, key: key.key, nonce: noncePrefix + SyncBytes.uint32(index), aad: associatedData(blobId: blobId, index: index, final: index == count - 1)))
        }
        return out
    }

    public static func open(_ data: Data, blobId: String, key: SyncBlobKey) throws -> Data {
        try SyncIdentifiers.validate(blobId, "blobId")
        guard data.count > headerSize + SyncCryptoConstants.tagSize else { throw SyncCryptoError.malformed }
        let version = data[data.startIndex]
        guard version == SyncCryptoConstants.formatVersion else { throw SyncCryptoError.unsupportedVersion(version) }
        let chunkSize = SyncBytes.readUInt32(data, at: 1)
        guard allowedChunkSizes.contains(chunkSize) else { throw SyncCryptoError.malformed }
        let noncePrefix = SyncBytes.slice(data, 5, 8)
        let sealedChunk = chunkSize + SyncCryptoConstants.tagSize
        let body = data.count - headerSize
        let count = (body + sealedChunk - 1) / sealedChunk
        var padded = Data()
        padded.reserveCapacity(body)
        for index in 0..<count {
            let start = headerSize + index * sealedChunk
            let length = min(sealedChunk, data.count - start)
            guard length > SyncCryptoConstants.tagSize else { throw SyncCryptoError.malformed }
            padded.append(try SyncAEAD.open(SyncBytes.slice(data, start, length), key: key.key, nonce: noncePrefix + SyncBytes.uint32(index), aad: associatedData(blobId: blobId, index: index, final: index == count - 1)))
        }
        return try SyncPadding.unpad(padded)
    }

    public static func associatedData(blobId: String, index: Int, final: Bool) -> Data {
        SyncBytes.fields(["matilde/v1/blob", blobId, String(index), final ? "1" : "0"])
    }
}
