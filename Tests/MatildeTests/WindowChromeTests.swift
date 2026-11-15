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
        XCTAssertEqual(WindowChrome.toggleLeading(trafficLightsTrailing: 69), 69 + WindowChrome.toggleGap)
        XCTAssertEqual(WindowChrome.toggleLeading(trafficLightsTrailing: nil), WindowChrome.fullScreenToggleLeading)
    }

    func testControlsCenterOnTrafficLights() {
        XCTAssertEqual(WindowChrome.controlTop(trafficLightsCenter: 14), 2)
        XCTAssertEqual(WindowChrome.controlTop(trafficLightsCenter: 20), 8)
        XCTAssertEqual(WindowChrome.controlTop(trafficLightsCenter: 0), 2)
        XCTAssertEqual(WindowChrome.controlTop(trafficLightsCenter: 500), WindowChrome.barHeight + 8)
    }

    func testRowFollowsTheZoomButton() {
        // Zoom button 14 points square, 7 points from the top, ending 54 points in.
        let row = WindowChrome.row(zoomFrame: CGRect(x: 40, y: 7, width: 14, height: 14))
        XCTAssertEqual(row.center, 14)
        XCTAssertEqual(row.trafficLightsTrailing, 54)
        XCTAssertEqual(row.toggleLeading, 54 + WindowChrome.toggleGap)
        // The toggle is vertically centered on the traffic lights.
        XCTAssertEqual(row.controlTop + WindowChrome.controlHeight / 2, row.center)
    }

    func testRowIsTheSameWhetherTheSidebarIsOpenOrNot() {
        // Placement depends only on the traffic lights, so toggling never moves the control.
        let frame = CGRect(x: 47, y: 9, width: 14, height: 14)
        XCTAssertEqual(WindowChrome.row(zoomFrame: frame), WindowChrome.row(zoomFrame: frame))
        XCTAssertEqual(WindowChrome.row(zoomFrame: frame).toggleLeading, 61 + WindowChrome.toggleGap)
    }

    func testHiddenTrafficLightsKeepTheRowAtTheTopLeft() {
        let row = WindowChrome.row(zoomFrame: nil)
        XCTAssertNil(row.trafficLightsTrailing)
        XCTAssertEqual(row.toggleLeading, WindowChrome.fullScreenToggleLeading)
        XCTAssertEqual(row.center, WindowChrome.defaultTrafficLightsCenter)
    }

    func testImplausibleZoomFrameFallsBackToDefaults() {
        XCTAssertEqual(WindowChrome.row(zoomFrame: .zero), WindowChrome.Row())
        XCTAssertEqual(WindowChrome.row(zoomFrame: CGRect(x: 40, y: 700, width: 14, height: 14)), WindowChrome.Row())
        XCTAssertEqual(WindowChrome.Row().trafficLightsTrailing, WindowChrome.defaultTrafficLightsTrailing)
    }

    func testSidebarContentStartsBelowTheControlRow() {
        for center in [CGFloat(10), 14, 16, 20, 26] {
            let row = WindowChrome.Row(center: center)
            XCTAssertGreaterThanOrEqual(row.bandHeight, row.controlTop + WindowChrome.controlHeight)
            XCTAssertGreaterThanOrEqual(row.bandHeight, WindowChrome.barHeight)
            // Tight: no more than the small gap below the row.
            XCTAssertLessThanOrEqual(row.bandHeight, max(WindowChrome.barHeight,
                                                         row.controlTop + WindowChrome.controlHeight + WindowChrome.rowBottomGap))
        }
        XCTAssertEqual(WindowChrome.bandHeight(trafficLightsCenter: 14), 28)
        XCTAssertEqual(WindowChrome.bandHeight(trafficLightsCenter: 20), 34)
    }
}
