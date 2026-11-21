import SwiftUI
import MatildeKit

/// IOS-04: the notes list (folder sections, newest first, pull down to search) and the open
/// note. A split view collapses to a stack on iPhone and becomes two columns on iPad later
/// (IOS-09). Also hosts the launch splash, the first-run tour and the guided sync setup.
///
/// No pull to refresh: sync runs by itself at launch, when the app comes to the front, a few
/// seconds after each edit, on the server's live nudge and on a slow poll (`SyncController`).
struct RootView: View {
    @Environment(NoteLibrary.self) private var library
    @Environment(SyncController.self) private var sync
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(FirstRunTour.seenKey) private var tourSeen = false
    @State private var selection: Draft.ID?
    @State private var query = ""
    @State private var search = PullToSearch()
    @State private var showingSettings = false
    @State private var newFolder = false
    @State private var folderName = ""
    @State private var settingUpSync = false
    @State private var splash = true
    @State private var notesCreated = 0

    var body: some View {
        NavigationSplitView {
            NoteList(selection: $selection, query: $query, search: $search, settingUpSync: $settingUpSync, newNote: newNote)
                .navigationTitle("Notes")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Settings", systemImage: "gearshape") { showingSettings = true }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("Search", systemImage: "magnifyingglass") { openSearch() }
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
                .toolbar(search.mode == .searching ? .hidden : .automatic, for: .navigationBar)
                .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.35), value: search.mode)
        } detail: {
            if let id = selection, library.draft(id: id) != nil {
                NavigationStack { NoteScreen(draftID: id) }
            } else {
                Paper.background.ignoresSafeArea()
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: notesCreated)
        .overlay {
            if splash {
                SplashView().transition(.opacity)
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(450))
            withAnimation(.easeOut(duration: 0.35)) { splash = false }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .fullScreenCover(isPresented: $settingUpSync) {
            SyncOnboardingView(phase: sync.setupPhase)
        }
        .fullScreenCover(isPresented: Binding(get: { !tourSeen && !splash && !showingSettings && !settingUpSync },
                                              set: { if !$0 { tourSeen = true } })) {
            FirstRunView { setUpSync in
                tourSeen = true
                if setUpSync && sync.phase != .ready {
                    // Once the tour has gone away, so the two covers don't overlap.
                    Task {
                        try? await Task.sleep(for: .milliseconds(500))
                        settingUpSync = true
                    }
                }
            }
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
        if let draft = library.create() {
            notesCreated += 1
            selection = draft.id
        }
    }

    private func openSearch() { search.open() }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: Draft.ID?
    @Binding var query: String
    @Binding var search: PullToSearch
    @Binding var settingUpSync: Bool
    let newNote: () -> Void
    @State private var dragging = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        let sections = library.sections(matching: search.mode == .searching ? query : "")
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
        .scrollDismissesKeyboard(.immediately)
        // Pull down past the top to search: the overscroll grows the affordance, letting go past
        // the threshold opens the search field (PullToSearch in MatildeKit).
        .onScrollGeometryChange(for: Double.self) { geometry in
            -(geometry.contentOffset.y + geometry.contentInsets.top)
        } action: { _, overscroll in
            if dragging { search.dragged(overscroll: overscroll) }
        }
        .onScrollPhaseChange { _, phase in
            let nowDragging = phase == .interacting
            if dragging && !nowDragging { search.released() }
            dragging = nowDragging
        }
        .sensoryFeedback(.impact(weight: .light), trigger: search.armChanges)
        .overlay(alignment: .top) {
            if search.mode == .browsing && search.reveal > 0 {
                PullAffordance(reveal: search.reveal, armed: search.armed)
                    .padding(.top, max(0, search.pull / 2 - 16))
                    .allowsHitTesting(false)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if search.mode == .searching {
                SearchBar(query: $query, focused: $searchFocused) { closeSearch() }
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .onChange(of: search.mode) { _, mode in
            guard mode == .searching else { query = ""; return }
            // After the field has appeared, so focus has something to land on.
            Task {
                try? await Task.sleep(for: .milliseconds(60))
                searchFocused = true
            }
        }
        .onChange(of: searchFocused) { wasFocused, focused in
            if wasFocused && !focused { search.keyboardDismissed(query: query) }
        }
        .accessibilityAction(named: "Search") { search.open() }
        .overlay {
            if library.drafts.isEmpty {
                emptyState
            } else if sections.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    private func closeSearch() {
        searchFocused = false
        search.close()
    }

    @ViewBuilder private var emptyState: some View {
        if sync.phase == .ready {
            ContentUnavailableView {
                Label("No notes yet", systemImage: "doc.text")
            } description: {
                Text("Notes from your Mac appear here.")
            } actions: {
                Button("New Note", action: newNote)
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
                Button("New Note", action: newNote)
                    .buttonStyle(.matildeSecondary)
            }
        }
    }
}

/// The magnifier that grows out of the top as the list is pulled down.
private struct PullAffordance: View {
    let reveal: Double
    let armed: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: armed ? .semibold : .regular))
            Text(armed ? "Release to Search" : "Search")
                .font(.footnote)
        }
        .foregroundStyle(armed ? Paper.ink : Paper.muted)
        .scaleEffect(0.6 + 0.4 * reveal)
        .opacity(reveal)
        .animation(.spring(duration: 0.25), value: armed)
        .accessibilityHidden(true)
    }
}

/// The search field at the top of the list while searching.
private struct SearchBar: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Paper.muted)
                TextField("Search notes", text: $query)
                    .focused(focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") { query = "" }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Paper.muted)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .glassEffect(.regular, in: Capsule())
            Button("Cancel", action: cancel)
                .foregroundStyle(Paper.accent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Paper.background)
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
