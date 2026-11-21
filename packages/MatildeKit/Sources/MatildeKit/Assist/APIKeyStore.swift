import Foundation
#if canImport(Security)
import Security

/// The Langdock API key in the Keychain (this device only), shared by the Mac and iOS apps.
public struct APIKeyStore {
    public let service: String
    public let account: String
    public init(service: String = "app.matilde.credentials", account: String = "langdock") {
        self.service = service; self.account = account
    }
    private static let session = CredentialSessionCache()
    private var cacheID: String { "\(service.utf8.count):\(service)\(account)" }
    public var cachedKey: String? { Self.session.cached(for: cacheID) }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    public func containsKey() throws -> Bool {
        var request = query
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return false }
        try check(status)
        return true
    }
    public func save(_ key: String) throws {
        let cleaned = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw KeyError.empty }
        Self.session.store(nil, for: cacheID)
        let changes = [kSecValueData as String: Data(cleaned.utf8)]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(changes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            item[kSecAttrLabel as String] = "Matilde — Langdock API key"
            try check(SecItemAdd(item as CFDictionary, nil))
        } else { try check(status) }
        Self.session.store(cleaned, for: cacheID)
    }
    /// Only callers making an authorized provider request should retrieve the key.
    /// Settings uses an attributes-only query and never loads it into the UI.
    public func load() throws -> String? {
        try Self.session.load(for: cacheID) { try readKeychain() }
    }
    private func readKeychain() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else { throw KeyError.access(errSecDecode) }
        return key
    }
    public func remove() throws {
        Self.session.store(nil, for: cacheID)
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw KeyError.access(status) }
    }
    public enum KeyError: LocalizedError {
        case empty, access(OSStatus)
        var errorDescription: String? {
            switch self {
            case .empty: return "Enter an API key before saving."
            case .access(let status): return "Keychain could not complete the operation (\(status)). Your saved key has not been cleared."
            }
        }
    }
}
#endif
