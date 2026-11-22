import Foundation
#if os(macOS)
import Security

/// The vault as one generic-password item in the login Keychain.
public final class KeychainCredentialVaultBackend: CredentialVaultBackend, @unchecked Sendable {
    public static let service = "app.matilde.local.vault"
    public static let account = "default"
    /// Shown in the macOS dialog: “Matilde wants to use your confidential information stored in "Matilde" in your keychain.”
    public static let label = "Matilde"
    public let service: String

    public init(service: String = KeychainCredentialVaultBackend.service) { self.service = service }

    private var vaultQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: Self.account]
    }

    public func readVault() throws -> Data? {
        var request = vaultQuery
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CredentialVaultError.keychain(status) }
        return data
    }

    public func vaultEntryNames() throws -> [String]? {
        var request = vaultQuery
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let attributes = result as? [String: Any] else { throw CredentialVaultError.keychain(status) }
        guard let generic = attributes[kSecAttrGeneric as String] as? Data,
              let names = try? JSONDecoder().decode([String].self, from: generic) else { return [] }
        return names
    }

    public func writeVault(_ data: Data, names: [String]) throws {
        let generic = try JSONEncoder().encode(names)
        let changes: [String: Any] = [kSecValueData as String: data, kSecAttrGeneric as String: generic]
        let status = SecItemUpdate(vaultQuery as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item = vaultQuery.merging(changes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecAttrLabel as String] = Self.label
            item[kSecAttrDescription as String] = "Matilde sign-ins"
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw CredentialVaultError.keychain(added) }
        } else if status != errSecSuccess {
            throw CredentialVaultError.keychain(status)
        }
    }

    public func deleteVault() throws {
        let status = SecItemDelete(vaultQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialVaultError.keychain(status) }
    }

    public func legacyAccounts(service: String) throws -> [String] {
        let request: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                      kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { throw CredentialVaultError.keychain(status) }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    public func readLegacy(service: String, account: String) throws -> Data? {
        let request: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                      kSecAttrAccount as String: account,
                                      kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CredentialVaultError.keychain(status) }
        return data
    }

    public func deleteLegacy(service: String, account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        _ = SecItemDelete(query as CFDictionary)
    }
}

public enum CodeSigningIdentity {
    /// This process's designated requirement as text, e.g. `cdhash H"…"` for an ad-hoc build
    /// (changes with every build) or `identifier "app.matilde.local" and anchor apple generic and
    /// certificate leaf[subject.OU] = "…"` for a release signed with an Apple certificate.
    public static func current() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        return text as String
    }
}

extension CredentialVault {
    /// The Mac app's vault in the login Keychain.
    public static let shared = CredentialVault(backend: KeychainCredentialVaultBackend(),
                                               record: DefaultsCredentialAccessRecord(currentIdentity: CodeSigningIdentity.current()))
}
#endif

/// Sync tokens as a vault entry (`app.matilde.local.sync.session|<host>`), the Mac's replacement
/// for `KeychainSyncTokenStore`.
public final class VaultSyncTokenStore: SyncTokenStore, @unchecked Sendable {
    public static let service = "app.matilde.local.sync.session"
    private let vault: CredentialVault
    private let name: String

    public init(server: SyncServer, vault: CredentialVault) {
        self.vault = vault
        name = CredentialVault.entryName(service: Self.service, account: server.baseURL.host ?? "sync")
    }

    public func load() throws -> SyncTokens? {
        try vault.value(name).map { try JSONDecoder().decode(SyncTokens.self, from: $0) }
    }
    public func save(_ tokens: SyncTokens) throws { try vault.set(try JSONEncoder().encode(tokens), for: name) }
    public func remove() throws { try vault.set(nil, for: name) }
}

/// Account keys as vault entries (`app.matilde.local.sync.account-key|<userId>`), the Mac's
/// replacement for `KeychainAccountKeyStore`.
public struct VaultAccountKeyStore: AccountKeyStore {
    public static let service = "app.matilde.local.sync.account-key"
    private let vault: CredentialVault

    public init(vault: CredentialVault) { self.vault = vault }

    private func name(_ userId: String) -> String { CredentialVault.entryName(service: Self.service, account: userId) }

    public func load(userId: String) throws -> AccountKeyRing? {
        try vault.value(name(userId)).map { try AccountKeyRingCoding.decode($0, userId: userId) }
    }
    public func save(_ ring: AccountKeyRing) throws { try vault.set(AccountKeyRingCoding.encode(ring), for: name(ring.userId)) }
    public func remove(userId: String) throws { try vault.set(nil, for: name(userId)) }
}
