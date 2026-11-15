import AppKit
import SwiftUI
import CryptoKit

struct ReviewComment: Codable, Identifiable {
    let id: UUID
    var suggestion: ReviewSuggestion
    var location: Int
    var length: Int
    /// "open", "removed" (passage deleted; undo restores it), "accepted", "dismissed";
    /// "stale" only in reviews saved before passages were tracked.
    var status: String = "open"
    var messages: [ReviewMessage]? = nil
    var replyError: String? = nil
    var userInitiated: Bool? = nil
    /// The passage a suggested rewrite was written for, once the writer has edited it.
    var rewriteQuote: String? = nil
    var range: NSRange { NSRange(location: location, length: length) }
}

struct WritingReview: Codable, Identifiable {
    let id: UUID
    let draftID: String
    let created: Date
    let model: String
    var revision: String
    var stale: Bool
    var comments: [ReviewComment]
    var source: ReviewInput? = nil

    static func revision(_ input: ReviewInput) -> String {
        let data = try! JSONEncoder().encode([input.title, input.goal, input.body])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func anchor(_ suggestion: ReviewSuggestion, in text: String) -> NSRange? {
        let source = text as NSString
        guard !suggestion.quote.isEmpty else { return nil }
        var search = NSRange(location: 0, length: source.length)
        var found: NSRange?
        while search.length > 0 {
            let range = source.range(of: suggestion.quote, options: .literal, range: search)
            if range.location == NSNotFound { break }
            let before = source.substring(to: range.location)
            let after = source.substring(from: NSMaxRange(range))
            if before.hasSuffix(suggestion.prefix), after.hasPrefix(suggestion.suffix) {
                if found != nil { return nil }
                found = range
            }
            let next = range.location + 1
            search = NSRange(location: next, length: source.length - next)
        }
        return found
    }
    static func make(draftID: String, input: ReviewInput, model: String, suggestions: [ReviewSuggestion]) throws -> Self {
        var comments: [ReviewComment] = []
        for suggestion in suggestions {
            guard let range = anchor(suggestion, in: input.body),
                  !comments.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else {
                throw ReviewError.message("The review couldn’t be matched reliably to this draft. Please review again.")
            }
            let comment = ReviewComment(id: UUID(), suggestion: suggestion, location: range.location, length: range.length)
            comments.append(CommentAnchor.refreshed(comment, range: range, in: input.body))
        }
        return Self(id: UUID(), draftID: draftID, created: Date(), model: model, revision: revision(input), stale: false, comments: comments, source: input)
    }
}

extension Workspace {
    func reviewHistory(draftID: String) throws -> [WritingReview] {
        try db.execute("CREATE TABLE IF NOT EXISTS writing_reviews (id TEXT PRIMARY KEY, draft_id TEXT NOT NULL, created REAL NOT NULL, payload TEXT NOT NULL)")
        return try db.execute("SELECT payload FROM writing_reviews WHERE draft_id = ? ORDER BY created DESC", [draftID]).map { row in
            guard let payload = row["payload"] else { throw ReviewError.message("A saved review could not be read.") }
            return try JSONDecoder().decode(WritingReview.self, from: Data(payload.utf8))
        }
    }
    func saveReview(_ review: WritingReview) throws {
        try db.execute("CREATE TABLE IF NOT EXISTS writing_reviews (id TEXT PRIMARY KEY, draft_id TEXT NOT NULL, created REAL NOT NULL, payload TEXT NOT NULL)")
        let payload = String(decoding: try JSONEncoder().encode(review), as: UTF8.self)
        try db.execute("INSERT OR REPLACE INTO writing_reviews (id, draft_id, created, payload) VALUES (?, ?, ?, ?)",
                       [review.id.uuidString, review.draftID, String(review.created.timeIntervalSince1970), payload])
    }
}

@MainActor
final class WritingReviewModel: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var history: [WritingReview] = []
    @Published var error: String?
    private var workspace: Workspace?
    private var draftID: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var requestRevision: String?
    private var currentInput: ReviewInput?
    private var idleTask: Task<Void, Never>?
    private var automaticBaseline: ReviewInput?
    private var attemptedRevision: String?
    @Published private(set) var automaticPaused = UserDefaults.standard.bool(forKey: "writingAssist.paused")
    @Published private(set) var streamingReply = ""
    @Published private(set) var replyingTo: UUID?
    @Published private(set) var focusedCommentID: UUID?
    @Published private(set) var focusRequest = UUID()
    @Published var historyVisible = false
    var automaticAllowed: () -> Bool = { true }
    var reportError: (String) -> Void = { _ in }
    var automaticDelay: Duration = .seconds(30)
    var automaticConfiguration: () -> LangdockConfiguration = { .current }
    var automaticKey: (() -> String?)? // Test seam; production loads Keychain only when due.

    let client: LangdockServing
    init(client: LangdockServing = LangdockClient()) { self.client = client }

    func bind(workspace: Workspace?, draftID: String?, input: ReviewInput) {
        if self.workspace !== workspace || self.draftID != draftID {
            cancel(); idleTask?.cancel(); automaticBaseline = input; attemptedRevision = nil
            self.workspace = workspace; self.draftID = draftID
            error = nil
            do { history = try draftID.map { try workspace?.reviewHistory(draftID: $0) ?? [] } ?? [] }
            catch { history = []; fail("Saved reviews could not be loaded.") }
            focusedCommentID = nil
            for r in history.indices {
                for c in history[r].comments.indices where history[r].comments[c].messages?.last?.delivery == "pending" {
                    var messages = history[r].comments[c].messages!
                    messages[messages.count - 1].delivery = "failed"
                    history[r].comments[c].messages = messages
                    history[r].comments[c].replyError = "Reply interrupted. Try again."
                    persist(history[r])
                }
            }
        }
        invalidate(input)
    }
    func beginSelection(_ range: NSRange, input: ReviewInput) {
        let body = input.body as NSString
        guard let draftID, workspace != nil, range.location >= 0, range.length > 0,
              NSMaxRange(range) <= body.length else { return }
        cancel(); error = nil
        invalidate(input)
        if history.first?.stale != false || history.first?.revision != WritingReview.revision(input) {
            guard let run = try? WritingReview.make(draftID: draftID, input: input, model: LangdockConfiguration.current.model, suggestions: []) else { return }
            history.insert(run, at: 0)
        }
        if let existing = history[0].comments.first(where: { $0.range == range && $0.status == "open" }) {
            focusedCommentID = existing.id; focusRequest = UUID()
            return
        }
        let suggestion = ReviewSuggestion(quote: body.substring(with: range), prefix: "", suffix: "", explanation: "", replacement: nil)
        var comment = CommentAnchor.refreshed(ReviewComment(id: UUID(), suggestion: suggestion, location: range.location, length: range.length),
                                              range: range, in: input.body)
        comment.userInitiated = true
        history[0].comments.append(comment)
        persist(history[0]); focusedCommentID = comment.id; focusRequest = UUID()
    }
    func changed(workspace: Workspace?, draftID: String?, input: ReviewInput) {
        guard self.workspace === workspace, self.draftID == draftID else { cancel(); return }
        invalidate(input)
        scheduleAutomatic(input)
    }
    func invalidate(_ input: ReviewInput) {
        let revision = WritingReview.revision(input)
        if isRunning && requestRevision != revision { cancel() }
        for index in history.indices where !history[index].stale {
            if history[index].revision == revision {
                if history[index].source == nil { history[index].source = input }
                continue
            }
            history[index].track(input)
            persist(history[index])
        }
        currentInput = input
    }
    func cancel() {
        streamingReply = ""
        if let replyingTo { failReply(replyingTo, message: "Reply cancelled. Try again.") }
        generation = UUID(); task?.cancel(); task = nil; isRunning = false; requestRevision = nil; replyingTo = nil; idleTask?.cancel()
    }
    /// Errors from automatic reviews only mark the toolbar control; others are also reported.
    func start(input: ReviewInput, configuration: LangdockConfiguration = .current, key: String? = nil, automatic: Bool = false) {
        cancel(); error = nil
        automaticBaseline = input; attemptedRevision = WritingReview.revision(input)
        guard let draftID, workspace != nil else { return }
        guard !input.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { fail("Write a little first, then review your draft.", quietly: automatic); return }
        let credential: String
        do {
            guard !configuration.model.isEmpty else { throw ReviewError.message("Choose a model in Settings → Connections first.") }
            guard let loaded = try key ?? APIKeyStore().load(), !loaded.isEmpty else { throw ReviewError.message("Add your Langdock API key in Settings → Connections first.") }
            credential = loaded
        } catch { fail(error.localizedDescription, quietly: automatic); return }
        let token = generation
        isRunning = true
        requestRevision = WritingReview.revision(input)
        task = Task { [weak self, client] in
            do {
                let suggestions = try await client.review(input, configuration: configuration, key: credential)
                try Task.checkCancellation()
                var result = try WritingReview.make(draftID: draftID, input: input, model: configuration.model, suggestions: suggestions)
                guard let self, self.generation == token else { return }
                // Carry open threads forward and suppress already-reviewed unchanged passages.
                let existing = self.history.first?.comments ?? []
                let oldQuotes = Set(self.history.flatMap(\.comments).filter { $0.status != "stale" && input.body.contains($0.suggestion.quote) }.map { $0.suggestion.quote })
                result.comments.removeAll { oldQuotes.contains($0.suggestion.quote) }
                result.comments = existing.filter { $0.status == "open" && $0.matches(input.body) } + result.comments
                for i in self.history.indices where !self.history[i].stale {
                    self.history[i].stale = true; self.persist(self.history[i])
                }
                try self.workspace?.saveReview(result)
                self.history.insert(result, at: 0)
                self.isRunning = false; self.task = nil
            } catch is CancellationError {
                // A newer request owns the state after cancellation.
            } catch {
                guard let self, self.generation == token else { return }
                self.isRunning = false; self.task = nil
                self.fail((error as? ReviewError)?.localizedDescription ?? "The review could not be saved or completed. Please try again.", quietly: automatic)
            }
        }
    }
    func toggleAutomatic() {
        automaticPaused.toggle()
        UserDefaults.standard.set(automaticPaused, forKey: "writingAssist.paused")
        idleTask?.cancel()
        if automaticPaused { cancel() }
        else if let currentInput { scheduleAutomatic(currentInput) }
    }
    private func scheduleAutomatic(_ input: ReviewInput) {
        idleTask?.cancel()
        guard !automaticPaused, let baseline = automaticBaseline,
              Self.meaningfulChange(from: baseline, to: input),
              attemptedRevision != WritingReview.revision(input) else { return }
        idleTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: self.automaticDelay) } catch { return }
            guard !self.automaticPaused, self.currentInput == input, self.automaticAllowed(), !self.isRunning else { return }
            let configuration = self.automaticConfiguration()
            guard !configuration.model.isEmpty else { return }
            // Background work must never open a Keychain password dialog.
            // Saving the key or the first manual request authorizes this process session.
            guard let key = self.automaticKey?() ?? APIKeyStore().cachedKey else { return }
            self.start(input: input, configuration: configuration, key: key, automatic: true)
        }
    }
    func reply(runID: UUID, commentID: UUID, text: String, input: ReviewInput,
               configuration: LangdockConfiguration = .current, key: String? = nil) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !question.isEmpty,
              let r = history.firstIndex(where: { $0.id == runID }), !history[r].stale,
              history[r].revision == WritingReview.revision(input),
              let c = history[r].comments.firstIndex(where: { $0.id == commentID }),
              history[r].comments[c].status == "open", history[r].comments[c].matches(input.body) else { return }
        guard question.utf8.count <= 8000 else {
            history[r].comments[c].replyError = "Keep your message under 8,000 bytes."; return
        }
        cancel(); error = nil
        let comment = history[r].comments[c]
        var thread = comment.messages ?? []
        if thread.last?.role == "user", thread.last?.delivery == "failed", thread.last?.text == question {
            thread.removeLast()
        }
        let prior = thread.filter { $0.delivery != "failed" }
        thread.append(ReviewMessage(role: "user", text: question, delivery: "pending"))
        history[r].comments[c].messages = thread
        history[r].comments[c].replyError = nil
        persist(history[r])
        let credential: String
        do {
            guard !configuration.model.isEmpty else { throw ReviewError.message("Choose a model in Settings → Connections.") }
            guard let loaded = try key ?? APIKeyStore().load(), !loaded.isEmpty else {
                throw ReviewError.message("Add your Langdock API key in Settings → Connections.")
            }
            credential = loaded
        } catch { failReply(commentID, message: error.localizedDescription); return }
        isRunning = true; replyingTo = commentID
        requestRevision = WritingReview.revision(input)
        let token = generation
        task = Task { [weak self, client] in
            do {
                let answer = try await client.streamReply(input, suggestion: comment.suggestion,
                    messages: prior, question: question, configuration: configuration, key: credential) { [weak self] text in
                        guard let self, self.generation == token, self.replyingTo == commentID else { return }
                        self.streamingReply = text
                    }
                try Task.checkCancellation()
                guard let self, self.generation == token,
                      let r = self.history.firstIndex(where: { $0.id == runID }),
                      let c = self.history[r].comments.firstIndex(where: { $0.id == commentID }) else { return }
                var completed = self.history[r].comments[c].messages ?? []
                if !completed.isEmpty { completed[completed.count - 1].delivery = "sent" }
                completed.append(ReviewMessage(role: "assistant", text: answer.answer))
                self.history[r].comments[c].messages = completed
                if let replacement = answer.replacement {
                    let old = self.history[r].comments[c].suggestion
                    self.history[r].comments[c].suggestion = ReviewSuggestion(quote: old.quote, prefix: old.prefix,
                        suffix: old.suffix, explanation: old.explanation, replacement: replacement)
                    self.history[r].comments[c].rewriteQuote = comment.suggestion.quote
                }
                self.persist(self.history[r])
                self.streamingReply = ""; self.isRunning = false; self.replyingTo = nil; self.task = nil
            } catch {
                guard let self, self.generation == token else { return }
                self.failReply(commentID, message: (error as? ReviewError)?.localizedDescription ?? "Couldn't get a reply. Try again.")
                self.streamingReply = ""; self.isRunning = false; self.replyingTo = nil; self.task = nil
            }
        }
    }
    private func failReply(_ commentID: UUID, message: String) {
        guard let r = history.firstIndex(where: { $0.comments.contains { $0.id == commentID } }),
              let c = history[r].comments.firstIndex(where: { $0.id == commentID }) else { return }
        if var messages = history[r].comments[c].messages, !messages.isEmpty, messages.last?.delivery == "pending" {
            messages[messages.count - 1].delivery = "failed"
            history[r].comments[c].messages = messages
        }
        history[r].comments[c].replyError = message
        persist(history[r])
    }
    private func persist(_ run: WritingReview) {
        do { try workspace?.saveReview(run) }
        catch { fail("This review change could not be saved. Your writing is unaffected.") }
    }
    private func fail(_ message: String, quietly: Bool = false) {
        error = message
        if !quietly { reportError(message) }
    }
    func dismiss(runID: UUID, commentID: UUID) { setStatus("dismissed", runID: runID, commentID: commentID) }
    /// Explicit deletion from the side panel; the thread is removed from saved history.
    func delete(runID: UUID, commentID: UUID) {
        guard let run = history.firstIndex(where: { $0.id == runID }),
              history[run].comments.contains(where: { $0.id == commentID }) else { return }
        if replyingTo == commentID { cancel() }
        history[run].comments.removeAll { $0.id == commentID }
        if focusedCommentID == commentID { focusedCommentID = nil }
        persist(history[run])
    }
    private func setStatus(_ status: String, runID: UUID, commentID: UUID) {
        guard let run = history.firstIndex(where: { $0.id == runID }), let comment = history[run].comments.firstIndex(where: { $0.id == commentID }) else { return }
        history[run].comments[comment].status = status
        persist(history[run])
    }
    func locate(runID: UUID, commentID: UUID, input: ReviewInput, editor: WritingTextView) {
        guard let run = history.first(where: { $0.id == runID }), !run.stale, run.revision == WritingReview.revision(input), editor.string == input.body,
              let comment = run.comments.first(where: { $0.id == commentID }), comment.matches(editor.string) else { return }
        editor.window?.makeFirstResponder(editor)
        editor.setSelectedRange(comment.range)
        editor.scrollRangeToVisible(comment.range)
    }
    func accept(runID: UUID, commentID: UUID, input: ReviewInput, editor: WritingTextView) {
        guard let run = history.first(where: { $0.id == runID }), run.draftID == draftID, !run.stale,
              run.revision == WritingReview.revision(input), editor.string == input.body,
              let comment = run.comments.first(where: { $0.id == commentID }), comment.status == "open",
              let replacement = comment.suggestion.replacement, comment.rewriteApplies,
              comment.matches(editor.string) else {
            fail("The passage has changed. Review the current draft before accepting a rewrite."); return
        }
        editor.breakUndoCoalescing()
        editor.window?.makeFirstResponder(editor)
        let expected = (editor.string as NSString).replacingCharacters(in: comment.range, with: replacement)
        editor.insertText(replacement, replacementRange: comment.range)
        guard editor.string == expected else { fail("The rewrite could not be applied. Your review is still available."); return }
        setStatus("accepted", runID: runID, commentID: commentID)
        // Track unaffected passages through this accepted native edit.
        invalidate(ReviewInput(title: input.title, goal: input.goal, body: editor.string))
    }
}

struct WritingReviewPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var review: WritingReviewModel
    @ObservedObject var comments: UserCommentStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredComment: UUID?
    @State private var anchors: [UUID: CGFloat] = [:]
    @State private var selected: UUID?
    @State private var heights: [UUID: CGFloat] = [:]
    @State private var expandedHeights: [UUID: CGFloat] = [:]
    @State private var footerHeights: [UUID: CGFloat] = [:]
    @FocusState private var focusedReply: UUID?
    @State private var replyText: [UUID: String] = [:]
    private var run: WritingReview? { review.history.first }
    var body: some View {
        if model.active != nil {
            GeometryReader { geometry in
                let available = geometry.size.width - textRight - CommentMargin.cardGap - CommentMargin.outerMargin
                let compact = available < CommentMargin.minimumCardWidth
                let cardWidth: CGFloat = compact ? 40 : min(CommentMargin.cardWidth, available)
                let left = compact ? min(textRight + 16, geometry.size.width - cardWidth - 12) : textRight + CommentMargin.cardGap
                let items = marginItems
                let placed = positions(items, compact: compact, viewportHeight: geometry.size.height)
                ZStack(alignment: .topLeading) {
                    ReviewAnchorProbe(anchors: items.map { MarginAnchor(id: $0.id, range: $0.range) }, revision: model.reviewInput,
                                      threads: items.filter(\.isReview).map(\.range),
                                      highlighted: items.first { $0.id == (selected ?? hoveredComment) && $0.isReview }?.range,
                                      onChange: { anchors = $0 }, onTextRight: { textRight = $0 })
                        .allowsHitTesting(false)
                    ForEach(items) { item in
                        if let y = placed[item.id] {
                            if compact {
                                compactMarker(item, viewportHeight: geometry.size.height)
                                    .offset(x: left, y: y)
                            } else {
                                card(item, viewportHeight: geometry.size.height)
                                    .frame(width: cardWidth)
                                    .offset(x: left, y: y)
                            }
                        }
                    }
                }
                .onChange(of: review.focusRequest) { _, _ in
                    selected = review.focusedCommentID
                    focusedReply = review.focusedCommentID
                }
                .onChange(of: comments.marginRequest) { _, request in
                    guard let request else { return }
                    selected = request.id
                    if request.focus { DispatchQueue.main.async { if selected == request.id { focusedReply = request.id } } }
                }
                .onChange(of: selected) { previous, current in
                    if let previous, previous != current, comments.comments.contains(where: { $0.id == previous }) { comments.finishEditing(previous) }
                    if let current, comments.comments.contains(where: { $0.id == current }) { comments.activeID = current }
                }
                .onChange(of: review.history.first?.comments.flatMap { $0.messages ?? [] }.count) { _, _ in
                    for comment in run?.comments ?? [] {
                        if let sent = comment.messages?.last(where: { $0.role == "user" }), sent.text == replyText[comment.id]?.trimmingCharacters(in: .whitespacesAndNewlines) { replyText[comment.id] = "" }
                    }
                }
                .onPreferenceChange(ReviewCardHeights.self) { heights = $0 }
                .onPreferenceChange(ReviewExpandedHeights.self) { expandedHeights = $0 }
                .onPreferenceChange(ReviewFooterHeights.self) { footerHeights = $0 }
                .clipped()
            }
            .opacity(model.boardVisible || model.isBranching || model.boardFlight != nil ? 0 : 1)
            .allowsHitTesting(!model.boardVisible && !model.isBranching && model.boardFlight == nil)
            .sheet(isPresented: $review.historyVisible) {
                VStack(alignment: .leading) {
                    HStack { Text("Review history").font(.headline); Spacer(); Button("Done") { review.historyVisible = false } }
                    ScrollView { ForEach(review.history) { run in
                        Text(run.created, style: .time).font(.body)
                        reviewRun(run)
                    } }.scrollIndicators(.hidden)
                }.padding(20).frame(width: 400, height: 560)
            }
        }
    }
    @State private var textRight: CGFloat = 736
    /// Ask Matilde threads and private comments, in passage order, shown together in the margin.
    private var marginItems: [MarginItem] {
        var items: [MarginItem] = []
        if let run, !run.stale { items += run.comments.filter { $0.status == "open" }.map { .review(run, $0) } }
        items += comments.comments.filter { $0.attached && (!$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.id == selected) }.map { .note($0) }
        return items.sorted { $0.range.location < $1.range.location }
    }
    @ViewBuilder private func compactMarker(_ item: MarginItem, viewportHeight: CGFloat) -> some View {
        switch item {
        case let .review(run, comment):
            Button { openConversation(run, comment) } label: { MatildeIcon.askMatilde.image(size: 17).padding(8) }
                .buttonStyle(.plain).accessibilityLabel("Review: " + comment.suggestion.quote)
                .background(ConversationPointer())
                .background(Color(Paper.accent).opacity(hoveredComment == comment.id ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 6))
                .onHover { inside in hoveredComment = inside ? comment.id : nil }
                .popover(isPresented: Binding(get: { selected == comment.id }, set: { if !$0 { selected = nil } })) {
                    threadView(run, comment, maxHeight: min(460, max(200, viewportHeight - 80)))
                        .frame(width: CommentMargin.cardWidth)
                        .background(PopoverPaperBackground())
                }
        case let .note(note):
            // Narrow windows keep the editor's own popover, anchored to the highlighted passage.
            Button { withEditor { $0.showCommentPopover(note.id, focus: true) } } label: { MatildeIcon.note.image(size: 17).padding(8) }
                .buttonStyle(.plain).foregroundStyle(Color(Paper.muted)).accessibilityLabel("Comment: " + note.text)
                .background(ConversationPointer())
                .background(Color(Paper.accent).opacity(hoveredComment == note.id ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 6))
                .onHover { inside in hoveredComment = inside ? note.id : nil }
        }
    }
    private func card(_ item: MarginItem, viewportHeight: CGFloat) -> some View {
        let id = item.id
        let isSelected = selected == id
        let hovered = hoveredComment == id
        return VStack(alignment: .leading, spacing: 0) {
            switch item {
            case let .review(run, comment):
                if isSelected {
                    threadView(run, comment, maxHeight: min(420, max(180, viewportHeight - 160)))
                } else {
                    Button { openConversation(run, comment) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            reviewQuote(comment.suggestion.quote, lines: 2, kind: .matilde)
                            Text(comment.messages?.last?.text ?? (comment.suggestion.explanation.isEmpty ? "Ask about this passage…" : comment.suggestion.explanation)).font(.body).lineSpacing(3).lineLimit(3)
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                        .background(ConversationPointer())
                }
            case let .note(note):
                if isSelected { noteEditor(note) }
                else {
                    Button { openNote(note) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            reviewQuote(note.quote, lines: 2, kind: .note)
                            Text(note.text).font(.body).lineSpacing(3).lineLimit(4)
                                .foregroundStyle(Color(Paper.ink))
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                        .background(ConversationPointer())
                        .accessibilityLabel("Comment: " + note.text)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .background(Color(Paper.background), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(Paper.accent).opacity(hovered && !isSelected ? 0.03 : 0))
                .allowsHitTesting(false)
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color(Paper.accent).opacity(0.45) : Color(Paper.ink).opacity(hovered ? 0.16 : 0.09), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            if (hovered || isSelected) && archivable(item) {
                Button { archive(item) } label: {
                    MatildeIcon.archive.image(size: 16).frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Color(Paper.muted))
                .help("Archive").accessibilityLabel("Archive")
                .padding(.top, 8).padding(.trailing, 8)
                .transition(.opacity)
            }
        }
        .shadow(color: .black.opacity(isSelected ? 0.08 : hovered ? 0.05 : 0.025), radius: isSelected ? 10 : 6, y: 2)
        .onHover { inside in hoveredComment = inside ? id : (hoveredComment == id ? nil : hoveredComment) }
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.88), value: isSelected)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.88), value: expandedHeights[id])
        .background(GeometryReader { card in
            Color.clear.preference(key: ReviewCardHeights.self, value: [id: card.size.height])
        })
    }
    private func noteEditor(_ note: UserComment) -> some View {
        let empty = note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 12) {
            reviewQuote(note.quote, lines: 3, kind: .note)
            HStack(alignment: .bottom, spacing: 6) {
                TextField("Add a note…", text: Binding(get: { comments.comments.first { $0.id == note.id }?.text ?? "" },
                                                      set: { comments.update(note.id, text: $0) }), axis: .vertical)
                    .lineLimit(1...10).textFieldStyle(.plain).font(.body)
                    .foregroundStyle(Color(Paper.ink))
                    .focused($focusedReply, equals: note.id)
                    .onSubmit { closeNote(note.id) }
                    .accessibilityLabel("Comment")
                Button { closeNote(note.id) } label: { MatildeIcon.done.image(size: 20) }
                    .buttonStyle(.plain).foregroundStyle(Color(Paper.accent).opacity(empty ? 0.35 : 1))
                    .help("Done").accessibilityLabel("Done")
            }
            .composerField()
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(ConversationFocusBoundary { if selected == note.id { closeNote(note.id) } })
    }
    private func openNote(_ note: UserComment) {
        selected = note.id
        hoveredComment = nil
        DispatchQueue.main.async { if selected == note.id { focusedReply = note.id } }
    }
    private func closeNote(_ id: UUID) {
        if selected == id { selected = nil; focusedReply = nil }
        comments.finishEditing(id)
    }
    private func archivable(_ item: MarginItem) -> Bool {
        switch item {
        case .review: true
        case let .note(note): !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    /// Archived Ask Matilde threads stay in Review history; archived comments leave the margin.
    private func archive(_ item: MarginItem) {
        if selected == item.id { selected = nil; focusedReply = nil }
        if hoveredComment == item.id { hoveredComment = nil }
        switch item {
        case let .review(run, comment):
            replyText[comment.id] = nil
            if review.replyingTo == comment.id { review.cancel() }
            review.dismiss(runID: run.id, commentID: comment.id)
        case let .note(note): comments.archive(note.id)
        }
    }
    private func single(_ run: WritingReview, _ comment: ReviewComment) -> WritingReview {
        WritingReview(id: run.id, draftID: run.draftID, created: run.created, model: run.model,
                      revision: run.revision, stale: run.stale, comments: [comment])
    }
    private func positions(_ items: [MarginItem], compact: Bool, viewportHeight: CGFloat) -> [UUID: CGFloat] {
        var result: [UUID: CGFloat] = [:]
        var bottom: CGFloat = -.infinity
        let ordered = items.filter { anchors[$0.id] != nil }
        for item in ordered {
            let y = max(anchors[item.id]!, bottom + 12)
            result[item.id] = y
            bottom = y + (compact ? 36 : heights[item.id] ?? 120)
        }
        if !compact, let selected, let y = result[selected], let index = ordered.firstIndex(where: { $0.id == selected }) {
            result[selected] = max(100, min(y, viewportHeight - (heights[selected] ?? 300) - 12))
            var edge = result[selected]!
            for item in ordered.prefix(index).reversed() {
                result[item.id] = min(result[item.id]!, edge - (heights[item.id] ?? 120) - 12)
                edge = result[item.id]!
            }
            edge = result[selected]! + (heights[selected] ?? 300)
            for item in ordered.dropFirst(index + 1) {
                result[item.id] = max(result[item.id]!, edge + 12)
                edge = result[item.id]! + (heights[item.id] ?? 120)
            }
        }
        return result
    }
    /// Leaves room on the right for the archive button that appears on hover.
    private func reviewQuote(_ text: String, lines: Int, kind: PassageQuote.Kind) -> some View {
        PassageQuote(text: text, lines: lines, kind: kind).padding(.trailing, 22)
    }
    @ViewBuilder private func reviewRun(_ run: WritingReview, includeFooter: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if run.stale { Text("Draft changed · review again for current suggestions").font(.body).foregroundStyle(.secondary) }
            if run.comments.isEmpty { Text("No changes suggested.").font(.body).foregroundStyle(.secondary) }
            ForEach(run.comments) { comment in
                VStack(alignment: .leading, spacing: 10) {
                    Button { withEditor { review.locate(runID: run.id, commentID: comment.id, input: model.reviewInput, editor: $0) } } label: {
                        reviewQuote(comment.suggestion.quote, lines: 3, kind: .matilde)
                    }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(run.stale)
                    if !comment.suggestion.explanation.isEmpty {
                        Divider().padding(.vertical, 2)
                        Text(comment.suggestion.explanation).font(.body).lineSpacing(4).textSelection(.enabled)
                    }
                    if let replacement = comment.suggestion.replacement {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .center) {
                                Text("Suggested rewrite").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                                Spacer(minLength: 8)
                                if comment.status == "open" && !run.stale { acceptButton(run, comment) }
                            }
                            Text(replacement.isEmpty ? "Remove this passage" : replacement)
                                .font(.body).lineSpacing(4).textSelection(.enabled)
                        }.padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(Paper.ink).opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                    }
                    ForEach(comment.messages ?? []) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.role == "user" ? "You" : "Ask Matilde").font(.body.weight(.medium))
                                .foregroundStyle(message.role == "user" ? Color(Paper.accent) : Color(Paper.ink))
                            Text(message.text).font(.body).lineSpacing(3).textSelection(.enabled)
                            if message.delivery == "failed" { Text("No reply").font(.body).foregroundStyle(.secondary) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if review.replyingTo == comment.id {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Ask Matilde").font(.body.weight(.medium)).foregroundStyle(Color(Paper.ink))
                            if review.streamingReply.isEmpty {
                                ThinkingShimmer()
                            } else {
                                Text(review.streamingReply).font(.body).lineSpacing(3).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if includeFooter { replyFooter(run, comment) }
                    Color.clear.frame(height: 1).id("thread-end-" + comment.id.uuidString)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        if includeFooter { RoundedRectangle(cornerRadius: 10).fill(Color(Paper.background)) }
                    }
                    .overlay {
                        if includeFooter {
                            RoundedRectangle(cornerRadius: 10).strokeBorder(Color(Paper.ink).opacity(0.09), lineWidth: 1)
                        }
                    }
            }
        }
    }
    private func replyFooter(_ run: WritingReview, _ comment: ReviewComment) -> some View {
        VStack(alignment: .leading, spacing: 10) {
                    if let error = comment.replyError {
                        HStack(alignment: .top) {
                            Text(error).font(.body).foregroundStyle(.secondary)
                            if !run.stale, comment.status == "open", let last = comment.messages?.last, last.delivery == "failed" {
                                Button("Retry") { review.reply(runID: run.id, commentID: comment.id, text: last.text, input: model.reviewInput) }
                                    .buttonStyle(.plain).disabled(review.isRunning)
                            }
                        }
                    }
                    if comment.status == "open" && !run.stale {
                        HStack(alignment: .bottom, spacing: 6) {
                            TextField(comment.messages?.isEmpty != false ? "How can I help with this passage?" : "Reply…", text: Binding(get: { replyText[comment.id] ?? "" }, set: { replyText[comment.id] = $0 }), axis: .vertical)
                                .lineLimit(1...5).textFieldStyle(.plain).font(.body)
                                .focused($focusedReply, equals: comment.id)
                                .onAppear {
                                    if selected == comment.id && !review.historyVisible {
                                        DispatchQueue.main.async { if selected == comment.id { focusedReply = comment.id } }
                                    }
                                }
                                .onSubmit { sendReply(run, comment) }
                            if review.replyingTo == comment.id {
                                Button { review.cancel() } label: { MatildeIcon.stopReply.image(size: 20) }
                                    .buttonStyle(.plain).foregroundStyle(Color(Paper.accent))
                                    .help("Cancel").accessibilityLabel("Cancel")
                            } else {
                                let empty = (replyText[comment.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                Button { sendReply(run, comment) } label: { MatildeIcon.send.image(size: 20) }
                                    .buttonStyle(.plain).foregroundStyle(Color(Paper.accent).opacity(empty || review.isRunning ? 0.35 : 1))
                                    .disabled(review.isRunning || empty)
                                    .help("Send").accessibilityLabel("Send")
                            }
                        }
                        .composerField()
                    }
                    if comment.status != "open" { Text(comment.status.capitalized).font(.body).foregroundStyle(.secondary) }
        }
    }
    private func threadView(_ run: WritingReview, _ comment: ReviewComment, maxHeight: CGFloat) -> some View {
        let content = expandedHeights[comment.id] ?? 120
        let footer = footerHeights[comment.id] ?? 56
        return VStack(spacing: 0) {
            ScrollViewReader { reader in
                ScrollView {
                    reviewRun(single(run, comment), includeFooter: false)
                        .background(GeometryReader { content in
                            Color.clear.preference(key: ReviewExpandedHeights.self, value: [comment.id: content.size.height])
                        })
                }
                .scrollIndicators(.hidden)
                .onChange(of: review.replyingTo) { _, id in
                    if id == comment.id {
                        reader.scrollTo("thread-end-" + comment.id.uuidString, anchor: .bottom)
                    }
                }
                .onChange(of: review.streamingReply) { _, _ in
                    if review.replyingTo == comment.id {
                        reader.scrollTo("thread-end-" + comment.id.uuidString, anchor: .bottom)
                    }
                }
                .onChange(of: comment.messages?.count) { _, _ in
                    reader.scrollTo("thread-end-" + comment.id.uuidString, anchor: .bottom)
                }
            }
            Divider().opacity(content + footer > maxHeight ? 1 : 0)
            replyFooter(run, comment).padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 12)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { box in
                    Color.clear.preference(key: ReviewFooterHeights.self, value: [comment.id: box.size.height + 1])
                })
        }
        .frame(height: min(maxHeight, content + footer))
        .background(Color(Paper.background))
        .background(ConversationFocusBoundary {
            if selected == comment.id { selected = nil; focusedReply = nil }
        })
    }
    private func openConversation(_ run: WritingReview, _ comment: ReviewComment) {
        withEditor { review.locate(runID: run.id, commentID: comment.id, input: model.reviewInput, editor: $0) }
        selected = comment.id
        hoveredComment = nil
        DispatchQueue.main.async { if selected == comment.id { focusedReply = comment.id } }
    }
    /// Sits in the rewrite itself, so the composer stays alone at the bottom of the card.
    private func acceptButton(_ run: WritingReview, _ comment: ReviewComment) -> some View {
        let enabled = comment.rewriteApplies && !model.isBranching && model.boardFlight == nil
        return Button { withEditor { review.accept(runID: run.id, commentID: comment.id, input: model.reviewInput, editor: $0) } } label: {
            Label { Text("Accept") } icon: { MatildeIcon.check.image(size: 14) }.font(.callout.weight(.medium))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Color(Paper.background), in: Capsule())
                .overlay(Capsule().strokeBorder(Color(Paper.ink).opacity(0.12)))
                .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).foregroundStyle(Color(Paper.accent).opacity(enabled ? 1 : 0.4))
        .disabled(!enabled)
        .help(enabled ? "Replace the passage with this rewrite" : "The passage changed since this rewrite")
        .accessibilityLabel("Accept rewrite")
    }
    private func sendReply(_ run: WritingReview, _ comment: ReviewComment) {
        review.reply(runID: run.id, commentID: comment.id, text: replyText[comment.id] ?? "", input: model.reviewInput)
    }
    private func withEditor(_ action: (WritingTextView) -> Void) {
        func find(_ view: NSView) -> WritingTextView? {
            if let writing = view as? WritingTextView, writing.onEscape == nil { return writing }
            return view.subviews.lazy.compactMap(find).first
        }
        if let root = NSApp.keyWindow?.contentView, let editor = find(root) { action(editor) }
    }
}

enum CommentMargin {
    static let cardWidth: CGFloat = 280
    /// Narrowest card worth showing before falling back to compact markers.
    static let minimumCardWidth: CGFloat = 220
    /// Space between the end of the text and the cards.
    static let cardGap: CGFloat = 36
    /// The editor's horizontal text inset plus line-fragment padding on each side.
    static let textInset: CGFloat = 33
    /// Space kept between the cards and the window edge, matching the text's own inset on the left.
    static let outerMargin: CGFloat = textInset
    static let maximumColumn: CGFloat = 736
    static let minimumEditorWidth: CGFloat = 440
    /// How much wider the text-plus-cards group is than the editor column (which ends 28 points after its text).
    static var groupExtra: CGFloat { cardGap - 28 + cardWidth - textInset }
    static func fits(width: CGFloat) -> Bool { width - groupExtra - 2 * outerMargin >= minimumEditorWidth }
    /// The editor column's width and leading offset. With cards, the group from the text's left
    /// edge to the cards' right edge is centered, so both outer margins match.
    static func layout(width: CGFloat, reserve: Bool) -> (column: CGFloat, leading: CGFloat) {
        guard reserve else {
            let column = max(0, min(maximumColumn, width))
            return (column, max(0, (width - column) / 2))
        }
        let column = max(0, min(maximumColumn, width - groupExtra - 2 * outerMargin))
        return (column, max(0, (width - column - groupExtra) / 2 - textInset))
    }
}

private enum MarginItem: Identifiable {
    case review(WritingReview, ReviewComment)
    case note(UserComment)
    var id: UUID {
        switch self { case let .review(_, comment): comment.id; case let .note(note): note.id }
    }
    var range: NSRange {
        switch self { case let .review(_, comment): comment.range; case let .note(note): note.range }
    }
    var isReview: Bool { if case .review = self { true } else { false } }
}

struct MarginAnchor: Equatable {
    let id: UUID
    let range: NSRange
}

private struct ReviewExpandedHeights: PreferenceKey {
    static var defaultValue: [UUID: CGFloat] = [:]
    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

private struct ReviewFooterHeights: PreferenceKey {
    static var defaultValue: [UUID: CGFloat] = [:]
    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

private struct ReviewCardHeights: PreferenceKey {
    static var defaultValue: [UUID: CGFloat] = [:]
    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

/// Convert actual TextKit line positions into the floating margin's coordinates, and mark
/// Ask Matilde passages in the text: a quiet accent underline with a faint tint, stronger for the
/// thread that is hovered or open. Private comments keep their yellow highlighter instead.
private struct ReviewAnchorProbe: NSViewRepresentable {
    let anchors: [MarginAnchor]
    let revision: ReviewInput
    let threads: [NSRange]
    let highlighted: NSRange?
    let onChange: ([UUID: CGFloat]) -> Void
    let onTextRight: (CGFloat) -> Void
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.anchors = anchors; view.threads = threads; view.highlighted = highlighted
        view.onChange = onChange; view.onTextRight = onTextRight
        view.schedule()
    }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.clearHighlight() }
    static let markedAttributes: [NSAttributedString.Key] = [.backgroundColor, .underlineStyle, .underlineColor]
    final class Probe: NSView {
        override var isFlipped: Bool { true }
        var anchors: [MarginAnchor] = []
        var threads: [NSRange] = []
        var highlighted: NSRange?
        private weak var markedLayout: NSLayoutManager?
        private var marked: (threads: [NSRange], highlighted: NSRange?, length: Int)?
        func clearHighlight() {
            if let layout = markedLayout, let length = layout.textStorage?.length, length > 0 {
                // Temporary attributes move with edits, so clear them across the whole text.
                for key in ReviewAnchorProbe.markedAttributes {
                    layout.removeTemporaryAttribute(key, forCharacterRange: NSRange(location: 0, length: length))
                }
            }
            marked = nil; markedLayout = nil
        }
        private func mark(_ layout: NSLayoutManager, length: Int) {
            let valid = { (range: NSRange) in range.length > 0 && NSMaxRange(range) <= length }
            let wanted = (threads: threads.filter(valid), highlighted: highlighted.flatMap { valid($0) ? $0 : nil }, length: length)
            if let marked, markedLayout === layout, marked.threads == wanted.threads,
               marked.highlighted == wanted.highlighted, marked.length == wanted.length { return }
            clearHighlight()
            for range in wanted.threads {
                layout.addTemporaryAttributes([
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: Paper.accent.withAlphaComponent(0.5),
                    .backgroundColor: Paper.accent.withAlphaComponent(0.05)
                ], forCharacterRange: range)
            }
            if let range = wanted.highlighted {
                layout.addTemporaryAttributes([
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: Paper.accent.withAlphaComponent(0.85),
                    .backgroundColor: Paper.accent.withAlphaComponent(0.14)
                ], forCharacterRange: range)
            }
            marked = wanted; markedLayout = layout
        }
        var onChange: (([UUID: CGFloat]) -> Void)?
        var onTextRight: ((CGFloat) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var pending = false
        private var previous: [UUID: CGFloat] = [:]
        private var previousTextRight: CGFloat = 0
        override init(frame: NSRect) {
            super.init(frame: frame)
            for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification, NSText.didChangeNotification, NSWindow.didResizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.schedule() })
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); schedule() }
        override func layout() { super.layout(); schedule() }
        func schedule() {
            guard !pending else { return }; pending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.pending = false; self.measure()
            }
        }
        private func measure() {
            func find(_ view: NSView) -> WritingTextView? {
                if let editor = view as? WritingTextView, editor.onEscape == nil { return editor }
                return view.subviews.lazy.compactMap(find).first
            }
            guard let root = window?.contentView, let editor = find(root),
                  let layout = editor.layoutManager, let container = editor.textContainer else { return }
            editor.enclosingScrollView?.contentView.postsBoundsChangedNotifications = true
            layout.ensureLayout(for: container)
            mark(layout, length: (editor.string as NSString).length)
            var result: [UUID: CGFloat] = [:]
            for comment in anchors where NSMaxRange(comment.range) <= (editor.string as NSString).length && comment.range.length > 0 {
                let glyph = layout.glyphIndexForCharacter(at: comment.range.location)
                let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                result[comment.id] = convert(NSPoint(x: line.minX + editor.textContainerOrigin.x,
                                                     y: line.minY + editor.textContainerOrigin.y), from: editor).y
            }
            if result != previous { previous = result; onChange?(result) }
            let right = convert(NSPoint(x: editor.bounds.maxX - editor.textContainerInset.width, y: 0), from: editor).x
            if right != previousTextRight { previousTextRight = right; onTextRight?(right) }
        }
    }
}
