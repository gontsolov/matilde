import Foundation
#if canImport(Security)
import Security
#endif

/// A copy of the account's recovery key that the user's other devices can read, so adding a
/// device fills the key in instead of asking for it to be typed (owner decision 2026-11-21:
/// keep it in iCloud Keychain as well as wherever the user saved it).
///
/// The recovery key opens the account key; anyone who can read this copy (the user's Apple ID
/// and its devices) can unlock the notes. Notes on the server stay encrypted either way.
public protocol RecoveryKeyBackup {
    func load(userId: String) -> String?
    /// Returns whether the copy was stored (false when the Keychain refused, e.g. an unsigned build).
    @discardableResult func save(code: String, userId: String) -> Bool
    func remove(userId: String)
}

/// In-memory backup for tests and previews.
public final class MemoryRecoveryKeyBackup: RecoveryKeyBackup, @unchecked Sendable {
    private var items: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func load(userId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return items[userId]
    }

    @discardableResult public func save(code: String, userId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        items[userId] = code
        return true
    }

    public func remove(userId: String) {
        lock.lock(); defer { lock.unlock() }
        items[userId] = nil
    }
}

#if canImport(Security)
/// The recovery key as a synchronizable generic-password item in iCloud Keychain (end-to-end
/// encrypted by Apple), one per account (`account` = userId). It reaches the user's devices that
/// share the app's keychain access group: other iPhones with Matilde now; the Mac app too once
/// both apps are signed with a shared access group (IOS-07, DIST-02). Unsigned builds can't
/// write synchronizable items; `save` then returns false and nothing else changes.
public struct ICloudRecoveryKeyBackup: RecoveryKeyBackup {
    public static let defaultService = "app.matilde.sync.recovery-key"
    public var service = defaultService

    public init(service: String = defaultService) {
        self.service = service
    }

    private func query(userId: String) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: userId,
                                    kSecAttrSynchronizable as String: kCFBooleanTrue as Any]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    public func load(userId: String) -> String? {
        var request = query(userId: userId)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let code = String(data: data, encoding: .utf8), !code.isEmpty else { return nil }
        return code
    }

    @discardableResult public func save(code: String, userId: String) -> Bool {
        let base = query(userId: userId)
        let changes: [String: Any] = [kSecValueData as String: Data(code.utf8)]
        let status = SecItemUpdate(base as CFDictionary, changes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = base.merging(changes) { _, new in new }
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        item[kSecAttrLabel as String] = "Matilde — sync recovery key"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    public func remove(userId: String) {
        _ = SecItemDelete(query(userId: userId) as CFDictionary)
    }
}
#endif
