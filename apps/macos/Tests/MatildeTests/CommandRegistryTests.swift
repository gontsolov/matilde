import XCTest
import SwiftUI
@testable import Matilde

@MainActor
final class CommandRegistryTests: XCTestCase {
    private let writing = CommandContext(hasWorkspace: true, hasActive: true, canCycleNotes: true, draftCount: 3, canCheckForUpdates: true)

    func testIDsAreUniqueAndTitled() {
        let ids = AppCommands.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        for command in AppCommands.all {
            XCTAssertFalse(command.title(writing).isEmpty, command.id)
            XCTAssertFalse(command.title(CommandContext()).isEmpty, command.id)
        }
    }

    func testNoTwoCommandsShareAShortcut() {
        let shortcuts = AppCommands.all.compactMap(\.shortcut)
        XCTAssertEqual(shortcuts.count, Set(shortcuts).count)
    }

    /// The menu bar keeps the shortcuts it had before the registry, and ⌘K opens the palette.
    func testShortcutsMatchTheMenus() {
        let expected = [
            "new-document": "⌘N", "new-folder": "⇧⌘N", "open-workspace": "⌘O", "save": "⌘S",
            "command-palette": "⌘K", "checkbox": "⇧⌘L", "ask-matilde": "⇧⌘A", "add-comment": "⇧⌘K",
            "branch": "⇧⌘B", "board": "⌘0", "toggle-stash": "⇧⌘J", "next-note": "⌃⌘↓", "previous-note": "⌃⌘↑",
            "focus-mode": "⌘\\", "settings": "⌘,",
        ]
        let actual = Dictionary(uniqueKeysWithValues: AppCommands.all.compactMap { command in
            command.shortcut.map { (command.id, $0.display) }
        })
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(AppCommands["add-comment"].shortcut?.keyboardShortcut, KeyboardShortcut("k", modifiers: [.command, .shift]))
        XCTAssertEqual(AppCommands["next-note"].shortcut?.keyboardShortcut, KeyboardShortcut(.downArrow, modifiers: [.command, .control]))
    }

    func testEveryMenuItemIsInTheRegistry() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/Matilde/MatildeApp.swift").standardizedFileURL, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"item\("([a-z-]+)"\)"#)
        let ids = regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
            Range($0.range(at: 1), in: source).map { String(source[$0]) }
        }
        XCTAssertGreaterThan(ids.count, 20)
        let known = Set(AppCommands.all.map(\.id))
        for id in ids { XCTAssertTrue(known.contains(id), "Menu item \(id) is not registered") }
        XCTAssertEqual(ids.count, Set(ids).count, "Each command appears once in the menu bar")
    }

    func testAvailabilityFollowsAppState() {
        let empty = CommandContext()
        XCTAssertFalse(AppCommands["new-document"].isEnabled(empty))
        XCTAssertTrue(AppCommands["open-workspace"].isEnabled(empty))
        XCTAssertTrue(AppCommands["focus-mode"].isEnabled(empty))
        XCTAssertFalse(AppCommands["ask-matilde"].isEnabled(empty))
        XCTAssertFalse(AppCommands["check-for-updates"].isEnabled(empty))

        XCTAssertTrue(AppCommands["branch"].isEnabled(writing))
        XCTAssertTrue(AppCommands["trash"].isEnabled(writing))
        XCTAssertTrue(AppCommands["next-note"].isEnabled(writing))

        var board = writing
        board.boardVisible = true
        XCTAssertFalse(AppCommands["branch"].isEnabled(board))
        XCTAssertFalse(AppCommands["ask-matilde"].isEnabled(board))
        XCTAssertTrue(AppCommands["board"].isEnabled(board))

        var branching = writing
        branching.isBranching = true
        XCTAssertFalse(AppCommands["trash"].isEnabled(branching))
        XCTAssertFalse(AppCommands["toggle-stash"].isEnabled(branching))
        XCTAssertFalse(AppCommands["duplicate"].isEnabled(branching))
    }

    func testTitlesFollowAppState() {
        var context = writing
        XCTAssertEqual(AppCommands["board"].title(context), "Show Draft Board")
        XCTAssertEqual(AppCommands["focus-mode"].title(context), "Enter Focus Mode")
        context.boardVisible = true
        context.sidebarVisible = false
        XCTAssertEqual(AppCommands["board"].title(context), "Return to Draft")
        XCTAssertEqual(AppCommands["focus-mode"].title(context), "Leave Focus Mode")
    }

    func testPaletteListsEverythingButItself() {
        XCTAssertFalse(AppCommands["command-palette"].inPalette)
        XCTAssertEqual(AppCommands.all.filter { !$0.inPalette }.map(\.id), ["command-palette"])
        XCTAssertEqual(AppCommands.all.filter(\.destructive).map(\.id), ["trash"])
        for id in CommandPaletteController.suggested { XCTAssertNotNil(AppCommands.all.first { $0.id == id }, id) }
    }

    func testShortcutDisplayUsesMenuModifierOrder() {
        XCTAssertEqual(CommandShortcut(key: .character("a"), modifiers: [.command, .shift, .option, .control]).display, "⌃⌥⇧⌘A")
        XCTAssertEqual(CommandShortcut(key: .delete).display, "⌘⌫")
        XCTAssertEqual(CommandShortcut.command("k").display, "⌘K")
    }

    func testSettingsDestinationsCoverEveryTab() {
        let ids = SettingsDestination.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertEqual(Set(SettingsDestination.all.map(\.tab)), Set(SettingsTab.allCases))
        let entries = SettingsDestination.all.map(\.entry)
        XCTAssertTrue(entries.allSatisfy { $0.section == .settings && $0.id.hasPrefix("settings:") })
        XCTAssertTrue(Set(entries.map(\.id)).isDisjoint(with: AppCommands.all.map(\.id)))
    }
}
