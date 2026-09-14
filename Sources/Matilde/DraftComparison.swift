import SwiftUI
import AppKit

/// A second editor owns its buffer and position without changing workspace selection.
@MainActor
final class DraftComparison: ObservableObject {
    let workspace: Workspace
    @Published private(set) var draft: Draft
    @Published private(set) var text: String
    @Published var error: String?
    private var savedText: String
    var cursor: Int
    var scroll: Double
    private var saveTask: Task<Void, Never>?

    init(workspace: Workspace, draft: Draft) throws {
        self.workspace = workspace; self.draft = draft
        let content = try workspace.read(draft)
        text = content; savedText = content
        cursor = draft.cursor; scroll = draft.scroll
    }
    deinit { saveTask?.cancel() }
    func edited(_ value: String) {
        text = value
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            guard let self else { return }
            do { try self.flush() } catch { self.error = error.localizedDescription }
        }
    }
    func position(_ cursor: Int, _ scroll: Double) { self.cursor = cursor; self.scroll = scroll }
    func flush() throws {
        saveTask?.cancel()
        // Refresh metadata first, so a rename does not redirect writes to the old path.
        guard let current = try workspace.allDrafts().first(where: { $0.id == draft.id }) else {
            throw WorkspaceError.message("This comparison draft was moved or removed. Your text is still open here.")
        }
        draft = current
        let disk = try workspace.read(current)
        if disk != savedText {
            try reload(disk)
        } else if text != savedText {
            try workspace.save(current, text: text)
            savedText = text
        }
        try workspace.position(current, cursor: cursor, scroll: scroll)
    }
    func poll() throws {
        guard error == nil else { return }
        guard let current = try workspace.allDrafts().first(where: { $0.id == draft.id }) else {
            throw WorkspaceError.message("This comparison draft was moved or removed. Your text is still open here.")
        }
        if draft != current { draft = current }
        let disk = try workspace.read(current)
        if disk != savedText { try reload(disk) }
    }
    private func reload(_ disk: String) throws {
        if text != savedText {
            let directory = workspace.root.appendingPathComponent(".matilde/recovery", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let copy = directory.appendingPathComponent("\(draft.id)-\(UUID().uuidString).md")
            try text.write(to: copy, atomically: true, encoding: .utf8)
            error = "The comparison draft changed on disk. Your unsaved text was preserved at \(copy.path)."
        }
        text = disk; savedText = disk
    }
}

struct DraftComparisonPane: View {
    @ObservedObject var comparison: DraftComparison
    @ObservedObject var model: AppModel
    @AppStorage(SettingKeys.textSize) private var textSize = 19.0
    @AppStorage(SettingKeys.lineSpacing) private var lineSpacing = 9.0
    @AppStorage(SettingKeys.spellChecking) private var spellChecking = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Menu {
                    ForEach(model.drafts.filter { $0.id != model.active?.id }) { draft in
                        Button(draft.title) { model.compare(draft) }
                    }
                } label: { Label(comparison.draft.title, systemImage: "rectangle.split.2x1") }
                Spacer()
                Button { model.closeComparison() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Close comparison")
            }.padding(14)
            if let error = comparison.error {
                Text(error).font(.callout).textSelection(.enabled).padding(.horizontal, 14)
            }
            MarkdownEditor(draftID: comparison.draft.id, text: comparison.text,
                           initialCursor: comparison.cursor, initialScroll: comparison.scroll,
                           onChange: comparison.edited, onPosition: comparison.position,
                           header: AnyView(VStack(alignment: .leading, spacing: 12) {
                               Text(comparison.draft.title).font(Font(Paper.body(30))).bold()
                               if !comparison.draft.goal.isEmpty {
                                   Label(comparison.draft.goal, systemImage: "flag").font(Font(Paper.body(CGFloat(textSize)))).foregroundStyle(Color(Paper.muted))
                               }
                           }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 10)),
                           saveImage: { try comparison.workspace.importImage($0, beside: comparison.draft) },
                           resolveImage: { comparison.workspace.image(at: $0, beside: comparison.draft) },
                           mediaError: { comparison.error = $0 }, textSize: textSize, lineSpacing: lineSpacing,
                           spellChecking: spellChecking, accessibilityName: "Comparison editor", onEscape: {})
                .id(comparison.draft.id)
                .frame(maxWidth: 736).frame(maxWidth: .infinity)
        }.background(Color(Paper.background))
    }
}
