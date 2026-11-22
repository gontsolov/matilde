import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import MatildeKit

/// The 12-word Matilde key (BIP-0039 words, HKDF slot secret) and its compatibility with the
/// legacy `MTLD-` recovery keys of 0.2.x accounts.
final class MatildeKeyTests: XCTestCase {
    private let userId = "6f1c2d3e-4a5b-4c6d-8e7f-90a1b2c3d4e5"

    private func serverStores(_ request: SyncPutKeysRequest) -> SyncKeysResponse {
        SyncKeysResponse(keyId: request.keyId, keyCheck: request.keyCheck, slots: request.slots.map {
            SyncKeySlot(slotId: $0.slotId, kind: $0.kind, keyId: request.keyId, params: $0.params, wrappedKey: $0.wrappedKey, updatedAt: 1)
        })
    }

    func testWordlistIsTheBIP39EnglishList() {
        let list = MatildeKeyPhrase.wordlist
        XCTAssertEqual(list.count, 2048)
        let digest = SHA256.hash(data: Data((list.joined(separator: "\n") + "\n").utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda")
        XCTAssertEqual(list, list.sorted())
        XCTAssertEqual(Set(list.map { String($0.prefix(4)) }).count, 2048, "every word is identified by its first four letters")
    }

    func testBIP39Vectors() throws {
        // From the BIP-0039 reference vectors (trezor/python-mnemonic vectors.json).
        let vectors: [(String, String)] = [
            ("80808080808080808080808080808080", "letter advice cage absurd amount doctor acoustic avoid letter advice cage above"),
            ("9e885d952ad362caeb4efe34a8e91bd2", "ozone drill grab fiber curtain grace pudding thank cruise elder eight picnic"),
            ("c0ba5a8e914111210f2bd131f3d5e08d", "scheme spot photo card baby mountain device kick cradle pact join borrow"),
        ]
        for (hex, words) in vectors {
            let entropy = Data(stride(from: 0, to: hex.count, by: 2).map { UInt8(hex.dropFirst($0).prefix(2), radix: 16)! })
            XCTAssertEqual(MatildeKeyPhrase.words(entropy: entropy).joined(separator: " "), words)
            XCTAssertEqual(try MatildeKeyPhrase.entropy(from: words), entropy)
        }
    }

    func testGeneratePhraseParseRoundTrip() throws {
        for _ in 0..<50 {
            let key = SyncRecoveryKey.generate()
            XCTAssertEqual(key.format, .words)
            XCTAssertEqual(key.words.count, 12)
            XCTAssertEqual(key.code, key.words.joined(separator: " "))
            XCTAssertEqual(try SyncRecoveryKey(code: key.code), key)
            XCTAssertEqual(key.key.syncBytes.count, 32)
        }
        XCTAssertNotEqual(SyncRecoveryKey.generate(), SyncRecoveryKey.generate())
    }

    func testPhraseParsingIsForgiving() throws {
        let key = SyncRecoveryKey.generate()
        let words = key.words
        let numbered: [String] = words.indices.map { "\($0 + 1). \(words[$0])" }
        let parenthesised: [String] = words.indices.map { "\($0 + 1)) \(words[$0])" }
        let short: [String] = words.map { String($0.prefix(4)) }
        var variants: [String] = [key.code.uppercased(), words.joined(separator: "\n")]
        variants.append("  " + words.joined(separator: ",  ") + "\n")
        variants.append(numbered.joined(separator: "\n"))
        variants.append(parenthesised.joined(separator: " "))
        variants.append(short.joined(separator: " "))
        for variant in variants {
            XCTAssertEqual(SyncRecoveryKey.format(of: variant), .words, variant)
            XCTAssertEqual(try SyncRecoveryKey(code: variant), key, variant)
            XCTAssertEqual(RecoveryKeyInput.state(of: variant), .valid, variant)
            XCTAssertEqual(RecoveryKeyInput.normalize(variant), key.code, variant)
        }
    }

    func testChecksumCatchesTyposAndSwaps() throws {
        // A wrong word passes the 4-bit checksum about 1 time in 16; it must still never give the same key.
        var caught = 0, total = 0
        for _ in 0..<20 {
            let key = SyncRecoveryKey.generate()
            for position in 0..<12 {
                var words = key.words
                let index = MatildeKeyPhrase.wordlist.firstIndex(of: words[position])!
                words[position] = MatildeKeyPhrase.wordlist[(index + 1 + position) % 2048]
                total += 1
                do {
                    let parsed = try SyncRecoveryKey(code: words.joined(separator: " "))
                    XCTAssertNotEqual(parsed, key)
                } catch {
                    XCTAssertEqual(error as? SyncCryptoError, .recoveryCodeTypo)
                    caught += 1
                }
            }
        }
        XCTAssertGreaterThan(Double(caught) / Double(total), 0.85)

        caught = 0; total = 0
        for _ in 0..<40 {
            let key = SyncRecoveryKey.generate()
            var words = key.words
            guard words[3] != words[7] else { continue }
            words.swapAt(3, 7)
            total += 1
            do {
                let parsed = try SyncRecoveryKey(code: words.joined(separator: " "))
                XCTAssertNotEqual(parsed, key)
            } catch {
                caught += 1
            }
        }
        XCTAssertGreaterThan(Double(caught) / Double(total), 0.75)
    }

    func testWrongLengthAndUnknownWords() {
        let words = SyncRecoveryKey.generate().words
        for bad in [words.dropLast().joined(separator: " "), (words + ["abandon"]).joined(separator: " "),
                    (words.dropLast() + ["matilde"]).joined(separator: " "), (words.dropLast() + ["ab"]).joined(separator: " ")] {
            XCTAssertThrowsError(try SyncRecoveryKey(code: bad)) { XCTAssertEqual($0 as? SyncCryptoError, .invalidRecoveryCode, bad) }
        }
    }

    func testFormatDetection() {
        XCTAssertNil(SyncRecoveryKey.format(of: "  - "))
        XCTAssertEqual(SyncRecoveryKey.format(of: "aban"), .words)
        XCTAssertEqual(SyncRecoveryKey.format(of: "1. abandon 2. abil"), .words)
        XCTAssertEqual(SyncRecoveryKey.format(of: "MTLD-7KQ2"), .legacy)
        XCTAssertEqual(SyncRecoveryKey.format(of: "mtld"), .legacy)
        XCTAssertEqual(SyncRecoveryKey.format(of: "7KQ2-M9XA"), .legacy)
        XCTAssertEqual(SyncRecoveryKey.format(of: "o i l"), .legacy)
        XCTAssertEqual(SyncRecoveryKey.format(of: "ABCU"), .legacy)
        for _ in 0..<50 {
            let legacy = SyncRecoveryKey.generateLegacy().code
            XCTAssertEqual(SyncRecoveryKey.format(of: legacy), .legacy)
            XCTAssertEqual(SyncRecoveryKey.format(of: String(legacy.dropFirst(5))), .legacy)
            XCTAssertEqual(SyncRecoveryKey.format(of: legacy.replacingOccurrences(of: "-", with: " ").lowercased()), .legacy)
        }
    }

    func testSlotSecretIsDerivedWithHKDF() throws {
        let entropy = Data(repeating: 0x2a, count: 16)
        let key = try SyncRecoveryKey(entropy: entropy)
        let expected = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: entropy), salt: Data("matilde/matilde-key/v1".utf8),
                                               info: Data("matilde/matilde-key/v1/slot-secret".utf8), outputByteCount: 32)
        XCTAssertEqual(key.key, expected)
        XCTAssertNotEqual(key.key.syncBytes.prefix(16), entropy)
    }

    // MARK: Enrollment

    func testNewAccountsGetWordsAndUnlockWithThem() throws {
        let first = try SyncKeyEnrollment.create(userId: userId)
        let recovery = try XCTUnwrap(first.recoveryKey)
        XCTAssertEqual(recovery.format, .words)
        let server = serverStores(first.request)
        XCTAssertEqual(server.slots.first { $0.kind == SyncKeySlotKind.recovery }?.params, SyncRecoverySlotParams.words)
        XCTAssertEqual(server.recoveryKeyFormat, .words)
        XCTAssertEqual(try SyncKeyEnrollment.recover(userId: userId, keys: server, recoveryCode: recovery.code), first.ring)
        let lines: [String] = recovery.words.indices.map { "\($0 + 1). \(recovery.words[$0].uppercased())" }
        let numbered = lines.joined(separator: "\n")
        XCTAssertEqual(try SyncKeyEnrollment.recover(userId: userId, keys: server, recoveryCode: numbered), first.ring)
        XCTAssertThrowsError(try SyncKeyEnrollment.recover(userId: userId, keys: server, recoveryKey: .generate()))
    }

    func testLegacyKeysStillUnlock() throws {
        // An account made by 0.2.x: a 32-byte recovery key, slot params null.
        let ring = try AccountKeyRing(userId: userId, current: AccountKey.generate(id: 1))
        let legacy = SyncRecoveryKey.generateLegacy()
        let server = serverStores(try SyncKeyEnrollment.request(ring: ring, expectedKeyId: nil, recovery: legacy))
        XCTAssertNil(server.slots[0].params)
        XCTAssertEqual(server.recoveryKeyFormat, .legacy)
        for entered in [legacy.code, legacy.code.lowercased(), String(legacy.code.dropFirst(5)).replacingOccurrences(of: "-", with: " "),
                        RecoveryKeyInput.normalize(legacy.code)] {
            XCTAssertEqual(try SyncKeyEnrollment.recover(userId: userId, keys: server, recoveryCode: entered), ring, entered)
        }
        // Regenerating the key on such an account switches it to words.
        let regenerated = try SyncKeyEnrollment.regenerateRecoveryKey(ring: ring)
        XCTAssertEqual(regenerated.recoveryKey?.format, .words)
        XCTAssertEqual(serverStores(regenerated.request).recoveryKeyFormat, .words)
        XCTAssertNil(SyncKeysResponse(keyId: nil, keyCheck: nil, slots: []).recoveryKeyFormat)
    }

    // MARK: Input

    func testInputStatesForWords() {
        let key = SyncRecoveryKey.generate()
        let words = key.words
        XCTAssertEqual(RecoveryKeyInput.state(of: words[0]), .incompleteWords(remaining: 11))
        XCTAssertEqual(RecoveryKeyInput.state(of: words.prefix(5).joined(separator: " ") + " "), .incompleteWords(remaining: 7))
        XCTAssertEqual(RecoveryKeyInput.state(of: "abandon abandon xylo"), .unknownWord("xylo"))
        XCTAssertEqual(RecoveryKeyInput.state(of: (words + words).joined(separator: " ")), .tooManyWords)
        XCTAssertEqual(RecoveryKeyInput.state(of: key.code), .valid)
        XCTAssertEqual(RecoveryKeyInput.state(of: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon"), .typo)
        XCTAssertNotNil(RecoveryKeyInput.message(for: .unknownWord("xylo")))
        XCTAssertNotNil(RecoveryKeyInput.message(for: .typo))
        XCTAssertNil(RecoveryKeyInput.message(for: .incompleteWords(remaining: 2)))
        XCTAssertEqual(RecoveryKeyInput.formatted("1. Abandon\n2. ABILITY"), "abandon ability")
        XCTAssertEqual(MatildeKeyPhrase.completions(for: "aba"), ["abandon"])
        XCTAssertEqual(MatildeKeyPhrase.completions(for: "ab", limit: 3), ["abandon", "ability", "able"])
        XCTAssertEqual(MatildeKeyPhrase.completions(for: "zz"), [])
        XCTAssertEqual(MatildeKeyPhrase.resolve("abil"), "ability")
        XCTAssertNil(MatildeKeyPhrase.resolve("abi"))
    }

    func testWordsEditor() {
        let key = SyncRecoveryKey.generate()
        var editor = MatildeKeyWordsEditor()
        XCTAssertEqual(editor.state, .empty)
        // Pasting the whole key into any slot fills every slot.
        let pasted: [String] = key.words.indices.map { "\($0 + 1). \(key.words[$0])" }
        XCTAssertEqual(editor.set(pasted.joined(separator: "\n"), at: 4), 11)
        XCTAssertEqual(editor.words, key.words)
        XCTAssertEqual(editor.state, .valid)
        XCTAssertEqual(try SyncRecoveryKey(code: editor.phrase), key)

        editor.clear()
        XCTAssertEqual(editor.set("aba", at: 0), 0)
        XCTAssertEqual(editor.suggestions(0), ["abandon"])
        XCTAssertEqual(editor.complete(0, with: "abandon"), 1)
        XCTAssertEqual(editor.set("abil ", at: 1), 2, "a space after a known word moves on")
        XCTAssertEqual(editor.words[1], "ability")
        XCTAssertEqual(editor.set("xylo", at: 2), 2)
        XCTAssertTrue(editor.isUnknown(2))
        XCTAssertFalse(editor.isUnknown(0))
        XCTAssertEqual(editor.state, .unknownWord("xylo"))
        XCTAssertEqual(editor.set("able about above", at: 2), 5, "several words fill from the slot on")
        XCTAssertEqual(Array(editor.words.prefix(5)), ["abandon", "ability", "able", "about", "above"])
        XCTAssertEqual(editor.state, .incompleteWords(remaining: 7))
    }
}
