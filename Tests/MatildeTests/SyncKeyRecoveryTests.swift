import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import Matilde

final class SyncKeyRecoveryTests: XCTestCase {
    private let userId = "6f1c2d3e-4a5b-4c6d-8e7f-90a1b2c3d4e5"
    private let recordContext = SyncRecordContext(userId: "6f1c2d3e-4a5b-4c6d-8e7f-90a1b2c3d4e5", recordId: "a1b2c3d4-e5f6-4a07-8b18-c29d3e4f5a60",
                                                  type: 2, hlc: "1763500000000.00042.0b3c1d2e-3f40-4a51-8b62-7c83d94ea5f6")

    /// What the server would store and return after accepting a `PUT /v1/keys` (server/src/auth/routes.ts).
    private func serverStores(_ request: SyncPutKeysRequest) -> SyncKeysResponse {
        SyncKeysResponse(keyId: request.keyId, keyCheck: request.keyCheck, slots: request.slots.map {
            SyncKeySlot(slotId: $0.slotId, kind: $0.kind, keyId: request.keyId, params: $0.params, wrappedKey: $0.wrappedKey, updatedAt: 1_763_500_000_000)
        })
    }

    // MARK: Recovery code

    func testRecoveryCodeFormat() throws {
        let recovery = SyncRecoveryKey.generate()
        let code = recovery.code
        let groups = code.split(separator: "-")
        XCTAssertEqual(groups.count, 14)
        XCTAssertEqual(groups.first, "MTLD")
        XCTAssertTrue(groups.dropFirst().allSatisfy { $0.count == 4 })
        XCTAssertTrue(groups.dropFirst().joined().allSatisfy { "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains($0) })
        XCTAssertEqual(recovery.lastGroup, String(groups.last!))
        XCTAssertNotEqual(SyncRecoveryKey.generate().code, code)
    }

    func testRecoveryCodeParsingIsForgiving() throws {
        let recovery = SyncRecoveryKey.generate()
        let code = recovery.code
        let bare = code.replacingOccurrences(of: "-", with: "")
        let variants = [
            code,
            code.lowercased(),
            String(bare.dropFirst(4)),
            code.replacingOccurrences(of: "-", with: " "),
            "  \(code)\n",
            code.replacingOccurrences(of: "0", with: "O").replacingOccurrences(of: "1", with: "l"),
            code.replacingOccurrences(of: "-", with: "–"),
        ]
        for variant in variants { XCTAssertEqual(try SyncRecoveryKey(code: variant), recovery, variant) }
    }

    func testRecoveryCodeTyposAreCaught() throws {
        let code = SyncRecoveryKey.generate().code
        XCTAssertThrowsError(try SyncRecoveryKey(code: String(code.dropLast()))) { XCTAssertEqual($0 as? SyncCryptoError, .invalidRecoveryCode) }
        XCTAssertThrowsError(try SyncRecoveryKey(code: code + "A")) { XCTAssertEqual($0 as? SyncCryptoError, .invalidRecoveryCode) }
        XCTAssertThrowsError(try SyncRecoveryKey(code: code.replacingOccurrences(of: "MTLD-", with: "MTLD-U"))) { _ in }
        XCTAssertThrowsError(try SyncRecoveryKey(code: "")) { XCTAssertEqual($0 as? SyncCryptoError, .invalidRecoveryCode) }
        // Single-character substitutions: the 4 check bits catch most (about 15 in 16); the rest are caught
        // later because the key slot won't unwrap. None may silently parse to the same key.
        var chars = Array(code)
        var caught = 0
        var total = 0
        for index in chars.indices where chars[index] != "-" && index >= 5 {
            let original = chars[index]
            chars[index] = original == "7" ? "8" : "7"
            total += 1
            do {
                let parsed = try SyncRecoveryKey(code: String(chars))
                XCTAssertNotEqual(parsed, try SyncRecoveryKey(code: code))
            } catch {
                caught += 1
            }
            chars[index] = original
        }
        XCTAssertGreaterThanOrEqual(Double(caught) / Double(total), 0.6)
    }

    func testLastGroupConfirmation() throws {
        let recovery = SyncRecoveryKey.generate()
        XCTAssertTrue(recovery.confirms(lastGroup: recovery.lastGroup))
        XCTAssertTrue(recovery.confirms(lastGroup: " \(recovery.lastGroup.lowercased()) "))
        XCTAssertFalse(recovery.confirms(lastGroup: ""))
        let wrong = recovery.lastGroup.first == "7" ? "8" + recovery.lastGroup.dropFirst() : "7" + recovery.lastGroup.dropFirst()
        XCTAssertFalse(recovery.confirms(lastGroup: wrong))
    }

    // MARK: Enrollment and recovery

    func testFirstDeviceEnrollmentRequest() throws {
        let result = try SyncKeyEnrollment.create(userId: userId)
        XCTAssertNotNil(result.recoveryKey)
        XCTAssertEqual(result.request.expectedKeyId, nil)
        XCTAssertEqual(result.request.keyId, 1)
        XCTAssertEqual(result.request.slots.map(\.kind), ["recovery"])
        XCTAssertEqual(Data(base64Encoded: result.request.keyCheck), result.ring.current.check)
        // Within the server's limits (server/src/auth/routes.ts).
        for slot in result.request.slots {
            XCTAssertNotNil(UUID(uuidString: slot.slotId))
            XCTAssertEqual(slot.slotId, slot.slotId.lowercased())
            XCTAssertLessThanOrEqual(slot.wrappedKey.count, 1024)
            XCTAssertNotNil(slot.kind.range(of: "^[a-z][a-z0-9-]{0,31}$", options: .regularExpression))
        }
        XCTAssertLessThanOrEqual(result.request.keyCheck.count, 128)
        // The wrapped key never contains the raw account key.
        let raw = result.ring.current.key.syncBytes
        XCTAssertFalse(result.request.slots.contains { Data(base64Encoded: $0.wrappedKey)!.range(of: raw) != nil })
    }

    func testPutKeysJSONMatchesServer() throws {
        let result = try SyncKeyEnrollment.create(userId: userId)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result.request)) as! [String: Any]
        // The server requires an explicit null (undefined is rejected) when no key exists yet.
        XCTAssertTrue(object.keys.contains("expectedKeyId"))
        XCTAssertTrue(object["expectedKeyId"] is NSNull)
        XCTAssertEqual(object["keyId"] as? Int, 1)
        let slot = (object["slots"] as! [[String: Any]])[0]
        XCTAssertEqual(Set(slot.keys), ["slotId", "kind", "params", "wrappedKey"])
        let rotated = try SyncKeyEnrollment.rotate(ring: result.ring)
        let rotatedObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rotated.request)) as! [String: Any]
        XCTAssertEqual(rotatedObject["expectedKeyId"] as? Int, 1)
        XCTAssertEqual(rotatedObject["keyId"] as? Int, 2)
    }

    func testKeysResponseDecodesServerJSON() throws {
        let json = """
        {"keyId":1,"keyCheck":"AAAA","slots":[{"slotId":"e5f6a7b8-c9d0-4e1f-8a2b-3c4d5e6f7a80","kind":"recovery","keyId":1,"params":null,"wrappedKey":"AAAA","updatedAt":1763500000000}]}
        """
        let keys = try JSONDecoder().decode(SyncKeysResponse.self, from: Data(json.utf8))
        XCTAssertEqual(keys.keyId, 1)
        XCTAssertEqual(keys.slots.first?.kind, "recovery")
        let empty = try JSONDecoder().decode(SyncKeysResponse.self, from: Data(#"{"keyId":null,"keyCheck":null,"slots":[]}"#.utf8))
        XCTAssertNil(empty.keyId)
        XCTAssertThrowsError(try SyncKeyEnrollment.recover(userId: userId, keys: empty, recoveryKey: .generate())) {
            XCTAssertEqual($0 as? SyncCryptoError, .noSlot)
        }
    }

    func testNewDeviceRecoversWithTheCode() throws {
        let first = try SyncKeyEnrollment.create(userId: userId)
        let server = serverStores(first.request)
        let envelope = try SyncRecordCrypto.seal(Data("synced".utf8), context: recordContext, key: first.ring.current)
        let code = first.recoveryKey!.code
        let recovered = try SyncKeyEnrollment.recover(userId: userId, keys: server, recoveryCode: code.lowercased())
        XCTAssertEqual(recovered, first.ring)
        XCTAssertEqual(try SyncRecordCrypto.open(envelope, context: recordContext, keyId: 1, ring: recovered), Data("synced".utf8))
    }

    func testWrongRecoveryCodeFails() throws {
        let first = try SyncKeyEnrollment.create(userId: userId)
        let server = serverStores(first.request)
        XCTAssertThrowsError(try SyncKeyEnrollment.recover(userId: userId, keys: server, recoveryKey: .generate())) {
            XCTAssertEqual($0 as? SyncCryptoError, .authenticationFailed)
        }
    }

    func testSlotIsBoundToAccountSlotAndEpoch() throws {
        let first = try SyncKeyEnrollment.create(userId: userId)
        let server = serverStores(first.request)
        let recovery = first.recoveryKey!
        XCTAssertThrowsError(try SyncKeyEnrollment.recover(userId: "7a2d3e4f-5b6c-4d7e-9f80-a1b2c3d4e5f6", keys: server, recoveryKey: recovery))
        var movedSlot = server
        movedSlot.slots[0].slotId = "f6a7b8c9-d0e1-4f2a-9b3c-4d5e6f7a8b91"
        XCTAssertThrowsError(try SyncKeyEnrollment.recover(userId: userId, keys: movedSlot, recoveryKey: recovery))
        var tampered = server
        var bytes = Data(base64Encoded: tampered.slots[0].wrappedKey)!
        bytes[bytes.count - 1] ^= 1
        tampered.slots[0].wrappedKey = bytes.base64EncodedString()
        XCTAssertThrowsError(try SyncKeyEnrollment.recover(userId: userId, keys: tampered, recoveryKey: recovery))
    }

    func testServerSubstitutedKeyCheckIsDetected() throws {
        let first = try SyncKeyEnrollment.create(userId: userId)
        var server = serverStores(first.request)
        server.keyCheck = try AccountKey.generate().check.base64EncodedString()
        XCTAssertThrowsError(try SyncKeyEnrollment.recover(userId: userId, keys: server, recoveryKey: first.recoveryKey!)) {
            XCTAssertEqual($0 as? SyncCryptoError, .keyCheckMismatch)
        }
        XCTAssertThrowsError(try SyncKeyEnrollment.ring(userId: userId, current: first.ring.current, keys: server)) {
            XCTAssertEqual($0 as? SyncCryptoError, .keyCheckMismatch)
        }
    }

    func testRegeneratedRecoveryCodeReplacesTheOldOne() throws {
        let first = try SyncKeyEnrollment.create(userId: userId)
        let regenerated = try SyncKeyEnrollment.regenerateRecoveryKey(ring: first.ring)
        XCTAssertEqual(regenerated.request.expectedKeyId, 1)
        XCTAssertEqual(regenerated.request.keyId, 1)
        XCTAssertEqual(regenerated.ring, first.ring)
        XCTAssertNotEqual(regenerated.recoveryKey, first.recoveryKey)
        let server = serverStores(regenerated.request)
        XCTAssertEqual(try SyncKeyEnrollment.recover(userId: userId, keys: server, recoveryKey: regenerated.recoveryKey!), first.ring)
        XCTAssertThrowsError(try SyncKeyEnrollment.recover(userId: userId, keys: server, recoveryKey: first.recoveryKey!))
    }

    func testRotationLetsANewDeviceReadOldAndNewRecords() throws {
        let first = try SyncKeyEnrollment.create(userId: userId)
        let old = try SyncRecordCrypto.seal(Data("before".utf8), context: recordContext, key: first.ring.current)
        // Rotate keeping the user's existing recovery code.
        let rotated = try SyncKeyEnrollment.rotate(ring: first.ring, recoveryKey: first.recoveryKey!)
        XCTAssertNil(rotated.recoveryKey)
        XCTAssertEqual(rotated.request.expectedKeyId, 1)
        XCTAssertEqual(Set(rotated.request.slots.map(\.kind)), ["recovery", "previous-keys"])
        let server = serverStores(rotated.request)
        let newer = try SyncRecordCrypto.seal(Data("after".utf8), context: recordContext, key: rotated.ring.current)

        let device = try SyncKeyEnrollment.recover(userId: userId, keys: server, recoveryCode: first.recoveryKey!.code)
        XCTAssertEqual(device.current.id, 2)
        XCTAssertEqual(device.previous, [first.ring.current])
        XCTAssertEqual(try SyncRecordCrypto.open(old, context: recordContext, keyId: 1, ring: device), Data("before".utf8))
        XCTAssertEqual(try SyncRecordCrypto.open(newer, context: recordContext, keyId: 2, ring: device), Data("after".utf8))

        // A device still holding only epoch 1 must not pass the check against epoch 2.
        XCTAssertThrowsError(try SyncKeyEnrollment.ring(userId: userId, current: first.ring.current, keys: server))
        // A device holding epoch 2 in its Keychain gets the old epoch from the slot.
        XCTAssertEqual(try SyncKeyEnrollment.ring(userId: userId, current: rotated.ring.current, keys: server), device)
    }

    func testRotationWithNewRecoveryCodeInvalidatesTheOldCode() throws {
        let first = try SyncKeyEnrollment.create(userId: userId)
        let rotated = try SyncKeyEnrollment.rotate(ring: first.ring)
        let server = serverStores(rotated.request)
        XCTAssertNotNil(rotated.recoveryKey)
        XCTAssertThrowsError(try SyncKeyEnrollment.recover(userId: userId, keys: server, recoveryKey: first.recoveryKey!))
        XCTAssertEqual(try SyncKeyEnrollment.recover(userId: userId, keys: server, recoveryKey: rotated.recoveryKey!), rotated.ring)
    }

    func testDropPreviousKeysKeepsRecoverySlot() throws {
        let first = try SyncKeyEnrollment.create(userId: userId)
        let rotated = try SyncKeyEnrollment.rotate(ring: first.ring)
        let server = serverStores(rotated.request)
        let dropped = try SyncKeyEnrollment.dropPreviousKeys(ring: rotated.ring, ids: [1], keys: server)
        XCTAssertEqual(dropped.request.expectedKeyId, 2)
        XCTAssertEqual(dropped.request.slots.map(\.kind), ["recovery"])
        XCTAssertEqual(dropped.ring.previous, [])
        let after = serverStores(dropped.request)
        let device = try SyncKeyEnrollment.recover(userId: userId, keys: after, recoveryKey: rotated.recoveryKey!)
        XCTAssertEqual(device.current, rotated.ring.current)
        XCTAssertEqual(device.previous, [])
    }

    func testManyRotationsStayWithinServerSlotLimits() throws {
        var result = try SyncKeyEnrollment.create(userId: userId)
        for _ in 0..<SyncKeyEnrollment.maxPreviousKeys {
            result = try SyncKeyEnrollment.rotate(ring: result.ring)
            for slot in result.request.slots { XCTAssertLessThanOrEqual(slot.wrappedKey.count, 1024) }
        }
        XCTAssertEqual(result.ring.previous.count, SyncKeyEnrollment.maxPreviousKeys)
        XCTAssertThrowsError(try SyncKeyEnrollment.rotate(ring: result.ring))
        let device = try SyncKeyEnrollment.recover(userId: userId, keys: serverStores(result.request), recoveryKey: result.recoveryKey!)
        XCTAssertEqual(device, result.ring)
    }

    // MARK: Key storage

    func testKeyRingStorageRoundTrip() throws {
        let store = MemoryAccountKeyStore()
        let first = try SyncKeyEnrollment.create(userId: userId)
        let rotated = try SyncKeyEnrollment.rotate(ring: first.ring)
        XCTAssertNil(try store.load(userId: userId))
        try store.save(rotated.ring)
        XCTAssertEqual(try store.load(userId: userId), rotated.ring)
        try store.remove(userId: userId)
        XCTAssertNil(try store.load(userId: userId))
        XCTAssertThrowsError(try AccountKeyRingCoding.decode(Data([1, 0]), userId: userId))
        XCTAssertThrowsError(try AccountKeyRingCoding.decode(AccountKeyRingCoding.encode(rotated.ring).dropLast(), userId: userId))
    }

    #if canImport(Security)
    func testKeychainStoreRoundTrip() throws {
        // A throwaway service so the real item is never touched.
        let store = KeychainAccountKeyStore(service: "app.matilde.local.tests.\(UUID().uuidString)")
        let ring = try SyncKeyEnrollment.create(userId: userId).ring
        do {
            try store.save(ring)
        } catch SyncCryptoError.keyStore(let status) {
            throw XCTSkip("Keychain unavailable in this environment (\(status))")
        }
        defer { try? store.remove(userId: userId) }
        XCTAssertEqual(try store.load(userId: userId), ring)
        let rotated = try SyncKeyEnrollment.rotate(ring: ring).ring
        try store.save(rotated)
        XCTAssertEqual(try store.load(userId: userId), rotated)
        try store.remove(userId: userId)
        XCTAssertNil(try store.load(userId: userId))
    }
    #endif
}
