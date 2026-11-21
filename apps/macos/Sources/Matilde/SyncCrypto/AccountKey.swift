import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// One epoch of the 256-bit account key (AK). Made on the first device, kept in the Keychain,
/// and sent to the server only wrapped (key slots). `id` is the `keyId` in record envelopes.
struct AccountKey: Equatable {
    let id: Int
    let key: SymmetricKey

    init(id: Int, key: SymmetricKey) throws {
        try SyncIdentifiers.validateKeyId(id)
        guard key.bitCount == 256 else { throw SyncCryptoError.malformed }
        self.id = id
        self.key = key
    }

    init(id: Int, bytes: Data) throws {
        guard bytes.count == SyncCryptoConstants.keySize else { throw SyncCryptoError.malformed }
        try self.init(id: id, key: SymmetricKey(data: bytes))
    }

    static func generate(id: Int = 1) throws -> AccountKey {
        try AccountKey(id: id, key: SymmetricKey(size: .bits256))
    }

    /// The value stored on the server as `keyCheck`, so a device can confirm it unwrapped the right key
    /// without the server learning anything about it: HMAC-SHA256(AK, fields("matilde/v1/key-check", keyId)).
    var check: Data {
        Data(HMAC<SHA256>.authenticationCode(for: SyncBytes.fields(["matilde/v1/key-check", String(id)]), using: key))
    }

    func verify(check expected: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(expected, authenticating: SyncBytes.fields(["matilde/v1/key-check", String(id)]), using: key)
    }

    static func == (lhs: AccountKey, rhs: AccountKey) -> Bool {
        lhs.id == rhs.id && lhs.key == rhs.key
    }
}

extension AccountKey: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "AccountKey(id: \(id), <redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["id": id]) }
}

/// The account keys a device holds: the current epoch plus older epochs still needed
/// to read records that have not been re-encrypted yet after a rotation.
struct AccountKeyRing: Equatable {
    let userId: String
    let current: AccountKey
    let previous: [AccountKey]

    init(userId: String, current: AccountKey, previous: [AccountKey] = []) throws {
        try SyncIdentifiers.validate(userId, "userId")
        guard !previous.contains(where: { $0.id >= current.id }) else { throw SyncCryptoError.invalidContext("previous keys must be older than the current key") }
        guard Set(previous.map(\.id)).count == previous.count else { throw SyncCryptoError.invalidContext("duplicate key id") }
        self.userId = userId
        self.current = current
        self.previous = previous.sorted { $0.id < $1.id }
    }

    func key(id: Int) throws -> AccountKey {
        if current.id == id { return current }
        guard let key = previous.first(where: { $0.id == id }) else { throw SyncCryptoError.unknownKey(id) }
        return key
    }

    /// A ring without the given old epochs (once no record uses them any more).
    func dropping(previousKeyIds ids: Set<Int>) throws -> AccountKeyRing {
        try AccountKeyRing(userId: userId, current: current, previous: previous.filter { !ids.contains($0.id) })
    }
}

extension AccountKeyRing: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "AccountKeyRing(current: \(current.id), previous: \(previous.map(\.id)), <redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["current": current.id, "previous": previous.map(\.id)]) }
}
