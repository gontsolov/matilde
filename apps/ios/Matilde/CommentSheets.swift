import SwiftUI
import MatildeKit

/// IOS-06: every comment and thread on the note, unread threads first.
struct CommentsSheet: View {
    let model: NoteEditorModel
    @ObservedObject var review: WritingReviewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let threads = model.threads.sorted { ($0.comment.isUnread ? 0 : 1, $0.comment.location) < ($1.comment.isUnread ? 0 : 1, $1.comment.location) }
        let comments = model.comments.comments
        NavigationStack {
            List {
                if threads.isEmpty && comments.isEmpty {
                    ContentUnavailableView {
                        Label("No comments", systemImage: "text.bubble")
                    } description: {
                        Text("Select a passage, then choose Comment for a private note or Ask Matilde to talk it through.")
                    }
                    .listRowBackground(Color.clear)
                }
                if !threads.isEmpty {
                    Section("Ask Matilde") {
                        ForEach(threads, id: \.comment.id) { thread in
                            Button {
                                model.sheet = .thread(runID: thread.runID, commentID: thread.comment.id)
                            } label: {
                                CommentRow(quote: thread.comment.suggestion.quote,
                                           text: ThreadTimeline.preview(for: thread.comment) ?? "",
                                           unread: thread.comment.isUnread, rule: Paper.accent)
                            }
                            .swipeActions {
                                Button("Resolve", systemImage: "checkmark") {
                                    review.dismiss(runID: thread.runID, commentID: thread.comment.id)
                                }
                                .tint(Paper.accent)
                            }
                        }
                    }
                }
                if !comments.isEmpty {
                    Section("Private comments") {
                        ForEach(comments) { comment in
                            Button {
                                model.sheet = .comment(comment)
                            } label: {
                                CommentRow(quote: comment.attached ? comment.quote : "Passage removed",
                                           text: comment.text, unread: false, rule: Paper.commentRule, author: comment.author)
                            }
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) { model.comments.delete(comment.id) }
                                Button("Archive", systemImage: "archivebox") { model.comments.archive(comment.id) }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Paper.background)
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", systemImage: "xmark", role: .close) { dismiss() }
                }
            }
        }
        .editorSheetPresentation()
    }
}

private struct CommentRow: View {
    let quote: String
    let text: String
    let unread: Bool
    let rule: Color
    /// The AI tool that left the comment through Matilde's MCP server, if one did.
    var author: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5).fill(rule).frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(quote)
                    .font(Paper.body(15).italic())
                    .foregroundStyle(Paper.muted)
                    .lineLimit(2)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(Paper.ink)
                    .lineLimit(3)
                if let author {
                    Text("From \(author)")
                        .font(.caption)
                        .foregroundStyle(Paper.muted)
                }
            }
            Spacer(minLength: 0)
            if unread {
                Circle().fill(Paper.accent).frame(width: 8, height: 8)
                    .accessibilityLabel("Unread")
            }
        }
        .padding(.vertical, 2)
    }
}

/// IOS-06: write, edit, archive or delete one private comment.
struct CommentSheet: View {
    let model: NoteEditorModel
    let comment: UserComment
    @State private var text: String
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: NoteEditorModel, comment: UserComment) {
        self.model = model
        self.comment = comment
        _text = State(initialValue: comment.text)
    }

    private var isSaved: Bool { model.comments.comments.contains { $0.id == comment.id } }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                if comment.attached {
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 1.5).fill(Paper.commentRule).frame(width: 3)
                        Text(comment.quote)
                            .font(Paper.body(16).italic())
                            .foregroundStyle(Paper.muted)
                            .lineLimit(4)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                if let author = comment.author {
                    Text("From \(author)")
                        .font(.caption)
                        .foregroundStyle(Paper.muted)
                }
                TextField("A note to yourself", text: $text, axis: .vertical)
                    .font(Paper.body(18))
                    .foregroundStyle(Paper.ink)
                    .focused($focused)
                    .lineLimit(3...12)
                Text("Only you see this comment. It syncs with your notes but never goes into the text.")
                    .font(.footnote)
                    .foregroundStyle(Paper.muted)
                Spacer()
            }
            .padding(20)
            .background(Paper.background)
            .navigationTitle(isSaved ? "Comment" : "New Comment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", role: .confirm) {
                        model.comments.save(comment, text: text)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaved)
                }
                if isSaved {
                    ToolbarItem(placement: .bottomBar) {
                        Menu {
                            Button("Archive", systemImage: "archivebox") { model.comments.archive(comment.id); dismiss() }
                            Button("Delete", systemImage: "trash", role: .destructive) { model.comments.delete(comment.id); dismiss() }
                            if comment.attached {
                                Button("Show in Note", systemImage: "text.viewfinder") { dismiss(); model.select(comment.range) }
                            }
                        } label: {
                            Label("Actions", systemImage: "ellipsis.circle")
                        }
                    }
                }
            }
        }
        .editorSheetPresentation()
        .onAppear { focused = !isSaved }
    }
}

extension View {
    /// IOS-06: comment and thread sheets open at half height over the note, with a grabber, and
    /// leave the note usable behind them so the passage stays in view (`NoteUITextView.reveal`).
    func editorSheetPresentation() -> some View {
        presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }
}
