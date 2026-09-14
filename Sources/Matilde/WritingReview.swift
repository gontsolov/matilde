import AppKit
import SwiftUI
import CryptoKit

struct ReviewComment: Codable, Identifiable {
    let id: UUID
    var suggestion: ReviewSuggestion
    var location: Int
    let length: Int
    var status: String = "open"
    var messages: [ReviewMessage]? = nil
    var replyError: String? = nil
    var userInitiated: Bool? = nil
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
            comments.append(ReviewComment(id: UUID(), suggestion: suggestion, location: range.location, length: range.length))
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
    var automaticAllowed: () -> Bool = { true }
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
            catch { history = []; self.error = "Saved reviews could not be loaded." }
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
        var comment = ReviewComment(id: UUID(), suggestion: suggestion, location: range.location, length: range.length)
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
    func start(input: ReviewInput, configuration: LangdockConfiguration = .current, key: String? = nil) {
        cancel(); error = nil
        automaticBaseline = input; attemptedRevision = WritingReview.revision(input)
        guard let draftID, workspace != nil else { return }
        guard !input.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "Write a little first, then review your draft."; return }
        let credential: String
        do {
            guard !configuration.model.isEmpty else { throw ReviewError.message("Choose a model in Settings → Connections first.") }
            guard let loaded = try key ?? APIKeyStore().load(), !loaded.isEmpty else { throw ReviewError.message("Add your Langdock API key in Settings → Connections first.") }
            credential = loaded
        } catch { self.error = error.localizedDescription; return }
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
                self.error = (error as? ReviewError)?.localizedDescription ?? "The review could not be saved or completed. Please try again."
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
            self.start(input: input, configuration: configuration, key: key)
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
                    let old = comment.suggestion
                    self.history[r].comments[c].suggestion = ReviewSuggestion(quote: old.quote, prefix: old.prefix,
                        suffix: old.suffix, explanation: old.explanation, replacement: replacement)
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
        catch { self.error = "This review change could not be saved. Your writing is unaffected." }
    }
    func dismiss(runID: UUID, commentID: UUID) { setStatus("dismissed", runID: runID, commentID: commentID) }
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
              let replacement = comment.suggestion.replacement,
              comment.matches(editor.string) else {
            error = "The passage has changed. Review the current draft before accepting a rewrite."; return
        }
        editor.breakUndoCoalescing()
        editor.window?.makeFirstResponder(editor)
        let expected = (editor.string as NSString).replacingCharacters(in: comment.range, with: replacement)
        editor.insertText(replacement, replacementRange: comment.range)
        guard editor.string == expected else { error = "The rewrite could not be applied. Your review is still available."; return }
        setStatus("accepted", runID: runID, commentID: commentID)
        // Track unaffected passages through this accepted native edit.
        invalidate(ReviewInput(title: input.title, goal: input.goal, body: editor.string))
    }
}

struct WritingReviewPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var review: WritingReviewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredComment: UUID?
    @State private var anchors: [UUID: CGFloat] = [:]
    @State private var selected: UUID?
    @State private var heights: [UUID: CGFloat] = [:]
    @State private var expandedHeights: [UUID: CGFloat] = [:]
    @State private var historyVisible = false
    @FocusState private var focusedReply: UUID?
    @State private var replyText: [UUID: String] = [:]
    private var run: WritingReview? { review.history.first }
    var body: some View {
        if model.active != nil {
            GeometryReader { geometry in
                let available = geometry.size.width - textRight - 28
                let compact = available < 240
                let cardWidth: CGFloat = compact ? 40 : min(340, available)
                let left = min(textRight + 16, geometry.size.width - cardWidth - 12)
                ZStack(alignment: .topLeading) {
                    ReviewAnchorProbe(comments: run?.comments ?? [], revision: model.reviewInput,
                                      highlightedID: run?.stale == false ? selected : nil,
                                      onChange: { anchors = $0 }, onTextRight: { textRight = $0 })
                        .allowsHitTesting(false)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Menu {
                                if compact {
                                    Button(review.isRunning ? "Cancel review" : "Review now") {
                                        if review.isRunning { review.cancel() } else { model.reviewNow() }
                                    }
                                }
                                Button(review.automaticPaused ? "Resume automatic reviews" : "Pause automatic reviews") { review.toggleAutomatic() }
                                Button("Review history") { historyVisible = true }
                                    .disabled(review.history.isEmpty)
                            } label: {
                                Text("Writing assist").font(.body.weight(.medium))
                            }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .foregroundStyle(Color(Paper.ink))
                            .accessibilityLabel("Writing assist").help("Writing assist · Review history")
                            if !compact {
                                Spacer(minLength: 16)
                                Button(review.isRunning ? "Cancel" : "Review") {
                                    if review.isRunning { review.cancel() } else { model.reviewNow() }
                                }
                                .font(.body.weight(.medium)).buttonStyle(.plain)
                                .foregroundStyle(Color(Paper.accent))
                                .accessibilityLabel(review.isRunning ? "Cancel review" : "Review now")
                            }
                        }
                        if review.isRunning && review.replyingTo == nil { HStack { ProgressView().controlSize(.small); Text("Reviewing…").font(.body).foregroundStyle(.secondary) } }
                        if review.automaticPaused && !compact { Text("Automatic reviews paused").font(.caption).foregroundStyle(.secondary) }
                        if !compact {
                            if let error = review.error { Text(error).font(.body).foregroundStyle(.secondary) }
                            else if run?.stale == true || run?.comments.contains(where: { $0.status == "stale" }) == true { Text("Draft changed · review again").font(.body).foregroundStyle(.secondary) }
                            else if run?.comments.isEmpty == true { Text("No changes suggested.").font(.body).foregroundStyle(.secondary) }
                        }
                    }.padding(.top, 18).padding(.bottom, 12)
                        .frame(width: compact ? 110 : cardWidth, alignment: .leading)
                        .background(Color(Paper.background))
                        .offset(x: compact ? max(0, geometry.size.width - 122) : left).zIndex(1)
                    if let run, !run.stale {
                        ForEach(run.comments.filter { $0.status == "open" }) { comment in
                            if let y = positions(compact: compact, viewportHeight: geometry.size.height)[comment.id] {
                                if compact {
                                    Button {
                                        openConversation(run, comment)
                                    } label: { Image(systemName: "text.bubble.fill").padding(8) }
                                        .buttonStyle(.plain).accessibilityLabel("Review: " + comment.suggestion.quote)
                                        .background(ConversationPointer())
                                        .background(Color(Paper.accent).opacity(hoveredComment == comment.id ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 6))
                                        .onHover { inside in hoveredComment = inside ? comment.id : nil }
                                        .popover(isPresented: Binding(get: { selected == comment.id }, set: { if !$0 { selected = nil } })) {
                                            threadView(run, comment, height: min(500, max(220, geometry.size.height - 80)))
                                                .padding(12).frame(width: 340)
                                        }
                                        .offset(x: left, y: y)
                                } else {
                                    VStack(alignment: .leading, spacing: 0) {
                                        if selected == comment.id {
                                            threadView(run, comment, height: min((expandedHeights[comment.id] ?? 150) + 120, min(420, max(180, geometry.size.height - 160))))
                                        } else {
                                            Button {
                                                openConversation(run, comment)
                                            } label: {
                                                VStack(alignment: .leading, spacing: 8) {
                                                    reviewQuote(comment.suggestion.quote, lines: 2)
                                                    Text(comment.messages?.last?.text ?? (comment.suggestion.explanation.isEmpty ? "Ask about this passage…" : comment.suggestion.explanation)).font(.body).lineSpacing(3).lineLimit(3)
                                                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                            }.buttonStyle(.plain)
                                                .background(ConversationPointer())
                                        }
                                    }
                                    .frame(width: cardWidth)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .background(Color(Paper.background), in: RoundedRectangle(cornerRadius: 12))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(Color(Paper.accent).opacity(selected == comment.id ? 0.025 : hoveredComment == comment.id ? 0.045 : 0))
                                            .allowsHitTesting(false)
                                        RoundedRectangle(cornerRadius: 12)
                                            .strokeBorder(selected == comment.id ? Color(Paper.accent).opacity(0.6) : Color(Paper.ink).opacity(hoveredComment == comment.id ? 0.28 : 0.16), lineWidth: selected == comment.id ? 1.5 : 1)
                                            .allowsHitTesting(false)
                                    }
                                    .shadow(color: .black.opacity(selected == comment.id ? 0.10 : hoveredComment == comment.id ? 0.08 : 0.04), radius: selected == comment.id ? 10 : 7, y: 3)
                                    .onHover { inside in hoveredComment = inside ? comment.id : (hoveredComment == comment.id ? nil : hoveredComment) }
                                    .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.88), value: selected == comment.id)
                                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hoveredComment == comment.id)
                                    .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.88), value: expandedHeights[comment.id])
                                    .background(GeometryReader { card in
                                        Color.clear.preference(key: ReviewCardHeights.self, value: [comment.id: card.size.height])
                                    })
                                    .offset(x: left, y: y)
                                }
                            }
                        }
                    }
                }
                .onChange(of: review.focusRequest) { _, _ in
                    selected = review.focusedCommentID
                    focusedReply = review.focusedCommentID
                }
                .onChange(of: review.history.first?.comments.flatMap { $0.messages ?? [] }.count) { _, _ in
                    for comment in run?.comments ?? [] {
                        if let sent = comment.messages?.last(where: { $0.role == "user" }), sent.text == replyText[comment.id]?.trimmingCharacters(in: .whitespacesAndNewlines) { replyText[comment.id] = "" }
                    }
                }
                .onPreferenceChange(ReviewCardHeights.self) { heights = $0 }
                .onPreferenceChange(ReviewExpandedHeights.self) { expandedHeights = $0 }
                .clipped()
            }
            .opacity(model.boardVisible || model.isBranching || model.boardFlight != nil ? 0 : 1)
            .allowsHitTesting(!model.boardVisible && !model.isBranching && model.boardFlight == nil)
            .sheet(isPresented: $historyVisible) {
                VStack(alignment: .leading) {
                    HStack { Text("Review history").font(.headline); Spacer(); Button("Done") { historyVisible = false } }
                    ScrollView { ForEach(review.history) { run in
                        Text(run.created, style: .time).font(.body)
                        reviewRun(run)
                    } }
                }.padding(20).frame(width: 400, height: 560)
            }
        }
    }
    @State private var textRight: CGFloat = 736
    private func single(_ run: WritingReview, _ comment: ReviewComment) -> WritingReview {
        WritingReview(id: run.id, draftID: run.draftID, created: run.created, model: run.model,
                      revision: run.revision, stale: run.stale, comments: [comment])
    }
    private func positions(compact: Bool, viewportHeight: CGFloat) -> [UUID: CGFloat] {
        var result: [UUID: CGFloat] = [:]
        var bottom: CGFloat = -.infinity
        for comment in (run?.comments ?? []).filter({ $0.status == "open" }).sorted(by: { $0.location < $1.location }) {
            guard let anchor = anchors[comment.id] else { continue }
            let y = max(anchor, bottom + 12)
            result[comment.id] = y
            bottom = y + (compact ? 36 : heights[comment.id] ?? 120)
        }
        if !compact, let selected, let y = result[selected] {
            let ordered = (run?.comments ?? []).filter { result[$0.id] != nil }.sorted { $0.location < $1.location }
            if let index = ordered.firstIndex(where: { $0.id == selected }) {
                result[selected] = max(100, min(y, viewportHeight - (heights[selected] ?? 300) - 12))
                var edge = result[selected]!
                for comment in ordered.prefix(index).reversed() {
                    result[comment.id] = min(result[comment.id]!, edge - (heights[comment.id] ?? 120) - 12)
                    edge = result[comment.id]!
                }
                edge = result[selected]! + (heights[selected] ?? 300)
                for comment in ordered.dropFirst(index + 1) {
                    result[comment.id] = max(result[comment.id]!, edge + 12)
                    edge = result[comment.id]! + (heights[comment.id] ?? 120)
                }
            }
        }
        return result
    }
    private func reviewQuote(_ text: String, lines: Int) -> some View {
        Text(text).font(.body).foregroundStyle(.secondary).lineSpacing(3).lineLimit(lines)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 10).padding(.vertical, 3)
            .overlay(alignment: .leading) {
                Rectangle().fill(Color(Paper.muted).opacity(0.55)).frame(width: 2)
            }
    }
    @ViewBuilder private func reviewRun(_ run: WritingReview, includeFooter: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if run.stale { Text("Draft changed · review again for current suggestions").font(.body).foregroundStyle(.secondary) }
            if run.comments.isEmpty { Text("No changes suggested.").font(.body).foregroundStyle(.secondary) }
            ForEach(run.comments) { comment in
                VStack(alignment: .leading, spacing: 10) {
                    Button { withEditor { review.locate(runID: run.id, commentID: comment.id, input: model.reviewInput, editor: $0) } } label: {
                        reviewQuote(comment.suggestion.quote, lines: 3)
                    }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(run.stale)
                    if !comment.suggestion.explanation.isEmpty {
                        Divider().padding(.vertical, 2)
                        Text(comment.suggestion.explanation).font(.body).lineSpacing(4).textSelection(.enabled)
                    }
                    if let replacement = comment.suggestion.replacement {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Suggested rewrite").font(.body.weight(.medium)).foregroundStyle(.secondary)
                            Text(replacement.isEmpty ? "Remove this passage" : replacement)
                                .font(.body).lineSpacing(4).textSelection(.enabled)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(Paper.ink).opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
                    }
                    ForEach(comment.messages ?? []) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.role == "user" ? "You" : "Writing assist").font(.body.weight(.medium))
                                .foregroundStyle(message.role == "user" ? Color(Paper.accent) : Color(Paper.ink))
                            Text(message.text).font(.body).lineSpacing(3).textSelection(.enabled)
                            if message.delivery == "failed" { Text("No reply").font(.body).foregroundStyle(.secondary) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if review.replyingTo == comment.id {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Writing assist").font(.body.weight(.medium)).foregroundStyle(Color(Paper.ink))
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
                        if includeFooter { RoundedRectangle(cornerRadius: 12).fill(Color(Paper.background)) }
                    }
                    .overlay {
                        if includeFooter {
                            RoundedRectangle(cornerRadius: 12).strokeBorder(Color(Paper.ink).opacity(0.14), lineWidth: 1)
                        }
                    }
                    .shadow(color: .black.opacity(includeFooter ? 0.035 : 0), radius: 3, y: 2)
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
                        HStack(alignment: .bottom, spacing: 8) {
                            TextField(comment.messages?.isEmpty != false ? "How can I help with this passage?" : "Reply…", text: Binding(get: { replyText[comment.id] ?? "" }, set: { replyText[comment.id] = $0 }), axis: .vertical)
                                .lineLimit(1...5).textFieldStyle(.plain).font(.body)
                                .focused($focusedReply, equals: comment.id)
                                .onAppear {
                                    if selected == comment.id && !historyVisible {
                                        DispatchQueue.main.async { if selected == comment.id { focusedReply = comment.id } }
                                    }
                                }
                                .onSubmit { sendReply(run, comment) }
                            if review.replyingTo == comment.id {
                                Button("Cancel") { review.cancel() }
                                    .buttonStyle(.plain).foregroundStyle(Color(Paper.accent))
                            } else {
                                Button("Send") { sendReply(run, comment) }
                                    .buttonStyle(.plain).foregroundStyle(Color(Paper.accent))
                                    .disabled(review.isRunning || (replyText[comment.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }.padding(10).background(Color(Paper.ink).opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if comment.status == "open" {
                        HStack {
                            if comment.suggestion.replacement != nil {
                                Button("Accept rewrite") { withEditor { review.accept(runID: run.id, commentID: comment.id, input: model.reviewInput, editor: $0) } }.disabled(run.stale || comment.status == "stale" || model.isBranching || model.boardFlight != nil)
                            }
                        }
                    } else { Text(comment.status.capitalized).font(.body).foregroundStyle(.secondary) }
        }
    }
    private func threadView(_ run: WritingReview, _ comment: ReviewComment, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { reader in
                ScrollView {
                    reviewRun(single(run, comment), includeFooter: false)
                        .background(GeometryReader { content in
                            Color.clear.preference(key: ReviewExpandedHeights.self, value: [comment.id: content.size.height])
                        })
                }
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
            Divider()
            replyFooter(run, comment).padding(12)
                .background(Color(Paper.background))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(height: height)
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

private struct ReviewExpandedHeights: PreferenceKey {
    static var defaultValue: [UUID: CGFloat] = [:]
    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

private struct ReviewCardHeights: PreferenceKey {
    static var defaultValue: [UUID: CGFloat] = [:]
    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

/// Convert actual TextKit line positions into the floating margin's coordinates.
private struct ReviewAnchorProbe: NSViewRepresentable {
    let comments: [ReviewComment]
    let revision: ReviewInput
    let highlightedID: UUID?
    let onChange: ([UUID: CGFloat]) -> Void
    let onTextRight: (CGFloat) -> Void
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.comments = comments; view.highlightedID = highlightedID; view.onChange = onChange; view.onTextRight = onTextRight
        view.schedule()
    }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.clearHighlight() }
    final class Probe: NSView {
        override var isFlipped: Bool { true }
        var comments: [ReviewComment] = []
        var highlightedID: UUID?
        private weak var highlightedLayout: NSLayoutManager?
        private var highlightedRange: NSRange?
        func clearHighlight() {
            if let highlightedRange, let layout = highlightedLayout {
                let valid = NSIntersectionRange(highlightedRange, NSRange(location: 0, length: layout.textStorage?.length ?? 0))
                if valid.length > 0 { layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: valid) }
            }
            highlightedRange = nil; highlightedLayout = nil
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
            let requested = comments.first(where: { $0.id == highlightedID })?.range
            if requested != highlightedRange || highlightedLayout !== layout {
                clearHighlight()
                if let requested, NSMaxRange(requested) <= (editor.string as NSString).length {
                    layout.addTemporaryAttribute(.backgroundColor, value: Paper.accent.withAlphaComponent(0.16), forCharacterRange: requested)
                    highlightedRange = requested; highlightedLayout = layout
                }
            }
            var result: [UUID: CGFloat] = [:]
            for comment in comments where NSMaxRange(comment.range) <= (editor.string as NSString).length && comment.length > 0 {
                let glyph = layout.glyphIndexForCharacter(at: comment.location)
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
