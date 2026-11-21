import XCTest
@testable import MatildeKit
import MatildeKitTesting

/// SYNC-02: HLCs, ids, canonical fields and the portable record format.
final class SyncRecordTests: XCTestCase {
    private let device = "6f1c2d3e-4a5b-4c6d-8e7f-0a1b2c3d4e5f"
    private let other = "00000000-0000-4000-8000-000000000001"

    func testHLCFormatMatchesTheServerAndStringOrderIsClockOrder() throws {
        let hlc = HLC(milliseconds: 1_763_500_000_000, counter: 42, device: device)
        XCTAssertEqual(hlc.description, "1763500000000.00042.\(device)")
        XCTAssertEqual(HLC(hlc.description), hlc)
        let pattern = #"^\d{13}\.\d{5}\.[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#
        XCTAssertNotNil(hlc.description.range(of: pattern, options: .regularExpression))
        let small = HLC(milliseconds: 5, counter: 0, device: device)
        XCTAssertEqual(small.description, "0000000000005.00000.\(device)")
        let values = [hlc, small, HLC(milliseconds: 5, counter: 1, device: other), HLC(milliseconds: 1_763_500_000_000, counter: 41, device: other)]
        XCTAssertEqual(values.sorted().map(\.description), values.map(\.description).sorted())
        for bad in ["", "1763500000000.00042", "1763500000000.42.\(device)", "176350000000.00042.\(device)",
                    "1763500000000.00042.\(device.uppercased())", "1763500000000.0004a.\(device)", "+763500000000.00042.\(device)"] {
            XCTAssertNil(HLC(bad), bad)
        }
    }

    func testClockNeverGoesBackwardsAndFoldsInRemoteClocks() {
        var clock = HybridClock(device: device)
        let first = clock.next(now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(first, HLC(milliseconds: 1_000_000, counter: 0, device: device))
        let sameMillisecond = clock.next(now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(sameMillisecond.counter, 1)
        let wallClockWentBack = clock.next(now: Date(timeIntervalSince1970: 10))
        XCTAssertGreaterThan(wallClockWentBack, sameMillisecond)
        XCTAssertEqual(wallClockWentBack.milliseconds, 1_000_000)

        clock.observe(HLC(milliseconds: 2_000_000, counter: 7, device: other))
        let afterRemote = clock.next(now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(afterRemote, HLC(milliseconds: 2_000_000, counter: 8, device: device))

        var full = HybridClock(device: device, last: HLC(milliseconds: 3, counter: HLC.maxCounter, device: device))
        XCTAssertEqual(full.next(now: Date(timeIntervalSince1970: 0)), HLC(milliseconds: 4, counter: 0, device: device))
    }

    func testDerivedIdsAreDeterministicVersion5UUIDs() {
        // Same vectors as Python's uuid.uuid5(namespace, name).
        XCTAssertEqual(SyncID.derived("body", "5f0c6c38-7d1e-4a43-9d39-6a0f1b2c3d4e"), "93e2bd5a-c975-5478-92ee-ac19b2641cda")
        XCTAssertEqual(SyncID.derived("folder", "Briefe/\u{00DC}ber"), "efd1203b-cbff-53d0-a088-39680e4b99ed")
        // Decomposed and precomposed spellings of a path get the same id.
        XCTAssertEqual(SyncID.derived("folder", "Briefe/U\u{0308}ber"), "efd1203b-cbff-53d0-a088-39680e4b99ed")
        XCTAssertNotEqual(SyncID.derived("stash", "x"), SyncID.derived("body", "x"))
        XCTAssertTrue(SyncID.isCanonical(SyncID.derived("asset", ".assets/a.png")))
    }

    func testExistingUppercaseIdsBecomeLowercaseRecordIds() {
        let id = UUID()
        XCTAssertEqual(SyncID.canonical(id.uuidString), id.uuidString.lowercased())
        XCTAssertTrue(SyncID.isCanonical(id.uuidString.lowercased()))
        XCTAssertFalse(SyncID.isCanonical(id.uuidString))
        XCTAssertNil(SyncID.canonical("welcome"))
    }

    func testFieldsAreCanonicalWhateverTheirOrder() throws {
        let a = JSONValue.object(["b": .number(1), "a": .string("x/y"), "c": .array([.bool(true), .null])])
        let b = JSONValue.object(["c": .array([.bool(true), .null]), "a": .string("x/y"), "b": .number(1)])
        XCTAssertEqual(try a.canonicalData(), try b.canonicalData())
        XCTAssertEqual(String(decoding: try a.canonicalData(), as: UTF8.self), #"{"a":"x/y","b":1,"c":[true,null]}"#)
        XCTAssertEqual(try a.digest(), try b.digest())
        XCTAssertNotEqual(try a.digest(), try JSONValue.object(["b": .number(2)]).digest())
    }

    func testPayloadsRoundTripThroughFields() throws {
        let comment = CommentPayload(draft: device, body: "Warmer? ✨", location: 3, length: 5, quote: "Hello", prefix: "", suffix: " world",
                                     created: 1_700_000_000_000, modified: 1_700_000_000_500, archived: false)
        let fields = try JSONValue.fields(of: comment)
        XCTAssertEqual(fields["location"], .number(3))
        XCTAssertEqual(fields["archived"], .bool(false))
        XCTAssertEqual(try JSONValue.decode(CommentPayload.self, from: fields), comment)
        let draft = DraftPayload(path: "Letters/Hi.md", family: device, parent: nil, goal: "", created: nil)
        XCTAssertNil(try JSONValue.fields(of: draft)["parent"], "nil fields are omitted")
    }

    func testRecordPlaintextRoundTripsAndTombstonesCarryNone() throws {
        let hlc = HLC(milliseconds: 1_763_500_000_000, counter: 1, device: device)
        let fields = try JSONValue.fields(of: BodyPayload(draft: other, text: "# Title\n\nBody", edited: 1_763_500_000_000))
        let record = SyncRecord(id: SyncID.derived("body", other), type: .body, hlc: hlc, baseHlc: nil, deleted: false,
                                fields: fields, fieldHLCs: Dictionary(uniqueKeysWithValues: fields.keys.map { ($0, hlc) }))
        let plaintext = try XCTUnwrap(record.plaintext())
        let decoded = try SyncRecord.decode(id: record.id, type: .body, hlc: hlc, deleted: false, plaintext: plaintext)
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(try decoded.payload(BodyPayload.self).text, "# Title\n\nBody")
        XCTAssertEqual(try record.plaintext(), plaintext, "encoding is deterministic")

        let tombstone = SyncRecord(id: record.id, type: .body, hlc: hlc, baseHlc: hlc, deleted: true, fields: [:], fieldHLCs: [:])
        XCTAssertNil(try tombstone.plaintext())
        XCTAssertEqual(try SyncRecord.decode(id: record.id, type: .body, hlc: hlc, deleted: true, plaintext: nil), tombstone.with(baseHlc: nil))

        let future = try JSONValue.canonicalEncoder().encode(SyncPlaintext(v: SyncRecord.schemaVersion + 1, fields: [:], fieldHlcs: [:]))
        XCTAssertThrowsError(try SyncRecord.decode(id: record.id, type: .body, hlc: hlc, deleted: false, plaintext: future)) {
            XCTAssertEqual($0 as? SyncModelError, .unsupportedSchema(SyncRecord.schemaVersion + 1))
        }
        XCTAssertThrowsError(try SyncRecord.decode(id: record.id, type: .body, hlc: hlc, deleted: false, plaintext: nil))
    }

    func testEnvelopeMatchesThePushShape() throws {
        let hlc = HLC(milliseconds: 1_763_500_000_000, counter: 2, device: device)
        let base = HLC(milliseconds: 1_763_400_000_000, counter: 0, device: other)
        let body = SyncRecord(id: SyncID.derived("body", other), type: .body, hlc: hlc, baseHlc: base, deleted: false, fields: [:], fieldHLCs: [:])
        XCTAssertEqual(body.envelope, SyncEnvelope(id: body.id, type: 2, hlc: hlc.description, baseHlc: base.description, deleted: false))
        let comment = SyncRecord(id: other, type: .comment, hlc: hlc, baseHlc: base, deleted: true, fields: [:], fieldHLCs: [:])
        XCTAssertNil(comment.envelope.baseHlc, "only compare-and-swap types send baseHlc")
        XCTAssertEqual(comment.deviceID, device)
        XCTAssertEqual(SyncRecordType.allCases.map(\.rawValue), Array(1...12))
        XCTAssertEqual(SyncRecordType.allCases.filter(\.usesCompareAndSwap), [.body, .stash])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body.envelope)) as? [String: Any]
        XCTAssertEqual(Set(json?.keys.map { $0 } ?? []), ["id", "type", "hlc", "baseHlc", "deleted"])
    }
}

private extension SyncRecord {
    func with(baseHlc: HLC?) -> SyncRecord { var copy = self; copy.baseHlc = baseHlc; return copy }
}
