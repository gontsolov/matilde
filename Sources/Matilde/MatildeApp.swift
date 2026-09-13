import SwiftUI
import AppKit

@main
struct MatildeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("Matilde", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 760, minHeight: 520)
                .preferredColorScheme(.light)
                .onAppear { delegate.model = model; NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1180, height: 820)
        .windowStyle(.titleBar)
        .commands {
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
                Button("Branch Draft") { model.branch() }.keyboardShortcut("b", modifiers: [.command, .shift]).disabled(model.active == nil)
                Button("Writing Goal…") { model.sheet = .goal }.disabled(model.active == nil)
                Divider()
                Button(model.sidebar ? "Enter Focus Mode" : "Leave Focus Mode") { model.toggleSidebar() }.keyboardShortcut("\\", modifiers: .command)
            }
        }
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
    @ObservedObject var model: AppModel
    @State private var collapsedFolders: Set<String> = []
    @State private var hoveredDraft: String?
    @State private var searchVisible = false
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draftsVisible = false
    var body: some View {
        HStack(spacing: 0) {
            if model.workspace != nil && model.sidebar {
                sidebar.frame(width: 244)
                Rectangle().fill(Color(Paper.ink).opacity(0.09)).frame(width: 1)
            }
            VStack(spacing: 0) {
                if model.workspace == nil { welcome }
                else {
                    if let draft = model.active { writing(draft) }
                    else { emptyWorkspace }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
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
            ToolbarItemGroup(placement: .primaryAction) {
                if model.workspace != nil {
                    Button { model.newDocument() } label: { Image(systemName: "square.and.pencil") }
                        .help("New document").accessibilityLabel("New document")
                }
                if model.active != nil {
                    Menu {
                        Button("Branch Draft") { model.branch() }
                        Button("Rename…") { model.sheet = .rename }
                        Button("Writing Goal…") { model.sheet = .goal }
                        Divider()
                        Button("Show in Finder") { model.reveal() }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .help("Document actions").accessibilityLabel("Document actions")
                }
            }
        }
        .sheet(item: $model.sheet) { kind in DocumentSheet(model: model, kind: kind) }
        .alert("Matilde", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Menu {
                    Button("Choose Folder…") { model.chooseWorkspace() }
                    Button("Show in Finder") {
                        if let root = model.workspace?.root { NSWorkspace.shared.activateFileViewerSelecting([root]) }
                    }
                } label: {
                    HStack(spacing: 7) {
                        Text(model.workspace?.root.lastPathComponent ?? "Matilde")
                            .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium)).foregroundStyle(Color(Paper.muted))
                    }
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button {
                    searchVisible.toggle()
                    if searchVisible { searchFocused = true } else { model.search = "" }
                } label: { sidebarIcon("magnifyingglass") }
                .help("Search documents").accessibilityLabel("Search documents")
            }.buttonStyle(.plain).padding(.horizontal, 16).frame(height: 48)
            if searchVisible {
                HStack(spacing: 6) {
                    TextField("Search", text: $model.search).textFieldStyle(.plain)
                        .focused($searchFocused).onExitCommand { model.search = ""; searchVisible = false }
                    if !model.search.isEmpty {
                        Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                }.font(.system(size: 12)).foregroundStyle(Color(Paper.muted))
                    .padding(.horizontal, 9).frame(height: 28)
                    .background(Color(Paper.ink).opacity(0.045), in: RoundedRectangle(cornerRadius: 5))
                    .padding(.horizontal, 12).padding(.bottom, 12)
            }
            HStack {
                Text("Documents").font(.system(size: 11, weight: .medium))
                Spacer()
                Button { model.sheet = .folder } label: { sidebarIcon("folder.badge.plus") }
                    .help("New folder").accessibilityLabel("New folder")
            }.buttonStyle(.plain).foregroundStyle(Color(Paper.muted))
                .padding(.horizontal, 16).frame(height: 30).padding(.top, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(model.folders, id: \.self) { folder in
                        let items = model.drafts.filter { $0.folder == folder && (model.search.isEmpty || $0.title.localizedCaseInsensitiveContains(model.search)) }
                        if !items.isEmpty || model.search.isEmpty {
                            VStack(alignment: .leading, spacing: 1) {
                                if !folder.isEmpty {
                                    Button {
                                        if collapsedFolders.contains(folder) { collapsedFolders.remove(folder) }
                                        else { collapsedFolders.insert(folder) }
                                    } label: {
                                        HStack(spacing: 8) {
                                            sidebarIcon(collapsedFolders.contains(folder) && model.search.isEmpty ? "folder" : "folder.fill")
                                            Text(folder).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                            Spacer(minLength: 0)
                                            Image(systemName: collapsedFolders.contains(folder) && model.search.isEmpty ? "chevron.right" : "chevron.down")
                                                .font(.system(size: 8, weight: .medium))
                                        }.foregroundStyle(Color(Paper.muted)).padding(.horizontal, 8).frame(height: 30).contentShape(Rectangle())
                                    }.buttonStyle(.plain).help(folder)
                                }
                                if folder.isEmpty || !collapsedFolders.contains(folder) || !model.search.isEmpty {
                                    ForEach(items.filter { candidate in
                                        let family = items.filter { $0.family == candidate.family }
                                        return (family.first { $0.parent == nil } ?? family.first)?.id == candidate.id
                                    }) { root in
                                        draftRow(root, indented: false)
                                        ForEach(items.filter { $0.family == root.family && $0.id != root.id }) { branch in draftRow(branch, indented: true) }
                                    }
                                }
                            }
                        }
                    }
                }.padding(.horizontal, 8).padding(.bottom, 12)
            }
        }.background(Color(red: 0.955, green: 0.949, blue: 0.933))
    }
    private func sidebarIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 13, weight: .regular))
            .frame(width: 18, height: 18).foregroundStyle(Color(Paper.muted))
    }
    private func draftRow(_ draft: Draft, indented: Bool) -> some View {
        let selected = model.active?.id == draft.id
        return Button { model.select(draft) } label: {
            HStack(spacing: 8) {
                sidebarIcon(indented ? "arrow.turn.down.right" : "doc.text")
                Text(draft.title).font(.system(size: 13, weight: selected ? .medium : .regular)).lineLimit(1)
                Spacer(minLength: 0)
            }.padding(.leading, indented ? 26 : 8).padding(.trailing, 8).frame(height: 30)
                .background(Color(Paper.ink).opacity(selected ? 0.075 : hoveredDraft == draft.id ? 0.035 : 0), in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(draft.path)
            .onHover { hoveredDraft = $0 ? draft.id : nil }
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func writing(_ draft: Draft) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 8) {
                    InlineTitle(model: model, draftID: draft.id).id(draft.id)
                    Spacer()
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
                }
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Image(systemName: "flag").font(.system(size: 13)).foregroundStyle(Color(Paper.muted))
                    TextField("What do you want to write?", text: Binding(
                        get: { model.headerGoal }, set: { model.editHeader(goal: $0) }
                    ), axis: .vertical)
                    .textFieldStyle(.plain).font(Font(Paper.body())).lineLimit(1...5)
                    .foregroundStyle(Color(Paper.muted)).accessibilityLabel("Writing goal")
                }
            }.padding(.horizontal, 28).padding(.top, 29).padding(.bottom, 10).frame(maxWidth: 736)
            if draftsVisible {
                DraftTray(model: model) {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) { draftsVisible = false }
                    DispatchQueue.main.async {
                        NSApp.keyWindow?.makeFirstResponder(findWritingView(NSApp.keyWindow?.contentView))
                    }
                }.transition(.opacity.combined(with: .move(edge: .top)))
            }
            MarkdownEditor(draftID: draft.id, text: model.text, initialCursor: draft.cursor, initialScroll: draft.scroll, onChange: model.edited, onPosition: model.position, focusOnLoad: model.focusTitleID != draft.id && !draftsVisible)
                .frame(maxWidth: 736).frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                Text("\(model.wordCount) words")
                Spacer()
                Circle().fill(Color(Paper.muted).opacity(0.6)).frame(width: 4, height: 4)
                Text(model.branchMoment.map { "Branched from \($0.sourceTitle)" } ?? model.status).lineLimit(1)
            }.font(.system(size: 10)).foregroundStyle(Color(Paper.muted)).padding(.horizontal, 34).frame(height: 40)
        }
        .background(PageCapture { model.capturePage = $0 })
        .overlay {
            if let moment = model.branchMoment { TearAwayPage(moment: moment).id(moment.id) }
        }
        .clipped()
        .onChange(of: model.active?.id) { _, _ in draftsVisible = false }
    }
    private func findWritingView(_ root: NSView?) -> NSView? {
        guard let root else { return nil }
        if root is WritingTextView { return root }
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
    @FocusState private var focused: Bool
    var body: some View {
        TextField("Untitled", text: Binding(
            get: { model.headerTitle }, set: { model.editHeader(title: $0) }
        ))
        .textFieldStyle(.plain).font(Font(Paper.body(31, bold: true)))
        .focused($focused).accessibilityLabel("Document title")
        .onAppear {
            if model.focusTitleID == draftID {
                DispatchQueue.main.async { focused = true }
            }
        }
        .onChange(of: focused) { _, value in
            if !value { model.focusTitleID = nil; model.attempt { try model.flush() } }
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
                    TextEditor(text: $goal).font(.system(size: 13)).scrollContentBackground(.hidden).padding(7).frame(height: 90).background(.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
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
