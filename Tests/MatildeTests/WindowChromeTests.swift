import XCTest
import AppKit
@testable import Matilde

final class WindowChromeTests: XCTestCase {
    func testTypingInEditorHidesControls() {
        var fade = ChromeFade()
        XCTAssertFalse(fade.hidden)
        fade.typed(inEditor: true)
        XCTAssertTrue(fade.hidden)
    }

    func testTypingOutsideEditorKeepsControls() {
        var fade = ChromeFade()
        fade.typed(inEditor: false)
        XCTAssertFalse(fade.hidden)
    }

    func testSmallPointerJitterDoesNotReveal() {
        var fade = ChromeFade()
        fade.typed(inEditor: true)
        fade.pointerMoved(by: 1)
        fade.pointerMoved(by: -2)
        XCTAssertTrue(fade.hidden)
        fade.pointerMoved(by: ChromeFade.revealDistance)
        XCTAssertFalse(fade.hidden)
    }

    func testTypingResetsAccumulatedTravel() {
        var fade = ChromeFade()
        fade.typed(inEditor: true)
        fade.pointerMoved(by: ChromeFade.revealDistance - 1)
        fade.typed(inEditor: true)
        fade.pointerMoved(by: 2)
        XCTAssertTrue(fade.hidden)
    }

    func testPointerMovementWhileVisibleDoesNotPreloadReveal() {
        var fade = ChromeFade()
        fade.pointerMoved(by: 100)
        fade.typed(inEditor: true)
        fade.pointerMoved(by: 1)
        XCTAssertTrue(fade.hidden)
    }

    func testHoverRevealsAndPinsControls() {
        var fade = ChromeFade()
        fade.typed(inEditor: true)
        fade.hover(true)
        XCTAssertFalse(fade.hidden)
        fade.typed(inEditor: true)
        XCTAssertFalse(fade.hidden)
        fade.hover(false)
        fade.typed(inEditor: true)
        XCTAssertTrue(fade.hidden)
    }

    func testLeavingEditorReveals() {
        var fade = ChromeFade()
        fade.typed(inEditor: true)
        fade.editorFocusChanged(focused: true)
        XCTAssertTrue(fade.hidden)
        fade.editorFocusChanged(focused: false)
        XCTAssertFalse(fade.hidden)
    }

    func testCommandShortcutsAreNotTyping() {
        XCTAssertTrue(ChromeFade.isTyping(modifiers: []))
        XCTAssertTrue(ChromeFade.isTyping(modifiers: [.shift]))
        XCTAssertTrue(ChromeFade.isTyping(modifiers: [.option, .control]))
        XCTAssertFalse(ChromeFade.isTyping(modifiers: [.command]))
        XCTAssertFalse(ChromeFade.isTyping(modifiers: [.command, .shift]))
    }

    func testToggleSitsPastTrafficLightsOrAtEdgeInFullScreen() {
        XCTAssertEqual(WindowChrome.toggleLeading(trafficLightsTrailing: 69), 79)
        XCTAssertEqual(WindowChrome.toggleLeading(trafficLightsTrailing: nil), 12)
    }

    func testControlsCenterOnTrafficLights() {
        XCTAssertEqual(WindowChrome.controlTop(trafficLightsCenter: 14), 2)
        XCTAssertEqual(WindowChrome.controlTop(trafficLightsCenter: 20), 8)
        XCTAssertEqual(WindowChrome.controlTop(trafficLightsCenter: 0), 2)
        XCTAssertEqual(WindowChrome.controlTop(trafficLightsCenter: 500), WindowChrome.barHeight + 8)
    }
}
