import XCTest
import AppKit
import SwiftUI
@testable import Matilde
import MatildeKit

@MainActor private final class SpellEditorModel: ObservableObject { @Published var text = "" }
private struct SpellEditorHost: View {
    @ObservedObject var model: SpellEditorModel
    var mount: (WritingTextView) -> Void
    var body: some View {
        MarkdownEditor(draftID: "spelling", text: model.text, initialCursor: 0, initialScroll: 0,
                       onChange: { model.text = $0 }, onPosition: { _, _ in }, spellChecking: true, onMount: mount)
            .frame(width: 600, height: 400)
    }
}

@MainActor
final class SpellCheckingTests: XCTestCase {
    private func run(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    /// Spins the run loop until `condition` holds or `timeout` passes. The editor reports a change
    /// made inside an editing batch on the next main-queue turn, which a busy CI runner can delay
    /// past a fixed short wait.
    private func run(until condition: () -> Bool, timeout: Double = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { run(0.01) }
    }

    /// Autocorrection can replace a word and report the change before the text storage has
    /// finished its editing batch. Restyling then must wait instead of forcing layout mid-edit.
    func testCorrectionReportedInsideEditingBatchDoesNotLayOutMidEdit() throws {
        let model = SpellEditorModel()
        model.text = "# Hedaing teh\n\nThs is **bodl teh** and `cdoe teh` [lnik teh](http://x).\n\n- [ ] tset teh\n> qoute teh\n\n---\n\nÜnïcödé tëh 😀 teh"
        var mounted: WritingTextView?
        let host = NSHostingView(rootView: SpellEditorHost(model: model, mount: { mounted = $0 }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        run(0.3)
        let view = try XCTUnwrap(mounted)
        window.makeFirstResponder(view)
        func words() -> [NSRange] {
            var result: [NSRange] = []
            let source = view.string as NSString
            source.enumerateSubstrings(in: NSRange(location: 0, length: source.length), options: .byWords) { _, range, _, _ in result.append(range) }
            return result
        }
        var corrected = 0
        for index in 0..<words().count {
            let current = words()
            guard index < current.count else { break }
            for replacement in ["corrected'", "a"] {
                let storage = try XCTUnwrap(view.textStorage)
                guard view.shouldChangeText(in: current[index], replacementString: replacement) else { continue }
                storage.beginEditing()
                storage.replaceCharacters(in: current[index], with: replacement)
                view.didChangeText()
                storage.endEditing()
                run(until: { model.text == view.string })
                XCTAssertEqual(model.text, view.string)
                XCTAssertNotNil(storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil))
                corrected += 1
                view.undoManager?.undo()
                run(until: { model.text == view.string })
            }
        }
        XCTAssertGreaterThan(corrected, 20)
    }

    /// Spelling markers sit just under the letters, not at the bottom of the line spacing.
    func testSpellingMarkersSitUnderBaseline() throws {
        let storage = NSTextStorage(string: "Ths is a tset\nsecond lnie")
        let layout = WritingLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 500, height: 1000))
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        _ = WritingTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200), textContainer: container)
        MarkdownStyler.style(storage, textSize: 19, lineSpacing: 12)
        layout.ensureLayout(for: container)
        let word = (storage.string as NSString).range(of: "tset")
        layout.addTemporaryAttribute(.spellingState, value: NSAttributedString.SpellingState.spelling.rawValue, forCharacterRange: word)
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
        let markers = layout.spellingMarkerRects(forGlyphRange: glyphs)
        XCTAssertEqual(markers.count, 1)
        let glyph = layout.glyphIndexForCharacter(at: word.location)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let baseline = line.minY + layout.location(forGlyphAt: glyph).y
        let marker = try XCTUnwrap(markers.first?.rect)
        XCTAssertGreaterThan(marker.minY, baseline)
        XCTAssertLessThan(marker.maxY, baseline + 8)
        XCTAssertLessThan(marker.maxY, line.maxY - 10, "marker should not drift into the line spacing")
        // AppKit's own drawing must not see the marker, or it would draw a second, lower one.
        XCTAssertNotNil(layout.temporaryAttribute(.spellingState, atCharacterIndex: word.location, effectiveRange: nil))
    }
}
