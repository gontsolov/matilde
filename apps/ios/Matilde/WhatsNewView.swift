import SwiftUI
import MatildeKit

/// What's New in Settings: every release from the changelog bundled into the app (the repo's
/// `changelog/` folder, the same notes as matilde.page/changelog and the Mac app), newest first.
struct WhatsNewView: View {
    private let entries = Changelog.bundled()

    var body: some View {
        List {
            if entries.isEmpty {
                Text("The release notes are on matilde.page/changelog.")
                    .foregroundStyle(Paper.muted)
            }
            ForEach(entries) { entry in
                NavigationLink {
                    WhatsNewEntryView(entry: entry)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.title)
                            .font(Paper.body(17, relativeTo: .body))
                            .foregroundStyle(Paper.ink)
                        Text("\(entry.versionLabel) · \(Changelog.shortDateText(entry.date))")
                            .font(.footnote)
                            .foregroundStyle(Paper.muted)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("What's New")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One release: its title, intro and bullets on paper, with Matilde's one-liner at the end.
private struct WhatsNewEntryView: View {
    let entry: ChangelogEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(entry.versionTitle) · \(Changelog.dateText(entry.date))")
                        .font(.footnote)
                        .foregroundStyle(Paper.muted)
                    Text(entry.title)
                        .font(Paper.body(28, relativeTo: .title))
                        .foregroundStyle(Paper.ink)
                }
                ForEach(Array(entry.blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .paragraph(let text):
                        Text(Self.inline(text))
                            .font(Paper.body())
                            .foregroundStyle(Paper.ink)
                    case .bullets(let items):
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text("•").foregroundStyle(Paper.muted)
                                    Text(Self.inline(item))
                                }
                                .font(Paper.body())
                                .foregroundStyle(Paper.ink)
                            }
                        }
                    }
                }
                if let matilde = entry.matilde {
                    Text(matilde)
                        .font(Paper.body(17, relativeTo: .body).italic())
                        .foregroundStyle(Paper.muted)
                        .padding(.top, 8)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Paper.background)
        .tint(Paper.accent)
        .navigationTitle(entry.versionLabel)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Bold and links in the notes, rendered inline.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
