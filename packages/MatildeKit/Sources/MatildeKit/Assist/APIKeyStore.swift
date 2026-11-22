import Foundation
#if canImport(Security)
import Security

/// The Langdock API key in the Keychain (this device only), shared by the Mac and iOS apps.
/// On the Mac the default key lives in the app's `CredentialVault` (one Keychain item for all of
/// Matilde's secrets); other services, e.g. in tests, keep their own item.
public struct APIKeyStore {
    public static let defaultService = "app.matilde.credentials"
    public static let defaultAccount = "langdock"
    public let service: String
    public let account: String
    private let vault: CredentialVault?
    public init(service: String = APIKeyStore.defaultService, account: String = APIKeyStore.defaultAccount) {
        self.service = service; self.account = account
        #if os(macOS)
        vault = service == Self.defaultService && account == Self.defaultAccount ? CredentialVault.shared : nil
        #else
        vault = nil
        #endif
    }
    /// A store backed by `vault` (tests).
    public init(vault: CredentialVault) {
        service = Self.defaultService; account = Self.defaultAccount; self.vault = vault
    }
    private var vaultName: String { CredentialVault.entryName(service: service, account: account) }
    private static let session = CredentialSessionCache()
    private var cacheID: String { "\(service.utf8.count):\(service)\(account)" }
    public var cachedKey: String? {
        if let vault { return vault.cachedValue(vaultName).flatMap { String(data: $0, encoding: .utf8) } }
        return Self.session.cached(for: cacheID)
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    public func containsKey() throws -> Bool {
        if let vault { return try mapVault { try vault.contains(vaultName) } }
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
        if let vault { return try mapVault { try vault.set(Data(cleaned.utf8), for: vaultName) } }
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
        if let vault {
            return try mapVault { try vault.value(vaultName).map { String(decoding: $0, as: UTF8.self) } }
        }
        return try Self.session.load(for: cacheID) { try readKeychain() }
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
        if let vault { return try mapVault { try vault.set(nil, for: vaultName) } }
        Self.session.store(nil, for: cacheID)
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    private func mapVault<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch CredentialVaultError.keychain(let status) { throw KeyError.access(status) }
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw KeyError.access(status) }
    }
    public enum KeyError: LocalizedError {
        case empty, access(OSStatus)
        public var errorDescription: String? {
            switch self {
            case .empty: return "Enter an API key before saving."
            case .access(let status): return "Keychain could not complete the operation (\(status)). Your saved key has not been cleared."
            }
        }
    }
}
#endif
