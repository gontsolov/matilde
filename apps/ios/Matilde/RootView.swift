import SwiftUI
import MatildeKit

/// IOS-04: the notes list (folder sections, newest first, search) and the open note. A split
/// view collapses to a stack on iPhone and becomes two columns on iPad later (IOS-09).
struct RootView: View {
    @Environment(NoteLibrary.self) private var library
    @Environment(SyncController.self) private var sync
    @State private var selection: Draft.ID?
    @State private var query = ""
    @State private var showingSettings = false
    @State private var newFolder = false
    @State private var folderName = ""
    @State private var settingUpSync = false

    var body: some View {
        NavigationSplitView {
            NoteList(selection: $selection, query: query, showingSettings: $showingSettings, settingUpSync: $settingUpSync)
                .navigationTitle("Notes")
                .searchable(text: $query)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Settings", systemImage: "gearshape") { showingSettings = true }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("New Folder", systemImage: "folder.badge.plus") { folderName = ""; newFolder = true }
                    }
                    if let problem = sync.attention {
                        ToolbarItem(placement: .bottomBar) {
                            SyncAttention(text: problem) { if sync.phase == .ready { showingSettings = true } else { settingUpSync = true } }
                        }
                    }
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) {
                        Button("New Note", systemImage: "square.and.pencil") { newNote() }
                    }
                }
        } detail: {
            if let id = selection, library.draft(id: id) != nil {
                NavigationStack { NoteScreen(draftID: id) }
            } else {
                Paper.background.ignoresSafeArea()
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .fullScreenCover(isPresented: $settingUpSync) {
            SyncOnboardingView(phase: sync.setupPhase)
        }
        .alert("New Folder", isPresented: $newFolder) {
            TextField("Name", text: $folderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { library.createFolder(named: folderName) }
        }
        .alert("Matilde", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("OK", role: .cancel) { library.error = nil }
        } message: {
            Text(library.error ?? "")
        }
    }

    private func newNote() {
        if let draft = library.create() { selection = draft.id }
    }
}

/// A sync problem (offline, update required, setup not finished) in the bottom bar; opens
/// Settings. Nothing is shown while sync is fine.
private struct SyncAttention: View {
    let text: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            Label(text, systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                .labelStyle(.titleAndIcon)
                .font(.footnote)
                .lineLimit(1)
        }
        .tint(Paper.muted)
        .accessibilityLabel("Sync: " + text)
    }
}

private struct NoteList: View {
    @Environment(NoteLibrary.self) private var library
    @Environment(SyncController.self) private var sync
    @Binding var selection: Draft.ID?
    let query: String
    @Binding var showingSettings: Bool
    @Binding var settingUpSync: Bool

    var body: some View {
        let sections = library.sections(matching: query)
        List(selection: $selection) {
            ForEach(sections) { section in
                Section {
                    ForEach(section.drafts) { draft in
                        NoteRow(draft: draft)
                            .tag(draft.id)
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) { library.trash(draft) }
                            }
                    }
                } header: {
                    if sections.count > 1 || !section.folder.isEmpty {
                        Text(section.title)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Paper.background)
        .refreshable { await sync.refresh() }
        .overlay {
            if library.drafts.isEmpty {
                if sync.phase == .ready {
                    ContentUnavailableView {
                        Label("No notes yet", systemImage: "doc.text")
                    } description: {
                        Text("Notes from your Mac appear here.")
                    } actions: {
                        Button("New Note") { if let draft = library.create() { selection = draft.id } }
                            .buttonStyle(.matildePrimary)
                            .fixedSize()
                    }
                } else {
                    ContentUnavailableView {
                        Label("No notes yet", systemImage: "doc.text")
                    } description: {
                        Text(sync.isSignedIn ? "Finish setting up sync to bring your notes over." : SyncOnboardingCopy.callToActionText)
                    } actions: {
                        Button(sync.isSignedIn ? "Finish Setting Up Sync" : SyncOnboardingCopy.callToActionTitle) { settingUpSync = true }
                            .buttonStyle(.matildePrimary)
                            .fixedSize()
                        Button("New Note") { if let draft = library.create() { selection = draft.id } }
                            .buttonStyle(.matildeSecondary)
                    }
                }
            } else if sections.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }
}

/// Two lines, like Notes: the title with the edited time on the right, then one line of text.
private struct NoteRow: View {
    @Environment(NoteLibrary.self) private var library
    let draft: Draft

    var body: some View {
        let title = library.displayTitle(draft)
        let preview = library.preview(of: draft)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title.isEmpty ? "Untitled" : title)
                    .font(Font(MarkdownStyle.bodyFont(18, bold: true)))
                    .foregroundStyle(title.isEmpty ? Paper.muted : Paper.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let edited = draft.editedAt {
                    Text(edited, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                        .font(.footnote)
                        .foregroundStyle(Paper.muted)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
            Text(preview.isEmpty ? "No text yet" : preview)
                .font(Font(MarkdownStyle.bodyFont(16)))
                .foregroundStyle(Paper.muted)
                .lineLimit(1)
        }
        .padding(.vertical, 6)
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(Paper.muted.opacity(0.16))
    }
}

#Preview("Empty") {
    RootView()
        .environment(NoteLibrary(root: nil))
        .environment(SyncController(startsAutomatically: false))
}
