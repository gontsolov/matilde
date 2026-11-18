import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// End-to-end encryption for cloud sync (SYNC-06). Specified in docs/sync-encryption.md;
// docs/sync-vectors/*.json are the shared test vectors. Nothing in this module logs,
// prints or describes key material or plaintext.

enum SyncCryptoError: Error, Equatable {
    /// The bytes are too short or structurally wrong for the format.
    case malformed
    case unsupportedVersion(UInt8)
    /// No key for this account-key epoch on this device.
    case unknownKey(Int)
    /// The envelope's key id differs from the record's cleartext `keyId`.
    case keyIdMismatch
    /// Wrong key, tampered bytes, or ciphertext moved to another record/account.
    case authenticationFailed
    case invalidPadding
    case invalidContext(String)
    case invalidRecoveryCode
    /// The recovery code parsed but its check bits are wrong (a typo).
    case recoveryCodeTypo
    /// No usable slot on the server for this key or method.
    case noSlot
    /// The unwrapped key does not match the account's key check value.
    case keyCheckMismatch
    case keyStore(Int32)
}

enum SyncCryptoConstants {
    static let formatVersion: UInt8 = 1
    static let saltSize = 32
    static let nonceSize = 12
    static let tagSize = 16
    static let keySize = 32
    static let minimumPaddedSize = 32
    static let maxKeyId = 0xFFFF
}

// MARK: - Bytes

enum SyncBytes {
    /// Cryptographically secure random bytes (arc4random on Apple platforms, getrandom on Linux).
    static func random(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        var data = Data(count: count)
        for index in 0..<count { data[index] = UInt8.random(in: .min ... .max, using: &generator) }
        return data
    }

    static func uint16(_ value: Int) -> Data {
        Data([UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    static func uint32(_ value: Int) -> Data {
        Data([UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    static func readUInt16(_ data: Data, at offset: Int) -> Int {
        let base = data.startIndex + offset
        return Int(data[base]) << 8 | Int(data[base + 1])
    }

    static func readUInt32(_ data: Data, at offset: Int) -> Int {
        let base = data.startIndex + offset
        return Int(data[base]) << 24 | Int(data[base + 1]) << 16 | Int(data[base + 2]) << 8 | Int(data[base + 3])
    }

    /// Unambiguous associated data: every field as a big-endian UInt16 byte length followed by its UTF-8 bytes.
    static func fields(_ values: [String]) -> Data {
        var out = Data()
        for value in values {
            let bytes = Data(value.utf8)
            precondition(bytes.count <= 0xFFFF, "associated-data field too long")
            out.append(uint16(bytes.count))
            out.append(bytes)
        }
        return out
    }

    static func slice(_ data: Data, _ offset: Int, _ count: Int) -> Data {
        let start = data.startIndex + offset
        return Data(data[start..<(start + count)])
    }
}

// MARK: - Padding

/// Padmé padding (Nikitin et al.): the padded size leaks only about log log of the length.
/// Plaintext is followed by 0x80 and zero bytes up to the bucket size (at least 32 bytes).
enum SyncPadding {
    static func paddedLength(for length: Int) -> Int {
        let needed = length + 1
        guard needed > SyncCryptoConstants.minimumPaddedSize else { return SyncCryptoConstants.minimumPaddedSize }
        let exponent = Int.bitWidth - 1 - needed.leadingZeroBitCount            // floor(log2 L)
        let exponentBits = Int.bitWidth - exponent.leadingZeroBitCount          // floor(log2 E) + 1
        let lastBits = exponent - exponentBits
        let mask = (1 << lastBits) - 1
        return (needed + mask) & ~mask
    }

    static func pad(_ data: Data) -> Data {
        var out = data
        out.append(0x80)
        out.append(Data(count: paddedLength(for: data.count) - data.count - 1))
        return out
    }

    static func unpad(_ data: Data) throws -> Data {
        var end = data.endIndex
        while end > data.startIndex, data[end - 1] == 0 { end -= 1 }
        guard end > data.startIndex, data[end - 1] == 0x80 else { throw SyncCryptoError.invalidPadding }
        return Data(data[data.startIndex..<(end - 1)])
    }
}

// MARK: - Validation

enum SyncIdentifiers {
    /// Ids are part of the associated data, so they must be byte-identical everywhere: lowercase canonical UUIDs.
    static func validate(_ id: String, _ name: String) throws {
        guard id.count == 36, id == id.lowercased(), UUID(uuidString: id) != nil else {
            throw SyncCryptoError.invalidContext("\(name) must be a lowercase UUID")
        }
    }

    static func validateKeyId(_ keyId: Int) throws {
        guard (1...SyncCryptoConstants.maxKeyId).contains(keyId) else { throw SyncCryptoError.invalidContext("keyId out of range") }
    }
}

// MARK: - AES-GCM primitives

enum SyncAEAD {
    static func deriveKey(_ input: SymmetricKey, salt: Data, info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: input, salt: salt, info: Data(info.utf8), outputByteCount: SyncCryptoConstants.keySize)
    }

    /// Returns ciphertext followed by the 16-byte tag.
    static func seal(_ plaintext: Data, key: SymmetricKey, nonce: Data, aad: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
        return box.ciphertext + box.tag
    }

    static func open(_ ciphertextAndTag: Data, key: SymmetricKey, nonce: Data, aad: Data) throws -> Data {
        guard ciphertextAndTag.count >= SyncCryptoConstants.tagSize else { throw SyncCryptoError.malformed }
        let split = ciphertextAndTag.count - SyncCryptoConstants.tagSize
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce),
                ciphertext: SyncBytes.slice(ciphertextAndTag, 0, split),
                tag: SyncBytes.slice(ciphertextAndTag, split, SyncCryptoConstants.tagSize)
            )
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch {
            throw SyncCryptoError.authenticationFailed
        }
    }
}

extension SymmetricKey {
    var syncBytes: Data { withUnsafeBytes { Data($0) } }
}
