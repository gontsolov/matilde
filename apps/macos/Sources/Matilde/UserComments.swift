import AppKit
import SwiftUI
import Combine
import MatildeKit

@MainActor
final class UserCommentStore: ObservableObject {
    static let maximumLength = 8000
    @Published private(set) var comments: [UserComment] = []
    /// The comment whose popover is open; drawn slightly stronger.
    @Published var activeID: UUID?
    /// True while the writing margin has room for comment cards; otherwise comments open in a popover.
    var marginVisible = false
    struct MarginRequest: Equatable { let id: UUID; let focus: Bool; let token = UUID() }
    /// Asks the margin to open a comment card.
    @Published private(set) var marginRequest: MarginRequest?
    func requestMargin(_ id: UUID, focus: Bool) { marginRequest = MarginRequest(id: id, focus: focus) }
    private(set) var body = ""
    private var workspace: Workspace?
    private(set) var draftID: String?
    var reportError: (String) -> Void = { _ in }

    func bind(workspace: Workspace?, draftID: String?, body: String) {
        guard self.workspace !== workspace || self.draftID != draftID else {
            changed(workspace: workspace, draftID: draftID, body: body); return
        }
        self.workspace = workspace; self.draftID = draftID; self.body = body; activeID = nil
        var loaded: [UserComment] = []
        do { loaded = try draftID.map { try workspace?.userComments(draftID: $0) ?? [] } ?? [] }
        catch { reportError("Comments could not be loaded.") }
        // An empty note is an abandoned new comment (for example the app quit while it was open).
        for comment in loaded where comment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? workspace?.deleteUserComment(comment.id)
        }
        loaded.removeAll { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let anchored = loaded.map { comment -> UserComment in
            if let range = CommentAnchor.relocate(comment, in: body) { return CommentAnchor.refreshed(comment, range: range, in: body) }
            var detached = comment; detached.length = 0
            return detached
        }
        persist(zip(loaded, anchored).filter { $0.0 != $0.1 }.map { $0.1 })
        comments = anchored
    }

    /// Sync changed the database: re-read this draft's comments unless one is being edited.
    func reload() {
        guard activeID == nil, let workspace, let draftID else { return }
        self.workspace = nil
        bind(workspace: workspace, draftID: draftID, body: body)
    }

    func changed(workspace: Workspace?, draftID: String?, body: String) {
        guard self.workspace === workspace, self.draftID == draftID, body != self.body else { return }
        let previous = self.body
        self.body = body
        guard !comments.isEmpty else { return }
        let edit = WritingEdit.between(previous, body)
        let updated = comments.map { CommentAnchor.track($0, edit: edit, in: body) }
        persist(zip(comments, updated).filter { $0.0 != $0.1 }.map { $0.1 })
        // Always republish so the editor redraws highlights against the new text.
        comments = updated
    }

    /// Adds an empty comment for the selection; it is discarded if left empty.
    func add(range: NSRange) -> UserComment? {
        let source = body as NSString
        guard let draftID, workspace != nil, range.location != NSNotFound, range.length > 0,
              NSMaxRange(range) <= source.length else { return nil }
        let whole = source.rangeOfComposedCharacterSequences(for: range)
        if let existing = comments.first(where: { $0.attached && $0.range == whole }) { return existing }
        let now = Date()
        let comment = CommentAnchor.refreshed(UserComment(id: UUID(), draftID: draftID, text: "", location: 0, length: 0,
                                                          quote: "", prefix: "", suffix: "", created: now, modified: now),
                                              range: whole, in: body)
        comments.append(comment)
        comments.sort { $0.location < $1.location }
        return comment
    }

    func update(_ id: UUID, text: String) {
        guard let index = comments.firstIndex(where: { $0.id == id }) else { return }
        let limited = String(text.prefix(Self.maximumLength))
        guard comments[index].text != limited else { return }
        comments[index].text = limited
        comments[index].modified = Date()
        if limited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { remove(id, keepInMemory: true) }
        else { persist([comments[index]]) }
    }

    func remove(_ id: UUID) { remove(id, keepInMemory: false) }
    /// Hides a comment from the draft while keeping it in the workspace database.
    func archive(_ id: UUID) {
        guard let comment = comments.first(where: { $0.id == id }) else { return }
        guard !comment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { remove(id); return }
        do { try workspace?.saveUserComments([comment]); try workspace?.archiveUserComment(id) }
        catch { reportError("This comment could not be archived. Your writing is unaffected."); return }
        comments.removeAll { $0.id == id }
        if activeID == id { activeID = nil }
    }
    private func remove(_ id: UUID, keepInMemory: Bool) {
        do { try workspace?.deleteUserComment(id) }
        catch { reportError("This comment could not be deleted. Your writing is unaffected.") }
        if !keepInMemory { comments.removeAll { $0.id == id }; if activeID == id { activeID = nil } }
    }

    /// Called when the comment editor closes: empty comments are removed.
    func finishEditing(_ id: UUID) {
        if activeID == id { activeID = nil }
        if let comment = comments.first(where: { $0.id == id }),
           comment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { remove(id) }
    }

    func comment(containing index: Int) -> UserComment? {
        comments.last { $0.attached && index >= $0.location && index < NSMaxRange($0.range) }
    }

    private func persist(_ changed: [UserComment]) {
        let saved = changed.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        do { try workspace?.saveUserComments(saved) }
        catch { reportError("Comments could not be saved. Your writing is unaffected.") }
    }
}

// MARK: - Highlighter rendering

extension WritingLayoutManager {
    static let commentHighlight = NSColor(name: NSColor.Name("Matilde.commentHighlight")) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.78, green: 0.60, blue: 0.30, alpha: 0.24)
            : NSColor(calibratedRed: 0.97, green: 0.80, blue: 0.40, alpha: 0.34)
    }
    /// The comment card's quote rule: the highlighter's yellow, solid enough to read as a line.
    static let commentRule = NSColor(name: NSColor.Name("Matilde.commentRule")) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.86, green: 0.67, blue: 0.33, alpha: 0.85)
            : NSColor(calibratedRed: 0.91, green: 0.69, blue: 0.24, alpha: 0.9)
    }
    static let activeCommentHighlight = NSColor(name: NSColor.Name("Matilde.activeCommentHighlight")) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.82, green: 0.63, blue: 0.32, alpha: 0.36)
            : NSColor(calibratedRed: 0.96, green: 0.76, blue: 0.34, alpha: 0.48)
    }

    /// Deterministic wobble in -1...1 so the marker edges stay put between redraws.
    private static func wobble(_ seed: Int) -> CGFloat {
        let value = sin(Double(seed) * 12.9898) * 43758.5453
        return CGFloat(value - value.rounded(.down)) * 2 - 1
    }

    /// A soft marker stroke: slightly uneven top and bottom edges with rounded, angled ends.
    static func markerPath(_ rect: NSRect, seed: Int) -> NSBezierPath {
        let w = { (n: Int) -> CGFloat in WritingLayoutManager.wobble(seed &* 31 &+ n) }
        let path = NSBezierPath()
        let lean: CGFloat = 1.5 + w(1) * 0.8
        let topLeft = NSPoint(x: rect.minX + lean, y: rect.minY + w(2) * 0.6)
        let topRight = NSPoint(x: rect.maxX + 0.5, y: rect.minY + w(3) * 0.6)
        let bottomRight = NSPoint(x: rect.maxX - lean, y: rect.maxY + w(4) * 0.6)
        let bottomLeft = NSPoint(x: rect.minX - 0.5, y: rect.maxY + w(5) * 0.6)
        let bulge = min(3, rect.height / 4)
        path.move(to: topLeft)
        path.curve(to: topRight, controlPoint1: NSPoint(x: rect.minX + rect.width / 3, y: rect.minY + w(6) * 0.9),
                   controlPoint2: NSPoint(x: rect.minX + rect.width * 2 / 3, y: rect.minY + w(7) * 0.9))
        path.curve(to: bottomRight, controlPoint1: NSPoint(x: topRight.x + bulge, y: rect.minY + rect.height / 3),
                   controlPoint2: NSPoint(x: bottomRight.x + bulge, y: rect.maxY - rect.height / 4))
        path.curve(to: bottomLeft, controlPoint1: NSPoint(x: rect.minX + rect.width * 2 / 3, y: rect.maxY + w(8) * 0.9),
                   controlPoint2: NSPoint(x: rect.minX + rect.width / 3, y: rect.maxY + w(9) * 0.9))
        path.curve(to: topLeft, controlPoint1: NSPoint(x: bottomLeft.x - bulge, y: rect.maxY - rect.height / 4),
                   controlPoint2: NSPoint(x: topLeft.x - bulge, y: rect.minY + rect.height / 3))
        path.close()
        return path
    }

    func commentHighlightRects(for range: NSRange) -> [NSRect] {
        guard let storage = textStorage, range.length > 0, NSMaxRange(range) <= storage.length else { return [] }
        var result: [NSRect] = []
        let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        enumerateLineFragments(forGlyphRange: glyphs) { line, _, container, fragment, _ in
            let run = NSIntersectionRange(fragment, glyphs)
            guard run.length > 0 else { return }
            let bounds = self.boundingRect(forGlyphRange: run, in: container)
            guard bounds.width > 0.5 else { return }
            let character = self.characterIndexForGlyph(at: run.location)
            let font = storage.attribute(.font, at: character, effectiveRange: nil) as? NSFont ?? Paper.body()
            let offset = storage.attribute(.baselineOffset, at: character, effectiveRange: nil) as? CGFloat ?? 0
            let baseline = line.minY + self.location(forGlyphAt: run.location).y - offset
            result.append(NSRect(x: bounds.minX - 1, y: baseline - font.capHeight - 3,
                                 width: bounds.width + 2, height: font.capHeight - font.descender * 0.7 + 5))
        }
        return result
    }

    func drawCommentHighlights(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard !commentRanges.isEmpty else { return }
        let visible = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        for range in commentRanges where NSIntersectionRange(range, visible).length > 0 {
            (range == activeCommentRange ? Self.activeCommentHighlight : Self.commentHighlight).setFill()
            for (index, rect) in commentHighlightRects(for: range).enumerated() {
                Self.markerPath(rect.offsetBy(dx: origin.x, dy: origin.y), seed: range.location &+ index).fill()
            }
        }
    }
}

// MARK: - Editor actions and popover

extension WritingTextView {
    func observeComments() {
        guard let store = commentStore else {
            commentObservation = nil; applyCommentHighlights(comments: [], activeID: nil); return
        }
        commentObservation = Publishers.CombineLatest(store.$comments, store.$activeID)
            .sink { [weak self] comments, activeID in self?.applyCommentHighlights(comments: comments, activeID: activeID) }
    }

    func applyCommentHighlights() {
        applyCommentHighlights(comments: commentStore?.comments ?? [], activeID: commentStore?.activeID)
    }

    func applyCommentHighlights(comments: [UserComment], activeID: UUID?) {
        guard let layout = layoutManager as? WritingLayoutManager else { return }
        let length = (string as NSString).length
        // Ranges are only valid against the text they were tracked with.
        let current = commentStore?.body == string
        let visible = current ? comments.filter { $0.attached && NSMaxRange($0.range) <= length } : []
        let ranges = visible.map(\.range)
        let active = visible.first { $0.id == activeID }?.range
        guard ranges != layout.commentRanges || active != layout.activeCommentRange else { return }
        layout.commentRanges = ranges
        layout.activeCommentRange = active
        needsDisplay = true
    }

    var addCommentMenuItem: NSMenuItem? {
        guard commentStore != nil, askRange != nil else { return nil }
        let item = NSMenuItem(title: "Add comment", action: #selector(addUserComment(_:)), keyEquivalent: "k")
        item.keyEquivalentModifierMask = [.command, .shift]
        item.target = self
        return item
    }

    @objc func addUserComment(_ sender: Any?) {
        guard let store = commentStore, store.body == string else { NSSound.beep(); return }
        let selection = selectedRange()
        guard selection.location != NSNotFound, NSMaxRange(selection) <= (string as NSString).length else { return }
        // Without a selection, open the comment under the caret or comment on the current paragraph.
        if selection.length == 0, let existing = store.comment(containing: selection.location) {
            presentComment(existing.id); return
        }
        guard let range = askRange else { NSSound.beep(); return }
        hideSelectionAssist()
        guard let comment = store.add(range: range) else { NSSound.beep(); return }
        presentComment(comment.id, focus: true)
    }

    /// Scrolls a comment's passage into view and marks it, without moving the caret.
    func revealComment(_ id: UUID) {
        guard let store = commentStore, store.body == string,
              let comment = store.comments.first(where: { $0.id == id && $0.attached }),
              NSMaxRange(comment.range) <= (string as NSString).length else { return }
        store.activeID = id
        scrollRangeToVisible(comment.range)
    }

    /// Opens a comment in the margin when it has room, else in a popover beside the passage.
    func presentComment(_ id: UUID, focus: Bool = false) {
        guard let store = commentStore else { return }
        guard store.marginVisible else { showCommentPopover(id, focus: focus); return }
        commentPopover?.close()
        // After any pending margin blur from this same click has run.
        DispatchQueue.main.async { [weak store] in store?.requestMargin(id, focus: focus) }
    }

    /// Opens a comment when a single click lands on highlighted text.
    func openComment(at event: NSEvent) -> Bool {
        guard let store = commentStore, !store.comments.isEmpty, store.body == string,
              let layoutManager, let textContainer else { return false }
        var point = convert(event.locationInWindow, from: nil)
        point.x -= textContainerOrigin.x; point.y -= textContainerOrigin.y
        let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs,
              layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).contains(point),
              let comment = store.comment(containing: layoutManager.characterIndexForGlyph(at: glyph)) else { return false }
        presentComment(comment.id)
        return true
    }

    func showCommentPopover(_ id: UUID, focus: Bool = false) {
        guard let store = commentStore, let comment = store.comments.first(where: { $0.id == id }),
              let layout = layoutManager as? WritingLayoutManager else { return }
        commentPopover?.close()
        let rects = layout.commentHighlightRects(for: comment.range)
        guard let first = rects.first else { return }
        store.activeID = id
        let popover = UserCommentPopover(store: store, comment: comment, focus: focus, editor: self)
        commentPopover = popover
        popover.show(relativeTo: first.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y), of: self, preferredEdge: .maxY)
    }
}

final class UserCommentPopover: NSPopover, NSPopoverDelegate {
    private let commentID: UUID
    private weak var store: UserCommentStore?
    private weak var editor: WritingTextView?

    @MainActor init(store: UserCommentStore, comment: UserComment, focus: Bool, editor: WritingTextView) {
        commentID = comment.id; self.store = store; self.editor = editor
        super.init()
        behavior = .transient
        animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        delegate = self
        let id = comment.id
        contentViewController = NSHostingController(rootView: UserCommentEditor(
            quote: comment.quote, author: comment.author, text: comment.text, focus: focus,
            onChange: { [weak store] in store?.update(id, text: $0) },
            onArchive: { [weak self, weak store] in store?.archive(id); self?.close() },
            onDone: { [weak self] in self?.close() }))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            store?.finishEditing(commentID)
            if let editor, editor.commentPopover === self {
                editor.commentPopover = nil
                editor.window?.makeFirstResponder(editor)
            }
        }
    }
}

private struct UserCommentEditor: View {
    let quote: String
    /// The AI tool that left the comment through Matilde's MCP server, if one did.
    let author: String?
    @State var text: String
    let focus: Bool
    let onChange: @MainActor (String) -> Void
    let onArchive: @MainActor () -> Void
    let onDone: @MainActor () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !quote.isEmpty { PassageQuote(text: quote, lines: 3, kind: .note).padding(.trailing, 22) }
            if let author {
                Text("From \(author)").font(.caption).foregroundStyle(Color(Paper.muted))
            }
                HStack(alignment: .bottom, spacing: 6) {
                    TextField("Add a note…", text: $text, axis: .vertical)
                        .lineLimit(1...10).textFieldStyle(.plain).composerText()
                        .foregroundStyle(Color(Paper.ink))
                        .focused($focused)
                        .onSubmit { ComposerReturn.handle { onDone() } }
                        .accessibilityLabel("Comment")
                    Button { onDone() } label: { MatildeIcon.done.image(size: 20).composerButton() }
                        .buttonStyle(.plain).foregroundStyle(Color(Paper.accent).opacity(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.35 : 1))
                        .help("Done").accessibilityLabel("Done")
                }
                .composerField()
        }
        .padding(14).frame(width: CommentMargin.cardWidth)
        .overlay(alignment: .topTrailing) {
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button { onArchive() } label: {
                    MatildeIcon.archive.image(size: 16).frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Color(Paper.muted))
                .help("Archive").accessibilityLabel("Archive").padding(.top, 8).padding(.trailing, 8)
            }
        }
        .background(Color(Paper.background))
        .background(PopoverPaperBackground())
        .onChange(of: text) { _, value in onChange(value) }
        .onAppear { if focus || text.isEmpty { DispatchQueue.main.async { focused = true } } }
    }
}

// MARK: - Shared comment chrome (Ask Matilde threads and private comments)

/// The quoted passage at the top of a comment, set off by a thin rule.
struct PassageQuote: View {
    /// The rule's color tells a private comment (highlighter yellow) from an Ask Matilde thread (accent).
    enum Kind { case note, matilde }
    let text: String
    let lines: Int
    var kind: Kind = .note
    var body: some View {
        Text(text).font(.body).foregroundStyle(.secondary).lineSpacing(3).lineLimit(lines)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 10).padding(.vertical, 3)
            .overlay(alignment: .leading) {
                Capsule().fill(kind == .note ? Color(WritingLayoutManager.commentRule) : Color(Paper.accent).opacity(0.55))
                    .frame(width: 2.5)
            }
    }
}

extension View {
    /// The quiet outlined input used by comment composers.
    func composerField() -> some View {
        padding(.leading, 11).padding(.trailing, 4).padding(.vertical, 4)
            .background(Color(Paper.ink).opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(Paper.ink).opacity(0.08)))
    }
}

/// Paints the whole popover, arrow included, in paper instead of the default material.
struct PopoverPaperBackground: NSViewRepresentable {
    final class Painter: NSView {
        private var fill: NSView?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard fill == nil, let frame = window?.contentView?.superview else { return }
            let view = NSView(frame: frame.bounds)
            view.wantsLayer = true
            effectiveAppearance.performAsCurrentDrawingAppearance { view.layer?.backgroundColor = Paper.background.cgColor }
            view.autoresizingMask = [.width, .height]
            frame.addSubview(view, positioned: .below, relativeTo: nil)
            fill = view
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            effectiveAppearance.performAsCurrentDrawingAppearance { fill?.layer?.backgroundColor = Paper.background.cgColor }
        }
    }
    func makeNSView(context: Context) -> Painter { Painter() }
    func updateNSView(_ view: Painter, context: Context) {}
}
