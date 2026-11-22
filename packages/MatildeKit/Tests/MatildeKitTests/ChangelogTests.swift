import XCTest
@testable import MatildeKit

final class ChangelogTests: XCTestCase {
    private let sample = """
    ---
    version: 1.2.3
    covers: 1.2.0 to 1.2.3
    date: 2026-12-01
    title: A small thing
    matilde: Hello there.
    ---

    A short intro
    over two lines.

    - **One** thing.
    - Another
      that wraps.

    A closing line.
    """

    /// changelog/ at the repo root, from this file's path.
    private var repoChangelog: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("changelog")
    }

    func testParsesFrontMatterAndBlocks() throws {
        let entry = try XCTUnwrap(Changelog.parse(sample))
        XCTAssertEqual(entry.version, "1.2.3")
        XCTAssertEqual(entry.versionLabel, "1.2.0 to 1.2.3")
        XCTAssertEqual(entry.versionTitle, "Versions 1.2.0 to 1.2.3")
        XCTAssertEqual(entry.title, "A small thing")
        XCTAssertEqual(entry.matilde, "Hello there.")
        XCTAssertEqual(Changelog.dateText(entry.date), "1 December 2026")
        XCTAssertEqual(Changelog.shortDateText(entry.date), "1 Dec 2026")
        XCTAssertEqual(entry.blocks, [
            .paragraph("A short intro over two lines."),
            .bullets(["**One** thing.", "Another that wraps."]),
            .paragraph("A closing line.")
        ])
    }

    func testRejectsBrokenEntries() {
        XCTAssertNil(Changelog.parse("No front matter"))
        XCTAssertNil(Changelog.parse(sample.replacingOccurrences(of: "version: 1.2.3", with: "version: 1.2")))
        XCTAssertNil(Changelog.parse(sample.replacingOccurrences(of: "2026-12-01", with: "2026-13-01")))
        XCTAssertNil(Changelog.parse(sample.replacingOccurrences(of: "title: A small thing\n", with: "")))
    }

    func testVersionOrder() {
        XCTAssertTrue(Changelog.isNewer("0.10.0", than: "0.9.9"))
        XCTAssertTrue(Changelog.isNewer("0.3.4", than: "0.3.3"))
        XCTAssertFalse(Changelog.isNewer("0.3.3", than: "0.3.3"))
        XCTAssertFalse(Changelog.isNewer("0.3.2", than: "0.3.3"))
        XCTAssertFalse(Changelog.isNewer("dev", than: "0.3.3"))
    }

    func testAnnouncesOnceAfterAnUpdateOnly() {
        let entries = [ChangelogEntry(version: "0.4.0", date: Date(), title: "New", blocks: [.paragraph("Hi")])]
        // Updated from a version that predates What's New: earlier launches, nothing recorded.
        XCTAssertEqual(Changelog.entryToAnnounce(current: "0.4.0", lastSeen: nil, launchedBefore: true, entries: entries)?.version, "0.4.0")
        // Fresh install.
        XCTAssertNil(Changelog.entryToAnnounce(current: "0.4.0", lastSeen: nil, launchedBefore: false, entries: entries))
        // Updated since the last launch.
        XCTAssertEqual(Changelog.entryToAnnounce(current: "0.4.0", lastSeen: "0.3.3", launchedBefore: true, entries: entries)?.version, "0.4.0")
        // Already seen, or went back to an older version.
        XCTAssertNil(Changelog.entryToAnnounce(current: "0.4.0", lastSeen: "0.4.0", launchedBefore: true, entries: entries))
        XCTAssertNil(Changelog.entryToAnnounce(current: "0.3.3", lastSeen: "0.4.0", launchedBefore: true, entries: entries))
        // No entry for this build (a development build).
        XCTAssertNil(Changelog.entryToAnnounce(current: "0.4.1", lastSeen: "0.4.0", launchedBefore: true, entries: entries))
    }

    func testEveryCommittedEntryParses() throws {
        let files = try FileManager.default.contentsOfDirectory(at: repoChangelog, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" && Changelog.parseVersion($0.deletingPathExtension().lastPathComponent) != nil }
        let entries = Changelog.load(from: repoChangelog)
        XCTAssertFalse(entries.isEmpty)
        XCTAssertEqual(entries.count, files.count, "every changelog/<version>.md must parse")
        XCTAssertEqual(entries.map(\.version), entries.map(\.version).sorted { Changelog.isNewer($0, than: $1) })
    }
}
