import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import Matilde

final class SyncCryptoTests: XCTestCase {
    private let userId = "6f1c2d3e-4a5b-4c6d-8e7f-90a1b2c3d4e5"
    private let otherUser = "7a2d3e4f-5b6c-4d7e-9f80-a1b2c3d4e5f6"
    private let recordId = "a1b2c3d4-e5f6-4a07-8b18-c29d3e4f5a60"
    private let hlc = "1763500000000.00042.0b3c1d2e-3f40-4a51-8b62-7c83d94ea5f6"

    private func ring(_ id: Int = 1) throws -> AccountKeyRing {
        try AccountKeyRing(userId: userId, current: AccountKey.generate(id: id))
    }

    private func context(type: Int = 2, hlc: String? = nil, recordId: String? = nil, userId: String? = nil, deleted: Bool = false) -> SyncRecordContext {
        SyncRecordContext(userId: userId ?? self.userId, recordId: recordId ?? self.recordId, type: type, hlc: hlc ?? self.hlc, deleted: deleted)
    }

    // MARK: Records

    func testRecordRoundTrip() throws {
        let ring = try ring()
        for text in ["", "a", "# Letter\n\nDear Anna, ünïcødé ✍️", String(repeating: "word ", count: 20_000)] {
            let envelope = try SyncRecordCrypto.seal(Data(text.utf8), context: context(), key: ring.current)
            XCTAssertEqual(envelope.first, 1)
            XCTAssertEqual(try SyncRecordCrypto.keyId(of: envelope), 1)
            let opened = try SyncRecordCrypto.open(envelope, context: context(), keyId: 1, ring: ring)
            XCTAssertEqual(String(data: opened, encoding: .utf8), text)
        }
    }

    func testRecordJSONRoundTrip() throws {
        struct Draft: Codable, Equatable { var title: String; var goal: String? }
        let ring = try ring()
        let draft = Draft(title: "Letter", goal: "Say thanks")
        let envelope = try SyncRecordCrypto.seal(json: draft, context: context(type: 1), key: ring.current)
        XCTAssertEqual(try SyncRecordCrypto.open(json: Draft.self, envelope, context: context(type: 1), keyId: 1, ring: ring), draft)
    }

    func testSealingTwiceGivesDifferentCiphertext() throws {
        let ring = try ring()
        let a = try SyncRecordCrypto.seal(Data("same".utf8), context: context(), key: ring.current)
        let b = try SyncRecordCrypto.seal(Data("same".utf8), context: context(), key: ring.current)
        XCTAssertNotEqual(a, b)
    }

    func testCiphertextHidesPlaintext() throws {
        let ring = try ring()
        let secret = "This sentence must never reach the server in clear."
        let envelope = try SyncRecordCrypto.seal(Data(secret.utf8), context: context(), key: ring.current)
        XCTAssertNil(envelope.range(of: Data("sentence".utf8)))
    }

    func testEveryTamperedByteIsDetected() throws {
        let ring = try ring()
        let envelope = try SyncRecordCrypto.seal(Data("tamper".utf8), context: context(), key: ring.current)
        for index in 0..<envelope.count {
            var tampered = envelope
            tampered[index] ^= 0x01
            XCTAssertThrowsError(try SyncRecordCrypto.open(tampered, context: context(), keyId: 1, ring: ring), "byte \(index)")
        }
    }

    func testTruncatedAndExtendedEnvelopesFail() throws {
        let ring = try ring()
        let envelope = try SyncRecordCrypto.seal(Data("short".utf8), context: context(), key: ring.current)
        XCTAssertThrowsError(try SyncRecordCrypto.open(envelope.dropLast(), context: context(), keyId: 1, ring: ring))
        XCTAssertThrowsError(try SyncRecordCrypto.open(envelope + Data([0]), context: context(), keyId: 1, ring: ring))
        XCTAssertThrowsError(try SyncRecordCrypto.open(Data(envelope.prefix(20)), context: context(), keyId: 1, ring: ring)) {
            XCTAssertEqual($0 as? SyncCryptoError, .malformed)
        }
        XCTAssertThrowsError(try SyncRecordCrypto.open(Data(), context: context(), keyId: 1, ring: ring))
    }

    func testCiphertextIsBoundToItsEnvelope() throws {
        let ring = try ring()
        let envelope = try SyncRecordCrypto.seal(Data("bound".utf8), context: context(), key: ring.current)
        let moved: [SyncRecordContext] = [
            context(type: 4),
            context(hlc: "1763500000001.00042.0b3c1d2e-3f40-4a51-8b62-7c83d94ea5f6"),
            context(recordId: "b2c3d4e5-f6a7-4b18-8c29-d3e4f5a6b701"),
            context(deleted: true),
        ]
        for other in moved {
            XCTAssertThrowsError(try SyncRecordCrypto.open(envelope, context: other, keyId: 1, ring: ring)) {
                XCTAssertEqual($0 as? SyncCryptoError, .authenticationFailed)
            }
        }
    }

    func testCiphertextCannotMoveToAnotherAccount() throws {
        let key = try AccountKey.generate()
        let mine = try AccountKeyRing(userId: userId, current: key)
        let theirs = try AccountKeyRing(userId: otherUser, current: key)
        let envelope = try SyncRecordCrypto.seal(Data("mine".utf8), context: context(), key: key)
        XCTAssertThrowsError(try SyncRecordCrypto.open(envelope, context: context(userId: otherUser), keyId: 1, ring: theirs))
        XCTAssertNoThrow(try SyncRecordCrypto.open(envelope, context: context(), keyId: 1, ring: mine))
    }

    func testWrongKeyFails() throws {
        let envelope = try SyncRecordCrypto.seal(Data("secret".utf8), context: context(), key: ring().current)
        XCTAssertThrowsError(try SyncRecordCrypto.open(envelope, context: context(), keyId: 1, ring: ring())) {
            XCTAssertEqual($0 as? SyncCryptoError, .authenticationFailed)
        }
    }

    func testKeyIdMustMatchEnvelopeAndRing() throws {
        let ring = try ring(3)
        let envelope = try SyncRecordCrypto.seal(Data("x".utf8), context: context(), key: ring.current)
        XCTAssertThrowsError(try SyncRecordCrypto.open(envelope, context: context(), keyId: 2, ring: ring)) {
            XCTAssertEqual($0 as? SyncCryptoError, .keyIdMismatch)
        }
        let other = try AccountKeyRing(userId: userId, current: AccountKey.generate(id: 4))
        XCTAssertThrowsError(try SyncRecordCrypto.open(envelope, context: context(), keyId: 3, ring: other)) {
            XCTAssertEqual($0 as? SyncCryptoError, .unknownKey(3))
        }
    }

    func testUnsupportedVersionIsReported() throws {
        let ring = try ring()
        var envelope = try SyncRecordCrypto.seal(Data("x".utf8), context: context(), key: ring.current)
        envelope[0] = 2
        XCTAssertThrowsError(try SyncRecordCrypto.open(envelope, context: context(), keyId: 1, ring: ring)) {
            XCTAssertEqual($0 as? SyncCryptoError, .unsupportedVersion(2))
        }
    }

    func testInvalidContextsAreRejected() throws {
        let key = try AccountKey.generate()
        XCTAssertThrowsError(try SyncRecordCrypto.seal(Data(), context: context(recordId: recordId.uppercased()), key: key))
        XCTAssertThrowsError(try SyncRecordCrypto.seal(Data(), context: context(type: 0), key: key))
        XCTAssertThrowsError(try SyncRecordCrypto.seal(Data(), context: context(type: 64), key: key))
        XCTAssertThrowsError(try SyncRecordCrypto.seal(Data(), context: context(hlc: ""), key: key))
        XCTAssertThrowsError(try SyncRecordCrypto.seal(Data(), context: context(userId: "not-a-uuid"), key: key))
        XCTAssertThrowsError(try AccountKey(id: 0, key: SymmetricKey(size: .bits256)))
        XCTAssertThrowsError(try AccountKey(id: 0x10000, key: SymmetricKey(size: .bits256)))
        XCTAssertThrowsError(try AccountKey(id: 1, key: SymmetricKey(size: .bits128)))
        XCTAssertThrowsError(try AccountKeyRing(userId: userId.uppercased(), current: key))
    }

    func testEnvelopeSizeLeaksOnlyThePaddingBucket() throws {
        let ring = try ring()
        let a = try SyncRecordCrypto.seal(Data(count: 1000), context: context(), key: ring.current)
        let b = try SyncRecordCrypto.seal(Data(count: 1010), context: context(), key: ring.current)
        XCTAssertEqual(a.count, b.count)
        XCTAssertEqual(a.count, SyncRecordCrypto.headerSize + 1024 + 16)
    }

    // MARK: Padding

    func testPaddingRoundTripAndBuckets() throws {
        for length in [0, 1, 31, 32, 33, 100, 255, 256, 1000, 4096, 65_535, 1_000_000] {
            let data = Data(repeating: 0x00, count: length)
            let padded = SyncPadding.pad(data)
            XCTAssertEqual(padded.count, SyncPadding.paddedLength(for: length))
            XCTAssertGreaterThan(padded.count, length)
            // Padmé overhead is at most about 12% above the minimum bucket.
            XCTAssertLessThanOrEqual(Double(padded.count), max(32, Double(length + 1) * 1.12))
            XCTAssertEqual(try SyncPadding.unpad(padded), data)
        }
        XCTAssertThrowsError(try SyncPadding.unpad(Data(count: 32)))
        XCTAssertThrowsError(try SyncPadding.unpad(Data()))
        XCTAssertThrowsError(try SyncPadding.unpad(Data([0x41, 0x81, 0x00])))
    }

    // MARK: Key ring and rotation

    func testRekeyMovesRecordToNewEpoch() throws {
        let first = try SyncKeyEnrollment.create(userId: userId)
        let envelope = try SyncRecordCrypto.seal(Data("old".utf8), context: context(), key: first.ring.current)
        let rotated = try SyncKeyEnrollment.rotate(ring: first.ring)
        XCTAssertEqual(rotated.ring.current.id, 2)
        XCTAssertEqual(rotated.ring.previous.map(\.id), [1])
        // Old records still open with the rotated ring.
        XCTAssertEqual(try SyncRecordCrypto.open(envelope, context: context(), keyId: 1, ring: rotated.ring), Data("old".utf8))
        let rekeyed = try SyncRecordCrypto.rekey(envelope, context: context(), keyId: 1, ring: rotated.ring)
        XCTAssertEqual(try SyncRecordCrypto.keyId(of: rekeyed), 2)
        let current = try rotated.ring.dropping(previousKeyIds: [1])
        XCTAssertEqual(try SyncRecordCrypto.open(rekeyed, context: context(), keyId: 2, ring: current), Data("old".utf8))
        XCTAssertThrowsError(try SyncRecordCrypto.open(envelope, context: context(), keyId: 1, ring: current)) {
            XCTAssertEqual($0 as? SyncCryptoError, .unknownKey(1))
        }
    }

    func testRingRejectsInconsistentEpochs() throws {
        let one = try AccountKey.generate(id: 1)
        let two = try AccountKey.generate(id: 2)
        XCTAssertThrowsError(try AccountKeyRing(userId: userId, current: one, previous: [two]))
        XCTAssertThrowsError(try AccountKeyRing(userId: userId, current: two, previous: [one, one]))
        XCTAssertEqual(try AccountKeyRing(userId: userId, current: two, previous: [one]).key(id: 1), one)
    }

    func testKeyCheck() throws {
        let key = try AccountKey.generate(id: 1)
        XCTAssertEqual(key.check.count, 32)
        XCTAssertTrue(key.verify(check: key.check))
        XCTAssertFalse(try AccountKey.generate(id: 1).verify(check: key.check))
        XCTAssertFalse(try AccountKey(id: 2, key: key.key).verify(check: key.check))
    }

    // MARK: Fields

    func testDeviceNameRoundTripAndBinding() throws {
        let ring = try ring()
        let device = "0b3c1d2e-3f40-4a51-8b62-7c83d94ea5f6"
        let sealed = try SyncFieldCrypto.sealDeviceName("Anna's MacBook", deviceId: device, ring: ring)
        XCTAssertEqual(try SyncFieldCrypto.openDeviceName(sealed, deviceId: device, ring: ring), "Anna's MacBook")
        XCTAssertThrowsError(try SyncFieldCrypto.openDeviceName(sealed, deviceId: "1c4d2e3f-4051-4b62-8c73-8d94ea5fb607", ring: ring))
        XCTAssertThrowsError(try SyncFieldCrypto.open(sealed, purpose: "other", subject: device, ring: ring))
        XCTAssertNil(sealed.range(of: Data("MacBook".utf8)))
        // A record envelope can't be passed off as a field and vice versa.
        XCTAssertThrowsError(try SyncRecordCrypto.open(sealed, context: context(), keyId: 1, ring: ring))
    }

    // MARK: Blobs

    func testBlobRoundTripAcrossChunkBoundaries() throws {
        let key = SyncBlobKey.generate()
        let blobId = "17a8b9c0-d1e2-4f3a-8b4c-5d6e7f8a9b02"
        for size in [0, 1, 1022, 1023, 1024, 1025, 4096, 10_000] {
            let data = SyncBytes.random(size)
            let sealed = try SyncBlobCrypto.seal(data, blobId: blobId, key: key, chunkSize: 1024)
            XCTAssertEqual(try SyncBlobCrypto.open(sealed, blobId: blobId, key: key), data, "size \(size)")
        }
        let big = SyncBytes.random(200_000)
        XCTAssertEqual(try SyncBlobCrypto.open(SyncBlobCrypto.seal(big, blobId: blobId, key: key), blobId: blobId, key: key), big)
    }

    func testBlobTamperReorderTruncateAndWrongKeyFail() throws {
        let key = SyncBlobKey.generate()
        let blobId = "17a8b9c0-d1e2-4f3a-8b4c-5d6e7f8a9b02"
        let sealed = try SyncBlobCrypto.seal(SyncBytes.random(3000), blobId: blobId, key: key, chunkSize: 1024)
        let header = SyncBlobCrypto.headerSize
        let chunk = 1024 + 16
        // Flipped byte anywhere.
        for index in stride(from: 0, to: sealed.count, by: 97) {
            var tampered = sealed
            tampered[index] ^= 0x40
            XCTAssertThrowsError(try SyncBlobCrypto.open(tampered, blobId: blobId, key: key), "byte \(index)")
        }
        // Swapped chunks.
        var swapped = Data(sealed.prefix(header))
        swapped.append(sealed[(header + chunk)..<(header + 2 * chunk)])
        swapped.append(sealed[header..<(header + chunk)])
        swapped.append(sealed[(header + 2 * chunk)...])
        XCTAssertThrowsError(try SyncBlobCrypto.open(swapped, blobId: blobId, key: key))
        // Final chunk dropped (truncation at a chunk boundary).
        XCTAssertThrowsError(try SyncBlobCrypto.open(Data(sealed.prefix(header + 2 * chunk)), blobId: blobId, key: key))
        XCTAssertThrowsError(try SyncBlobCrypto.open(sealed, blobId: blobId, key: .generate()))
        XCTAssertThrowsError(try SyncBlobCrypto.open(sealed, blobId: "28b9c0d1-e2f3-4a4b-9c5d-6e7f8a9b0c13", key: key))
        XCTAssertThrowsError(try SyncBlobCrypto.open(Data(sealed.prefix(header)), blobId: blobId, key: key))
    }

    func testBlobKeyCodableAndRedacted() throws {
        struct Asset: Codable { var blobKey: SyncBlobKey }
        let key = SyncBlobKey.generate()
        let json = try JSONEncoder().encode(Asset(blobKey: key))
        XCTAssertEqual(try JSONDecoder().decode(Asset.self, from: json).blobKey, key)
        XCTAssertFalse(String(describing: key).contains(key.key.syncBytes.base64EncodedString()))
    }

    // MARK: Redaction

    func testKeysNeverAppearInDescriptions() throws {
        let key = try AccountKey.generate()
        let ring = try AccountKeyRing(userId: userId, current: key)
        let recovery = SyncRecoveryKey.generate()
        let secrets = [key.key.syncBytes, recovery.key.syncBytes].flatMap { bytes in
            [bytes.base64EncodedString(), bytes.map { String(format: "%02x", $0) }.joined()]
        } + [recovery.code]
        var dumped = ""
        dump(key, to: &dumped)
        dump(ring, to: &dumped)
        dump(recovery, to: &dumped)
        let texts = [String(describing: key), String(reflecting: key), String(describing: ring), String(reflecting: ring),
                     String(describing: recovery), String(reflecting: recovery), "\(key) \(ring) \(recovery)", dumped]
        for text in texts {
            XCTAssertTrue(text.contains("redacted") || text.contains("current") || text.contains("id"), text)
            for secret in secrets { XCTAssertFalse(text.contains(secret)) }
        }
    }
}
