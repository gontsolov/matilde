import SwiftUI
import AppKit
import MatildeKit

// WHAT'S NEW: Help → What's New in Matilde… opens a small window laid out like the app and like
// matilde.page/changelog: the releases as notes in a sidebar, newest first, and the selected one
// on paper in Newsreader, with Matilde's one-liner beneath. It also opens once after an update to
// a version with an entry. The entries are changelog/*.md at the repo root, copied into the app by
// build-app.sh (`Changelog.bundled()`), so it works offline.

/// The What's New window's scene: one window, centred, not in the Window menu.
struct WhatsNewWindow: Scene {
    static let id = "whats-new"

    var body: some Scene {
        Window("What's New in Matilde", id: Self.id) {
            WhatsNewView()
                .modifier(AppAppearanceModifier())
                .scrollIndicators(.hidden)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 780, height: 540)
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)
        .commandsRemoved()
    }
}

/// Opens the What's New window (Help menu). A view because `openWindow` only exists inside views.
struct WhatsNewButton<Label: View>: View {
    @Environment(\.openWindow) private var openWindow
    let label: () -> Label

    init(@ViewBuilder label: @escaping () -> Label) { self.label = label }

    var body: some View {
        Button(action: {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: WhatsNewWindow.id)
        }, label: label)
    }
}

/// Shows What's New once after an update: on the main window's first appearance, if this version
/// is newer than the last one recorded and has an entry. Fresh installs see the welcome note instead.
struct AnnounceWhatsNew: ViewModifier {
    static let lastSeenKey = "whatsNew.lastSeenVersion"
    @Environment(\.openWindow) private var openWindow
    nonisolated(unsafe) private static var checked = false

    func body(content: Content) -> some View {
        content.onAppear {
            guard !Self.checked else { return }
            Self.checked = true
            guard let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  Changelog.parseVersion(current) != nil else { return }
            let defaults = UserDefaults.standard
            let lastSeen = defaults.string(forKey: Self.lastSeenKey)
            // Versions before What's New recorded nothing; a chosen workspace means Matilde ran before.
            let launchedBefore = defaults.object(forKey: "workspacePath") != nil || defaults.object(forKey: "workspaceBookmark") != nil
            let entry = Changelog.entryToAnnounce(current: current, lastSeen: lastSeen, launchedBefore: launchedBefore,
                                                  entries: Changelog.bundled())
            if lastSeen.map({ Changelog.isNewer(current, than: $0) }) ?? true {
                defaults.set(current, forKey: Self.lastSeenKey)
            }
            guard entry != nil else { return }
            // Let the writing window settle first, so the notes open on top of it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                openWindow(id: WhatsNewWindow.id)
            }
        }
    }
}

struct WhatsNewView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var entries: [ChangelogEntry] = Changelog.bundled()
    @State private var selection: String?
    @State private var hovered: String?

    private var selected: ChangelogEntry? {
        entries.first { $0.version == selection } ?? entries.first
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 236)
                .background(Color(Paper.sidebar))
            Group {
                if let entry = selected {
                    page(entry).id(entry.version)
                } else {
                    Text("The release notes aren't included in this copy of Matilde. They're also at matilde.page/changelog.")
                        .font(Font(Paper.body(17)))
                        .foregroundStyle(Color(Paper.muted))
                        .multilineTextAlignment(.center)
                        .padding(40)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(Paper.background))
        }
        .frame(minWidth: 680, minHeight: 440)
        .ignoresSafeArea(.container, edges: .top)
        .onAppear { selection = entries.first?.version }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    MatildeIcon.folderOpen.image(size: 16)
                    Text("Releases")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(Paper.muted))
                .frame(height: 30)
                .padding(.horizontal, 8)
                ForEach(entries) { entry in row(entry) }
            }
            .padding(.horizontal, 8)
            .padding(.top, 44)
            .padding(.bottom, 16)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard let index = entries.firstIndex(where: { $0.version == selected?.version }) else { return .ignored }
        let next = min(max(index + step, 0), entries.count - 1)
        selection = entries[next].version
        return .handled
    }

    private func row(_ entry: ChangelogEntry) -> some View {
        let isSelected = entry.version == selected?.version
        return Button { selection = entry.version } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(Color(Paper.ink))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(entry.versionLabel).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Changelog.shortDateText(entry.date)).lineLimit(1)
                }
                .font(.system(size: 12))
                .foregroundStyle(Color(Paper.muted))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(Paper.ink).opacity(isSelected ? 0.075 : (hovered == entry.version ? 0.035 : 0)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? entry.version : (hovered == entry.version ? nil : hovered) }
        .accessibilityLabel("\(entry.title), \(entry.versionTitle), \(Changelog.dateText(entry.date))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Page

    private func page(_ entry: ChangelogEntry) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.title)
                        .font(Font(Paper.body(28, bold: true)))
                        .foregroundStyle(Color(Paper.ink))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("\(entry.versionTitle) · \(Changelog.dateText(entry.date))")
                        .font(Font(Paper.body(15)))
                        .foregroundStyle(Color(Paper.muted))
                        .padding(.top, 6)
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(entry.blocks.enumerated()), id: \.offset) { _, block in
                            blockView(block)
                        }
                    }
                    .padding(.top, 22)
                    if let line = entry.matilde {
                        matildeCard(title: entry.title, line: line).padding(.top, 26)
                    }
                }
                .frame(maxWidth: 520, alignment: .leading)
                .padding(.horizontal, 40)
                .padding(.top, 48)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Continue Writing") { dismissWindow(id: WhatsNewWindow.id) }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .onExitCommand { dismissWindow(id: WhatsNewWindow.id) }
    }

    @ViewBuilder
    private func blockView(_ block: ChangelogEntry.Block) -> some View {
        switch block {
        case .paragraph(let text):
            Text(Self.inline(text))
                .font(Font(Paper.body(17)))
                .lineSpacing(5)
                .foregroundStyle(Color(Paper.ink))
                .fixedSize(horizontal: false, vertical: true)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("•").foregroundStyle(Color(Paper.muted))
                        Text(Self.inline(item))
                            .lineSpacing(5)
                            .foregroundStyle(Color(Paper.ink))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(Font(Paper.body(17)))
                }
            }
        }
    }

    /// Matilde's one-liner, styled like a margin comment card.
    private func matildeCard(title: String, line: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(Font(Paper.body(13.5, italic: true)))
                .foregroundStyle(Color(Paper.muted))
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color(Paper.accent).opacity(0.5)).frame(width: 2)
                }
            Text("MATILDE")
                .font(.system(size: 11, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(Color(Paper.muted))
                .padding(.top, 10)
            Text(line)
                .font(.system(size: 13))
                .foregroundStyle(Color(Paper.ink))
                .padding(.top, 3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: 300, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(Paper.background)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(Paper.ink).opacity(0.09)))
        .shadow(color: .black.opacity(0.04), radius: 3, y: 2)
        .accessibilityElement(children: .combine)
    }

    /// Bold, italics and links from the entry's Markdown; plain text if it doesn't parse.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
