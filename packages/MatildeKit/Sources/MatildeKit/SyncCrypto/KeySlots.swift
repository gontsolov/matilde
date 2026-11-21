import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// Key slots: wrapped copies of the account key stored by the server (`GET`/`PUT /v1/keys`,
// server/PROTOCOL.md). The server can't unwrap them.
//
// Wrapped key v1: `version(1)=0x01 | salt(32) | nonce(12) | ciphertext | tag(16)`.
// KEK = HKDF-SHA256(secret, salt, "matilde/v1/slot/<kind>"); AES-256-GCM with associated data
// fields("matilde/v1/slot", userId, slotId, kind, keyId).
//
// Kinds:
// - `recovery`: secret = the recovery key; plaintext = the 32-byte account key.
// - `previous-keys`: secret = the current account key; plaintext = older epochs still needed after a
//   rotation, each `keyId(2, big-endian) | key(32)`. Lets a new device read records that have not been
//   re-encrypted yet. Absent when there are none.

public enum SyncKeySlotKind {
    public static let recovery = "recovery"
    public static let previousKeys = "previous-keys"
}

/// A slot as returned by `GET /v1/keys`.
public struct SyncKeySlot: Codable, Equatable, Sendable {
    public var slotId: String
    public var kind: String
    public var keyId: Int
    public var params: String?
    public var wrappedKey: String
    public var updatedAt: Int64?

    public init(slotId: String, kind: String, keyId: Int, params: String? = nil, wrappedKey: String, updatedAt: Int64? = nil) {
        self.slotId = slotId
        self.kind = kind
        self.keyId = keyId
        self.params = params
        self.wrappedKey = wrappedKey
        self.updatedAt = updatedAt
    }
}

/// `GET /v1/keys` response.
public struct SyncKeysResponse: Codable, Equatable, Sendable {
    public var keyId: Int?
    public var keyCheck: String?
    public var slots: [SyncKeySlot]

    public init(keyId: Int? = nil, keyCheck: String? = nil, slots: [SyncKeySlot]) {
        self.keyId = keyId
        self.keyCheck = keyCheck
        self.slots = slots
    }
}

/// `PUT /v1/keys` body. Replaces the key check value and all slots atomically;
/// `expectedKeyId` is a compare-and-swap on the stored key id (encoded as `null` when none exists).
public struct SyncPutKeysRequest: Encodable, Equatable, Sendable {
    public struct Slot: Encodable, Equatable, Sendable {
        public var slotId: String
        public var kind: String
        public var params: String?
        public var wrappedKey: String

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(slotId, forKey: .slotId)
            try container.encode(kind, forKey: .kind)
            if let params { try container.encode(params, forKey: .params) } else { try container.encodeNil(forKey: .params) }
            try container.encode(wrappedKey, forKey: .wrappedKey)
        }

        public enum CodingKeys: String, CodingKey { case slotId, kind, params, wrappedKey }

        public init(slotId: String, kind: String, params: String? = nil, wrappedKey: String) {
            self.slotId = slotId
            self.kind = kind
            self.params = params
            self.wrappedKey = wrappedKey
        }
    }

    public var expectedKeyId: Int?
    public var keyId: Int
    public var keyCheck: String
    public var slots: [Slot]

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let expectedKeyId { try container.encode(expectedKeyId, forKey: .expectedKeyId) } else { try container.encodeNil(forKey: .expectedKeyId) }
        try container.encode(keyId, forKey: .keyId)
        try container.encode(keyCheck, forKey: .keyCheck)
        try container.encode(slots, forKey: .slots)
    }

    public enum CodingKeys: String, CodingKey { case expectedKeyId, keyId, keyCheck, slots }

    public init(expectedKeyId: Int? = nil, keyId: Int, keyCheck: String, slots: [Slot]) {
        self.expectedKeyId = expectedKeyId
        self.keyId = keyId
        self.keyCheck = keyCheck
        self.slots = slots
    }
}

public enum SyncKeyWrap {
    public static let headerSize = 1 + SyncCryptoConstants.saltSize + SyncCryptoConstants.nonceSize

    public static func associatedData(userId: String, slotId: String, kind: String, keyId: Int) -> Data {
        SyncBytes.fields(["matilde/v1/slot", userId, slotId, kind, String(keyId)])
    }

    public static func wrap(_ plaintext: Data, secret: SymmetricKey, userId: String, slotId: String, kind: String, keyId: Int,
                     salt: Data = SyncBytes.random(SyncCryptoConstants.saltSize), nonce: Data = SyncBytes.random(SyncCryptoConstants.nonceSize)) throws -> Data {
        try SyncIdentifiers.validate(userId, "userId")
        try SyncIdentifiers.validate(slotId, "slotId")
        try SyncIdentifiers.validateKeyId(keyId)
        let kek = SyncAEAD.deriveKey(secret, salt: salt, info: "matilde/v1/slot/\(kind)")
        var out = Data([SyncCryptoConstants.formatVersion])
        out.append(salt)
        out.append(nonce)
        out.append(try SyncAEAD.seal(plaintext, key: kek, nonce: nonce, aad: associatedData(userId: userId, slotId: slotId, kind: kind, keyId: keyId)))
        return out
    }

    public static func unwrap(_ wrapped: Data, secret: SymmetricKey, userId: String, slotId: String, kind: String, keyId: Int) throws -> Data {
        guard wrapped.count >= headerSize + SyncCryptoConstants.tagSize else { throw SyncCryptoError.malformed }
        let version = wrapped[wrapped.startIndex]
        guard version == SyncCryptoConstants.formatVersion else { throw SyncCryptoError.unsupportedVersion(version) }
        let salt = SyncBytes.slice(wrapped, 1, SyncCryptoConstants.saltSize)
        let nonce = SyncBytes.slice(wrapped, 1 + SyncCryptoConstants.saltSize, SyncCryptoConstants.nonceSize)
        let body = SyncBytes.slice(wrapped, headerSize, wrapped.count - headerSize)
        let kek = SyncAEAD.deriveKey(secret, salt: salt, info: "matilde/v1/slot/\(kind)")
        return try SyncAEAD.open(body, key: kek, nonce: nonce, aad: associatedData(userId: userId, slotId: slotId, kind: kind, keyId: keyId))
    }

    public static func encodePreviousKeys(_ keys: [AccountKey]) -> Data {
        var out = Data()
        for key in keys.sorted(by: { $0.id < $1.id }) {
            out.append(SyncBytes.uint16(key.id))
            out.append(key.key.syncBytes)
        }
        return out
    }

    public static func decodePreviousKeys(_ data: Data) throws -> [AccountKey] {
        let entry = 2 + SyncCryptoConstants.keySize
        guard data.count % entry == 0 else { throw SyncCryptoError.malformed }
        return try stride(from: 0, to: data.count, by: entry).map {
            try AccountKey(id: SyncBytes.readUInt16(data, at: $0), bytes: SyncBytes.slice(data, $0 + 2, SyncCryptoConstants.keySize))
        }
    }
}

/// Builds and reads the server's key material. Pure: no networking, no Keychain. The caller sends
/// `request` to `PUT /v1/keys` and, only after the server accepted it, stores `ring` in the Keychain
/// (and shows a new recovery key once). On `409 key_conflict` it fetches `GET /v1/keys` and recovers instead.
public enum SyncKeyEnrollment {
    public struct Result {
        public let ring: AccountKeyRing
        public let request: SyncPutKeysRequest
        /// Set when a new recovery key was made; show it once (with print/confirm) and never store it.
        public let recoveryKey: SyncRecoveryKey?

        public init(ring: AccountKeyRing, request: SyncPutKeysRequest, recoveryKey: SyncRecoveryKey?) {
            self.ring = ring
            self.request = request
            self.recoveryKey = recoveryKey
        }
    }

    /// First device: a new account key (epoch 1) and a new recovery key.
    public static func create(userId: String) throws -> Result {
        let ring = try AccountKeyRing(userId: userId, current: AccountKey.generate(id: 1))
        let recovery = SyncRecoveryKey.generate()
        return Result(ring: ring, request: try request(ring: ring, expectedKeyId: nil, recovery: recovery), recoveryKey: recovery)
    }

    /// New device, or a device that lost its Keychain item: unwrap the account key with the recovery key.
    public static func recover(userId: String, keys: SyncKeysResponse, recoveryCode: String) throws -> AccountKeyRing {
        try recover(userId: userId, keys: keys, recoveryKey: SyncRecoveryKey(code: recoveryCode))
    }

    public static func recover(userId: String, keys: SyncKeysResponse, recoveryKey: SyncRecoveryKey) throws -> AccountKeyRing {
        try SyncIdentifiers.validate(userId, "userId")
        guard let keyId = keys.keyId else { throw SyncCryptoError.noSlot }
        let slots = keys.slots.filter { $0.kind == SyncKeySlotKind.recovery && $0.keyId == keyId }
        guard !slots.isEmpty else { throw SyncCryptoError.noSlot }
        var lastError = SyncCryptoError.authenticationFailed
        for slot in slots {
            do {
                guard let wrapped = Data(base64Encoded: slot.wrappedKey) else { throw SyncCryptoError.malformed }
                let bytes = try SyncKeyWrap.unwrap(wrapped, secret: recoveryKey.key, userId: userId, slotId: slot.slotId, kind: slot.kind, keyId: keyId)
                return try ring(userId: userId, current: AccountKey(id: keyId, bytes: bytes), keys: keys)
            } catch let error as SyncCryptoError {
                lastError = error
            }
        }
        throw lastError
    }

    /// Checks a key this device already holds (e.g. from the Keychain) against the server and returns the
    /// full ring, including older epochs from the `previous-keys` slot.
    public static func ring(userId: String, current: AccountKey, keys: SyncKeysResponse) throws -> AccountKeyRing {
        guard keys.keyId == current.id else { throw SyncCryptoError.unknownKey(keys.keyId ?? 0) }
        guard let checkText = keys.keyCheck, let check = Data(base64Encoded: checkText), current.verify(check: check) else {
            throw SyncCryptoError.keyCheckMismatch
        }
        var previous: [AccountKey] = []
        if let slot = keys.slots.first(where: { $0.kind == SyncKeySlotKind.previousKeys && $0.keyId == current.id }) {
            guard let wrapped = Data(base64Encoded: slot.wrappedKey) else { throw SyncCryptoError.malformed }
            previous = try SyncKeyWrap.decodePreviousKeys(SyncKeyWrap.unwrap(wrapped, secret: current.key, userId: userId, slotId: slot.slotId, kind: slot.kind, keyId: current.id))
        }
        return try AccountKeyRing(userId: userId, current: current, previous: previous)
    }

    /// A new recovery key for the same account key (the old code stops working once the server stores this).
    public static func regenerateRecoveryKey(ring: AccountKeyRing) throws -> Result {
        let recovery = SyncRecoveryKey.generate()
        return Result(ring: ring, request: try request(ring: ring, expectedKeyId: ring.current.id, recovery: recovery), recoveryKey: recovery)
    }

    /// Full rotation: a new account key epoch. Older epochs move to the `previous-keys` slot until every record
    /// has been re-encrypted (`SyncRecordCrypto.rekey`); then `dropPreviousKeys`. Needs a recovery key for the
    /// new slot: the user's existing one (re-entered) or a new one.
    public static func rotate(ring: AccountKeyRing, recoveryKey: SyncRecoveryKey? = nil) throws -> Result {
        guard ring.current.id < SyncCryptoConstants.maxKeyId else { throw SyncCryptoError.invalidContext("keyId exhausted") }
        let next = try AccountKeyRing(userId: ring.userId, current: AccountKey.generate(id: ring.current.id + 1), previous: ring.previous + [ring.current])
        let recovery = recoveryKey ?? SyncRecoveryKey.generate()
        return Result(ring: next, request: try request(ring: next, expectedKeyId: ring.current.id, recovery: recovery),
                      recoveryKey: recoveryKey == nil ? recovery : nil)
    }

    /// Forgets old epochs no record uses any more. Keeps the existing recovery slot(s) unchanged.
    public static func dropPreviousKeys(ring: AccountKeyRing, ids: Set<Int>, keys: SyncKeysResponse) throws -> Result {
        let next = try ring.dropping(previousKeyIds: ids)
        let kept = keys.slots.filter { $0.kind != SyncKeySlotKind.previousKeys && $0.keyId == ring.current.id }
            .map { SyncPutKeysRequest.Slot(slotId: $0.slotId, kind: $0.kind, params: $0.params, wrappedKey: $0.wrappedKey) }
        guard kept.contains(where: { $0.kind == SyncKeySlotKind.recovery }) else { throw SyncCryptoError.noSlot }
        var slots = kept
        if let previous = try previousKeysSlot(ring: next) { slots.append(previous) }
        return Result(ring: next, request: SyncPutKeysRequest(expectedKeyId: ring.current.id, keyId: next.current.id,
                                                              keyCheck: next.current.check.base64EncodedString(), slots: slots), recoveryKey: nil)
    }

    public static func request(ring: AccountKeyRing, expectedKeyId: Int?, recovery: SyncRecoveryKey) throws -> SyncPutKeysRequest {
        let slotId = UUID().uuidString.lowercased()
        let wrapped = try SyncKeyWrap.wrap(ring.current.key.syncBytes, secret: recovery.key, userId: ring.userId, slotId: slotId,
                                           kind: SyncKeySlotKind.recovery, keyId: ring.current.id)
        var slots = [SyncPutKeysRequest.Slot(slotId: slotId, kind: SyncKeySlotKind.recovery, params: nil, wrappedKey: wrapped.base64EncodedString())]
        if let previous = try previousKeysSlot(ring: ring) { slots.append(previous) }
        return SyncPutKeysRequest(expectedKeyId: expectedKeyId, keyId: ring.current.id, keyCheck: ring.current.check.base64EncodedString(), slots: slots)
    }

    /// The server caps `wrappedKey` at 1024 base64 characters: about 20 older epochs.
    public static let maxPreviousKeys = 20

    private static func previousKeysSlot(ring: AccountKeyRing) throws -> SyncPutKeysRequest.Slot? {
        guard !ring.previous.isEmpty else { return nil }
        guard ring.previous.count <= maxPreviousKeys else { throw SyncCryptoError.invalidContext("too many previous keys; finish re-encrypting first") }
        let slotId = UUID().uuidString.lowercased()
        let wrapped = try SyncKeyWrap.wrap(SyncKeyWrap.encodePreviousKeys(ring.previous), secret: ring.current.key, userId: ring.userId,
                                           slotId: slotId, kind: SyncKeySlotKind.previousKeys, keyId: ring.current.id)
        return SyncPutKeysRequest.Slot(slotId: slotId, kind: SyncKeySlotKind.previousKeys, params: nil, wrappedKey: wrapped.base64EncodedString())
    }
}
