import AppKit
import SwiftUI
import CryptoKit

struct ReviewComment: Codable, Identifiable {
    let id: UUID
    let suggestion: ReviewSuggestion
    let location: Int
    let length: Int
    var status: String = "open"
    var range: NSRange { NSRange(location: location, length: length) }
}

struct WritingReview: Codable, Identifiable {
    let id: UUID
    let draftID: String
    let created: Date
    let model: String
    let revision: String
    var stale: Bool
    var comments: [ReviewComment]

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
        return Self(id: UUID(), draftID: draftID, created: Date(), model: model, revision: revision(input), stale: false, comments: comments)
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
    @Published var isOpen = false
    @Published private(set) var isRunning = false
    @Published private(set) var history: [WritingReview] = []
    @Published var error: String?
    private var workspace: Workspace?
    private var draftID: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var requestRevision: String?
    let client: LangdockServing
    init(client: LangdockServing = LangdockClient()) { self.client = client }

    func bind(workspace: Workspace?, draftID: String?, input: ReviewInput) {
        if self.workspace !== workspace || self.draftID != draftID {
            cancel()
            self.workspace = workspace; self.draftID = draftID
            error = nil
            do { history = try draftID.map { try workspace?.reviewHistory(draftID: $0) ?? [] } ?? [] }
            catch { history = []; self.error = "Saved reviews could not be loaded." }
        }
        invalidate(input)
    }
    func changed(workspace: Workspace?, draftID: String?, input: ReviewInput) {
        guard self.workspace === workspace, self.draftID == draftID else { cancel(); return }
        invalidate(input)
    }
    func invalidate(_ input: ReviewInput) {
        guard isRunning || !history.isEmpty else { return }
        let revision = WritingReview.revision(input)
        if isRunning && requestRevision != revision { cancel() }
        for index in history.indices where !history[index].stale && history[index].revision != revision {
            history[index].stale = true
            persist(history[index])
        }
    }
    func cancel() {
        generation = UUID(); task?.cancel(); task = nil; isRunning = false; requestRevision = nil
    }
    func start(input: ReviewInput, configuration: LangdockConfiguration = .current, key: String? = nil) {
        isOpen = true
        cancel(); error = nil
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
                let result = try WritingReview.make(draftID: draftID, input: input, model: configuration.model, suggestions: suggestions)
                guard let self, self.generation == token else { return }
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
              let comment = run.comments.first(where: { $0.id == commentID }), WritingReview.anchor(comment.suggestion, in: editor.string) == comment.range else { return }
        editor.window?.makeFirstResponder(editor)
        editor.setSelectedRange(comment.range)
        editor.scrollRangeToVisible(comment.range)
    }
    func accept(runID: UUID, commentID: UUID, input: ReviewInput, editor: WritingTextView) {
        guard let run = history.first(where: { $0.id == runID }), run.draftID == draftID, !run.stale,
              run.revision == WritingReview.revision(input), editor.string == input.body,
              let comment = run.comments.first(where: { $0.id == commentID }), comment.status == "open",
              let replacement = comment.suggestion.replacement,
              WritingReview.anchor(comment.suggestion, in: editor.string) == comment.range else {
            error = "The passage has changed. Review the current draft before accepting a rewrite."; return
        }
        editor.breakUndoCoalescing()
        editor.window?.makeFirstResponder(editor)
        let expected = (editor.string as NSString).replacingCharacters(in: comment.range, with: replacement)
        editor.insertText(replacement, replacementRange: comment.range)
        guard editor.string == expected else { error = "The rewrite could not be applied. Your review is still available."; return }
        setStatus("accepted", runID: runID, commentID: commentID)
        // Keep other suggestions stale after a replacement; never reinterpret them.
        invalidate(ReviewInput(title: input.title, goal: input.goal, body: editor.string))
    }
}

struct WritingReviewPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var review: WritingReviewModel
    @State private var anchors: [UUID: CGFloat] = [:]
    @State private var selected: UUID?
    @State private var heights: [UUID: CGFloat] = [:]
    @State private var expandedHeights: [UUID: CGFloat] = [:]
    @State private var historyVisible = false
    private var run: WritingReview? { review.history.first }
    var body: some View {
        if review.isOpen && model.active != nil {
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
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Menu {
                                Button("Review now") { model.reviewNow() }.disabled(review.isRunning)
                                Button("Review history") { historyVisible = true }
                                if review.isRunning { Button("Cancel review") { review.cancel() } }
                            } label: { Image(systemName: "text.bubble") }
                                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Writing review")
                            if !compact { Text("Writing review").font(.body).foregroundStyle(.secondary) }
                            Spacer(minLength: 0)
                            Button { review.isOpen = false } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).accessibilityLabel("Close writing review")
                        }
                        if review.isRunning { ProgressView().controlSize(.small) }
                        if !compact {
                            if let error = review.error { Text(error).font(.body).foregroundStyle(.secondary) }
                            else if run?.stale == true { Text("Draft changed · review again").font(.body).foregroundStyle(.secondary) }
                            else if run?.comments.isEmpty == true { Text("No changes suggested.").font(.body).foregroundStyle(.secondary) }
                            else if run == nil { Button("Review now") { model.reviewNow() } }
                        }
                    }.padding(.top, 18).padding(.bottom, 12)
                        .frame(width: cardWidth).background(Color(Paper.background)).offset(x: left).zIndex(1)
                    if let run, !run.stale {
                        ForEach(run.comments.filter { $0.status == "open" }) { comment in
                            if let y = positions(compact: compact)[comment.id] {
                                if compact {
                                    Button {
                                        selected = comment.id
                                        withEditor { review.locate(runID: run.id, commentID: comment.id, input: model.reviewInput, editor: $0) }
                                    } label: { Image(systemName: "text.bubble.fill").padding(8) }
                                        .buttonStyle(.plain).accessibilityLabel("Review: " + comment.suggestion.quote)
                                        .popover(isPresented: Binding(get: { selected == comment.id }, set: { if !$0 { selected = nil } })) {
                                            reviewRun(single(run, comment)).padding(12).frame(width: 340)
                                        }
                                        .offset(x: left, y: y)
                                } else {
                                    VStack(alignment: .leading, spacing: 0) {
                                        if selected == comment.id {
                                            ScrollView {
                                                reviewRun(single(run, comment))
                                                    .background(GeometryReader { content in
                                                        Color.clear.preference(key: ReviewExpandedHeights.self, value: [comment.id: content.size.height])
                                                    })
                                            }
                                                .frame(height: min(expandedHeights[comment.id] ?? 260, min(420, max(180, geometry.size.height - 100))))
                                            Button("Collapse") { selected = nil }.buttonStyle(.plain).font(.body).padding(8)
                                        } else {
                                            Button {
                                                selected = comment.id
                                                withEditor { review.locate(runID: run.id, commentID: comment.id, input: model.reviewInput, editor: $0) }
                                            } label: {
                                                VStack(alignment: .leading, spacing: 8) {
                                                    reviewQuote(comment.suggestion.quote, lines: 2)
                                                    Text(comment.suggestion.explanation).font(.body).lineSpacing(3).lineLimit(3)
                                                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                            }.buttonStyle(.plain)
                                        }
                                    }
                                    .frame(width: cardWidth)
                                    .background(Color(Paper.background), in: RoundedRectangle(cornerRadius: 12))
                                    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color(Paper.ink).opacity(0.16)) }
                                    .shadow(color: .black.opacity(0.06), radius: 7, y: 3)
                                    .background(GeometryReader { card in
                                        Color.clear.preference(key: ReviewCardHeights.self, value: [comment.id: card.size.height])
                                    })
                                    .offset(x: left, y: y)
                                }
                            }
                        }
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
    private func positions(compact: Bool) -> [UUID: CGFloat] {
        var result: [UUID: CGFloat] = [:]
        var bottom: CGFloat = -.infinity
        for comment in (run?.comments ?? []).filter({ $0.status == "open" }).sorted(by: { $0.location < $1.location }) {
            guard let anchor = anchors[comment.id] else { continue }
            let y = max(anchor, bottom + 12)
            result[comment.id] = y
            bottom = y + (compact ? 36 : heights[comment.id] ?? 120)
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
    @ViewBuilder private func reviewRun(_ run: WritingReview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if run.stale { Text("Draft changed · review again for current suggestions").font(.body).foregroundStyle(.secondary) }
            if run.comments.isEmpty { Text("No changes suggested.").font(.body).foregroundStyle(.secondary) }
            ForEach(run.comments) { comment in
                VStack(alignment: .leading, spacing: 10) {
                    Button { withEditor { review.locate(runID: run.id, commentID: comment.id, input: model.reviewInput, editor: $0) } } label: {
                        reviewQuote(comment.suggestion.quote, lines: 3)
                    }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(run.stale)
                    Divider().padding(.vertical, 2)
                    Text(comment.suggestion.explanation).font(.body).lineSpacing(4).textSelection(.enabled)
                    if let replacement = comment.suggestion.replacement {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Suggested rewrite").font(.body.weight(.medium)).foregroundStyle(.secondary)
                            Text(replacement.isEmpty ? "Remove this passage" : replacement)
                                .font(.body).lineSpacing(4).textSelection(.enabled)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(Paper.ink).opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if comment.status == "open" {
                        HStack {
                            if comment.suggestion.replacement != nil {
                                Button("Accept rewrite") { withEditor { review.accept(runID: run.id, commentID: comment.id, input: model.reviewInput, editor: $0) } }.disabled(run.stale || model.isBranching || model.boardFlight != nil)
                            }
                            Button("Dismiss") { review.dismiss(runID: run.id, commentID: comment.id) }.buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                    } else { Text(comment.status.capitalized).font(.body).foregroundStyle(.secondary) }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(Paper.background), in: RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color(Paper.ink).opacity(0.14), lineWidth: 1) }
                    .shadow(color: .black.opacity(0.035), radius: 3, y: 2)
            }
        }
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
