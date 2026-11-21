import SwiftUI
import MatildeKit

/// IOS-06 and IOS-08: one Ask Matilde thread. The passage, the conversation with Matilde and
/// her suggested rewrites in order, a composer, and Accept for the latest rewrite.
struct ThreadSheet: View {
    let model: NoteEditorModel
    @ObservedObject var review: WritingReviewModel
    let runID: UUID
    let commentID: UUID
    @State private var message = ""
    @FocusState private var composing: Bool
    @Environment(\.dismiss) private var dismiss

    private var comment: ReviewComment? {
        review.history.first { $0.id == runID }?.comments.first { $0.id == commentID }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let comment {
                    thread(comment)
                } else {
                    ContentUnavailableView("This thread is gone", systemImage: "text.bubble")
                }
            }
            .background(Paper.background)
            .navigationTitle("Ask Matilde")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let comment {
                        Menu {
                            Button("Show in Note", systemImage: "text.viewfinder") { dismiss(); model.select(comment.range) }
                            Button("Resolve", systemImage: "checkmark") {
                                review.dismiss(runID: runID, commentID: commentID); dismiss()
                            }
                            Button("Delete Thread", systemImage: "trash", role: .destructive) {
                                review.delete(runID: runID, commentID: commentID); dismiss()
                            }
                        } label: {
                            Label("Actions", systemImage: "ellipsis.circle")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", systemImage: "xmark", role: .close) { dismiss() }
                }
            }
        }
        .editorSheetPresentation()
        .onAppear {
            review.threadOpened(commentID)
            if comment?.messages?.isEmpty ?? true, comment?.suggestion.replacement == nil { composing = true }
        }
        .onDisappear { review.threadOpened(nil) }
    }

    private func thread(_ comment: ReviewComment) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 10) {
                            RoundedRectangle(cornerRadius: 1.5).fill(Paper.accent).frame(width: 3)
                            Text(comment.suggestion.quote)
                                .font(Paper.body(16).italic())
                                .foregroundStyle(Paper.muted)
                                .lineLimit(6)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        if !comment.suggestion.explanation.isEmpty {
                            bubble(speaker: "Matilde", text: comment.suggestion.explanation, mine: false)
                        }
                        ForEach(ThreadTimeline.items(for: comment)) { item in
                            switch item {
                            case .message(_, let message):
                                bubble(speaker: message.role == "user" ? "You" : "Matilde", text: message.text,
                                       mine: message.role == "user", failed: message.delivery == "failed")
                            case .suggestion(let suggestion):
                                rewrite(suggestion, comment: comment)
                            }
                        }
                        if review.replyingTo == commentID {
                            if review.streamingReply.isEmpty {
                                Text("Matilde is thinking…")
                                    .font(.subheadline)
                                    .foregroundStyle(Paper.muted)
                            } else {
                                bubble(speaker: "Matilde", text: review.streamingReply, mine: false)
                            }
                        }
                        if let error = comment.replyError {
                            Text(error).font(.footnote).foregroundStyle(.red)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(20)
                }
                .onChange(of: review.streamingReply) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: comment.messages?.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            composer(comment)
        }
    }

    private func bubble(speaker: String, text: String, mine: Bool, failed: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(speaker)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Paper.muted)
            Text(text)
                .font(Paper.body(17))
                .foregroundStyle(failed ? Paper.muted : Paper.ink)
                .textSelection(.enabled)
            if failed {
                Text("Not sent").font(.caption).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(mine ? Paper.accent.opacity(0.08) : Paper.sidebar, in: .rect(cornerRadius: 14))
    }

    private func rewrite(_ suggestion: ThreadSuggestion, comment: ReviewComment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Suggested rewrite", systemImage: "pencil.line")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Paper.accent)
            Text(suggestion.replacement)
                .font(Paper.body(17))
                .foregroundStyle(suggestion.isCurrent ? Paper.ink : Paper.muted)
                .textSelection(.enabled)
            if suggestion.isCurrent {
                Button("Accept") {
                    model.accept(runID: runID, commentID: commentID)
                    if review.error == nil { dismiss() }
                }
                .buttonStyle(.glassProminent)
                .disabled(!comment.rewriteApplies || !comment.matches(model.text) || review.replyingTo != nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Paper.accent.opacity(0.35)))
    }

    private func composer(_ comment: ReviewComment) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask Matilde about this passage", text: $message, axis: .vertical)
                .lineLimit(1...6)
                .focused($composing)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
            Button {
                send()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || review.replyingTo != nil)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func send() {
        model.flush()
        review.reply(runID: runID, commentID: commentID, text: message, input: model.input)
        if review.replyingTo == commentID { message = "" }
    }
}
