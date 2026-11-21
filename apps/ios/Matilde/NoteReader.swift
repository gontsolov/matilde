import SwiftUI

/// Read-only view of a note: title, goal and body in the writing typeface. Editing comes in
/// IOS-05; until then Markdown is shown with inline formatting only.
struct NoteReader: View {
    let note: NoteSummary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(note.title)
                    .font(Paper.body(31, relativeTo: .largeTitle).weight(.bold))
                    .foregroundStyle(Paper.ink)
                if !note.goal.isEmpty {
                    Label(note.goal, systemImage: "flag")
                        .font(Paper.body(17))
                        .foregroundStyle(Paper.muted)
                }
                Text(Self.rendered(note.body))
                    .font(Paper.body())
                    .foregroundStyle(Paper.ink)
                    .lineSpacing(6)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
        .background(Paper.background)
        .navigationBarTitleDisplayMode(.inline)
    }

    static func rendered(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }
}

#Preview {
    NavigationStack {
        NoteReader(note: NoteSummary(id: "preview", title: "A letter", goal: "Say thank you, briefly",
                                     body: "Dear Anna,\n\nThank you for *everything* this summer.", edited: .now))
    }
}
