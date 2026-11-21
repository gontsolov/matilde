import Foundation
#if canImport(Security)
import Security
#endif

/// Where a device keeps its account keys. Never synced through Matilde's server.
public protocol AccountKeyStore {
    func load(userId: String) throws -> AccountKeyRing?
    func save(_ ring: AccountKeyRing) throws
    func remove(userId: String) throws
}

/// Keychain item format v1: `version(1)=0x01 | currentKeyId(2) | (keyId(2) | key(32))…`, current key first.
public enum AccountKeyRingCoding {
    public static func encode(_ ring: AccountKeyRing) -> Data {
        var out = Data([SyncCryptoConstants.formatVersion])
        out.append(SyncBytes.uint16(ring.current.id))
        for key in [ring.current] + ring.previous {
            out.append(SyncBytes.uint16(key.id))
            out.append(key.key.syncBytes)
        }
        return out
    }

    public static func decode(_ data: Data, userId: String) throws -> AccountKeyRing {
        guard data.count >= 3 else { throw SyncCryptoError.malformed }
        let version = data[data.startIndex]
        guard version == SyncCryptoConstants.formatVersion else { throw SyncCryptoError.unsupportedVersion(version) }
        let currentId = SyncBytes.readUInt16(data, at: 1)
        let keys = try SyncKeyWrap.decodePreviousKeys(SyncBytes.slice(data, 3, data.count - 3))
        guard let current = keys.first(where: { $0.id == currentId }) else { throw SyncCryptoError.malformed }
        return try AccountKeyRing(userId: userId, current: current, previous: keys.filter { $0.id != currentId })
    }
}

/// In-memory store for tests and previews.
public final class MemoryAccountKeyStore: AccountKeyStore, @unchecked Sendable {
    private var items: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public func load(userId: String) throws -> AccountKeyRing? {
        lock.lock(); defer { lock.unlock() }
        return try items[userId].map { try AccountKeyRingCoding.decode($0, userId: userId) }
    }

    public func save(_ ring: AccountKeyRing) throws {
        lock.lock(); defer { lock.unlock() }
        items[ring.userId] = AccountKeyRingCoding.encode(ring)
    }

    public func remove(userId: String) throws {
        lock.lock(); defer { lock.unlock() }
        items[userId] = nil
    }
}

#if canImport(Security)
/// Account keys in the login Keychain, one generic-password item per account (`account` = userId),
/// readable after first unlock and never migrated to other devices (`…ThisDeviceOnly`). Syncing through
/// iCloud Keychain needs a keychain access group, so it waits for Developer ID signing (DIST-02).
public struct KeychainAccountKeyStore: AccountKeyStore {
    public static let defaultService = "app.matilde.local.sync.account-key"
    public var service = defaultService

    public init(service: String = defaultService) {
        self.service = service
    }

    private func query(userId: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: userId]
    }

    public func load(userId: String) throws -> AccountKeyRing? {
        var request = query(userId: userId)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SyncCryptoError.keyStore(status) }
        guard let data = result as? Data else { throw SyncCryptoError.malformed }
        return try AccountKeyRingCoding.decode(data, userId: userId)
    }

    public func save(_ ring: AccountKeyRing) throws {
        let base = query(userId: ring.userId)
        let changes: [String: Any] = [kSecValueData as String: AccountKeyRingCoding.encode(ring)]
        let status = SecItemUpdate(base as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item = base.merging(changes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecAttrLabel as String] = "Matilde — sync encryption key"
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw SyncCryptoError.keyStore(added) }
        } else if status != errSecSuccess {
            throw SyncCryptoError.keyStore(status)
        }
    }

    public func remove(userId: String) throws {
        let status = SecItemDelete(query(userId: userId) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SyncCryptoError.keyStore(status) }
    }
}
#endif
