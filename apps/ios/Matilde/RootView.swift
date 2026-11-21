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

    var body: some View {
        NavigationSplitView {
            NoteList(selection: $selection, query: query, showingSettings: $showingSettings)
                .navigationTitle("Notes")
                .searchable(text: $query)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Settings", systemImage: "gearshape") { showingSettings = true }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("New Folder", systemImage: "folder.badge.plus") { folderName = ""; newFolder = true }
                        } label: {
                            Label("New Note", systemImage: "square.and.pencil")
                        } primaryAction: {
                            newNote()
                        }
                    }
                    ToolbarItem(placement: .bottomBar) {
                        SyncStatusLine()
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

/// "Synced 09:41", "Syncing…", "Offline" or "Not signed in" under the list.
private struct SyncStatusLine: View {
    @Environment(SyncController.self) private var sync

    var body: some View {
        Text(sync.phase == .ready ? sync.statusText : sync.isSignedIn ? "Setting up sync" : "Not signed in")
            .font(.footnote)
            .foregroundStyle(Paper.muted)
            .accessibilityLabel("Sync status: " + (sync.phase == .ready ? sync.statusText : "not syncing"))
    }
}

private struct NoteList: View {
    @Environment(NoteLibrary.self) private var library
    @Environment(SyncController.self) private var sync
    @Binding var selection: Draft.ID?
    let query: String
    @Binding var showingSettings: Bool

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
                if sync.isSignedIn {
                    ContentUnavailableView {
                        Label("No notes yet", systemImage: "doc.text")
                    } description: {
                        Text(sync.phase == .ready ? "Notes from your Mac appear here. Pull down to sync now." : "Finish setting up sync in Settings.")
                    } actions: {
                        Button("New Note") { if let draft = library.create() { selection = draft.id } }
                            .buttonStyle(.glassProminent)
                    }
                } else {
                    ContentUnavailableView {
                        Label("No notes yet", systemImage: "doc.text")
                    } description: {
                        Text("Sign in with the email you use for sync on your Mac.")
                    } actions: {
                        Button("Sign In") { showingSettings = true }
                            .buttonStyle(.glassProminent)
                    }
                }
            } else if sections.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }
}

private struct NoteRow: View {
    @Environment(NoteLibrary.self) private var library
    let draft: Draft

    var body: some View {
        let title = library.displayTitle(draft)
        VStack(alignment: .leading, spacing: 3) {
            Text(title.isEmpty ? "Untitled" : title)
                .font(Paper.body(18, relativeTo: .headline).weight(.semibold))
                .foregroundStyle(title.isEmpty ? Paper.muted : Paper.ink)
                .lineLimit(2)
            let preview = library.preview(of: draft)
            if !preview.isEmpty {
                Text(preview)
                    .font(Paper.body(15))
                    .foregroundStyle(Paper.muted)
                    .lineLimit(2)
            }
            HStack(alignment: .firstTextBaseline) {
                if !draft.goal.isEmpty {
                    Label(draft.goal, systemImage: "flag")
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let edited = draft.editedAt {
                    Text(edited, format: .relative(presentation: .named))
                }
            }
            .font(.footnote)
            .foregroundStyle(Paper.muted)
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.clear)
    }
}

#Preview("Empty") {
    RootView()
        .environment(NoteLibrary(root: nil))
        .environment(SyncController(startsAutomatically: false))
}
