import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The cleartext envelope fields a record's ciphertext is bound to (see server/PROTOCOL.md).
/// Changing any of them, or moving the ciphertext to another account, makes decryption fail.
public struct SyncRecordContext: Sendable, Equatable {
    public var userId: String
    public var recordId: String
    public var type: Int
    public var hlc: String
    public var deleted: Bool = false

    public func validate() throws {
        try SyncIdentifiers.validate(userId, "userId")
        try SyncIdentifiers.validate(recordId, "recordId")
        guard (1...63).contains(type) else { throw SyncCryptoError.invalidContext("type out of range") }
        guard !hlc.isEmpty, hlc.utf8.count <= 128 else { throw SyncCryptoError.invalidContext("hlc malformed") }
    }

    public func associatedData(keyId: Int) -> Data {
        SyncBytes.fields(["matilde/v1", userId, recordId, String(type), hlc, deleted ? "1" : "0", String(keyId)])
    }

    public init(userId: String, recordId: String, type: Int, hlc: String, deleted: Bool = false) {
        self.userId = userId
        self.recordId = recordId
        self.type = type
        self.hlc = hlc
        self.deleted = deleted
    }
}

/// Record envelope v1 (`ct` in push/pull):
/// `version(1)=0x01 | keyId(2, big-endian) | salt(32) | nonce(12) | ciphertext | tag(16)`.
/// Key: HKDF-SHA256(AK, salt, "matilde/v1/record"); AES-256-GCM; plaintext Padmé-padded.
public enum SyncRecordCrypto {
    public static let info = "matilde/v1/record"
    public static let headerSize = 1 + 2 + SyncCryptoConstants.saltSize + SyncCryptoConstants.nonceSize

    public static func seal(_ plaintext: Data, context: SyncRecordContext, key: AccountKey) throws -> Data {
        try seal(plaintext, context: context, key: key, salt: SyncBytes.random(SyncCryptoConstants.saltSize), nonce: SyncBytes.random(SyncCryptoConstants.nonceSize))
    }

    /// Deterministic variant for test vectors only. Never reuse a salt in production.
    public static func seal(_ plaintext: Data, context: SyncRecordContext, key: AccountKey, salt: Data, nonce: Data) throws -> Data {
        try context.validate()
        guard salt.count == SyncCryptoConstants.saltSize, nonce.count == SyncCryptoConstants.nonceSize else { throw SyncCryptoError.malformed }
        let recordKey = SyncAEAD.deriveKey(key.key, salt: salt, info: info)
        var out = Data([SyncCryptoConstants.formatVersion])
        out.append(SyncBytes.uint16(key.id))
        out.append(salt)
        out.append(nonce)
        out.append(try SyncAEAD.seal(SyncPadding.pad(plaintext), key: recordKey, nonce: nonce, aad: context.associatedData(keyId: key.id)))
        return out
    }

    /// The key id written in an envelope's header (for choosing a key before opening it).
    public static func keyId(of envelope: Data) throws -> Int {
        guard envelope.count >= headerSize + SyncCryptoConstants.tagSize else { throw SyncCryptoError.malformed }
        let version = envelope[envelope.startIndex]
        guard version == SyncCryptoConstants.formatVersion else { throw SyncCryptoError.unsupportedVersion(version) }
        return SyncBytes.readUInt16(envelope, at: 1)
    }

    /// Opens a record. `keyId` is the cleartext envelope field from the server row; it must match the header.
    public static func open(_ envelope: Data, context: SyncRecordContext, keyId: Int, ring: AccountKeyRing) throws -> Data {
        try context.validate()
        guard context.userId == ring.userId else { throw SyncCryptoError.authenticationFailed }
        guard try self.keyId(of: envelope) == keyId else { throw SyncCryptoError.keyIdMismatch }
        let key = try ring.key(id: keyId)
        let salt = SyncBytes.slice(envelope, 3, SyncCryptoConstants.saltSize)
        let nonce = SyncBytes.slice(envelope, 3 + SyncCryptoConstants.saltSize, SyncCryptoConstants.nonceSize)
        let body = SyncBytes.slice(envelope, headerSize, envelope.count - headerSize)
        let recordKey = SyncAEAD.deriveKey(key.key, salt: salt, info: info)
        let padded = try SyncAEAD.open(body, key: recordKey, nonce: nonce, aad: context.associatedData(keyId: keyId))
        return try SyncPadding.unpad(padded)
    }

    /// Re-encrypts a record under the ring's current key for a `rekey` push (same HLC, newer keyId).
    public static func rekey(_ envelope: Data, context: SyncRecordContext, keyId: Int, ring: AccountKeyRing) throws -> Data {
        let plaintext = try open(envelope, context: context, keyId: keyId, ring: ring)
        return try seal(plaintext, context: context, key: ring.current)
    }

    public static func seal<Value: Encodable>(json value: Value, context: SyncRecordContext, key: AccountKey) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try seal(encoder.encode(value), context: context, key: key)
    }

    public static func open<Value: Decodable>(json type: Value.Type, _ envelope: Data, context: SyncRecordContext, keyId: Int, ring: AccountKeyRing) throws -> Value {
        try JSONDecoder().decode(type, from: open(envelope, context: context, keyId: keyId, ring: ring))
    }
}

/// Small values encrypted with the account key outside records, such as the device name
/// the server stores as `deviceNameCt`. Same envelope as records, key info "matilde/v1/field",
/// associated data fields("matilde/v1/field", userId, purpose, subject, keyId).
public enum SyncFieldCrypto {
    public static let info = "matilde/v1/field"
    public static let deviceNamePurpose = "device-name"

    public static func associatedData(userId: String, purpose: String, subject: String, keyId: Int) -> Data {
        SyncBytes.fields([info, userId, purpose, subject, String(keyId)])
    }

    public static func seal(_ value: Data, purpose: String, subject: String, ring: AccountKeyRing) throws -> Data {
        try seal(value, purpose: purpose, subject: subject, ring: ring, salt: SyncBytes.random(SyncCryptoConstants.saltSize), nonce: SyncBytes.random(SyncCryptoConstants.nonceSize))
    }

    public static func seal(_ value: Data, purpose: String, subject: String, ring: AccountKeyRing, salt: Data, nonce: Data) throws -> Data {
        let key = ring.current
        let fieldKey = SyncAEAD.deriveKey(key.key, salt: salt, info: info)
        var out = Data([SyncCryptoConstants.formatVersion])
        out.append(SyncBytes.uint16(key.id))
        out.append(salt)
        out.append(nonce)
        out.append(try SyncAEAD.seal(SyncPadding.pad(value), key: fieldKey, nonce: nonce, aad: associatedData(userId: ring.userId, purpose: purpose, subject: subject, keyId: key.id)))
        return out
    }

    public static func open(_ envelope: Data, purpose: String, subject: String, ring: AccountKeyRing) throws -> Data {
        let keyId = try SyncRecordCrypto.keyId(of: envelope)
        let key = try ring.key(id: keyId)
        let salt = SyncBytes.slice(envelope, 3, SyncCryptoConstants.saltSize)
        let nonce = SyncBytes.slice(envelope, 3 + SyncCryptoConstants.saltSize, SyncCryptoConstants.nonceSize)
        let body = SyncBytes.slice(envelope, SyncRecordCrypto.headerSize, envelope.count - SyncRecordCrypto.headerSize)
        let fieldKey = SyncAEAD.deriveKey(key.key, salt: salt, info: info)
        return try SyncPadding.unpad(SyncAEAD.open(body, key: fieldKey, nonce: nonce, aad: associatedData(userId: ring.userId, purpose: purpose, subject: subject, keyId: keyId)))
    }

    public static func sealDeviceName(_ name: String, deviceId: String, ring: AccountKeyRing) throws -> Data {
        try SyncIdentifiers.validate(deviceId, "deviceId")
        return try seal(Data(name.utf8), purpose: deviceNamePurpose, subject: deviceId, ring: ring)
    }

    public static func openDeviceName(_ envelope: Data, deviceId: String, ring: AccountKeyRing) throws -> String {
        guard let name = String(data: try open(envelope, purpose: deviceNamePurpose, subject: deviceId, ring: ring), encoding: .utf8) else { throw SyncCryptoError.malformed }
        return name
    }
}
