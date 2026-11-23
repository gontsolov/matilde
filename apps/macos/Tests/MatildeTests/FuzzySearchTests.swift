import XCTest
@testable import Matilde

final class FuzzySearchTests: XCTestCase {
    private func score(_ query: String, _ candidate: String) -> Int? { FuzzySearch.match(query, in: candidate)?.score }

    private func ranking(_ query: String, _ candidates: [String]) -> [String] {
        candidates.compactMap { candidate in FuzzySearch.match(query, in: candidate).map { (candidate, $0.score) } }
            .sorted { $0.1 > $1.1 }.map(\.0)
    }

    func testEmptyQueryAndMissingCharactersDoNotMatch() {
        XCTAssertNil(FuzzySearch.match("", in: "New Document"))
        XCTAssertNil(FuzzySearch.match("   ", in: "New Document"))
        XCTAssertNil(FuzzySearch.match("xyz", in: "New Document"))
        XCTAssertNil(FuzzySearch.match("documents", in: "Document"), "Longer than the candidate")
        XCTAssertNil(FuzzySearch.match("tn", in: "Note"), "Characters must appear in order")
    }

    func testIgnoresCaseAndDiacritics() {
        XCTAssertNotNil(FuzzySearch.match("CAFE", in: "Café au lait"))
        XCTAssertNotNil(FuzzySearch.match("über", in: "Uber notes"))
        XCTAssertEqual(FuzzySearch.match("cafe", in: "Café")?.positions, [0, 1, 2, 3])
    }

    func testTiersExactPrefixWordStartAcronymSubstringScattered() {
        let exact = score("rename", "Rename")!
        let prefix = score("rena", "Rename Document")!
        let wordStart = score("doc", "Rename Document")!
        let acronym = score("nd", "New Document")!
        let substring = score("nd", "Window")!
        let scattered = score("trsh", "Move to Trash")!
        XCTAssertGreaterThan(exact, prefix)
        XCTAssertGreaterThan(prefix, wordStart)
        XCTAssertGreaterThan(wordStart, acronym)
        XCTAssertGreaterThan(acronym, substring)
        XCTAssertGreaterThan(substring, scattered)
    }

    func testRanksTypicalPaletteQueries() {
        let commands = ["New Document", "New Folder…", "Rename Document…", "Move to Trash", "Show in Finder", "Next Note", "Settings…"]
        XCTAssertEqual(Set(ranking("new", commands).prefix(2)), ["New Document", "New Folder…"])
        XCTAssertEqual(ranking("nd", commands).first, "New Document")
        XCTAssertEqual(ranking("doc", commands).first, "New Document")
        XCTAssertEqual(ranking("trash", commands), ["Move to Trash"])
        XCTAssertEqual(ranking("set", commands).first, "Settings…")
        XCTAssertEqual(ranking("nn", commands).first, "Next Note")
    }

    func testShorterCandidateWinsATie() {
        XCTAssertGreaterThan(score("save", "Save")!, score("save", "Save a Copy")!)
        XCTAssertGreaterThan(score("note", "Notes")!, score("note", "Notes from the long meeting in spring")!)
    }

    func testEveryWordMustMatchInAnyOrder() {
        XCTAssertNotNil(FuzzySearch.match("move trash", in: "Move to Trash"))
        XCTAssertNotNil(FuzzySearch.match("trash move", in: "Move to Trash"))
        XCTAssertNil(FuzzySearch.match("move folder", in: "Move to Trash"))
    }

    func testPositionsHighlightTheBestOccurrence() {
        XCTAssertEqual(FuzzySearch.match("doc", in: "New Document")?.positions, [4, 5, 6])
        // A word start beats an earlier mid-word occurrence.
        XCTAssertEqual(FuzzySearch.match("art", in: "Start Article")?.positions, [6, 7, 8])
        XCTAssertEqual(FuzzySearch.match("nd", in: "New Document")?.positions, [0, 4])
        XCTAssertEqual(FuzzySearch.match("move trash", in: "Move to Trash")?.positions, [0, 1, 2, 3, 8, 9, 10, 11, 12])
    }

    func testScatteredMatchesPreferConsecutiveLetters() {
        // "ltr": "Letter" (l…tt…r) against "Long trip": consecutive "tr" at a word start wins.
        XCTAssertGreaterThan(score("ltr", "Long trip")!, score("ltr", "Lantern")!)
    }

    func testHandlesEmojiAndLongCandidates() {
        XCTAssertNotNil(FuzzySearch.match("plan", in: "🌱 Garden plan"))
        let long = String(repeating: "a", count: 2000) + " target"
        XCTAssertNotNil(FuzzySearch.match("target", in: long), "Contiguous matches work at any length")
        XCTAssertNil(FuzzySearch.match("tgt", in: long), "Scattered matching is skipped for very long text")
    }
}
