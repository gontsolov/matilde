import Foundation
#if canImport(Combine)
import Combine

/// Ask Matilde reviews and threads for one draft: requests, replies, unread state and passage
/// tracking. Shared by the Mac and iOS apps; each app applies accepted rewrites in its own editor.
@MainActor
public final class WritingReviewModel: ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var history: [WritingReview] = []
    @Published public var error: String?
    private var workspace: Workspace?
    public private(set) var draftID: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var requestRevision: String?
    private var currentInput: ReviewInput?
    private var idleTask: Task<Void, Never>?
    private var automaticBaseline: ReviewInput?
    private var attemptedRevision: String?
    @Published public private(set) var automaticPaused = UserDefaults.standard.bool(forKey: "writingAssist.paused")
    @Published public private(set) var streamingReply = ""
    @Published public private(set) var replyingTo: UUID?
    @Published public private(set) var focusedCommentID: UUID?
    @Published public private(set) var focusRequest = UUID()
    @Published public var historyVisible = false
    /// The thread open in the margin; replies arriving there are read right away.
    @Published public private(set) var openThreadID: UUID?
    public var automaticAllowed: () -> Bool = { true }
    public var reportError: (String) -> Void = { _ in }
    public var automaticDelay: Duration = .seconds(30)
    public var automaticConfiguration: () -> LangdockConfiguration = { .current }
    public var automaticKey: (() -> String?)? // Test seam; production loads Keychain only when due.

    public let client: LangdockServing
    public init(client: LangdockServing = LangdockClient()) { self.client = client }

    public func bind(workspace: Workspace?, draftID: String?, input: ReviewInput) {
        if self.workspace !== workspace || self.draftID != draftID {
            cancel(); idleTask?.cancel(); automaticBaseline = input; attemptedRevision = nil
            self.workspace = workspace; self.draftID = draftID
            error = nil
            do { history = try draftID.map { try workspace?.reviewHistory(draftID: $0) ?? [] } ?? [] }
            catch { history = []; fail("Saved reviews could not be loaded.") }
            focusedCommentID = nil; openThreadID = nil
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
    public func beginSelection(_ range: NSRange, input: ReviewInput) {
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
        comment.reviewedQuote = comment.quote
        history[0].comments.append(comment)
        persist(history[0]); focusedCommentID = comment.id; focusRequest = UUID()
    }
    /// Sync changed the database: re-read this draft's reviews and threads while nothing is running.
    public func reload() {
        guard !isRunning, replyingTo == nil, let workspace, let draftID,
              let loaded = try? workspace.reviewHistory(draftID: draftID) else { return }
        history = loaded
    }
    public func changed(workspace: Workspace?, draftID: String?, input: ReviewInput) {
        guard self.workspace === workspace, self.draftID == draftID else { cancel(); return }
        invalidate(input)
        scheduleAutomatic(input)
    }
    public func invalidate(_ input: ReviewInput) {
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
    public func cancel() {
        streamingReply = ""
        if let replyingTo { failReply(replyingTo, message: "Reply cancelled. Try again.") }
        generation = UUID(); task?.cancel(); task = nil; isRunning = false; requestRevision = nil; replyingTo = nil; idleTask?.cancel()
    }
    /// Errors from automatic reviews only mark the toolbar control; others are also reported.
    public func start(input: ReviewInput, configuration: LangdockConfiguration = .current, key: String? = nil, automatic: Bool = false) {
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
        // Everything already said about this draft goes with the request, so the review doesn't
        // repeat it (AI-19): Ask Matilde comments in every state and the writer's own comments.
        let commentContext = existingComments(body: input.body)
        task = Task { [weak self, client] in
            do {
                let suggestions = try await client.review(input, existing: commentContext, configuration: configuration, key: credential)
                try Task.checkCancellation()
                var result = try WritingReview.make(draftID: draftID, input: input, model: configuration.model, suggestions: suggestions)
                guard let self, self.generation == token else { return }
                // Carry open threads forward and drop suggestions that repeat an existing comment:
                // unchanged quotes of earlier reviews, then the overlap-and-wording check.
                let existing = self.history.first?.comments ?? []
                let oldQuotes = Set(self.history.flatMap(\.comments).filter { $0.status != "stale" && input.body.contains($0.suggestion.quote) }.map { $0.suggestion.quote })
                result.comments.removeAll { oldQuotes.contains($0.suggestion.quote) }
                result.comments = ReviewDeduplication.filter(result.comments, against: commentContext)
                for index in result.comments.indices { result.comments[index].unread = true }
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
    /// The draft's comments as the next review should see them (`ReviewContext`).
    public func existingComments(body: String) -> [ExistingComment] {
        let notes = draftID.flatMap { try? workspace?.userComments(draftID: $0) } ?? []
        let archived = draftID.flatMap { try? workspace?.archivedUserComments(draftID: $0) } ?? []
        return ReviewContext.existingComments(history: history, notes: notes, archivedNotes: archived, body: body)
    }
    public func toggleAutomatic() {
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
    public func reply(runID: UUID, commentID: UUID, text: String, input: ReviewInput,
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
        let conversation = comment.replyConversation(input: input, prior: prior, question: question)
        thread.append(ReviewMessage(role: "user", text: question, delivery: "pending", prompt: conversation.turn))
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
                let answer = try await client.streamReply(conversation, configuration: configuration, key: credential) { [weak self] text in
                        guard let self, self.generation == token, self.replyingTo == commentID else { return }
                        self.streamingReply = text
                    }
                try Task.checkCancellation()
                guard let self, self.generation == token,
                      let r = self.history.firstIndex(where: { $0.id == runID }),
                      let c = self.history[r].comments.firstIndex(where: { $0.id == commentID }) else { return }
                var completed = self.history[r].comments[c].messages ?? []
                if !completed.isEmpty { completed[completed.count - 1].delivery = "sent" }
                var reply = ReviewMessage(role: "assistant", text: answer.answer)
                reply.replacement = answer.replacement
                completed.append(reply)
                self.history[r].comments[c].messages = completed
                var context = conversation.context
                context.known = input.transmitted
                self.history[r].comments[c].replyContext = context
                if self.openThreadID != commentID { self.history[r].comments[c].unread = true }
                if let replacement = answer.replacement {
                    let old = self.history[r].comments[c].suggestion
                    if self.history[r].comments[c].rewriteMessageID == nil {
                        self.history[r].comments[c].initialReplacement = old.replacement
                    }
                    self.history[r].comments[c].suggestion = ReviewSuggestion(quote: old.quote, prefix: old.prefix,
                        suffix: old.suffix, explanation: old.explanation, replacement: replacement)
                    self.history[r].comments[c].rewriteMessageID = reply.id
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
    public func fail(_ message: String, quietly: Bool = false) {
        error = message
        if !quietly { reportError(message) }
    }
    /// The margin opened (or, with `nil`, closed) a thread. Opening marks it read.
    public func threadOpened(_ commentID: UUID?) {
        openThreadID = commentID
        if let commentID { markRead(commentID) }
    }
    public func markRead(_ commentID: UUID) {
        // Open threads carried into a newer review share their id with the older copy.
        for r in history.indices {
            guard let c = history[r].comments.firstIndex(where: { $0.id == commentID && $0.isUnread }) else { continue }
            history[r].comments[c].unread = nil
            persist(history[r])
        }
    }
    public func dismiss(runID: UUID, commentID: UUID) { setStatus("dismissed", runID: runID, commentID: commentID) }
    /// Explicit deletion from the side panel; the thread is removed from saved history.
    public func delete(runID: UUID, commentID: UUID) {
        guard let run = history.firstIndex(where: { $0.id == runID }),
              history[run].comments.contains(where: { $0.id == commentID }) else { return }
        if replyingTo == commentID { cancel() }
        history[run].comments.removeAll { $0.id == commentID }
        if focusedCommentID == commentID { focusedCommentID = nil }
        persist(history[run])
    }
    public func setStatus(_ status: String, runID: UUID, commentID: UUID) {
        guard let run = history.firstIndex(where: { $0.id == runID }), let comment = history[run].comments.firstIndex(where: { $0.id == commentID }) else { return }
        history[run].comments[comment].status = status
        persist(history[run])
    }
}

extension WritingReviewModel {
    public static func meaningfulChange(from old: ReviewInput, to new: ReviewInput) -> Bool {
        func words(_ value: String) -> String {
            value.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        }
        return words(old.body) != words(new.body) || words(old.goal) != words(new.goal)
    }
}
#endif
