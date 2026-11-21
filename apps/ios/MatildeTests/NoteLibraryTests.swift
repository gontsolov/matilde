import Foundation
import Testing
import MatildeKit
@testable import Matilde

@MainActor
struct NoteLibraryTests {
    @Test func startsEmptyOnProduction() {
        let library = NoteLibrary()
        #expect(library.notes.isEmpty)
        #expect(library.serverHost == "sync.matilde.page")
    }

    @Test func sortsNewestFirstAndFilters() {
        let old = NoteSummary(id: "a", title: "Old letter", goal: "", body: "Dear Anna", edited: Date(timeIntervalSince1970: 1))
        let new = NoteSummary(id: "b", title: "New essay", goal: "", body: "On walking", edited: Date(timeIntervalSince1970: 2))
        let library = NoteLibrary(notes: [old, new])
        #expect(library.sorted().map(\.id) == ["b", "a"])
        #expect(library.sorted(matching: "anna").map(\.id) == ["a"])
        #expect(library.sorted(matching: "  ").count == 2)
        #expect(library.note(id: "b")?.title == "New essay")
    }

    @Test func readerRendersInlineMarkdownOnly() {
        let text = NoteReader.rendered("# Not a heading\n*soft*")
        #expect(String(text.characters).hasPrefix("# Not a heading"))
    }

    /// MatildeKit's record model and crypto run on iOS (the same code the Mac syncs with).
    @Test func sharedSyncCoreWorksOnDevice() throws {
        var clock = HybridClock(device: UUID().uuidString.lowercased())
        let first = clock.next(now: Date(timeIntervalSince1970: 1_763_500_000))
        let second = clock.next(now: Date(timeIntervalSince1970: 1_763_400_000))
        #expect(first < second)
        #expect(SyncID.derived("body", "x") == SyncID.derived("body", "x"))
        #expect(SyncID.isCanonical(SyncID.derived("body", "x")))
    }
}
