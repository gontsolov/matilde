import XCTest
import AppKit
@testable import Matilde
import MatildeKit

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

    func testHeaderRowNumbers() {
        XCTAssertEqual(WindowChrome.headerHeight, 52)
        XCTAssertEqual(WindowChrome.rowCenter, 26)
        XCTAssertEqual(WindowChrome.horizontalInset, 18)
        // Controls are centred on the row.
        XCTAssertEqual(WindowChrome.controlTop, 14)
        XCTAssertEqual(WindowChrome.controlTop + WindowChrome.controlHeight / 2, WindowChrome.rowCenter)
    }

    func testTrafficLightsSitAtTheHeaderInsetCentredOnTheRow() {
        let origins = WindowChrome.trafficLightOrigins(buttonSize: CGSize(width: 14, height: 14), stride: 20)
        XCTAssertEqual(origins, [CGPoint(x: 18, y: 19), CGPoint(x: 38, y: 19), CGPoint(x: 58, y: 19)])
        XCTAssertEqual(origins[0].y + 7, WindowChrome.rowCenter)
        XCTAssertEqual(origins[2].x + 14, WindowChrome.defaultTrafficLightsTrailing)
        // The system's spacing is kept; a broken measurement falls back to the default stride.
        XCTAssertEqual(WindowChrome.trafficLightOrigins(buttonSize: CGSize(width: 16, height: 16), stride: 24).map(\.x), [18, 42, 66])
        XCTAssertEqual(WindowChrome.trafficLightOrigins(buttonSize: CGSize(width: 14, height: 14), stride: 0).map(\.x), [18, 38, 58])
    }

    func testOpenSidebarPutsTheToggleAtItsTrailingEdge() {
        let leading = WindowChrome.toggleLeading(sidebarOpen: true, trafficLightsTrailing: 72)
        // Right edge flush with the search field's right edge.
        XCTAssertEqual(leading + WindowChrome.controlWidth, WindowChrome.sidebarWidth - WindowChrome.sidebarContentInset)
        XCTAssertEqual(leading, 204)
        // Same spot in full screen.
        XCTAssertEqual(WindowChrome.toggleLeading(sidebarOpen: true, trafficLightsTrailing: nil), leading)
    }

    func testCollapsedSidebarPutsTheTogglePastTheTrafficLights() {
        XCTAssertEqual(WindowChrome.toggleLeading(sidebarOpen: false, trafficLightsTrailing: 72), 72 + WindowChrome.toggleGap)
        // The icon sits as far from the zoom button as the close button sits from the window edge.
        XCTAssertEqual(WindowChrome.toggleGap + WindowChrome.iconMargin, WindowChrome.horizontalInset)
        // Full screen: the icon at the header inset.
        XCTAssertEqual(WindowChrome.toggleLeading(sidebarOpen: false, trafficLightsTrailing: nil) + WindowChrome.iconMargin,
                       WindowChrome.horizontalInset)
    }

    func testTopRightIconsUseTheSameInsetAsTheLeft() {
        XCTAssertEqual(WindowChrome.clusterTrailing + WindowChrome.clusterPadding + WindowChrome.iconMargin,
                       WindowChrome.horizontalInset)
        // The cluster's backing is centred on the row too.
        let clusterTop = WindowChrome.controlTop - WindowChrome.clusterPadding
        XCTAssertEqual(clusterTop + (WindowChrome.controlHeight + 2 * WindowChrome.clusterPadding) / 2, WindowChrome.rowCenter)
    }

    func testTrafficLightsTrailingFollowsTheZoomButton() {
        XCTAssertEqual(WindowChrome.trafficLightsTrailing(zoomFrame: CGRect(x: 58, y: 19, width: 14, height: 14)), 72)
        XCTAssertEqual(WindowChrome.trafficLightsTrailing(zoomFrame: CGRect(x: 40, y: 7, width: 14, height: 14)), 54)
        XCTAssertNil(WindowChrome.trafficLightsTrailing(zoomFrame: nil))
    }

    func testImplausibleZoomFrameFallsBackToDefault() {
        XCTAssertEqual(WindowChrome.trafficLightsTrailing(zoomFrame: .zero), WindowChrome.defaultTrafficLightsTrailing)
        XCTAssertEqual(WindowChrome.trafficLightsTrailing(zoomFrame: CGRect(x: 40, y: 700, width: 14, height: 14)),
                       WindowChrome.defaultTrafficLightsTrailing)
        XCTAssertEqual(WindowChrome.trafficLightsTrailing(zoomFrame: CGRect(x: 400, y: 19, width: 14, height: 14)),
                       WindowChrome.defaultTrafficLightsTrailing)
    }

    func testContentStartsBelowTheHeaderRow() {
        XCTAssertGreaterThanOrEqual(WindowChrome.headerHeight, WindowChrome.controlTop + WindowChrome.controlHeight)
        // Equal room above and below the controls inside the row.
        XCTAssertEqual(WindowChrome.headerHeight - (WindowChrome.controlTop + WindowChrome.controlHeight), WindowChrome.controlTop)
        XCTAssertEqual(WindowChrome.canvasTopInset, WindowChrome.headerHeight)
        XCTAssertGreaterThan(WindowChrome.fadeHeight, WindowChrome.headerHeight)
    }
}
