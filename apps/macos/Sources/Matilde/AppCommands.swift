import SwiftUI
import AppKit
import MatildeKit

/// A menu shortcut, described once for the menu bar (`keyboardShortcut`) and the command
/// palette's hint (`display`).
struct CommandShortcut: Equatable, Hashable {
    enum Key: Hashable {
        case character(Character)
        case upArrow, downArrow, delete
    }
    var key: Key
    var modifiers: EventModifiers = .command

    static func == (left: CommandShortcut, right: CommandShortcut) -> Bool {
        left.key == right.key && left.modifiers.rawValue == right.modifiers.rawValue
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(modifiers.rawValue)
    }

    static func command(_ character: Character, shift: Bool = false) -> CommandShortcut {
        CommandShortcut(key: .character(character), modifiers: shift ? [.command, .shift] : .command)
    }

    var keyboardShortcut: KeyboardShortcut {
        let equivalent: KeyEquivalent
        switch key {
        case .character(let character): equivalent = KeyEquivalent(character)
        case .upArrow: equivalent = .upArrow
        case .downArrow: equivalent = .downArrow
        case .delete: equivalent = .delete
        }
        return KeyboardShortcut(equivalent, modifiers: modifiers)
    }

    /// Native menu order: ⌃ ⌥ ⇧ ⌘, then the key.
    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case .character(let character): text += String(character).uppercased()
        case .upArrow: text += "↑"
        case .downArrow: text += "↓"
        case .delete: text += "⌫"
        }
        return text
    }
}

/// The app state a command needs to decide whether it is available and how it is titled.
/// A plain value so the registry can be tested without a window or workspace.
struct CommandContext: Equatable {
    var hasWorkspace = false
    var hasActive = false
    var boardVisible = false
    var isBranching = false
    var boardFlying = false
    var canCycleNotes = false
    var sidebarVisible = true
    var draftCount = 0
    var canCheckForUpdates = false

    var busy: Bool { isBranching || boardFlying }
}

extension CommandContext {
    @MainActor init(model: AppModel, canCheckForUpdates: Bool = false) {
        self.init(hasWorkspace: model.workspace != nil, hasActive: model.active != nil, boardVisible: model.boardVisible,
                  isBranching: model.isBranching, boardFlying: model.boardFlight != nil, canCycleNotes: model.canCycleNotes,
                  sidebarVisible: model.sidebar, draftCount: model.drafts.count, canCheckForUpdates: canCheckForUpdates)
    }
}

/// Settings window tabs, in their order. The raw value is what the Settings tab view selects.
enum SettingsTab: String, CaseIterable {
    case general, writing, askMatilde, connections, sync

    static let storageKey = "settings.selectedTab"

    var title: String {
        switch self {
        case .general: "General"
        case .writing: "Writing"
        case .askMatilde: "Ask Matilde"
        case .connections: "Connections"
        case .sync: "Sync"
        }
    }

    var icon: MatildeIcon {
        switch self {
        case .general: .settings
        case .writing: .typography
        case .askMatilde: .askMatilde
        case .connections: .key
        case .sync: .sync
        }
    }
}

/// What commands act on. Window and Settings openers only exist inside SwiftUI views, so the
/// view running a command supplies them.
@MainActor
struct CommandActions {
    let model: AppModel
    var openWindow: (String) -> Void = { _ in }
    var openSettings: (SettingsTab?) -> Void = { _ in }
    var checkForUpdates: () -> Void = {}
    var togglePalette: () -> Void = {}

    /// Editor commands go to the focused writing view, like their menu items.
    func sendToEditor(_ action: Selector) { NSApp.sendAction(action, to: nil, from: nil) }
}

/// One command, shared by the menu bar and the command palette (UI-31).
@MainActor
struct AppCommand {
    enum Group: String, CaseIterable { case file, writing, document, navigation, help, settings }

    let id: String
    let group: Group
    let icon: MatildeIcon
    /// Extra words the palette matches, beyond the title.
    var keywords = ""
    var shortcut: CommandShortcut?
    /// Hidden from the palette (for example the palette's own menu item).
    var inPalette = true
    var destructive = false
    let title: @MainActor (CommandContext) -> String
    let isEnabled: @MainActor (CommandContext) -> Bool
    let perform: @MainActor (CommandActions) -> Void

    init(_ id: String, _ group: Group, icon: MatildeIcon, keywords: String = "", shortcut: CommandShortcut? = nil,
         inPalette: Bool = true, destructive: Bool = false, title: String,
         enabled: @escaping @MainActor (CommandContext) -> Bool = { _ in true }, perform: @escaping @MainActor (CommandActions) -> Void) {
        self.init(id, group, icon: icon, keywords: keywords, shortcut: shortcut, inPalette: inPalette, destructive: destructive,
                  dynamicTitle: { _ in title }, enabled: enabled, perform: perform)
    }

    init(_ id: String, _ group: Group, icon: MatildeIcon, keywords: String = "", shortcut: CommandShortcut? = nil,
         inPalette: Bool = true, destructive: Bool = false, dynamicTitle: @escaping @MainActor (CommandContext) -> String,
         enabled: @escaping @MainActor (CommandContext) -> Bool = { _ in true }, perform: @escaping @MainActor (CommandActions) -> Void) {
        self.id = id; self.group = group; self.icon = icon; self.keywords = keywords; self.shortcut = shortcut
        self.inPalette = inPalette; self.destructive = destructive
        self.title = dynamicTitle; self.isEnabled = enabled; self.perform = perform
    }
}

/// The command registry. Menus look commands up by ID (`AppCommands["new-document"]`);
/// the palette lists every enabled command plus `dynamic(for:)`.
@MainActor
enum AppCommands {
    static let all: [AppCommand] = [
        // File
        AppCommand("new-document", .file, icon: .newDocument, keywords: "note create add untitled write", shortcut: .command("n"),
                   title: "New Document", enabled: { $0.hasWorkspace }) { $0.model.newDocument() },
        AppCommand("new-folder", .file, icon: .newFolder, keywords: "create add directory", shortcut: .command("n", shift: true),
                   title: "New Folder…", enabled: { $0.hasWorkspace }) { $0.model.sheet = .folder },
        AppCommand("open-workspace", .file, icon: .folderOpen, keywords: "workspace folder choose switch", shortcut: .command("o"),
                   title: "Open Workspace…") { $0.model.chooseWorkspace() },
        AppCommand("save", .file, icon: .save, keywords: "write disk", shortcut: .command("s"),
                   title: "Save", enabled: { $0.hasActive }) { actions in actions.model.attempt { try actions.model.flush() } },
        AppCommand("rename", .file, icon: .activeDraft, keywords: "title name file", title: "Rename Document…",
                   enabled: { $0.hasActive }) { $0.model.sheet = .rename },

        // Writing
        AppCommand("command-palette", .writing, icon: .search, keywords: "", shortcut: .command("k"), inPalette: false,
                   title: "Command Palette…") { $0.togglePalette() },
        AppCommand("checkbox", .writing, icon: .checkbox, keywords: "todo task checklist", shortcut: .command("l", shift: true),
                   title: "Checkbox", enabled: { $0.hasActive && !$0.boardVisible }) { $0.sendToEditor(#selector(WritingTextView.insertCheckbox(_:))) },
        AppCommand("ask-matilde", .writing, icon: .askMatilde, keywords: "ai assist help question selection paragraph", shortcut: .command("a", shift: true),
                   title: "Ask Matilde…", enabled: { $0.hasActive && !$0.boardVisible }) { $0.sendToEditor(#selector(WritingTextView.askAboutSelection)) },
        AppCommand("add-comment", .writing, icon: .note, keywords: "note annotate private comment", shortcut: .command("k", shift: true),
                   title: "Add Comment", enabled: { $0.hasActive && !$0.boardVisible }) { $0.sendToEditor(#selector(WritingTextView.addUserComment(_:))) },
        AppCommand("branch", .writing, icon: .branch, keywords: "alternative draft version copy", shortcut: .command("b", shift: true),
                   title: "Branch Draft", enabled: { $0.hasActive && !$0.boardVisible }) { $0.model.branch() },
        AppCommand("board", .writing, icon: .board, keywords: "canvas drafts overview family", shortcut: .command("0"),
                   dynamicTitle: { $0.boardVisible ? "Return to Draft" : "Show Draft Board" },
                   enabled: { $0.hasActive }) { $0.model.boardRequest += 1 },
        AppCommand("toggle-stash", .writing, icon: .stash, keywords: "scratch tray clippings", shortcut: .command("j", shift: true),
                   title: "Toggle Stash", enabled: { $0.hasActive && !$0.busy }) { $0.model.stash.toggle() },
        AppCommand("reveal-stash", .writing, icon: .folderOpen, keywords: "finder stash", title: "Reveal Stash in Finder",
                   enabled: { $0.hasActive }) { $0.model.stash.reveal() },
        AppCommand("reload-stash", .writing, icon: .refresh, keywords: "disk stash", title: "Reload Stash from Disk",
                   enabled: { $0.hasActive }) { $0.model.stash.reloadPreservingChanges() },
        AppCommand("reveal-all-stashes", .writing, icon: .folderOpen, keywords: "finder stash", title: "Show All Stashes in Finder",
                   enabled: { $0.hasWorkspace }) { $0.model.stash.reveal(all: true) },
        AppCommand("review-now", .writing, icon: .askMatilde, keywords: "ask matilde ai feedback review", title: "Review now",
                   enabled: { $0.hasActive && !$0.boardVisible && !$0.isBranching }) { $0.model.reviewNow() },
        AppCommand("goal", .writing, icon: .goal, keywords: "aim purpose flag", title: "Writing Goal…",
                   enabled: { $0.hasActive }) { $0.model.sheet = .goal },

        // Document actions (toolbar menu and palette)
        AppCommand("duplicate", .document, icon: .copy, keywords: "copy clone", title: "Duplicate",
                   enabled: { $0.hasActive && !$0.busy }) { actions in
                       if let draft = actions.model.active { actions.model.duplicate(draft) }
                   },
        AppCommand("copy-markdown", .document, icon: .copy, keywords: "export clipboard text", title: "Copy Markdown",
                   enabled: { $0.hasActive }) { $0.model.copyMarkdown() },
        AppCommand("copy-path", .document, icon: .copy, keywords: "export clipboard file location", title: "Copy Path",
                   enabled: { $0.hasActive }) { actions in
                       if let draft = actions.model.active { actions.model.copyPath(of: draft) }
                   },
        AppCommand("reveal", .document, icon: .folderOpen, keywords: "finder export file show", title: "Show in Finder",
                   enabled: { $0.hasActive }) { $0.model.reveal() },
        AppCommand("trash", .document, icon: .trash, keywords: "delete remove", destructive: true, title: "Move to Trash",
                   enabled: { $0.hasActive && !$0.busy }) { actions in
                       if let draft = actions.model.active { actions.model.trashDraft(draft) }
                   },

        // Navigation. ⌃⌘↑/↓: free in NSTextView key bindings (⌘↑/↓, ⌥↑/↓ and ⌃↑/↓ stay with text
        // editing and Mission Control) and clear of ⇧⌘A, ⇧⌘K and the other menu items.
        AppCommand("next-note", .navigation, icon: .chevronDown, keywords: "down following", shortcut: CommandShortcut(key: .downArrow, modifiers: [.command, .control]),
                   title: "Next Note", enabled: { $0.canCycleNotes }) { $0.model.cycleNote(forward: true) },
        AppCommand("previous-note", .navigation, icon: .chevronUp, keywords: "up before", shortcut: CommandShortcut(key: .upArrow, modifiers: [.command, .control]),
                   title: "Previous Note", enabled: { $0.canCycleNotes }) { $0.model.cycleNote(forward: false) },
        AppCommand("focus-mode", .navigation, icon: .sidebar, keywords: "toggle sidebar hide show distraction", shortcut: .command("\\"),
                   dynamicTitle: { $0.sidebarVisible ? "Enter Focus Mode" : "Leave Focus Mode" }) { $0.model.toggleSidebar() },

        // Help
        AppCommand("welcome", .help, icon: .note, keywords: "help guide introduction", title: "Welcome to Matilde",
                   enabled: { $0.hasWorkspace }) { $0.model.showWelcomeDocument() },
        AppCommand("whats-new", .help, icon: .sparkles, keywords: "changelog release notes update", title: "What's New in Matilde…") { actions in
            NSApp.activate(ignoringOtherApps: true); actions.openWindow(WhatsNewWindow.id)
        },
        AppCommand("feedback", .help, icon: .feedback, keywords: "bug idea report contact", title: FeedbackCopy.menuTitle) { actions in
            NSApp.activate(ignoringOtherApps: true); actions.openWindow(FeedbackWindow.id)
        },
        AppCommand("check-for-updates", .help, icon: .download, keywords: "update upgrade version sparkle", title: "Check for Updates…",
                   enabled: { $0.canCheckForUpdates }) { $0.checkForUpdates() },

        // Settings, palette only: the app menu already has the native Settings item.
        AppCommand("settings", .settings, icon: .settings, keywords: "preferences options", shortcut: .command(","),
                   title: "Settings…") { $0.openSettings(nil) },
        AppCommand("appearance-light", .settings, icon: .sun, keywords: "appearance theme mode color bright", title: "Use Light Appearance") { _ in
            UserDefaults.standard.set(AppAppearance.light.rawValue, forKey: SettingKeys.appearance)
        },
        AppCommand("appearance-dark", .settings, icon: .moon, keywords: "appearance theme mode color night", title: "Use Dark Appearance") { _ in
            UserDefaults.standard.set(AppAppearance.dark.rawValue, forKey: SettingKeys.appearance)
        },
        AppCommand("appearance-system", .settings, icon: .sunMoon, keywords: "appearance theme mode color automatic", title: "Match System Appearance") { _ in
            UserDefaults.standard.set(AppAppearance.system.rawValue, forKey: SettingKeys.appearance)
        },
        AppCommand("spell-checking", .settings, icon: .spellCheck, keywords: "spelling typos autocorrect",
                   dynamicTitle: { _ in UserDefaults.standard.bool(forKey: SettingKeys.spellChecking) ? "Turn Off Spell Checking" : "Turn On Spell Checking" }) { _ in
            let defaults = UserDefaults.standard
            defaults.set(!defaults.bool(forKey: SettingKeys.spellChecking), forKey: SettingKeys.spellChecking)
        },
    ]

    private static let byID: [String: AppCommand] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static subscript(id: String) -> AppCommand {
        guard let command = byID[id] else { preconditionFailure("Unknown command \(id)") }
        return command
    }

    /// Commands that depend on the workspace: move the current note to each other folder and
    /// compare with each other draft of its family. Only the palette lists them.
    static func dynamic(for model: AppModel) -> [AppCommand] {
        guard let active = model.active else { return [] }
        let busy = model.isBranching || model.boardFlight != nil
        let moves = SidebarActions.moveTargets(folders: model.folders, from: active.folder).map { destination in
            AppCommand("move:\(destination)", .document, icon: .folder, keywords: "move folder file put",
                       title: "Move to \(destination.isEmpty ? "Documents" : destination)", enabled: { _ in !busy }) { actions in
                actions.model.moveNote(family: active.family, from: active.folder, to: destination)
                actions.model.collapsedFolders.remove(destination)
            }
        }
        let compares = model.related.filter { $0.id != active.id }.map { draft in
            AppCommand("compare:\(draft.id)", .document, icon: .compare, keywords: "side by side compare diff split",
                       title: "Compare with \(draft.title)", enabled: { _ in !busy }) { $0.model.compare(draft) }
        }
        return moves + compares
    }
}

/// A menu bar item for a registry command.
struct CommandMenuItem: View {
    let command: AppCommand
    let context: CommandContext
    let actions: CommandActions
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    init(_ id: String, context: CommandContext, actions: CommandActions) {
        self.command = AppCommands[id]; self.context = context; self.actions = actions
    }

    var body: some View {
        let button = Button(command.title(context), role: command.destructive ? .destructive : nil) {
            var actions = actions
            let openWindow = openWindow, openSettings = openSettings
            actions.openWindow = { openWindow(id: $0) }
            actions.openSettings = { tab in
                if let tab { UserDefaults.standard.set(tab.rawValue, forKey: SettingsTab.storageKey) }
                openSettings()
            }
            command.perform(actions)
        }.disabled(!command.isEnabled(context))
        if let shortcut = command.shortcut { button.keyboardShortcut(shortcut.keyboardShortcut) } else { button }
    }
}
