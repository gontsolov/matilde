import XCTest
import AppKit
import SwiftUI
@testable import Matilde

final class NoteNavigationTests: XCTestCase {
    private func draft(_ id: String, folder: String = "", family: String? = nil, parent: String? = nil, edited: Double) -> Draft {
        Draft(id: id, path: (folder.isEmpty ? "" : folder + "/") + id + ".md", family: family ?? id, parent: parent,
              goal: "", cursor: 0, scroll: 0, editedAt: Date(timeIntervalSince1970: edited))
    }
    private var drafts: [Draft] {
        [draft("Loose", edited: 1), draft("Recent", edited: 9),
         draft("Essay", folder: "Essays", edited: 5), draft("Older essay", folder: "Essays", edited: 2),
         draft("Alternate", folder: "Essays", family: "Older essay", parent: "Older essay", edited: 3),
         draft("Poem", folder: "Poems", edited: 4)]
    }
    private func order(collapsed: Set<String> = [], search: String = "") -> [String] {
        SidebarOrder.visible(drafts, folders: ["", "Essays", "Poems"], collapsed: collapsed, search: search)
            .flatMap { $0.groups.map(\.id) }
    }

    func testVisibleOrderFollowsFoldersCollapsingAndSearch() {
        XCTAssertEqual(order(), ["Recent", "Loose", "Essay", "Older essay", "Poem"])
        XCTAssertEqual(order(collapsed: ["Essays"]), ["Recent", "Loose", "Poem"])
        let sections = SidebarOrder.visible(drafts, folders: ["", "Essays", "Poems"], collapsed: ["Essays"], search: "")
        XCTAssertEqual(sections.map(\.folder), ["", "Essays", "Poems"], "a collapsed folder keeps its row")
        // Search matches branch titles too, shows collapsed folders, and drops empty folders.
        XCTAssertEqual(order(collapsed: ["Essays"], search: "alter"), ["Older essay"])
        XCTAssertEqual(SidebarOrder.visible(drafts, folders: ["", "Essays", "Poems"], collapsed: [], search: "alter").map(\.folder), ["Essays"])
        XCTAssertEqual(order(search: "zzz"), [])
    }

    func testNextAndPreviousWrapAtTheEnds() {
        let notes = order()
        XCTAssertEqual(SidebarOrder.neighbor(of: "Recent", in: notes, forward: true), "Loose")
        XCTAssertEqual(SidebarOrder.neighbor(of: "Loose", in: notes, forward: true), "Essay")
        XCTAssertEqual(SidebarOrder.neighbor(of: "Poem", in: notes, forward: true), "Recent")
        XCTAssertEqual(SidebarOrder.neighbor(of: "Recent", in: notes, forward: false), "Poem")
        XCTAssertEqual(SidebarOrder.neighbor(of: "Essay", in: notes, forward: false), "Loose")
        // A hidden note (collapsed folder or filtered out) starts from the matching edge.
        let collapsed = order(collapsed: ["Essays"])
        XCTAssertEqual(SidebarOrder.neighbor(of: "Essay", in: collapsed, forward: true), "Recent")
        XCTAssertEqual(SidebarOrder.neighbor(of: "Essay", in: collapsed, forward: false), "Poem")
        XCTAssertEqual(SidebarOrder.neighbor(of: nil, in: collapsed, forward: true), "Recent")
        XCTAssertNil(SidebarOrder.neighbor(of: "Only", in: ["Only"], forward: true))
        XCTAssertEqual(SidebarOrder.neighbor(of: "Other", in: ["Only"], forward: false), "Only")
        XCTAssertNil(SidebarOrder.neighbor(of: "Recent", in: [], forward: true))
    }

    func testSwitchingLandsAtTopUnlessRestoringSessionOrBranch() {
        let top = EditorLanding.position(cursor: 420, scroll: 1260, restores: false)
        XCTAssertEqual(top.cursor, 0); XCTAssertEqual(top.scroll, 0)
        let restored = EditorLanding.position(cursor: 420, scroll: 1260, restores: true)
        XCTAssertEqual(restored.cursor, 420); XCTAssertEqual(restored.scroll, 1260)
        let clamped = EditorLanding.position(cursor: -1, scroll: -5, restores: true)
        XCTAssertEqual(clamped.cursor, 0); XCTAssertEqual(clamped.scroll, 0)
    }

    func testPlaceholderShowsOnlyForAnEmptyBodyWithoutComposition() {
        XCTAssertTrue(EditorLanding.showsBodyPlaceholder(textLength: 0, hasMarkedText: false))
        XCTAssertFalse(EditorLanding.showsBodyPlaceholder(textLength: 0, hasMarkedText: true))
        XCTAssertFalse(EditorLanding.showsBodyPlaceholder(textLength: 1, hasMarkedText: false))
    }
}

@MainActor private final class LandingModel: ObservableObject {
    @Published var id = "long"
    @Published var text = ""
    @Published var scroll = 0.0
}
private struct LandingHost: View {
    @ObservedObject var model: LandingModel
    var mount: (WritingTextView) -> Void
    var body: some View {
        MarkdownEditor(draftID: model.id, text: model.text, initialCursor: 0, initialScroll: model.scroll,
                       onChange: { model.text = $0 }, onPosition: { _, _ in }, focusOnLoad: false, onMount: mount,
                       placeholder: EditorLanding.bodyPlaceholder)
            .frame(width: 600, height: 400)
    }
}

@MainActor
final class NoteLandingEditorTests: XCTestCase {
    private func run(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    /// Let SwiftUI apply one model change (well under the old 100 ms restoration delay).
    private func update(_ window: NSWindow) {
        run(0.01); window.contentView?.layoutSubtreeIfNeeded(); run(0.01)
    }
    private let long = (1...200).map { "Disposable paragraph \($0) for scrolling." }.joined(separator: "\n\n")

    private func mount(_ model: LandingModel) throws -> (WritingTextView, NSScrollView, NSWindow) {
        var mounted: WritingTextView?
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: LandingHost(model: model, mount: { mounted = $0 }))
        run(0.3)
        let view = try XCTUnwrap(mounted)
        return (view, try XCTUnwrap(view.enclosingScrollView), window)
    }

    /// The new note must be at the top on the first draw after the switch, not after a delay.
    func testSwitchingNotesLandsAtTopBeforeTheNextDraw() throws {
        let model = LandingModel()
        model.text = long
        let (view, scroll, window) = try mount(model)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1500)); scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 1500, accuracy: 1)
        model.id = "other"; model.text = long.replacingOccurrences(of: "Disposable", with: "Other"); model.scroll = 0
        update(window)
        XCTAssertTrue(view.string.hasPrefix("Other paragraph 1 "))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 0.5)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 0))
        // A restored position (session or branch) is applied in the same synchronous step.
        model.id = "restored"; model.text = long; model.scroll = 600
        update(window)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 600, accuracy: 1)
        run(0.2)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 600, accuracy: 1)
    }

    func testBodyPlaceholderIsDrawnOnlyAndAlignsWithTypedText() throws {
        let model = LandingModel()
        model.text = "Some text"
        let (view, _, window) = try mount(model)
        XCTAssertFalse(view.showsBodyPlaceholder)
        model.id = "empty"; model.text = ""
        update(window)
        XCTAssertTrue(view.showsBodyPlaceholder)
        XCTAssertEqual(view.string, "")
        XCTAssertEqual(view.accessibilityPlaceholderValue(), EditorLanding.bodyPlaceholder)
        XCTAssertFalse(view.undoManager?.canUndo ?? false, "showing the placeholder registers no undo")
        let placeholder = view.bodyPlaceholderOrigin
        let padding = try XCTUnwrap(view.textContainer).lineFragmentPadding
        XCTAssertEqual(placeholder.x, view.textContainerOrigin.x + padding, accuracy: 0.5)

        window.makeFirstResponder(view)
        view.insertText("W", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertFalse(view.showsBodyPlaceholder)
        XCTAssertEqual(view.string, "W")
        XCTAssertEqual(model.text, "W", "the placeholder never reaches the Markdown")
        let layout = try XCTUnwrap(view.layoutManager)
        layout.ensureLayout(for: try XCTUnwrap(view.textContainer))
        let line = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let baseline = view.textContainerOrigin.y + line.minY + layout.location(forGlyphAt: 0).y
        XCTAssertEqual(placeholder.y, baseline, accuracy: 1.5, "placeholder shares the body's first baseline")
        XCTAssertEqual(view.textContainerOrigin.x + line.minX + layout.location(forGlyphAt: 0).x, placeholder.x, accuracy: 0.5)

        view.setSelectedRange(NSRange(location: 0, length: 1))
        view.insertText("", replacementRange: NSRange(location: 0, length: 1))
        XCTAssertTrue(view.showsBodyPlaceholder)
        XCTAssertEqual(model.text, "")

        // IME composition hides it before anything is committed.
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertFalse(view.showsBodyPlaceholder)
        view.unmarkText()
        XCTAssertEqual(view.string, "か")
        XCTAssertFalse(view.showsBodyPlaceholder)
    }
}
