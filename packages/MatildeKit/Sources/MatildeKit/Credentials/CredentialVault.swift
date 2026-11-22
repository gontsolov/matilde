import Foundation

/// The Mac app's secrets in one Keychain item (the sync session, the sync encryption key and the
/// Langdock API key), read once per app session and kept in memory (owner report 2026-11-22: a
/// password prompt per item after every update).
///
/// Why one item: Matilde isn't signed with an Apple team yet (DIST-02), so the login Keychain ties
/// each item to the exact build that last used it (the `cdhash:` partition and a cdhash-based
/// designated requirement). Every update is then a stranger to every item, and macOS asks for the
/// login password once per item. One item means one question, and only when something needs it:
/// nothing here touches the Keychain until a caller asks for a value. Release signing with an
/// Apple-issued certificate (docs/releases.md) removes the question after updates altogether.
///
/// Entries are named `service|account` after the item each one used to be, so the one-time
/// migration (`legacyItems`) and the stores (`VaultSyncTokenStore`, `VaultAccountKeyStore`,
/// `APIKeyStore` on the Mac) agree. The entry names are also kept in the item's attributes, so
/// "is a key saved?" never needs the secret (and never prompts).
public final class CredentialVault: @unchecked Sendable {
    public struct LegacyItem: Hashable, Sendable {
        public var service: String
        /// Nil: every account of the service.
        public var account: String?
        public init(service: String, account: String? = nil) { self.service = service; self.account = account }
    }

    /// The items the Mac app kept before the vault (0.3.3 and earlier).
    public static let legacyItems = [
        LegacyItem(service: "app.matilde.local.sync.session"),
        LegacyItem(service: "app.matilde.local.sync.account-key"),
        LegacyItem(service: "app.matilde.credentials", account: "langdock")
    ]

    public static func entryName(service: String, account: String) -> String { "\(service)|\(account)" }

    /// Called on the main thread just before a read that is likely to make macOS ask (see
    /// `promptLikely`), at most once per app session, so the app can say what's coming first.
    /// `migrating` is the number of older items about to be read (0 for the vault itself).
    nonisolated(unsafe) public static var willAskForAccess: ((_ migrating: Int) -> Void)?

    private let backend: CredentialVaultBackend
    private let record: CredentialAccessRecord
    private let legacy: [LegacyItem]
    private let lock = NSLock()
    private var entries: [String: Data]?
    private var announced = false

    public init(backend: CredentialVaultBackend, record: CredentialAccessRecord, legacy: [LegacyItem] = CredentialVault.legacyItems) {
        self.backend = backend
        self.record = record
        self.legacy = legacy
    }

    /// Whether the values are in memory (no Keychain access needed).
    public var isLoaded: Bool { lock.lock(); defer { lock.unlock() }; return entries != nil }

    /// Whether reading now would probably make macOS ask: something is stored and this build's
    /// signature differs from the one that last opened it. Attributes only; never prompts.
    public func promptLikely() -> Bool {
        if isLoaded { return false }
        let stored = (try? backend.vaultEntryNames()) != nil || legacyCount() > 0
        return stored && record.lastIdentity != record.currentIdentity
    }

    /// Reads the vault (or migrates the older items into it) unless it's already in memory.
    /// Failures (e.g. the person chose Deny) aren't remembered; the next call asks again.
    public func load() throws {
        if isLoaded { return }
        announceIfNeeded()
        lock.lock(); defer { lock.unlock() }
        if entries != nil { return }
        entries = try readOrMigrate()
        record.lastIdentity = record.currentIdentity
    }

    public func value(_ name: String) throws -> Data? {
        try load()
        lock.lock(); defer { lock.unlock() }
        return entries?[name]
    }

    /// The value only if it's already in memory; never touches the Keychain.
    public func cachedValue(_ name: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return entries?[name]
    }

    /// Nil removes the entry. Writes the whole vault, reading it first if needed.
    public func set(_ data: Data?, for name: String) throws {
        try load()
        lock.lock(); defer { lock.unlock() }
        var next = entries ?? [:]
        next[name] = data
        if next == entries { return }
        try write(next)
        entries = next
    }

    /// Whether an entry exists, from memory or the item's attributes; never prompts.
    public func contains(_ name: String) throws -> Bool {
        lock.lock()
        if let entries { lock.unlock(); return entries[name] != nil }
        lock.unlock()
        if let names = try backend.vaultEntryNames() { return names.contains(name) }
        return legacyNames().contains(name)
    }

    // MARK: Internals (called with `lock` held)

    private func readOrMigrate() throws -> [String: Data] {
        if let data = try backend.readVault() { return try CredentialVaultCoding.decode(data) }
        // No vault yet: carry the older items over once, then remove them.
        var migrated: [String: Data] = [:]
        var moved: [(String, String)] = []
        for item in legacy {
            for account in (try? backend.legacyAccounts(service: item.service)) ?? [] where item.account == nil || item.account == account {
                // A refused or unreadable item is left where it is; that sign-in is simply asked for again.
                guard let data = try? backend.readLegacy(service: item.service, account: account) else { continue }
                migrated[Self.entryName(service: item.service, account: account)] = data
                moved.append((item.service, account))
            }
        }
        if !migrated.isEmpty {
            try write(migrated)
            for (service, account) in moved { backend.deleteLegacy(service: service, account: account) }
        }
        return migrated
    }

    private func write(_ next: [String: Data]) throws {
        if next.isEmpty { try backend.deleteVault(); return }
        try backend.writeVault(CredentialVaultCoding.encode(next), names: next.keys.sorted())
    }

    private func announceIfNeeded() {
        guard Thread.isMainThread, let announce = Self.willAskForAccess else { return }
        lock.lock()
        let first = !announced
        announced = true
        lock.unlock()
        guard first, promptLikely() else { return }
        announce((try? backend.vaultEntryNames()) != nil ? 0 : legacyCount())
    }

    private func legacyNames() -> Set<String> {
        var names = Set<String>()
        for item in legacy {
            for account in (try? backend.legacyAccounts(service: item.service)) ?? [] where item.account == nil || item.account == account {
                names.insert(Self.entryName(service: item.service, account: account))
            }
        }
        return names
    }

    private func legacyCount() -> Int { legacyNames().count }
}

/// Storage under the vault: the Keychain on the Mac, memory in tests.
public protocol CredentialVaultBackend: AnyObject {
    /// The vault's secret bytes, or nil if there's no vault. May make macOS ask.
    func readVault() throws -> Data?
    /// The entry names kept in the vault's attributes, or nil if there's no vault. Never prompts.
    func vaultEntryNames() throws -> [String]?
    func writeVault(_ data: Data, names: [String]) throws
    func deleteVault() throws
    /// Accounts of an older item's service, from attributes only. Never prompts.
    func legacyAccounts(service: String) throws -> [String]
    /// An older item's secret. May make macOS ask.
    func readLegacy(service: String, account: String) throws -> Data?
    /// Best effort: macOS may refuse when the item belongs to an older build.
    func deleteLegacy(service: String, account: String)
}

/// Which signature last opened the vault, so the app can tell when macOS is about to ask.
public protocol CredentialAccessRecord: AnyObject {
    /// This build's code-signing identity (its designated requirement), or nil if unknown.
    var currentIdentity: String? { get }
    var lastIdentity: String? { get set }
}

public final class DefaultsCredentialAccessRecord: CredentialAccessRecord, @unchecked Sendable {
    public static let key = "keychain.vaultIdentity"
    private let defaults: UserDefaults
    public let currentIdentity: String?
    public init(defaults: UserDefaults = .standard, currentIdentity: String?) {
        self.defaults = defaults
        self.currentIdentity = currentIdentity
    }
    public var lastIdentity: String? {
        get { defaults.string(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}

/// Vault format v1: JSON `{"version":1,"entries":{name: base64}}`.
public enum CredentialVaultCoding {
    struct Payload: Codable { var version: Int; var entries: [String: Data] }
    public static func encode(_ entries: [String: Data]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(Payload(version: 1, entries: entries))
    }
    public static func decode(_ data: Data) throws -> [String: Data] {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard payload.version == 1 else { throw CredentialVaultError.unsupportedVersion(payload.version) }
        return payload.entries
    }
}

public enum CredentialVaultError: Error, Equatable {
    case unsupportedVersion(Int)
    case keychain(Int32)
}

/// In-memory backend for tests; counts the reads that would make macOS ask.
public final class MemoryCredentialVaultBackend: CredentialVaultBackend, @unchecked Sendable {
    public var vault: (data: Data, names: [String])?
    public var legacy: [String: [String: Data]] = [:]
    /// Legacy items whose delete macOS refuses (older build's partition).
    public var undeletable: Set<String> = []
    /// Reads of an item that would make macOS ask, in order (`vault` or `service|account`).
    public private(set) var secretReads: [String] = []
    public var denied: Set<String> = []
    public init() {}

    public func readVault() throws -> Data? {
        guard let vault else { return nil }
        secretReads.append("vault")
        if denied.contains("vault") { throw CredentialVaultError.keychain(-128) }
        return vault.data
    }
    public func vaultEntryNames() throws -> [String]? { vault?.names }
    public func writeVault(_ data: Data, names: [String]) throws { vault = (data, names) }
    public func deleteVault() throws { vault = nil }
    public func legacyAccounts(service: String) throws -> [String] { legacy[service].map { $0.keys.sorted() } ?? [] }
    public func readLegacy(service: String, account: String) throws -> Data? {
        let name = CredentialVault.entryName(service: service, account: account)
        secretReads.append(name)
        if denied.contains(name) { throw CredentialVaultError.keychain(-128) }
        return legacy[service]?[account]
    }
    public func deleteLegacy(service: String, account: String) {
        guard !undeletable.contains(CredentialVault.entryName(service: service, account: account)) else { return }
        legacy[service]?[account] = nil
        if legacy[service]?.isEmpty == true { legacy[service] = nil }
    }
}

public final class MemoryCredentialAccessRecord: CredentialAccessRecord, @unchecked Sendable {
    public var currentIdentity: String?
    public var lastIdentity: String?
    public init(current: String?, last: String? = nil) { currentIdentity = current; lastIdentity = last }
}
