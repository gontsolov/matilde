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
                Button("New Document…") { model.sheet = .document }.keyboardShortcut("n").disabled(model.workspace == nil)
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
                    Button { model.sheet = .document } label: { Image(systemName: "square.and.pencil") }
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
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12))
                TextField("Search", text: $model.search).textFieldStyle(.plain).font(.system(size: 12))
            }.foregroundStyle(Color(Paper.muted)).padding(10).background(Color.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 7)).padding(.horizontal, 16).padding(.top, 16)
            HStack {
                Text("Documents").font(.system(size: 11, weight: .semibold))
                Spacer()
                Button { model.sheet = .folder } label: { Image(systemName: "folder.badge.plus") }.help("New folder")
            }.buttonStyle(.plain).foregroundStyle(Color(Paper.muted)).padding(.horizontal, 23).padding(.top, 28).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    ForEach(model.folders, id: \.self) { folder in
                        let items = model.drafts.filter { $0.folder == folder && (model.search.isEmpty || $0.title.localizedCaseInsensitiveContains(model.search)) }
                        if !items.isEmpty || model.search.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                if !folder.isEmpty {
                                    Label(folder, systemImage: "folder").font(.system(size: 11, weight: .medium)).foregroundStyle(Color(Paper.muted)).padding(.horizontal, 14).padding(.bottom, 3)
                                }
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
                }.padding(.horizontal, 10)
            }
            Spacer(minLength: 12)
            Button { model.chooseWorkspace() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "externaldrive")
                    Text(model.workspace?.root.lastPathComponent ?? "Workspace").lineLimit(1)
                    Spacer(); Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
                }.font(.system(size: 10)).foregroundStyle(Color(Paper.muted)).padding(.horizontal, 23).padding(.vertical, 20)
            }.buttonStyle(.plain).help("Change workspace")
        }.background(Color(red: 0.945, green: 0.933, blue: 0.905))
    }
    private func draftRow(_ draft: Draft, indented: Bool) -> some View {
        Button { model.select(draft) } label: {
            HStack(spacing: 9) {
                Image(systemName: indented ? "arrow.turn.down.right" : "doc.text").font(.system(size: 12)).foregroundStyle(Color(Paper.muted))
                Text(draft.title).font(.system(size: 12, weight: model.active?.id == draft.id ? .medium : .regular)).lineLimit(1)
                Spacer(minLength: 0)
                if model.active?.id == draft.id { Circle().fill(Color(Paper.accent)).frame(width: 4, height: 4) }
            }.padding(.vertical, 10).padding(.leading, indented ? 25 : 13).padding(.trailing, 10)
                .background(model.active?.id == draft.id ? Color.white.opacity(0.65) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(draft.path)
    }
    private func writing(_ draft: Draft) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 8) {
                    Button { model.sheet = .rename } label: {
                        Text(draft.title).font(.system(size: 25, weight: .semibold)).multilineTextAlignment(.leading)
                    }.buttonStyle(.plain).help("Rename document")
                    Spacer()
                    Menu {
                        ForEach(model.related) { branch in
                            Button { model.select(branch) } label: {
                                if branch.id == draft.id { Label(branch.title, systemImage: "checkmark") } else { Text(branch.title) }
                            }
                        }
                        Divider(); Button("Branch into a new draft") { model.branch() }
                    } label: {
                        Label("\(model.related.count) \(model.related.count == 1 ? "draft" : "drafts")", systemImage: "arrow.triangle.branch").font(.system(size: 10))
                    }.menuStyle(.borderlessButton).fixedSize().foregroundStyle(Color(Paper.muted))
                }
                if !draft.goal.isEmpty {
                Button { model.sheet = .goal } label: {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "smallcircle.filled.circle").font(.system(size: 10)).padding(.top, 2)
                        Text(draft.goal).font(.system(size: 12)).lineLimit(2)
                    }.foregroundStyle(Color(Paper.muted))
                }.buttonStyle(.plain).help("Edit writing goal")
                }
            }.padding(.horizontal, 28).padding(.top, 29).padding(.bottom, 10).frame(maxWidth: 736)
            MarkdownEditor(draftID: draft.id, text: model.text, initialCursor: draft.cursor, initialScroll: draft.scroll, onChange: model.edited, onPosition: model.position)
                .frame(maxWidth: 736).frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                Text("\(model.wordCount) words")
                Spacer()
                Circle().fill(Color(Paper.muted).opacity(0.6)).frame(width: 4, height: 4)
                Text(model.status)
            }.font(.system(size: 10)).foregroundStyle(Color(Paper.muted)).padding(.horizontal, 34).frame(height: 40)
        }
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
            Button("Create a document") { model.sheet = .document }.buttonStyle(.borderedProminent).controlSize(.large)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
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
