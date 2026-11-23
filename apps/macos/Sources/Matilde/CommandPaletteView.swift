import SwiftUI
import AppKit
import MatildeKit

/// Sizes of the command palette card, in points. The panel grows and shrinks with its results,
/// keeping its top edge in place.
enum PaletteLayout {
    static let width: CGFloat = 600
    static let searchHeight: CGFloat = 52
    static let footerHeight: CGFloat = 32
    static let headerHeight: CGFloat = 26
    static let rowHeight: CGFloat = 36
    static let listPadding: CGFloat = 6
    static let emptyHeight: CGFloat = 76
    static let maxListHeight: CGFloat = 384
    static let cornerRadius: CGFloat = 12
    /// Transparent margin around the card for its shadow.
    static let shadowInset: CGFloat = 28
    /// Distance from the window's top edge to the card.
    static let topOffset: CGFloat = 88

    static func listHeight(_ groups: [PaletteGroup]) -> CGFloat {
        guard !groups.isEmpty else { return emptyHeight }
        let rows = CGFloat(groups.reduce(0) { $0 + $1.items.count })
        return min(maxListHeight, CGFloat(groups.count) * headerHeight + rows * rowHeight + listPadding * 2)
    }

    static func cardHeight(_ groups: [PaletteGroup]) -> CGFloat {
        searchHeight + 1 + listHeight(groups) + 1 + footerHeight
    }

    /// Centered over `window`, near its top; kept on the window's screen.
    static func frame(cardHeight: CGFloat, in window: NSRect, screen: NSRect?) -> NSRect {
        let width = Self.width + shadowInset * 2
        let height = cardHeight + shadowInset * 2
        var x = window.midX - width / 2
        var top = window.maxY - topOffset + shadowInset
        if let screen {
            x = min(max(x, screen.minX), screen.maxX - width)
            top = min(top, screen.maxY)
        }
        return NSRect(x: x, y: top - height, width: width, height: height)
    }
}

private enum PaletteStyle {
    private static func adaptive(_ name: String, light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: NSColor.Name("Matilde.palette." + name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
    // The slash menu's surface, border and selection, so both floating lists look related.
    static let surface = adaptive("surface", light: .white, dark: NSColor(calibratedRed: 0.195, green: 0.197, blue: 0.2, alpha: 1))
    static let border = adaptive("border", light: NSColor.black.withAlphaComponent(0.13), dark: NSColor.white.withAlphaComponent(0.13))
    static let selection = adaptive("selection", light: NSColor.black.withAlphaComponent(0.06), dark: NSColor.white.withAlphaComponent(0.08))
    static let rule = adaptive("rule", light: NSColor.black.withAlphaComponent(0.07), dark: NSColor.white.withAlphaComponent(0.08))
    static let glyph = adaptive("glyph", light: NSColor(calibratedRed: 0.24, green: 0.25, blue: 0.22, alpha: 0.56),
                                dark: NSColor(calibratedRed: 0.87, green: 0.87, blue: 0.86, alpha: 0.52))
}

final class CommandPalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Opens, filters and runs the command palette (UI-31). One per app; the main window's
/// content registers itself as the host.
@MainActor
final class CommandPaletteController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = CommandPaletteController()

    @Published var query = "" { didSet { if query != oldValue { refresh(keepSelection: false) } } }
    @Published private(set) var groups: [PaletteGroup] = []
    @Published var selection: PaletteTarget?
    /// Changes on every opening so the view can focus its field again.
    @Published private(set) var openings = 0

    weak var model: AppModel?
    weak var hostWindow: NSWindow?
    weak var updater: AppUpdater?
    var openWindow: (String) -> Void = { _ in }
    var openSettings: () -> Void = {}

    /// Shown under Actions when the query is empty.
    static let suggested = ["new-document", "ask-matilde", "board", "focus-mode", "settings"]

    private var panel: CommandPalettePanel?
    private var monitor: Any?
    private var notes: [PaletteNote] = []
    private var entries: [PaletteEntry] = []
    private var commands: [String: AppCommand] = [:]
    /// Draft text read for searching, with the edit date it was read at.
    private var bodies: [String: (edited: Date, text: String)] = [:]
    private var loadTask: Task<Void, Never>?
    private var closing = false

    var isOpen: Bool { panel?.isVisible == true && !closing }
    var items: [PaletteItem] { PaletteSearch.flatten(groups) }

    // MARK: Keyboard

    func installKeyMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handle(event) } ? nil : event
        }
    }

    /// ⌘K opens the palette, except in the editor with text selected, where it still adds or
    /// edits a link (owner's choice, 2026-11-23). Inside the palette: arrows, Return, Escape.
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let isCommandK = flags == .command && event.charactersIgnoringModifiers?.lowercased() == "k"
        if let panel, isOpen, event.window === panel {
            if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
            if isCommandK { close(); return true }
            let control = flags == .control
            switch event.keyCode {
            case 125 where flags.isEmpty: move(1); return true
            case 126 where flags.isEmpty: move(-1); return true
            case 45 where control: move(1); return true   // ⌃N
            case 35 where control: move(-1); return true  // ⌃P
            case 36 where flags.isEmpty, 76 where flags.isEmpty: run(selectedItem); return true
            case 53: close(); return true
            default: return false
            }
        }
        guard isCommandK, let host = hostWindow, event.window === host, host.attachedSheet == nil else { return false }
        if let editor = host.firstResponder as? WritingTextView, editor.selectedRange().length > 0 { return false }
        show()
        return true
    }

    func toggle() { isOpen ? close() : show() }

    func move(_ delta: Int) {
        let items = items
        guard !items.isEmpty else { return }
        let index = items.firstIndex { $0.target == selection } ?? (delta > 0 ? -1 : 0)
        selection = items[(index + delta + items.count) % items.count].target
    }

    var selectedItem: PaletteItem? { items.first { $0.target == selection } ?? items.first }

    // MARK: Showing

    func show() {
        guard let host = hostWindow, host.attachedSheet == nil else { return }
        if isOpen { panel?.makeKey(); return }
        prepare()
        query = ""
        refresh(keepSelection: false)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if panel.parent !== host { panel.parent?.removeChildWindow(panel); host.addChildWindow(panel, ordered: .above) }
        panel.appearance = host.effectiveAppearance
        panel.setFrame(PaletteLayout.frame(cardHeight: PaletteLayout.cardHeight(groups), in: host.frame, screen: host.screen?.visibleFrame), display: false)
        // Appears instantly, with no fade or motion.
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        openings += 1
    }

    func close() {
        guard let panel, panel.isVisible, !closing else { return }
        // Guards against re-entry: resigning key while closing calls close() again.
        closing = true
        defer { closing = false }
        loadTask?.cancel()
        let host = panel.parent
        // Disappears instantly, with no fade.
        host?.removeChildWindow(panel)
        panel.orderOut(nil)
        host?.makeKey()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking elsewhere closes the palette, like a menu.
        close()
    }

    private func makePanel() -> CommandPalettePanel {
        let panel = CommandPalettePanel(contentRect: .zero, styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .none
        panel.delegate = self
        panel.setAccessibilityLabel("Command palette")
        let hosting = NSHostingView(rootView: CommandPaletteView(controller: self))
        hosting.sizingOptions = []
        panel.contentView = hosting
        return panel
    }

    // MARK: Results

    private var context: CommandContext {
        guard let model else { return CommandContext() }
        return CommandContext(model: model, canCheckForUpdates: updater?.canCheckForUpdates ?? false)
    }

    /// Snapshot of commands, settings and notes for this opening.
    private func prepare() {
        guard let model else { return }
        let context = context
        let available = (AppCommands.all + AppCommands.dynamic(for: model)).filter { $0.inPalette && $0.isEnabled(context) }
        commands = Dictionary(available.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        entries = available.map { command in
            PaletteEntry(id: command.id, title: command.title(context), keywords: command.keywords, icon: command.icon,
                         section: command.group == .settings ? .settings : .actions, shortcut: command.shortcut?.display,
                         destructive: command.destructive)
        } + SettingsDestination.all.map(\.entry)
        let roots = Set(SidebarOrder.groups(model.drafts).map(\.root.id))
        notes = model.drafts.map { draft in
            let edited = SidebarOrder.date(draft)
            let isActive = draft.id == model.active?.id
            let cached = bodies[draft.id].flatMap { $0.edited == edited ? $0.text : nil }
            return PaletteNote(id: draft.id, family: draft.family, title: draft.title, folder: draft.folder,
                               isRoot: roots.contains(draft.id), edited: edited, isActive: isActive,
                               body: isActive ? model.text : cached)
        }
        loadBodies(model)
    }

    /// Reads the drafts' text off the main thread so typing in the palette never waits on disk.
    private func loadBodies(_ model: AppModel) {
        loadTask?.cancel()
        guard let workspace = model.workspace else { return }
        let unread = Set(notes.filter { $0.body == nil }.map(\.id))
        let missing: [(id: String, edited: Date, url: URL)] = model.drafts.compactMap { draft in
            guard unread.contains(draft.id), let url = try? workspace.url(for: draft.path) else { return nil }
            return (draft.id, SidebarOrder.date(draft), url)
        }
        guard !missing.isEmpty else { return }
        loadTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { () -> [(String, Date, String)] in
                missing.compactMap { item in
                    guard !Task.isCancelled, let text = try? String(contentsOf: item.url, encoding: .utf8) else { return nil }
                    return (item.id, item.edited, String(text.prefix(200_000)))
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            for (id, edited, text) in loaded { self.bodies[id] = (edited, text) }
            self.notes = self.notes.map { note in
                var note = note
                if note.body == nil, let body = self.bodies[note.id], body.edited == note.edited { note.body = body.text }
                return note
            }
            if !self.query.isEmpty { self.refresh(keepSelection: true) }
        }
    }

    private func refresh(keepSelection: Bool) {
        groups = PaletteSearch.results(query: query, notes: notes, entries: entries, suggested: Self.suggested)
        let items = items
        if !keepSelection || !items.contains(where: { $0.target == selection }) { selection = items.first?.target }
        resize()
    }

    private func resize() {
        guard let panel, panel.isVisible, let host = panel.parent ?? hostWindow else { return }
        let frame = PaletteLayout.frame(cardHeight: PaletteLayout.cardHeight(groups), in: host.frame, screen: host.screen?.visibleFrame)
        // Keep the top edge where it opened when the window has not moved.
        var next = frame
        next.origin.y = panel.frame.maxY - frame.height
        if abs(panel.frame.maxY - frame.maxY) > 1 || abs(panel.frame.minX - frame.minX) > 1 { next = frame }
        panel.setFrame(next, display: true, animate: false)
    }

    // MARK: Running

    func run(_ item: PaletteItem?) {
        guard let item, let model else { return }
        close()
        let actions = commandActions(model)
        // After the panel gives focus back, so editor commands reach the writing view.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch item.target {
                case .family(let family): model.selectFamily(family)
                case .draft(let id): if let draft = model.drafts.first(where: { $0.id == id }) { model.openDraft(draft) }
                case .entry(let id):
                    if let destination = SettingsDestination.all.first(where: { "settings:\($0.id)" == id }) {
                        actions.openSettings(destination.tab)
                    } else {
                        self.commands[id]?.perform(actions)
                    }
                }
            }
        }
    }

    func commandActions(_ model: AppModel, updater: AppUpdater? = nil) -> CommandActions {
        let openWindow = openWindow, openSettings = openSettings
        let updater = updater ?? self.updater
        return CommandActions(model: model, openWindow: openWindow, openSettings: { tab in
            if let tab { UserDefaults.standard.set(tab.rawValue, forKey: SettingsTab.storageKey) }
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }, checkForUpdates: { [weak updater] in updater?.checkForUpdates() }, togglePalette: { [weak self] in self?.toggle() })
    }
}

/// Registers the main window and its window/Settings openers with the palette.
struct CommandPaletteHost: ViewModifier {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content
            .background(CommandPaletteAnchor(model: model))
            .onAppear {
                let controller = CommandPaletteController.shared
                let openWindow = openWindow, openSettings = openSettings
                controller.openWindow = { openWindow(id: $0) }
                controller.openSettings = { openSettings() }
                controller.installKeyMonitor()
            }
    }
}

private struct CommandPaletteAnchor: NSViewRepresentable {
    let model: AppModel
    func makeNSView(context: Context) -> AnchorView { AnchorView(model: model) }
    func updateNSView(_ view: AnchorView, context: Context) { view.model = model }

    final class AnchorView: NSView {
        weak var model: AppModel?
        init(model: AppModel) { self.model = model; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            MainActor.assumeIsolated {
                CommandPaletteController.shared.hostWindow = window
                CommandPaletteController.shared.model = model
            }
        }
    }
}

struct CommandPaletteView: View {
    @ObservedObject var controller: CommandPaletteController
    @FocusState private var fieldFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var lastPointer: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            card
            Spacer(minLength: 0)
        }
        .padding(PaletteLayout.shadowInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { fieldFocused = true }
        .onChange(of: controller.openings) { _, _ in fieldFocused = true }
    }

    private var card: some View {
        let dark = colorScheme == .dark
        let shape = RoundedRectangle(cornerRadius: PaletteLayout.cornerRadius, style: .continuous)
        return VStack(spacing: 0) {
            searchField
            rule
            results.frame(height: PaletteLayout.listHeight(controller.groups))
            rule
            footer
        }
        .frame(width: PaletteLayout.width)
        .background(shape.fill(Color(PaletteStyle.surface)))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color(PaletteStyle.border), lineWidth: 0.75))
        // A tight contact shadow plus a larger diffuse one, like the slash menu.
        .shadow(color: .black.opacity(dark ? 0.45 : 0.10), radius: 1.5, y: 1)
        .shadow(color: .black.opacity(dark ? 0.5 : 0.16), radius: 20, y: 10)
    }

    private var rule: some View { Rectangle().fill(Color(PaletteStyle.rule)).frame(height: 1) }

    private var searchField: some View {
        HStack(spacing: 10) {
            MatildeIcon.search.image(size: 18).foregroundStyle(Color(PaletteStyle.glyph))
            TextField("Search notes, actions and settings", text: $controller.query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .foregroundStyle(Color(Paper.ink))
                .focused($fieldFocused)
                .accessibilityLabel("Search notes, actions and settings")
        }
        .padding(.horizontal, 18)
        .frame(height: PaletteLayout.searchHeight)
    }

    @ViewBuilder private var results: some View {
        if controller.groups.isEmpty {
            Text("No results")
                .font(.system(size: 13)).foregroundStyle(Color(Paper.muted))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(controller.groups) { group in
                            Text(group.section.rawValue)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Color(Paper.muted))
                                .padding(.leading, 12).padding(.top, 8)
                                .frame(height: PaletteLayout.headerHeight, alignment: .leading)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(group.items) { item in row(item).id(item.target) }
                        }
                    }
                    .padding(PaletteLayout.listPadding)
                }
                .scrollIndicators(.hidden)
                .onChange(of: controller.selection) { _, target in
                    guard let target else { return }
                    proxy.scrollTo(target)
                }
            }
        }
    }

    private func row(_ item: PaletteItem) -> some View {
        let selected = item.target == controller.selection
        return HStack(spacing: 10) {
            item.icon.image(size: 16)
                .foregroundStyle(item.destructive ? Color(nsColor: .systemRed).opacity(0.8) : Color(PaletteStyle.glyph))
                .frame(width: 18)
            HStack(spacing: 8) {
                highlighted(item)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color(Paper.ink))
                    .layoutPriority(1)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Color(Paper.muted))
                }
            }
            .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 12)
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(size: 12)).tracking(1.5)
                    .foregroundStyle(Color(Paper.muted))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: PaletteLayout.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(PaletteStyle.selection))
                .opacity(selected ? 1 : 0)
        )
        .contentShape(Rectangle())
        .onTapGesture { controller.selection = item.target; controller.run(item) }
        .onContinuousHover { phase in
            // Only a moving pointer selects, so keyboard scrolling under a resting pointer does not.
            guard case .active = phase else { return }
            let pointer = NSEvent.mouseLocation
            defer { lastPointer = pointer }
            if let lastPointer, lastPointer != pointer { controller.selection = item.target }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.title, item.subtitle].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(item.shortcut ?? "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// The title with matched characters in a heavier weight.
    private func highlighted(_ item: PaletteItem) -> Text {
        guard !item.highlights.isEmpty else { return Text(item.title) }
        let marks = Set(item.highlights)
        // Runs of matched and unmatched characters, concatenated.
        var text = Text("")
        var run = "", runMatched = false
        for (index, character) in item.title.enumerated() {
            let matched = marks.contains(index)
            if matched != runMatched && !run.isEmpty {
                text = text + (runMatched ? Text(run).fontWeight(.semibold) : Text(run))
                run = ""
            }
            runMatched = matched
            run.append(character)
        }
        if !run.isEmpty { text = text + (runMatched ? Text(run).fontWeight(.semibold) : Text(run)) }
        return text
    }

    private var footer: some View {
        HStack(spacing: 16) {
            hint("↑↓", "Navigate")
            hint("↵", "Open")
            hint("esc", "Close")
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(height: PaletteLayout.footerHeight)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(.system(size: 11, weight: .medium)).foregroundStyle(Color(Paper.ink).opacity(0.7))
            Text(label).font(.system(size: 11)).foregroundStyle(Color(Paper.muted))
        }
        .accessibilityElement(children: .combine)
    }
}
