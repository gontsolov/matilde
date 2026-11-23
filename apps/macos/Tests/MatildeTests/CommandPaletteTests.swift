import XCTest
import AppKit
@testable import Matilde

final class CommandPaletteTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func note(_ id: String, _ title: String, family: String? = nil, root: Bool = true, folder: String = "",
                      age: TimeInterval = 0, active: Bool = false, body: String? = nil) -> PaletteNote {
        PaletteNote(id: id, family: family ?? id, title: title, folder: folder, isRoot: root,
                    edited: now.addingTimeInterval(-age), isActive: active, body: body)
    }

    private let entries: [PaletteEntry] = [
        PaletteEntry(id: "new-document", title: "New Document", keywords: "note create", icon: .newDocument, shortcut: "⌘N"),
        PaletteEntry(id: "rename", title: "Rename Document…", keywords: "title name", icon: .activeDraft),
        PaletteEntry(id: "trash", title: "Move to Trash", keywords: "delete remove", icon: .trash, destructive: true),
        PaletteEntry(id: "focus-mode", title: "Enter Focus Mode", keywords: "toggle sidebar hide", icon: .sidebar, shortcut: "⌘\\"),
        PaletteEntry(id: "settings", title: "Settings…", keywords: "preferences", icon: .settings, section: .settings, shortcut: "⌘,"),
    ] + SettingsDestination.all.map(\.entry)

    private func titles(_ groups: [PaletteGroup], _ section: PaletteSection) -> [String] {
        groups.first { $0.section == section }?.items.map(\.title) ?? []
    }

    func testEmptyQueryShowsRecentNotesNewestFirstThenSuggestions() {
        let notes = [
            note("a", "Old letter", age: 300),
            note("b", "Current essay", age: 0, active: true),
            note("c", "Fresh idea", age: 10),
            note("c2", "Fresh idea — Alternative 2", family: "c", root: false, age: 5),
        ]
        let groups = PaletteSearch.results(query: "  ", notes: notes, entries: entries, suggested: ["new-document", "missing", "settings"])
        XCTAssertEqual(groups.map(\.section), [.recent, .actions])
        XCTAssertEqual(titles(groups, .recent), ["Fresh idea", "Old letter"], "One row per note, by its main draft; the open note is left out")
        XCTAssertEqual(groups[0].items.first?.target, .family("c"))
        XCTAssertEqual(titles(groups, .actions), ["New Document", "Settings…"], "Unknown suggestions are skipped")
    }

    func testRecentNotesAreLimited() {
        let notes = (0..<20).map { note("n\($0)", "Note \($0)", age: TimeInterval($0)) }
        let recent = PaletteSearch.results(query: "", notes: notes, entries: [], suggested: [])
        XCTAssertEqual(recent.first?.items.count, PaletteSearch.recentLimit)
        XCTAssertEqual(recent.first?.items.first?.title, "Note 0")
    }

    func testQueryGroupsNotesActionsAndSettings() {
        let notes = [note("a", "Rename ideas"), note("b", "Groceries")]
        let groups = PaletteSearch.results(query: "rename", notes: notes, entries: entries)
        XCTAssertEqual(titles(groups, .notes), ["Rename ideas"])
        XCTAssertEqual(titles(groups, .actions), ["Rename Document…"])
        XCTAssertTrue(titles(groups, .settings).isEmpty)
        XCTAssertFalse(groups.contains { $0.section == .recent })
    }

    func testGroupWithTheBestMatchLeads() {
        let notes = [note("a", "Plans for spring settings")]
        let groups = PaletteSearch.results(query: "settings", notes: notes, entries: entries)
        XCTAssertEqual(groups.first?.section, .settings, "“Settings…” is a prefix match; the note only matches mid-title")
        XCTAssertEqual(groups.first?.items.first?.title, "Settings…")
    }

    func testKeywordsFindCommandsBelowTitleMatches() {
        let groups = PaletteSearch.results(query: "delete", notes: [], entries: entries)
        XCTAssertEqual(titles(groups, .actions), ["Move to Trash"])
        XCTAssertEqual(groups.first?.items.first?.highlights, [], "Keyword hits do not highlight the title")
        let sidebar = PaletteSearch.results(query: "sidebar", notes: [], entries: entries)
        XCTAssertEqual(titles(sidebar, .actions), ["Enter Focus Mode"])
    }

    func testSettingsSectionsAreSearchable() {
        let groups = PaletteSearch.results(query: "spell", notes: [], entries: entries)
        XCTAssertEqual(titles(groups, .settings).first, "Spell Checking")
        XCTAssertEqual(groups.first { $0.section == .settings }?.items.first?.subtitle, "Settings › Writing")
        let font = PaletteSearch.results(query: "font", notes: [], entries: entries)
        XCTAssertEqual(titles(font, .settings).first, "Text Size")
        XCTAssertEqual(SettingsDestination.all.first { $0.id == "guidance" }?.tab, .askMatilde)
    }

    func testFindsNotesByTheirText() {
        let notes = [
            note("a", "Letter", body: "# Dear Ana\n\nThe harbour was quiet when the boats came in."),
            note("b", "Shopping", body: "- milk\n- bread"),
        ]
        let groups = PaletteSearch.results(query: "harbour", notes: notes, entries: entries)
        XCTAssertEqual(titles(groups, .notes), ["Letter"])
        let item = groups.first { $0.section == .notes }!.items[0]
        XCTAssertEqual(item.target, .draft("a"))
        XCTAssertEqual(item.subtitle, "The harbour was quiet when the boats came in.")
        XCTAssertNil(PaletteSearch.contentMatch("h", in: "harbour"), "Single characters only match titles")
    }

    func testTextMatchesIgnoreCaseAndDiacriticsAndNeedEveryWord() {
        XCTAssertNotNil(PaletteSearch.contentMatch("cafe noir", in: "A CAFÉ called Noir"))
        XCTAssertNil(PaletteSearch.contentMatch("cafe tea", in: "A café called Noir"))
        let phrase = PaletteSearch.contentMatch("called noir", in: "Noir, it was called noir")!
        let words = PaletteSearch.contentMatch("noir called", in: "Noir, it was called")!
        XCTAssertGreaterThan(phrase.score, words.score, "The exact phrase scores higher")
    }

    func testTitleMatchesOutrankTextMatches() {
        let notes = [
            note("a", "Garden", body: "Nothing about it"),
            note("b", "Weekend", body: "We worked in the garden all day"),
        ]
        let groups = PaletteSearch.results(query: "garden", notes: notes, entries: [])
        XCTAssertEqual(titles(groups, .notes), ["Garden", "Weekend"])
        XCTAssertEqual(groups[0].items[0].subtitle, nil, "A strong title match shows no snippet")
    }

    func testOneRowPerNoteUsingTheBestMatchingDraft() {
        let notes = [
            note("a", "Essay", folder: "School", body: "Draft one"),
            note("a2", "Essay — Alternative 2", family: "a", root: false, body: "A lighthouse appears"),
        ]
        let groups = PaletteSearch.results(query: "lighthouse", notes: notes, entries: [])
        XCTAssertEqual(groups.first?.items.map(\.target), [.draft("a2")])
        let titleQuery = PaletteSearch.results(query: "essay", notes: notes, entries: [])
        XCTAssertEqual(titleQuery.first?.items.count, 1)
        XCTAssertEqual(titleQuery.first?.items.first?.target, .draft("a"), "The shorter exact title wins")
        XCTAssertEqual(titleQuery.first?.items.first?.subtitle, "School")
    }

    func testNotesAndEntriesAreLimitedPerSection() {
        let notes = (0..<30).map { note("n\($0)", "Note \($0)") }
        let groups = PaletteSearch.results(query: "note", notes: notes, entries: [])
        XCTAssertEqual(groups.first?.items.count, PaletteSearch.sectionLimit)
    }

    func testSnippetTrimsMarkdownAndLongLines() {
        let body = "Intro\n- [ ] call the harbour master tomorrow\nEnd"
        let range = body.range(of: "harbour")!
        XCTAssertEqual(PaletteSearch.snippet(body, around: range), "call the harbour master tomorrow")
        let long = String(repeating: "word ", count: 40) + "needle" + String(repeating: " tail", count: 40)
        let snippet = PaletteSearch.snippet(long, around: long.range(of: "needle")!)
        XCTAssertTrue(snippet.hasPrefix("…") && snippet.hasSuffix("…"))
        XCTAssertTrue(snippet.contains("needle"))
        XCTAssertLessThanOrEqual(snippet.count, 84)
    }

    func testFlattenFollowsDisplayOrder() {
        let notes = [note("a", "Rename ideas")]
        let groups = PaletteSearch.results(query: "rename", notes: notes, entries: entries)
        XCTAssertEqual(PaletteSearch.flatten(groups).map(\.title), groups.flatMap { $0.items.map(\.title) })
    }

    func testLayoutGrowsWithResultsUpToAMaximum() {
        XCTAssertEqual(PaletteLayout.listHeight([]), PaletteLayout.emptyHeight)
        let one = [PaletteGroup(section: .actions, items: [PaletteItem(target: .entry("x"), section: .actions, title: "X", icon: .plus)])]
        XCTAssertEqual(PaletteLayout.listHeight(one), PaletteLayout.headerHeight + PaletteLayout.rowHeight + PaletteLayout.listPadding * 2)
        let many = [PaletteGroup(section: .notes, items: (0..<40).map { PaletteItem(target: .draft("\($0)"), section: .notes, title: "\($0)", icon: .document) })]
        XCTAssertEqual(PaletteLayout.listHeight(many), PaletteLayout.maxListHeight)
        let window = NSRect(x: 100, y: 100, width: 1200, height: 800)
        let frame = PaletteLayout.frame(cardHeight: 300, in: window, screen: nil)
        XCTAssertEqual(frame.midX, window.midX, accuracy: 0.5)
        XCTAssertEqual(frame.maxY - PaletteLayout.shadowInset, window.maxY - PaletteLayout.topOffset, accuracy: 0.5)
    }
}
