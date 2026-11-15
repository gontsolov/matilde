import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
                .onAppear { delegate.model = model; NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1180, height: 820)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Document") { model.newDocument() }.keyboardShortcut("n").disabled(model.workspace == nil)
                Button("New Folder…") { model.sheet = .folder }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(model.workspace == nil)
                Divider()
                Button("Open Workspace…") { model.chooseWorkspace() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.attempt { try model.flush() } }.keyboardShortcut("s").disabled(model.active == nil)
                Button("Rename Document…") { model.sheet = .rename }.disabled(model.active == nil)
            }
            CommandMenu("Writing") {
                Button("Checkbox") {
                    NSApp.sendAction(#selector(WritingTextView.insertCheckbox(_:)), to: nil, from: nil)
                }.keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(model.active == nil || model.boardVisible)
                Divider()
                Button("Ask Matilde…") {
                    NSApp.sendAction(#selector(WritingTextView.askAboutSelection), to: nil, from: nil)
                }.keyboardShortcut("a", modifiers: [.command, .shift]).disabled(model.active == nil || model.boardVisible)
                Button("Add Comment") {
                    NSApp.sendAction(#selector(WritingTextView.addUserComment(_:)), to: nil, from: nil)
                }.keyboardShortcut("k", modifiers: [.command, .shift]).disabled(model.active == nil || model.boardVisible)
                Button("Branch Draft") { model.branch() }.keyboardShortcut("b", modifiers: [.command, .shift]).disabled(model.active == nil || model.boardVisible)
                Button(model.boardVisible ? "Return to Draft" : "Show Draft Board") { model.boardRequest += 1 }.keyboardShortcut("0").disabled(model.active == nil)
                Button("Toggle Stash") { model.stash.toggle() }.keyboardShortcut("j", modifiers: [.command, .shift]).disabled(model.active == nil || model.boardFlight != nil || model.isBranching)
                Button("Reveal Stash in Finder") { model.stash.reveal() }.disabled(model.active == nil)
                Button("Reload Stash from Disk") { model.stash.reloadPreservingChanges() }.disabled(model.active == nil)
                Button("Show All Stashes in Finder") { model.stash.reveal(all: true) }.disabled(model.workspace == nil)
                Button("Review now") { model.reviewNow() }.disabled(model.active == nil || model.boardVisible || model.isBranching)
                Button("Writing Goal…") { model.sheet = .goal }.disabled(model.active == nil)
                Divider()
                Button(model.sidebar ? "Enter Focus Mode" : "Leave Focus Mode") { model.toggleSidebar() }.keyboardShortcut("\\", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("Welcome to Matilde") { model.showWelcomeDocument() }.disabled(model.workspace == nil)
            }
        }
        Settings { AppSettingsView().scrollIndicators(.hidden) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        do { try model?.flush(); return .terminateNow }
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
    @State private var collapsedFolders: Set<String> = []
    @State private var hoveredDraft: String?
    @State private var hoveredFolder: String?
    @State private var draggedNote: SidebarNoteDrag?
    @State private var dropFolder: String?
    @State private var sidebarKeyboard = SidebarKeyboardView()
    private var sidebarFocused: Bool { sidebarKeyboard.window?.firstResponder === sidebarKeyboard }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var headerCollapsed = false
    @State private var draftsVisible = false
    @State private var boardAmount: CGFloat = 0
    @State private var pinchTarget: CGFloat = 0
    @State private var animatingFlightID: UUID?
    var body: some View {
        HStack(spacing: 0) {
            if model.workspace != nil && model.sidebar {
                sidebar.frame(width: 244)
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
            if let comparison = model.comparison {
                DraftComparisonPane(comparison: comparison, model: model).frame(minWidth: 360, maxWidth: .infinity)
            }
            }
            .background(ComparisonSplitPosition(enabled: model.comparison != nil, fraction: model.comparisonFraction,
                                                changed: { model.comparisonFraction = $0 }))
            .id(model.workspace?.root.path)
        }
        .background(Color(Paper.background))
        .foregroundStyle(Color(Paper.ink))
        .tint(Color(Paper.accent))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if model.workspace != nil {
                    Button { model.toggleSidebar() } label: { Image(systemName: "sidebar.left") }
                        .help("Toggle sidebar").accessibilityLabel("Toggle sidebar")
                }
            }
            ToolbarItem(placement: .principal) {
                if headerCollapsed && !model.boardVisible {
                    Text(model.headerTitle.isEmpty ? "Untitled" : model.headerTitle)
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 16).frame(maxWidth: 480)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if model.workspace != nil {
                    Button { model.newDocument() } label: { Image(systemName: "square.and.pencil") }
                        .help("New document").accessibilityLabel("New document")
                }
                if model.active != nil {
                    Button { model.boardRequest += 1 } label: { Image(systemName: model.boardVisible ? "doc.text" : "square.grid.2x2") }
                        .help(model.boardVisible ? "Return to draft · ⌘0" : "Show draft board · ⌘0")
                        .accessibilityLabel(model.boardVisible ? "Return to draft" : "Show draft board")
                    AskMatildeToolbar(model: model, review: model.review)
                    StashToolbarButton(stash: model.stash).disabled(model.boardFlight != nil || model.isBranching)
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
                    } label: { Image(systemName: "ellipsis.circle") }
                    .help("Document actions").accessibilityLabel("Document actions")
                }
            }
        }
        .sheet(item: $model.sheet) { kind in DocumentSheet(model: model, kind: kind).scrollIndicators(.hidden) }
        .alert("Matilde", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11))
                TextField("Search", text: $model.search).textFieldStyle(.plain)
                    .onExitCommand { model.search = "" }
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }.font(.system(size: 12)).foregroundStyle(Color(Paper.muted))
                .padding(.horizontal, 9).frame(height: 28)
                .background(Color(Paper.ink).opacity(0.045), in: RoundedRectangle(cornerRadius: 5))
                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
            HStack(spacing: 6) {
                Text("Documents").font(.system(size: 11, weight: .medium))
                Spacer()
                Button { newNote(in: "") } label: { sidebarIcon("square.and.pencil") }
                    .help("New document").accessibilityLabel("New document")
                Button { model.sheet = .folder } label: { sidebarIcon("folder.badge.plus") }
                    .help("New folder").accessibilityLabel("New folder")
            }.buttonStyle(.plain).foregroundStyle(Color(Paper.muted))
                .padding(.horizontal, 16).frame(height: 30).padding(.top, 4)
                .background(dropHighlight(""))
                .onDrop(of: [SidebarNoteDrag.type], isTargeted: dropTarget("")) { dropNote($0, into: "") }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(model.folders, id: \.self) { folder in
                        let items = model.drafts.filter { $0.folder == folder }
                        let groups = SidebarOrder.groups(items).filter { group in
                            model.search.isEmpty || ([group.root] + group.branches).contains { $0.title.localizedCaseInsensitiveContains(model.search) }
                        }
                        if !groups.isEmpty || model.search.isEmpty {
                            VStack(alignment: .leading, spacing: 1) {
                                if !folder.isEmpty { folderRow(folder) }
                                if folder.isEmpty || !collapsedFolders.contains(folder) || !model.search.isEmpty {
                                    ForEach(groups) { group in
                                        draftRow(group, folder: folder)
                                    }
                                }
                            }
                            .background(dropHighlight(folder))
                            .onDrop(of: [SidebarNoteDrag.type], isTargeted: dropTarget(folder)) { dropNote($0, into: folder) }
                        }
                    }
                }.padding(.horizontal, 8).padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            .background(SidebarKeyboardInput(view: sidebarKeyboard) {
                if let draft = model.active { model.trashDraft(draft) }
            })
            .simultaneousGesture(TapGesture().onEnded { sidebarKeyboard.window?.makeFirstResponder(sidebarKeyboard) })
            HStack {
                SettingsLink { Image(systemName: "gearshape").font(.system(size: 14)) }
                    .buttonStyle(.plain).foregroundStyle(Color(Paper.muted))
                    .help("Settings · ⌘,").accessibilityLabel("Settings")
                Spacer()
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 14)
        }.background(Color(Paper.sidebar))
    }
    private func sidebarIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 13, weight: .regular))
            .frame(width: 18, height: 18).foregroundStyle(Color(Paper.muted))
    }
    private func folderRow(_ folder: String) -> some View {
        let collapsed = collapsedFolders.contains(folder) && model.search.isEmpty
        return Button {
            if collapsedFolders.contains(folder) { collapsedFolders.remove(folder) }
            else { collapsedFolders.insert(folder) }
        } label: {
            HStack(spacing: 8) {
                sidebarIcon(collapsed ? "folder" : "folder.fill")
                Text(folder).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                Color.clear.frame(width: 18, height: 18)
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .medium))
            }.foregroundStyle(Color(Paper.muted)).padding(.horizontal, 8).frame(height: 30).contentShape(Rectangle())
        }.buttonStyle(.plain).help(folder)
            .overlay(alignment: .trailing) {
                Button { newNote(in: folder) } label: { sidebarIcon("plus") }
                    .buttonStyle(.plain)
                    .help("New document in \(folder)").accessibilityLabel("New document in \(folder)")
                    .padding(.trailing, 22)
                    .opacity(hoveredFolder == folder ? 1 : 0)
                    .allowsHitTesting(hoveredFolder == folder)
            }
            .onHover { inside in
                if inside { hoveredFolder = folder } else if hoveredFolder == folder { hoveredFolder = nil }
            }
    }
    private func newNote(in folder: String) {
        collapsedFolders.remove(folder)
        model.newDocument(in: folder)
    }
    private func dropTarget(_ folder: String) -> Binding<Bool> {
        Binding(get: { dropFolder == folder }, set: { inside in
            if inside { dropFolder = folder } else if dropFolder == folder { dropFolder = nil }
        })
    }
    private func dropNote(_ providers: [NSItemProvider], into folder: String) -> Bool {
        defer { draggedNote = nil; dropFolder = nil }
        guard SidebarNoteDrag.accepts(providers), let note = draggedNote, note.folder != folder else { return false }
        model.moveNote(family: note.family, from: note.folder, to: folder)
        collapsedFolders.remove(folder)
        return true
    }
    private func dropHighlight(_ folder: String) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color(Paper.accent).opacity(dropFolder == folder && draggedNote != nil && draggedNote?.folder != folder ? 0.1 : 0))
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
                            Image(systemName: "arrow.triangle.branch")
                            Text("\(group.branches.count)")
                        }
                            .font(.system(size: 11)).foregroundStyle(Color(Paper.muted)).fixedSize()
                            .accessibilityLabel("\(group.branches.count) alternate drafts")
                            .help("\(group.branches.count) alternate drafts · Switch drafts above the document title")
                    }
                }
                HStack(spacing: 8) {
                    Text(draft.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? "No goal set" : draft.goal.replacingOccurrences(of: "\n", with: " "))
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
                if let target {
                    Button("Compare Side by Side") { model.compare(target) }
                        .disabled(target.id == model.active?.id || model.isBranching || model.boardFlight != nil)
                    Button("Move ‘\(target.title)’ to Trash", systemImage: "trash", role: .destructive) { model.trashDraft(target) }
                        .disabled(model.isBranching || model.boardFlight != nil)
                }
            }
            .onHover { hoveredDraft = $0 ? draft.id : nil }
            .onDrag {
                draggedNote = SidebarNoteDrag(family: group.id, folder: folder)
                return SidebarNoteDrag.provider()
            }
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
                StashPocket(stash: model.stash, size: geometry.size)
                    .opacity(model.boardFlight == nil && !model.isBranching ? 1 : 0)
                    .allowsHitTesting(model.boardFlight == nil && !model.isBranching)
            }
            .clipped()
            .background(WritingPinchInput(enabled: !model.boardVisible && !model.isBranching && model.boardFlight == nil,
                                          changed: updateWritingPinch))
            .onAppear { model.boardSize = geometry.size; model.reduceBoardMotion = reduceMotion }
            .onChange(of: geometry.size) { _, size in model.boardSize = size }
            .onChange(of: reduceMotion) { _, value in model.reduceBoardMotion = value }
            .onChange(of: model.boardRequest) { _, _ in draftsVisible = false; model.toggleBoard() }
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
            draftsVisible = false
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
        CommentMarginColumn(review: model.review, comments: model.comments, width: width) { writingEditor(draft) }
        .background(PageCapture { model.capturePage = $0 })
        .overlay {
            if let moment = model.branchMoment { TearAwayPage(moment: moment).id(moment.id) }
        }
        .clipped()
        .onChange(of: model.active?.id) { _, _ in draftsVisible = false }
    }
    private func writingEditor(_ draft: Draft) -> some View {
            MarkdownEditor(draftID: draft.id, text: model.text, initialCursor: draft.cursor, initialScroll: draft.scroll, onChange: model.edited, onPosition: model.position, focusOnLoad: model.focusTitleID != draft.id && !draftsVisible && !model.boardVisible && !sidebarFocused, onReady: { model.editorReadyID = $0 }, header: AnyView(writingHeader(draft)), onHeaderVisibility: { headerCollapsed = $0 }, saveImage: { data in
                guard let workspace = model.workspace else { throw WorkspaceError.message("Open a workspace first.") }
                return try workspace.importImage(data, beside: draft)
            }, resolveImage: { model.workspace?.image(at: $0, beside: draft) }, mediaError: { model.error = $0 },
                           textSize: writingTextSize, lineSpacing: writingLineSpacing, spellChecking: writingSpellChecking, differenceRanges: model.comparisonDifferences,
                           onAskSelection: { range in
                               if let range { model.review.beginSelection(range, input: model.reviewInput) } else { model.reviewNow() }
                           },
                           commentStore: model.comments)
    }
    private func writingHeader(_ draft: Draft) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 8) {
                    HStack(spacing: 12) {
                        Button {
                            withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) { draftsVisible.toggle() }
                        } label: {
                            HStack(spacing: 5) {
                                Text("\(model.related.count) \(model.related.count == 1 ? "draft" : "drafts")")
                                Image(systemName: draftsVisible ? "chevron.up" : "chevron.down").font(.system(size: 8))
                            }.font(.system(size: 11))
                        }.help("Show drafts").accessibilityLabel("Show drafts")
                        Button { draftsVisible = false; model.branch() } label: {
                            Image(systemName: "arrow.triangle.branch").font(.system(size: 13))
                        }.help("Branch draft · ⇧⌘B").accessibilityLabel("Branch draft").disabled(model.isBranching)
                    }.buttonStyle(.plain).foregroundStyle(Color(Paper.muted))
                    Spacer()
                }.padding(.bottom, 12)
                InlineTitle(model: model, draftID: draft.id) {
                    guard let window = NSApp.keyWindow,
                          let editor = findWritingView(window.contentView) as? WritingTextView else { return }
                    window.makeFirstResponder(editor)
                    editor.scrollRangeToVisible(editor.selectedRange())
                }.id(draft.id)
            }
            // Match the body's left edge: text inset (28) plus line-fragment padding (5).
            .padding(.horizontal, 33).padding(.top, 29).padding(.bottom, 10).frame(maxWidth: CommentMargin.maximumColumn)
            if draftsVisible {
                DraftTray(model: model) {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) { draftsVisible = false }
                    DispatchQueue.main.async {
                        NSApp.keyWindow?.makeFirstResponder(findWritingView(NSApp.keyWindow?.contentView))
                    }
                }.transition(.opacity.combined(with: .move(edge: .top)))
            }
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
                Image(systemName: "flag").font(.system(size: 13)).foregroundStyle(Color(Paper.muted))
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
    @State private var error: String?
    @FocusState private var focused: Bool
    var title: String {
        switch kind { case .document: "New Document"; case .folder: "New Folder"; case .rename: "Rename Document"; case .goal: "Writing Goal" }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title).font(.system(size: 18, weight: .semibold))
            if kind != .goal {
                VStack(alignment: .leading, spacing: 7) {
                    Text(kind == .folder ? "Folder name" : "Document name").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField(kind == .folder ? "Essays" : "Untitled", text: $name).textFieldStyle(.roundedBorder).focused($focused).onSubmit { submit() }
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
                folder = model.active?.folder ?? ""
                if kind == .rename { name = model.active?.title ?? "" }
                if kind == .goal { goal = model.active?.goal ?? "" }
                focused = true
            }
    }
    private func submit() {
        do {
            switch kind {
            case .document: try model.create(name: name, folder: folder, goal: goal)
            case .folder: try model.workspace?.createFolder(name: name, parent: folder); try model.refresh()
            case .rename: try model.rename(name)
            case .goal: try model.setGoal(goal)
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

/// Stash lives in the toolbar so the writing margin stays free for comment cards.
private struct StashToolbarButton: View {
    @ObservedObject var stash: StashModel
    var body: some View {
        Button { stash.toggle() } label: { Image(systemName: stash.isOpen ? "tray.fill" : "tray") }
            .help("Stash · ⇧⌘J").accessibilityLabel(stash.isOpen ? "Close Stash" : "Open Stash")
    }
}

/// Ask Matilde's window controls: click to review the draft (or cancel), open the menu for more.
private struct AskMatildeToolbar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var review: WritingReviewModel
    private var reviewing: Bool { review.isRunning && review.replyingTo == nil }
    private var unavailable: Bool { model.boardVisible || model.isBranching || model.boardFlight != nil }
    var body: some View {
        HStack(spacing: 6) {
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
            Image(systemName: review.error != nil ? "exclamationmark.bubble" : reviewing ? "stop.circle" : "text.bubble")
        } primaryAction: { toggleReview() }
        .fixedSize()
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
    let width: CGFloat
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: reserve)
            .onChange(of: fits, initial: true) { _, value in comments.marginVisible = value }
    }
}
