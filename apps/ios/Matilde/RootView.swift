import SwiftUI

/// Notes list and reader. A split view collapses to a stack on iPhone and becomes the
/// two-column layout on iPad later (IOS-09) without restructuring.
struct RootView: View {
    @Environment(NoteLibrary.self) private var library
    @State private var selection: NoteSummary.ID?
    @State private var query = ""
    @State private var showingSettings = false

    var body: some View {
        NavigationSplitView {
            NoteList(selection: $selection, query: query, showingSettings: $showingSettings)
                .navigationTitle("Notes")
                .searchable(text: $query)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Settings", systemImage: "gearshape") { showingSettings = true }
                    }
                }
        } detail: {
            if let note = library.note(id: selection) {
                NoteReader(note: note)
            } else {
                Paper.background.ignoresSafeArea()
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }
}

private struct NoteList: View {
    @Environment(NoteLibrary.self) private var library
    @Binding var selection: NoteSummary.ID?
    let query: String
    @Binding var showingSettings: Bool

    var body: some View {
        let notes = library.sorted(matching: query)
        List(notes, selection: $selection) { note in
            NoteRow(note: note)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Paper.background)
        .overlay {
            if library.notes.isEmpty {
                ContentUnavailableView {
                    Label("No notes yet", systemImage: "doc.text")
                } description: {
                    Text("Sign in with the email you use for sync on your Mac.")
                } actions: {
                    Button("Sign In") { showingSettings = true }
                        .buttonStyle(.glassProminent)
                }
            } else if notes.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }
}

private struct NoteRow: View {
    let note: NoteSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(note.title)
                .font(Paper.body(18, relativeTo: .headline).weight(.semibold))
                .foregroundStyle(Paper.ink)
                .lineLimit(2)
            HStack(alignment: .firstTextBaseline) {
                Text(note.goal.isEmpty ? "No goal set" : note.goal)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(note.edited, format: .relative(presentation: .named))
            }
            .font(.footnote)
            .foregroundStyle(Paper.muted)
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.clear)
    }
}

#Preview("Empty") {
    RootView().environment(NoteLibrary())
}
