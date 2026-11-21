import Foundation
import Testing
import MatildeKit
@testable import Matilde

/// A fresh workspace and store in a temporary folder.
@MainActor
func makeLibrary() throws -> NoteLibrary {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("MatildeTests-\(UUID().uuidString)", isDirectory: true)
    let library = NoteLibrary(root: base.appendingPathComponent("Notes", isDirectory: true),
                              storeBase: base.appendingPathComponent("Store", isDirectory: true))
    #expect(library.workspace != nil)
    #expect(library.error == nil)
    return library
}

@MainActor
struct NoteLibraryTests {
    @Test func startsEmpty() throws {
        let library = try makeLibrary()
        #expect(library.drafts.isEmpty)
        #expect(library.sections().isEmpty)
    }

    @Test func createsSavesAndRenames() throws {
        let library = try makeLibrary()
        var changes = 0
        library.onLocalChange = { changes += 1 }
        let draft = try #require(library.create())
        #expect(library.isUntitled(draft))
        #expect(library.displayTitle(draft) == "")
        library.save(draft, text: "Dear Anna,\n\nThank you.")
        #expect(library.text(of: try #require(library.draft(id: draft.id))) == "Dear Anna,\n\nThank you.")
        let renamed = try #require(library.rename(draft, to: "A letter"))
        #expect(renamed.title == "A letter")
        #expect(!library.isUntitled(renamed))
        library.setGoal(renamed, to: "Say thank you")
        #expect(library.draft(id: draft.id)?.goal == "Say thank you")
        #expect(changes >= 4)
    }

    @Test func renameRejectsSlashes() throws {
        let library = try makeLibrary()
        let draft = try #require(library.create())
        library.rename(draft, to: "a/b")
        #expect(library.error != nil)
        #expect(library.draft(id: draft.id)?.title == "Untitled")
    }

    @Test func searchesTitleGoalAndText() throws {
        let library = try makeLibrary()
        let letter = try #require(library.create())
        library.save(letter, text: "Dear Anna")
        library.rename(letter, to: "Letter")
        let essay = try #require(library.create())
        library.save(essay, text: "On walking")
        #expect(library.sorted(matching: "anna").map(\.id) == [letter.id])
        #expect(library.sorted(matching: "letter").map(\.id) == [letter.id])
        #expect(library.sorted(matching: "walking").map(\.id) == [essay.id])
        #expect(library.sorted(matching: "  ").count == 2)
    }

    @Test func groupsFoldersAfterTopLevelNotes() throws {
        let library = try makeLibrary()
        library.createFolder(named: "Letters")
        _ = try #require(library.create(folder: "Letters"))
        _ = try #require(library.create())
        let sections = library.sections()
        #expect(sections.map(\.folder) == ["", "Letters"])
        #expect(sections.map(\.title) == ["Notes", "Letters"])
    }

    @Test func trashMovesTheFileOutOfTheList() throws {
        let library = try makeLibrary()
        let draft = try #require(library.create())
        library.trash(draft)
        #expect(library.drafts.isEmpty)
        let trash = try #require(library.root).appendingPathComponent(".matilde/trash")
        #expect(FileManager.default.fileExists(atPath: trash.path))
    }

    @Test func previewSkipsMarkdownAndImages() {
        #expect(NoteLibrary.preview("# Title\n\n![x](a.png)\n> Quoted line") == "Title")
        #expect(NoteLibrary.preview("\n\n![x](a.png)\n- item") == "item")
        #expect(NoteLibrary.preview("") == "")
    }

    @Test func remoteChangesBumpTheRevision() throws {
        let library = try makeLibrary()
        let before = library.remoteRevision
        library.remoteChangesApplied()
        #expect(library.remoteRevision == before + 1)
    }

    /// MatildeKit's record model and crypto run on iOS (the same code the Mac syncs with).
    @Test func sharedSyncCoreWorksOnDevice() throws {
        var clock = HybridClock(device: UUID().uuidString.lowercased())
        let first = clock.next(now: Date(timeIntervalSince1970: 1_763_500_000))
        let second = clock.next(now: Date(timeIntervalSince1970: 1_763_400_000))
        #expect(first < second)
        #expect(SyncID.isCanonical(SyncID.derived("body", "x")))
    }
}
