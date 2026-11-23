import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MatildeKit

@main
struct MatildeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    @StateObject private var updater = AppUpdater()
    var body: some Scene {
        Window("Matilde", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 760, minHeight: 520)
                .modifier(AppAppearanceModifier())
                .scrollIndicators(.hidden)
                .onAppear {
                    delegate.model = model
                    CommandPaletteController.shared.updater = updater
                    NSApp.activate(ignoringOtherApps: true)
                }
                .modifier(CommandPaletteHost(model: model))
                .modifier(AnnounceWhatsNew())
        }
        .defaultSize(width: 1180, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            // Every item comes from the command registry (`AppCommands`), shared with the
            // command palette (UI-31).
            let context = CommandContext(model: model, canCheckForUpdates: updater.canCheckForUpdates)
            let actions = CommandPaletteController.shared.commandActions(model, updater: updater)
            let item = { (id: String) in CommandMenuItem(id, context: context, actions: actions) }
            CommandGroup(after: .appInfo) {
                item("check-for-updates")
            }
            CommandGroup(replacing: .newItem) {
                item("new-document")
                item("new-folder")
                Divider()
                item("open-workspace")
            }
            CommandGroup(replacing: .saveItem) {
                item("save")
                item("rename")
            }
            CommandMenu("Writing") {
                item("command-palette")
                Divider()
                item("checkbox")
                Divider()
                item("ask-matilde")
                item("add-comment")
                item("branch")
                item("board")
                item("toggle-stash")
                item("reveal-stash")
                item("reload-stash")
                item("reveal-all-stashes")
                item("review-now")
                item("goal")
                Divider()
                item("next-note")
                item("previous-note")
                item("focus-mode")
            }
            CommandGroup(replacing: .help) {
                item("welcome")
                item("whats-new")
                Divider()
                item("feedback")
            }
        }
        Settings { AppSettingsView().scrollIndicators(.hidden) }
        FeedbackWindow()
        WhatsNewWindow()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        AppIconChoice.stored().apply()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        do {
            try model?.flush()
            // SYNC-02: record this session's changes for sync; never blocks quitting.
            model?.workspace?.trackSyncChangesLogged()
            return .terminateNow
        }
        catch {
            let alert = NSAlert()
            alert.messageText = "Your writing could not be saved"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "Keep Matilde Open")
            alert.runModal()
            return .terminateCancel
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @AppStorage(SettingKeys.textSize) private var writingTextSize = 19.0
    @AppStorage(SettingKeys.lineSpacing) private var writingLineSpacing = 9.0
    @AppStorage(SettingKeys.spellChecking) private var writingSpellChecking = false
    @ObservedObject var model: AppModel
    @State private var hoveredDraft: String?
    @State private var hoveredFolder: String?
    @State private var noteDrag: SidebarNoteDrag?
    @State private var noteDropTarget: SidebarDropTarget?
    @State private var sidebarFrames: [String: CGRect] = [:]
    @State private var sidebarKeyboard = SidebarKeyboardView()
    @State private var folderToTrash: String?
    private var sidebarFocused: Bool { sidebarKeyboard.window?.firstResponder === sidebarKeyboard }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var chrome = WindowChromeModel()
    @State private var boardAmount: CGFloat = 0
    @State private var pinchTarget: CGFloat = 0
    @State private var animatingFlightID: UUID?
    var body: some View {
        HStack(spacing: 0) {
            if model.workspace != nil && model.sidebar {
                sidebar.frame(width: WindowChrome.sidebarWidth).ignoresSafeArea(.container, edges: .top)
                Rectangle().fill(Color(Paper.ink).opacity(0.09)).frame(width: 1)
            }
            HSplitView {
            VStack(spacing: 0) {
                if model.workspace == nil { welcome }
                else {
                    if let draft = model.active { writingSpace(draft) }
                    else { emptyWorkspace }
                }
            }.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            // Split panes host their content separately and would otherwise start below the
            // hidden title bar; the window chrome is laid out from the window's top edge.
            .ignoresSafeArea(.container, edges: .top)
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    if model.active != nil && !model.boardVisible { CanvasTopFade() }
                }.frame(maxWidth: .infinity)
                .ignoresSafeArea(.container, edges: .top)
            }
            .overlay(alignment: .top) {
                WindowDragArea().frame(height: WindowChrome.headerHeight).ignoresSafeArea(.container, edges: .top)
            }
            .overlay(alignment: .topTrailing) { windowControls.ignoresSafeArea(.container, edges: .top) }
            if let comparison = model.comparison {
                DraftComparisonPane(comparison: comparison, model: model).frame(minWidth: 360, maxWidth: .infinity)
                    .ignoresSafeArea(.container, edges: .top)
            }
            }
            .background(ComparisonSplitPosition(enabled: model.comparison != nil, fraction: model.comparisonFraction,
                                                changed: { model.comparisonFraction = $0 }))
            .id(model.workspace?.root.path)
        }
        .background(Color(Paper.background))
        .foregroundStyle(Color(Paper.ink))
        .tint(Color(Paper.accent))
        .ignoresSafeArea(.container, edges: .top)
        // In the header row: at the sidebar's trailing edge when open, past the traffic lights when collapsed.
        .overlay(alignment: .topLeading) { sidebarToggle.ignoresSafeArea(.container, edges: .top) }
        .background(WindowChromeAttachment(chrome: chrome))
        .onChange(of: model.boardVisible) { _, _ in chrome.reveal() }
        .onChange(of: model.sidebar) { _, _ in chrome.reveal() }
        .sheet(item: $model.sheet) { kind in DocumentSheet(model: model, kind: kind).scrollIndicators(.hidden) }
        .alert("Matilde", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .alert(folderTrashTitle, isPresented: Binding(get: { folderToTrash != nil }, set: { if !$0 { folderToTrash = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let folder = folderToTrash { model.trashFolder(folder) }
                folderToTrash = nil
            }
            Button("Cancel", role: .cancel) { folderToTrash = nil }
        } message: { Text(folderTrashMessage) }
    }
    private var folderTrashTitle: String { "Move “\(folderToTrash ?? "")” to the Trash?" }
    private var folderTrashMessage: String {
        let count = SidebarActions.noteCount(in: folderToTrash ?? "", among: model.drafts)
        return count == 1 ? "It contains 1 note." : "It contains \(count) notes."
    }

    /// Over the sidebar it stays put; over the canvas it fades with the other window controls.
    @ViewBuilder private var sidebarToggle: some View {
        if model.workspace != nil {
            Button { model.toggleSidebar() } label: { MatildeIcon.sidebar.image(size: MatildeIcon.toolbarSize) }
                .buttonStyle(FloatingIconButtonStyle())
                .help("Toggle sidebar · ⌘\\").accessibilityLabel("Toggle sidebar")
                .padding(.top, WindowChrome.controlTop)
                .onHover { chrome.hover($0) }
                .opacity(!model.sidebar && chrome.hidden ? 0 : 1)
                .animation(chromeAnimation, value: chrome.hidden)
                .padding(.leading, chrome.toggleLeading(sidebarOpen: model.sidebar))
        }
    }
    private var chromeAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: chrome.hidden ? 0.45 : 0.2)
    }
    /// Document actions, floating quietly in the canvas's top-right corner.
    private var windowControls: some View {
        HStack(spacing: 2) {
            if model.workspace != nil {
                Button { model.newDocument() } label: { MatildeIcon.newDocument.image(size: MatildeIcon.toolbarSize) }
                    .buttonStyle(FloatingIconButtonStyle())
                    .help("New document · ⌘N").accessibilityLabel("New document")
            }
            if model.active != nil {
                Button { model.boardRequest += 1 } label: { (model.boardVisible ? MatildeIcon.document : .board).image(size: MatildeIcon.toolbarSize) }
                    .buttonStyle(FloatingIconButtonStyle())
                    .help(model.boardVisible ? "Return to draft · ⌘0" : "Show draft board · ⌘0")
                    .accessibilityLabel(model.boardVisible ? "Return to draft" : "Show draft board")
                AskMatildeControl(model: model, review: model.review)
                StashButton(stash: model.stash).disabled(model.boardFlight != nil || model.isBranching)
                Menu {
                    Button("Branch Draft") { model.branch() }
                    Button("Rename…") { model.sheet = .rename }
                    Button("Writing Goal…") { model.sheet = .goal }
                    Divider()
                    Menu("Compare Side by Side") {
                        ForEach(model.drafts.filter { $0.id != model.active?.id }) { draft in
                            Button(draft.title) { model.compare(draft) }
                        }
                    }.disabled(model.drafts.count < 2 || model.isBranching || model.boardFlight != nil)
                    Button("Copy Markdown", systemImage: "doc.on.doc") { model.copyMarkdown() }
                    Button("Show in Finder") { model.reveal() }
                    Divider()
                    Button("Move to Trash", role: .destructive) {
                        if let draft = model.active { model.trashDraft(draft) }
                    }.disabled(model.isBranching || model.boardFlight != nil)
                } label: { MatildeIcon.more.image(size: MatildeIcon.toolbarSize) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .foregroundStyle(Color(Paper.muted))
                .frame(width: WindowChrome.controlWidth, height: WindowChrome.controlHeight).contentShape(Rectangle())
                .help("Document actions").accessibilityLabel("Document actions")
            }
        }
        .padding(WindowChrome.clusterPadding)
        // Same paper as the canvas: invisible at rest, keeps icons legible over scrolled text.
        .background(Color(Paper.background).opacity(model.boardVisible ? 0.9 : 0.8), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { chrome.hover($0) }
        .opacity(chrome.hidden ? 0 : 1)
        .animation(chromeAnimation, value: chrome.hidden)
        .padding(.top, WindowChrome.controlTop - WindowChrome.clusterPadding).padding(.trailing, WindowChrome.clusterTrailing)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row: the traffic lights and the sidebar toggle float here.
            WindowDragArea().frame(height: WindowChrome.headerHeight)
            HStack(spacing: 6) {
                MatildeIcon.search.image(size: 14)
                TextField("Search", text: $model.search).textFieldStyle(.plain)
                    .onExitCommand { model.search = "" }
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { MatildeIcon.clear.image(size: 15) }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }.font(.system(size: 12)).foregroundStyle(Color(Paper.muted))
                .padding(.horizontal, 9).frame(height: 28)
                .background(Color(Paper.ink).opacity(0.045), in: RoundedRectangle(cornerRadius: 5))
                .padding(.horizontal, WindowChrome.sidebarContentInset).padding(.bottom, 8)
            HStack(spacing: 6) {
                Text("Documents").font(.system(size: 11, weight: .medium))
                Spacer()
                Button { newNote(in: "") } label: { sidebarIcon(.newDocument) }
                    .help("New document").accessibilityLabel("New document")
                Button { model.sheet = .folder } label: { sidebarIcon(.newFolder) }
                    .help("New folder").accessibilityLabel("New folder")
            }.buttonStyle(.plain).foregroundStyle(Color(Paper.muted))
                .padding(.horizontal, 16).frame(height: 30).padding(.top, 4)
                .background(dropHighlight("").padding(.horizontal, 8))
                .sidebarFrame(SidebarDropPlanner.headerKey(""))
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    // The same order Next/Previous Note walks through.
                    ForEach(visibleSections) { section in
                        let folder = section.folder
                        VStack(alignment: .leading, spacing: 1) {
                            if !folder.isEmpty { folderRow(folder) }
                            ForEach(section.groups) { group in
                                draftRow(group, folder: folder).id(group.id)
                            }
                        }
                        .sidebarFrame(SidebarDropPlanner.sectionKey(folder))
                    }
                }.padding(.horizontal, 8).padding(.bottom, 12)
            }
            .onChange(of: model.active?.family) { _, family in
                // Keep the open note's row in view, e.g. when cycling with ⌃⌘↑/↓.
                if let family { proxy.scrollTo(family) }
            }
            }
            .scrollIndicators(.hidden)
            .contextMenu { emptySidebarMenu }
            .background(SidebarKeyboardInput(view: sidebarKeyboard) {
                if let draft = model.active { model.trashDraft(draft) }
            })
            .simultaneousGesture(TapGesture().onEnded { sidebarKeyboard.window?.makeFirstResponder(sidebarKeyboard) })
            HStack {
                SettingsLink { MatildeIcon.settings.image(size: 18) }
                    .buttonStyle(.plain).foregroundStyle(Color(Paper.muted))
                    .help("Settings · ⌘,").accessibilityLabel("Settings")
                Spacer()
                SidebarFeedbackButton()
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 14)
        }
        .coordinateSpace(name: SidebarDropPlanner.space)
        .onPreferenceChange(SidebarFrameKey.self) { sidebarFrames = $0 }
        .overlay(alignment: .topLeading) { noteDragOverlay }
        .background(Color(Paper.sidebar))
    }
    private var visibleSections: [SidebarSection] {
        SidebarOrder.visible(model.drafts, folders: model.folders, collapsed: model.collapsedFolders,
                             search: model.search, order: model.sidebarOrders)
    }
    /// The insertion line and a small label following the pointer while a note is dragged.
    @ViewBuilder private var noteDragOverlay: some View {
        if let noteDrag {
            ZStack(alignment: .topLeading) {
                if let y = noteDropTarget?.lineY {
                    Capsule().fill(Color(Paper.accent))
                        .frame(width: WindowChrome.sidebarWidth - 32, height: 2)
                        .offset(x: 16, y: y - 1)
                }
                Text(noteDrag.title)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color(Paper.background), in: RoundedRectangle(cornerRadius: 6))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    .frame(maxWidth: WindowChrome.sidebarWidth - 40, alignment: .leading)
                    .fixedSize()
                    .offset(x: noteDrag.location.x + 12, y: noteDrag.location.y - 14)
            }
            .allowsHitTesting(false)
        }
    }
    private func noteDragGesture(_ group: SidebarDraftGroup, folder: String) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(SidebarDropPlanner.space))
            .onChanged { value in
                if noteDrag == nil { noteDrag = SidebarNoteDrag(family: group.id, folder: folder, title: group.root.title) }
                noteDrag?.location = value.location
                let sections = visibleSections.map { (folder: $0.folder, rows: $0.groups.map(\.id)) }
                noteDropTarget = SidebarDropPlanner.target(at: value.location, sections: sections, frames: sidebarFrames)
            }
            .onEnded { _ in
                defer { noteDrag = nil; noteDropTarget = nil }
                guard let note = noteDrag, let target = noteDropTarget else { return }
                model.placeNote(family: note.family, from: note.folder, to: target.folder, at: target.index)
                model.collapsedFolders.remove(target.folder)
            }
    }
    private func sidebarIcon(_ icon: MatildeIcon) -> some View {
        icon.image(size: 18)
            .frame(width: 18, height: 18).foregroundStyle(Color(Paper.muted))
    }
    private func folderRow(_ folder: String) -> some View {
        let collapsed = model.collapsedFolders.contains(folder) && model.search.isEmpty
        return Button {
            if model.collapsedFolders.contains(folder) { model.collapsedFolders.remove(folder) }
            else { model.collapsedFolders.insert(folder) }
        } label: {
            HStack(spacing: 8) {
                sidebarIcon(collapsed ? .folder : .folderOpen)
                Text(folder).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                Color.clear.frame(width: 18, height: 18)
                (collapsed ? MatildeIcon.chevronRight : .chevronDown).image(size: 14)
            }.foregroundStyle(Color(Paper.muted)).padding(.horizontal, 8).frame(height: 30).contentShape(Rectangle())
        }.buttonStyle(.plain).help(folder)
            .overlay(alignment: .trailing) {
                Button { newNote(in: folder) } label: { sidebarIcon(.plus) }
                    .buttonStyle(.plain)
                    .help("New document in \(folder)").accessibilityLabel("New document in \(folder)")
                    .padding(.trailing, 22)
                    .opacity(hoveredFolder == folder ? 1 : 0)
                    .allowsHitTesting(hoveredFolder == folder)
            }
            .onHover { inside in
                if inside { hoveredFolder = folder } else if hoveredFolder == folder { hoveredFolder = nil }
            }
            .contextMenu { folderMenu(folder) }
            .background(dropHighlight(folder))
            .sidebarFrame(SidebarDropPlanner.headerKey(folder))
    }
    @ViewBuilder private var emptySidebarMenu: some View {
        Button("New Document") { newNote(in: "") }
        Button("New Folder…") { model.presentFolderSheet(.folder, folder: "") }
    }
    @ViewBuilder private func folderMenu(_ folder: String) -> some View {
        let busy = model.isBranching || model.boardFlight != nil
        Button("New Document") { newNote(in: folder) }
        Button("New Folder…") { model.presentFolderSheet(.folder, folder: folder) }
        Divider()
        Button("Rename…") { model.presentFolderSheet(.renameFolder, folder: folder) }
        Button("Show in Finder") { model.revealFolder(folder) }
        Divider()
        Button("Expand All Folders") { model.collapsedFolders = [] }
            .disabled(model.collapsedFolders.isEmpty)
        Button("Collapse All Folders") { model.collapsedFolders = Set(model.folders.filter { !$0.isEmpty }) }
            .disabled(model.folders.allSatisfy { $0.isEmpty || model.collapsedFolders.contains($0) })
        Divider()
        Button("Move to Trash…", role: .destructive) { folderToTrash = folder }.disabled(busy)
    }
    @ViewBuilder private func noteMenu(_ target: Draft, folder: String, selected: Bool) -> some View {
        let busy = model.isBranching || model.boardFlight != nil
        let branch = Button("Branch Draft") { model.branch(from: target) }.disabled(busy)
        if selected { branch.keyboardShortcut("b", modifiers: [.command, .shift]) } else { branch }
        Button("Duplicate") { model.duplicate(target) }.disabled(busy)
        Button("Rename…") { model.present(.rename, for: target) }.disabled(busy)
        Button("Writing Goal…") { model.present(.goal, for: target) }.disabled(busy)
        Divider()
        Button("Compare Side by Side") { model.compare(target) }
            .disabled(target.id == model.active?.id || busy)
        Menu("Move To") {
            ForEach(SidebarActions.moveTargets(folders: model.folders, from: folder), id: \.self) { destination in
                Button(destination.isEmpty ? "Documents" : destination) {
                    model.moveNote(family: target.family, from: folder, to: destination)
                    model.collapsedFolders.remove(destination)
                }
            }
        }.disabled(busy || SidebarActions.moveTargets(folders: model.folders, from: folder).isEmpty)
        Divider()
        Button("Show in Finder") { model.reveal(target) }
        Button("Copy Markdown") { model.copyMarkdown(of: target) }
        Button("Copy Path") { model.copyPath(of: target) }
        Divider()
        let trash = Button("Move ‘\(target.title)’ to Trash", role: .destructive) { model.trashDraft(target) }.disabled(busy)
        if selected { trash.keyboardShortcut(.delete, modifiers: .command) } else { trash }
    }
    private func newNote(in folder: String) {
        model.collapsedFolders.remove(folder)
        model.newDocument(in: folder)
    }
    private func dropHighlight(_ folder: String) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color(Paper.accent).opacity(noteDropTarget?.onHeader == true && noteDropTarget?.folder == folder ? 0.12 : 0))
    }
    /// The goal when there is one, else the start of the note's text, else "No goal set".
    private func sidebarSubtitle(_ draft: Draft) -> String {
        let goal = draft.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !goal.isEmpty { return goal.split(whereSeparator: \.isNewline).joined(separator: " ") }
        let preview = model.preview(for: draft)
        return preview.isEmpty ? "No goal set" : preview
    }
    private func draftRow(_ group: SidebarDraftGroup, folder: String) -> some View {
        let draft = group.root
        let selected = model.active?.family == group.id
        var datedDraft = draft
        datedDraft.editedAt = group.latestEdit
        return Button {
            sidebarKeyboard.window?.makeFirstResponder(sidebarKeyboard)
            model.selectFamily(group.id)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(draft.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    if !group.branches.isEmpty {
                        HStack(spacing: 3) {
                            MatildeIcon.branch.image(size: 14)
                            Text("\(group.branches.count)")
                        }
                            .font(.system(size: 11)).foregroundStyle(Color(Paper.muted)).fixedSize()
                            .accessibilityLabel("\(group.branches.count) alternate drafts")
                            .help("\(group.branches.count) alternate drafts · Switch drafts on the draft board (⌘0)")
                    }
                }
                HStack(spacing: 8) {
                    Text(sidebarSubtitle(draft))
                        .font(.system(size: 12)).foregroundStyle(Color(Paper.muted))
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    DraftTimestamp(draft: datedDraft, compact: true).fixedSize()
                }.frame(height: 14, alignment: .leading)
            }.padding(.horizontal, 8).padding(.vertical, 9)
                .background(Color(Paper.ink).opacity(selected ? 0.075 : hoveredDraft == draft.id ? 0.035 : 0), in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(draft.path + "\n" + DraftDateFormat.details(datedDraft))
            .contextMenu {
                let target = selected ? model.active : (try? model.workspace?.lastFamilyDraft(group.id, among: model.drafts))
                if let target { noteMenu(target, folder: folder, selected: selected) }
            }
            .onHover { hoveredDraft = $0 ? draft.id : nil }
            .opacity(noteDrag?.family == group.id ? 0.4 : 1)
            .simultaneousGesture(noteDragGesture(group, folder: folder))
            .sidebarFrame(SidebarDropPlanner.rowKey(group.id))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func writingSpace(_ draft: Draft) -> some View {
        GeometryReader { geometry in
            ZStack {
                if model.boardVisible {
                    DraftBoard(model: model, open: model.openBoardDraft)
                        .allowsHitTesting(model.boardFlight == nil)
                }
                BoardPageSurface(amount: boardAmount, size: geometry.size,
                                 target: model.sheetRect(draft.id, in: geometry.size),
                                 sheet: model.boardSheets.first { $0.id == draft.id },
                                 editor: writing(draft, width: geometry.size.width))
                    .opacity(model.boardVisible && model.boardFlight == nil ? 0 : 1)
                    .allowsHitTesting(!model.boardVisible)
                    .accessibilityHidden(model.boardVisible)
            }
            .overlay {
                WritingReviewPane(model: model, review: model.review, comments: model.comments)
            }
            .overlay(alignment: .bottomTrailing) {
                StashPocket(stash: model.stash, size: CGSize(width: geometry.size.width,
                                                             height: geometry.size.height - WindowChrome.headerHeight))
                    .opacity(model.boardFlight == nil && !model.isBranching ? 1 : 0)
                    .allowsHitTesting(model.boardFlight == nil && !model.isBranching)
            }
            .clipped()
            .background(WritingPinchInput(enabled: !model.boardVisible && !model.isBranching && model.boardFlight == nil,
                                          changed: updateWritingPinch))
            .onAppear { model.boardSize = geometry.size; model.reduceBoardMotion = reduceMotion }
            .onChange(of: geometry.size) { _, size in model.boardSize = size }
            .onChange(of: reduceMotion) { _, value in model.reduceBoardMotion = value }
            .onChange(of: model.boardRequest) { _, _ in model.toggleBoard() }
            .onChange(of: model.boardFlight?.id) { _, _ in animateBoardFlight() }
            .onChange(of: model.boardFlight?.interactive) { _, _ in animateBoardFlight() }
            .onChange(of: model.editorReadyID) { _, _ in animateBoardFlight() }
            .task(id: model.boardFlight?.id) {
                var previous = ProcessInfo.processInfo.systemUptime
                while !Task.isCancelled, model.boardFlight?.interactive == true {
                    do { try await Task.sleep(for: .milliseconds(8)) } catch { return }
                    guard !Task.isCancelled, model.boardFlight?.interactive == true else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    var transaction = Transaction(); transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        boardAmount = reduceMotion ? 0 : WritingPinch.advance(boardAmount, toward: pinchTarget,
                                                                             elapsed: now - previous)
                    }
                    previous = now
                }
            }
            .onChange(of: model.boardVisible) { _, visible in
                if model.boardFlight == nil {
                    var transaction = Transaction(); transaction.disablesAnimations = true
                    withTransaction(transaction) { boardAmount = visible ? 1 : 0 }
                }
                if !visible && !sidebarFocused {
                    DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(findWritingView(NSApp.keyWindow?.contentView)) }
                }
            }
        }
    }
    private func animateBoardFlight() {
        guard let flight = model.boardFlight, animatingFlightID != flight.id,
              !flight.interactive,
              !flight.opening || model.editorReadyID == flight.draftID else { return }
        animatingFlightID = flight.id
        let animation: Animation = flight.opening
            ? .timingCurve(0.2, 0.65, 0.25, 1, duration: 0.34)
            : .timingCurve(1.0 / 3, 1, 2.0 / 3, 1, duration: WritingPinch.settleDuration(from: boardAmount))
        withAnimation(reduceMotion ? nil : animation, completionCriteria: .removed) {
            boardAmount = flight.opening ? 0 : 1
        } completion: {
            model.finishBoardFlight(flight.id)
            if animatingFlightID == flight.id { animatingFlightID = nil }
        }
    }
    private func updateWritingPinch(_ total: CGFloat, _ phase: NSEvent.Phase) {
        let ending = phase == .ended || phase == .cancelled
        if model.boardFlight == nil && !ending && WritingPinch.progress(total) > 0 {
            model.showBoard(interactive: true)
        }
        guard var flight = model.boardFlight, flight.interactive else { return }
        if ending {
            flight.opening = phase == .cancelled || !WritingPinch.commits(total)
            flight.interactive = false
            model.boardFlight = flight
        } else {
            pinchTarget = WritingPinch.progress(total)
        }
    }
    private func writing(_ draft: Draft, width: CGFloat) -> some View {
        CommentMarginColumn(review: model.review, comments: model.comments, draftID: draft.id, width: width) { writingEditor(draft) }
        .background(PageCapture { model.capturePage = $0 })
        .overlay {
            if let moment = model.branchMoment { TearAwayPage(moment: moment).id(moment.id) }
        }
        .clipped()
    }
    private func writingEditor(_ draft: Draft) -> some View {
            MarkdownEditor(draftID: draft.id, text: model.text, initialCursor: model.initialPosition(for: draft).cursor, initialScroll: model.initialPosition(for: draft).scroll, onChange: model.edited, onPosition: model.position, focusOnLoad: model.focusTitleID != draft.id && !model.boardVisible && !sidebarFocused, onReady: { model.editorReadyID = $0 }, header: AnyView(writingHeader(draft)), saveImage: { data in
                guard let workspace = model.workspace else { throw WorkspaceError.message("Open a workspace first.") }
                return try workspace.importImage(data, beside: draft)
            }, resolveImage: { model.workspace?.image(at: $0, beside: draft) }, mediaError: { model.error = $0 },
                           textSize: writingTextSize, lineSpacing: writingLineSpacing, spellChecking: writingSpellChecking, differenceRanges: model.comparisonDifferences,
                           onAskSelection: { range in
                               if let range { model.review.beginSelection(range, input: model.reviewInput) } else { model.reviewNow() }
                           },
                           commentStore: model.comments, placeholder: EditorLanding.bodyPlaceholder)
    }
    private func writingHeader(_ draft: Draft) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 15) {
                InlineTitle(model: model, draftID: draft.id) {
                    guard let window = NSApp.keyWindow,
                          let editor = findWritingView(window.contentView) as? WritingTextView else { return }
                    window.makeFirstResponder(editor)
                    editor.scrollRangeToVisible(editor.selectedRange())
                }.id(draft.id)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Match the body's left edge: text inset (28) plus line-fragment padding (5).
            .padding(.horizontal, 33).padding(.top, WindowChrome.canvasTopInset).padding(.bottom, 10).frame(maxWidth: CommentMargin.maximumColumn)
        }
    }
    private func findWritingView(_ root: NSView?) -> NSView? {
        guard let root else { return nil }
        if let editor = root as? WritingTextView, editor.onEscape == nil { return editor }
        return root.subviews.lazy.compactMap { findWritingView($0) }.first
    }
    private var welcome: some View {
        VStack(spacing: 22) {
            Text("Matilde").font(.system(size: 28, weight: .semibold))
            VStack(spacing: 13) {
                Button("Start writing") { model.startWriting() }.buttonStyle(.borderedProminent).controlSize(.large)
                Button("Choose another folder…") { model.chooseWorkspace() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color(Paper.muted))
            }.padding(.top, 15)
            Text("Documents/Matilde").font(.system(size: 11)).foregroundStyle(Color(Paper.muted)).padding(.top, 5)
        }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var emptyWorkspace: some View {
        VStack(spacing: 18) {
            Text("No Documents").font(.system(size: 20, weight: .semibold))
            Button("Create a document") { model.newDocument() }.buttonStyle(.borderedProminent).controlSize(.large)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct InlineTitle: View {
    @ObservedObject var model: AppModel
    let draftID: String
    var focusBody: () -> Void
    enum Field: Hashable { case title, goal }
    @FocusState private var focused: Field?
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            TextField("Untitled", text: Binding(
                get: { model.headerTitle }, set: { model.editHeader(title: $0) }
            ), axis: .vertical)
            .textFieldStyle(.plain).font(Font(Paper.body(31, bold: true)))
            .fixedSize(horizontal: false, vertical: true)
            .focused($focused, equals: .title).accessibilityLabel("Document title")
            .onKeyPress(keys: [.downArrow, .return, .tab], phases: .down) { press in
                guard press.modifiers.intersection([.shift, .control, .option, .command]).isEmpty else { return .ignored }
                focused = .goal
                return .handled
            }
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                MatildeIcon.goal.image(size: 17).iconBaseline().foregroundStyle(Color(Paper.muted))
                TextField("What do you want to write?", text: Binding(
                    get: { model.headerGoal }, set: { model.editHeader(goal: $0) }
                ), axis: .vertical)
                .textFieldStyle(.plain).font(Font(Paper.body())).lineLimit(1...5)
                .foregroundStyle(Color(Paper.muted)).accessibilityLabel("Writing goal")
                .focused($focused, equals: .goal)
                .onKeyPress(keys: [.upArrow, .downArrow, .return, .tab], phases: .down) { press in
                    guard press.modifiers.intersection([.shift, .control, .option, .command]).isEmpty else { return .ignored }
                    if press.key == .upArrow { focused = .title }
                    else {
                        model.attempt { try model.flush() }
                        focused = nil
                        // Let SwiftUI resign the field before claiming the native editor.
                        DispatchQueue.main.async { focusBody() }
                    }
                    return .handled
                }
            }
        }
        .onAppear {
            if model.focusTitleID == draftID {
                DispatchQueue.main.async { focused = .title }
            }
        }
        .onChange(of: focused) { old, value in
            if old == .title && value != .title {
                model.focusTitleID = nil; model.attempt { try model.flush() }
            }
        }
    }
}

struct DocumentSheet: View {
    @ObservedObject var model: AppModel
    let kind: AppModel.Sheet
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var goal = ""
    @State private var folder = ""
    @State private var renamedFolder = ""
    @State private var error: String?
    @FocusState private var focused: Bool
    var title: String {
        switch kind { case .document: "New Document"; case .folder: "New Folder"; case .rename: "Rename Document"; case .goal: "Writing Goal"; case .renameFolder: "Rename Folder" }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title).font(.system(size: 18, weight: .semibold))
            if kind != .goal {
                VStack(alignment: .leading, spacing: 7) {
                    Text(kind == .folder || kind == .renameFolder ? "Folder name" : "Document name").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField(kind == .folder || kind == .renameFolder ? "Essays" : "Untitled", text: $name).textFieldStyle(.roundedBorder).focused($focused).onSubmit { submit() }
                }
            }
            if kind == .document || kind == .folder {
                Picker("Folder", selection: $folder) {
                    ForEach(model.folders, id: \.self) { Text($0.isEmpty ? "Workspace" : $0).tag($0) }
                }
            }
            if kind == .document || kind == .goal {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Writing goal · optional").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextEditor(text: $goal).font(.system(size: 13)).scrollContentBackground(.hidden).padding(7).frame(height: 90).background(Color(Paper.background), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(kind == .document ? "Start writing" : kind == .folder ? "Create folder" : "Save") { submit() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(kind != .goal && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(32).frame(width: 460).background(Color(Paper.background))
            .onAppear {
                folder = model.sheetFolder ?? model.active?.folder ?? ""
                model.sheetFolder = nil
                if kind == .renameFolder { renamedFolder = folder; name = (folder as NSString).lastPathComponent }
                if kind == .rename { name = model.active?.title ?? "" }
                if kind == .goal { goal = model.active?.goal ?? "" }
                focused = true
            }
    }
    private func submit() {
        do {
            switch kind {
            case .document: try model.create(name: name, folder: folder, goal: goal)
            case .folder: try model.createFolder(name: name, parent: folder)
            case .renameFolder: try model.renameFolder(renamedFolder, to: name)
            case .rename: try model.rename(name)
            case .goal: try model.setGoal(goal)
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

/// Stash sits with the window controls so the writing margin stays free for comment cards.
private struct StashButton: View {
    @ObservedObject var stash: StashModel
    var body: some View {
        Button { stash.toggle() } label: { MatildeIcon.stash.image(size: MatildeIcon.toolbarSize) }
            .buttonStyle(FloatingIconButtonStyle(selected: stash.isOpen))
            .help("Stash · ⇧⌘J").accessibilityLabel("Stash")
            .accessibilityAddTraits(stash.isOpen ? .isSelected : [])
    }
}

/// Ask Matilde's window control: click to review the draft (or cancel), open the menu for more.
private struct AskMatildeControl: View {
    @ObservedObject var model: AppModel
    @ObservedObject var review: WritingReviewModel
    private var reviewing: Bool { review.isRunning && review.replyingTo == nil }
    private var unavailable: Bool { model.boardVisible || model.isBranching || model.boardFlight != nil }
    var body: some View {
        HStack(spacing: 4) {
            if reviewing { ProgressView().controlSize(.small).accessibilityLabel("Reviewing") }
            menu
        }
    }
    private var menu: some View {
        Menu {
            Button("Ask Matilde…") {
                NSApp.sendAction(#selector(WritingTextView.askAboutSelection), to: nil, from: nil)
            }.keyboardShortcut("a", modifiers: [.command, .shift]).disabled(model.boardVisible)
            Button(reviewing ? "Cancel review" : "Review now") { toggleReview() }.disabled(unavailable && !reviewing)
            Divider()
            Button(review.automaticPaused ? "Resume automatic reviews" : "Pause automatic reviews") { review.toggleAutomatic() }
            Button("Review history…") { review.historyVisible = true }.disabled(review.history.isEmpty)
        } label: {
            (review.error != nil ? MatildeIcon.askMatildeError : reviewing ? .stop : .askMatilde).image(size: MatildeIcon.toolbarSize)
        } primaryAction: { toggleReview() }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(Color(Paper.muted))
        .frame(height: 24).padding(.horizontal, 4).contentShape(Rectangle())
        .help(review.error ?? (reviewing ? "Cancel review" : "Ask Matilde"))
        .accessibilityLabel("Ask Matilde")
    }
    private func toggleReview() {
        if reviewing { review.cancel() } else if !unavailable { model.reviewNow() }
    }
}

/// Centers the writing column. With margin cards, the text and card column are centered together
/// as one group, with the same whitespace on both outer edges.
private struct CommentMarginColumn<Content: View>: View {
    @ObservedObject var review: WritingReviewModel
    @ObservedObject var comments: UserCommentStore
    let draftID: String
    let width: CGFloat
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The draft the current margin layout belongs to. Switching notes re-centers the column
    /// immediately; only adding or removing comments within a draft slides it.
    @State private var layoutDraftID: String?
    private var hasComments: Bool {
        if let run = review.history.first, !run.stale, run.comments.contains(where: { $0.status == "open" }) { return true }
        let opening = comments.marginRequest?.id
        return comments.comments.contains { $0.attached && (!$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.id == comments.activeID || $0.id == opening) }
    }
    private var fits: Bool { CommentMargin.fits(width: width) }
    var body: some View {
        let reserve = hasComments && fits
        let layout = CommentMargin.layout(width: width, reserve: reserve)
        content()
            .frame(width: layout.column)
            .padding(.leading, layout.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(reduceMotion || layoutDraftID != draftID ? nil : .easeOut(duration: 0.22), value: reserve)
            .onChange(of: fits, initial: true) { _, value in comments.marginVisible = value }
            .onChange(of: draftID, initial: true) { _, value in layoutDraftID = value }
    }
}
