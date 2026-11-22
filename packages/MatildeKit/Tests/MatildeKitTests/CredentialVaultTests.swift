import XCTest
@testable import MatildeKit

/// The Mac app's one Keychain item (owner report 2026-11-22: a password prompt per item after
/// every update). The memory backend counts the reads that would make macOS ask.
final class CredentialVaultTests: XCTestCase {
    private let session = "app.matilde.local.sync.session"
    private let accountKey = "app.matilde.local.sync.account-key"
    private let credentials = "app.matilde.credentials"

    private func vault(_ backend: MemoryCredentialVaultBackend, current: String? = "build-2", last: String? = "build-1") -> (CredentialVault, MemoryCredentialAccessRecord) {
        let record = MemoryCredentialAccessRecord(current: current, last: last)
        return (CredentialVault(backend: backend, record: record), record)
    }

    private func legacyBackend() -> MemoryCredentialVaultBackend {
        let backend = MemoryCredentialVaultBackend()
        backend.legacy = [session: ["sync.matilde.page": Data("tokens".utf8)],
                          accountKey: ["user-1": Data("ring".utf8)],
                          credentials: ["langdock": Data("sk-test".utf8), "other": Data("ignored".utf8)]]
        return backend
    }

    func testNothingIsReadUntilAValueIsNeeded() throws {
        let backend = legacyBackend()
        let (vault, _) = vault(backend)
        XCTAssertTrue(try vault.contains(CredentialVault.entryName(service: credentials, account: "langdock")))
        XCTAssertFalse(try vault.contains(CredentialVault.entryName(service: credentials, account: "other")))
        XCTAssertNil(vault.cachedValue(CredentialVault.entryName(service: session, account: "sync.matilde.page")))
        XCTAssertTrue(vault.promptLikely())
        XCTAssertEqual(backend.secretReads, [], "attribute checks never read a secret")
    }

    func testMigratesOlderItemsOnceIntoOneItem() throws {
        let backend = legacyBackend()
        let (vault, record) = vault(backend)
        let name = CredentialVault.entryName(service: session, account: "sync.matilde.page")
        XCTAssertEqual(try vault.value(name), Data("tokens".utf8))
        XCTAssertEqual(backend.secretReads.count, 3, "one read per older item, only the known accounts")
        XCTAssertEqual(backend.legacy[credentials]?.keys.sorted(), ["other"], "migrated items are removed")
        XCTAssertNil(backend.legacy[session])
        XCTAssertEqual(backend.vault?.names.sorted(), [
            CredentialVault.entryName(service: credentials, account: "langdock"),
            CredentialVault.entryName(service: accountKey, account: "user-1"),
            name])
        XCTAssertEqual(record.lastIdentity, "build-2")
        XCTAssertFalse(vault.promptLikely())

        // Later reads and writes in the same session stay in memory.
        XCTAssertEqual(try vault.value(CredentialVault.entryName(service: accountKey, account: "user-1")), Data("ring".utf8))
        try vault.set(Data("tokens-2".utf8), for: name)
        XCTAssertEqual(backend.secretReads.count, 3)

        // The next launch (same build): one read of the one item, no migration.
        let (next, _) = self.vault(backend, current: "build-2", last: record.lastIdentity)
        XCTAssertFalse(next.promptLikely())
        XCTAssertEqual(try next.value(name), Data("tokens-2".utf8))
        XCTAssertEqual(backend.secretReads.suffix(1), ["vault"])
    }

    func testRefusedOlderItemStaysAndTheRestMoves() throws {
        let backend = legacyBackend()
        backend.denied = [CredentialVault.entryName(service: session, account: "sync.matilde.page")]
        let (vault, _) = vault(backend)
        XCTAssertNil(try vault.value(CredentialVault.entryName(service: session, account: "sync.matilde.page")))
        XCTAssertEqual(try vault.value(CredentialVault.entryName(service: credentials, account: "langdock")), Data("sk-test".utf8))
        XCTAssertNotNil(backend.legacy[session], "a refused item is left alone")
    }

    func testAnUpdateMakesAPromptLikelyAgainOnlyWhenTheSignatureChanges() throws {
        let backend = MemoryCredentialVaultBackend()
        let (first, record) = vault(backend, current: "cdhash H\"aa\"", last: nil)
        XCTAssertFalse(first.promptLikely(), "nothing stored yet")
        try first.set(Data("k".utf8), for: "a|b")
        XCTAssertEqual(backend.secretReads, [], "creating the item reads nothing")

        // Ad-hoc update: new cdhash, so macOS will ask once.
        let (adHoc, _) = vault(backend, current: "cdhash H\"bb\"", last: record.lastIdentity)
        XCTAssertTrue(adHoc.promptLikely())

        // Signed with a stable identity: the switch asks once, the update after it doesn't.
        let stable = "identifier \"app.matilde.local\" and anchor apple generic and certificate leaf[subject.OU] = \"TEAM\""
        let (switched, switchedRecord) = vault(backend, current: stable, last: record.lastIdentity)
        XCTAssertTrue(switched.promptLikely())
        _ = try switched.value("a|b")
        let (updated, _) = vault(backend, current: stable, last: switchedRecord.lastIdentity)
        XCTAssertFalse(updated.promptLikely())
    }

    func testRefusedVaultReadIsNotRemembered() throws {
        let backend = MemoryCredentialVaultBackend()
        backend.vault = (try CredentialVaultCoding.encode(["a|b": Data("k".utf8)]), ["a|b"])
        backend.denied = ["vault"]
        let (vault, _) = vault(backend)
        XCTAssertThrowsError(try vault.value("a|b"))
        XCTAssertThrowsError(try vault.set(Data("x".utf8), for: "a|b"), "never overwrite a vault that couldn't be read")
        backend.denied = []
        XCTAssertEqual(try vault.value("a|b"), Data("k".utf8))
    }

    func testRemovingTheLastEntryDeletesTheItem() throws {
        let backend = MemoryCredentialVaultBackend()
        let (vault, _) = vault(backend)
        try vault.set(Data("k".utf8), for: "a|b")
        XCTAssertNotNil(backend.vault)
        try vault.set(nil, for: "a|b")
        XCTAssertNil(backend.vault)
        XCTAssertFalse(try vault.contains("a|b"))
    }

    func testStoresShareTheVault() async throws {
        let backend = legacyBackend()
        backend.legacy[session] = nil
        backend.legacy[accountKey] = nil
        let (vault, _) = vault(backend)
        let userId = UUID().uuidString.lowercased()
        let tokens = SyncTokens(accessToken: "a", accessExpiry: Date(timeIntervalSince1970: 100), refreshToken: "r", sessionId: "s", userId: userId)
        let tokenStore = VaultSyncTokenStore(server: .production, vault: vault)
        XCTAssertNil(try tokenStore.load())
        try tokenStore.save(tokens)
        XCTAssertEqual(try tokenStore.load(), tokens)

        let ring = try SyncKeyEnrollment.create(userId: userId).ring
        let keyStore = VaultAccountKeyStore(vault: vault)
        try keyStore.save(ring)
        XCTAssertEqual(try keyStore.load(userId: userId), ring)
        XCTAssertEqual(backend.secretReads, [CredentialVault.entryName(service: credentials, account: "langdock")],
                       "the one older item is read once; everything after stays in memory")
        let names = try XCTUnwrap(backend.vault?.names)
        XCTAssertTrue(names.contains(CredentialVault.entryName(service: credentials, account: "langdock")), "the API key moved along")
        XCTAssertEqual(names.count, 3)

        // A session reads its store when first used, from memory here.
        let lazy = SyncSession(http: SyncHTTP(server: .production), store: tokenStore)
        let current = await lazy.current
        XCTAssertEqual(current, tokens)
        XCTAssertEqual(backend.secretReads.count, 1)

        try keyStore.remove(userId: userId)
        try tokenStore.remove()
        XCTAssertEqual(try XCTUnwrap(backend.vault?.names), [CredentialVault.entryName(service: credentials, account: "langdock")])
    }

    func testSessionLoadsItsStoreOnFirstUse() async throws {
        final class CountingStore: SyncTokenStore, @unchecked Sendable {
            var loads = 0
            func load() throws -> SyncTokens? { loads += 1; return nil }
            func save(_ tokens: SyncTokens) throws {}
            func remove() throws {}
        }
        let store = CountingStore()
        let session = SyncSession(http: SyncHTTP(server: .production), store: store)
        XCTAssertEqual(store.loads, 0)
        _ = await session.current
        _ = await session.current
        XCTAssertEqual(store.loads, 1, "one attempt per session")
    }

    func testNoteCopyFollowsTheWordingRules() {
        for text in [KeychainNoteCopy.title, KeychainNoteCopy.text(migrating: 0), KeychainNoteCopy.text(migrating: 3)] {
            let lower = text.lowercased()
            for banned in ["we ", "we’", "by us", "filip", "not even us"] { XCTAssertFalse(lower.contains(banned), "\(banned) in \(text)") }
        }
        XCTAssertTrue(KeychainNoteCopy.text(migrating: 0).contains("Always Allow"))
        XCTAssertTrue(KeychainNoteCopy.text(migrating: 3).contains("3"))
    }
}
