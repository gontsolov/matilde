import SwiftUI
import UniformTypeIdentifiers
import MatildeKit

/// Opens a note by id: makes its editor model once and keeps it while the note is shown.
struct NoteScreen: View {
    let draftID: Draft.ID
    @Environment(NoteLibrary.self) private var library
    @State private var model: NoteEditorModel?

    var body: some View {
        Group {
            if let model {
                NoteEditorView(model: model)
            } else {
                Paper.background.ignoresSafeArea()
            }
        }
        .onAppear {
            guard model == nil, let draft = library.draft(id: draftID) else { return }
            model = NoteEditorModel(library: library, draft: draft)
        }
        .id(draftID)
    }
}

/// IOS-05: an open note. Title and goal on top, the writing below; autosaves while typing.
struct NoteEditorView: View {
    @Bindable var model: NoteEditorModel
    @ObservedObject private var review: WritingReviewModel
    @Environment(NoteLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(model: NoteEditorModel) {
        self.model = model
        review = model.review
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            NoteTextView(model: model, highlights: highlights)
        }
        .background(Paper.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .comments: CommentsSheet(model: model, review: review)
            case .comment(let comment): CommentSheet(model: model, comment: comment)
            case .thread(let runID, let commentID): ThreadSheet(model: model, review: review, runID: runID, commentID: commentID)
            }
        }
        .alert("Ask Matilde", isPresented: Binding(get: { review.error != nil && model.sheet == nil }, set: { if !$0 { review.error = nil } })) {
            Button("OK", role: .cancel) { review.error = nil }
        } message: {
            Text(review.error ?? "")
        }
        .onAppear {
            let open = model
            library.flushOpenNote = { [weak open] in open?.flush() }
        }
        .onDisappear {
            model.flush()
            library.flushOpenNote = nil
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.flush() } }
        .onChange(of: library.remoteRevision) { _, _ in model.remoteChanged() }
        .onChange(of: model.gone) { _, gone in if gone { dismiss() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Untitled", text: $model.title, axis: .vertical)
                .font(Paper.body(31, relativeTo: .largeTitle).weight(.bold))
                .foregroundStyle(Paper.ink)
                .submitLabel(.next)
                .onSubmit { model.textView?.becomeFirstResponder() }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "flag")
                    .foregroundStyle(Paper.muted)
                    .accessibilityHidden(true)
                TextField("What is this writing for?", text: $model.goal, axis: .vertical)
                    .font(Paper.body(17))
                    .foregroundStyle(Paper.muted)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var highlights: [TextHighlight] {
        _ = review.history
        let comments = model.comments.comments.filter(\.attached).map { TextHighlight(kind: .comment, range: $0.range) }
        let threads = model.threads.map { TextHighlight(kind: $0.comment.isUnread ? .unreadThread : .thread, range: $0.comment.range) }
        return comments + threads
    }

    private var unreadCount: Int { model.threads.filter { $0.comment.isUnread }.count }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if review.isRunning {
                ProgressView().accessibilityLabel("Matilde is reading")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                model.flush()
                model.sheet = .comments
            } label: {
                Label("Comments", systemImage: unreadCount > 0 ? "text.bubble.fill" : "text.bubble")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Ask Matilde to Review", systemImage: "sparkles") { model.reviewNote() }
                    .disabled(review.isRunning || model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                ShareLink(item: model.markdownForSharing, subject: Text(model.title), preview: SharePreview(model.title.isEmpty ? "Untitled" : model.title)) {
                    Label("Share Text", systemImage: "square.and.arrow.up")
                }
                ShareLink(item: MarkdownExport(name: model.title, text: model.markdownForSharing),
                          preview: SharePreview(model.title.isEmpty ? "Untitled" : model.title)) {
                    Label("Export Markdown File", systemImage: "doc.text")
                }
                Divider()
                Button("Delete Note", systemImage: "trash", role: .destructive) {
                    library.trash(model.draft)
                    dismiss()
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }
}

/// The note as a `.md` file for the share sheet, written only when a destination asks for it.
nonisolated struct MarkdownExport: Transferable {
    let name: String
    let text: String

    static let markdown = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: markdown) { export in
            SentTransferredFile(try export.write())
        }
    }

    /// `<title>.md` in a fresh temporary folder.
    func write() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(Self.fileName(for: name))
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    static func fileName(for title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = (trimmed.isEmpty ? "Untitled" : trimmed)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return safe + ".md"
    }
}
