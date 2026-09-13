import XCTest
@testable import Matilde

final class WritingPinchTests: XCTestCase {
    func testIncidentalAndOppositeGesturesStayInWriting() {
        for amount: CGFloat in [0.3, 0, -0.01, -0.03] {
            XCTAssertEqual(WritingPinch.progress(amount), 0)
            XCTAssertFalse(WritingPinch.commits(amount))
        }
        XCTAssertLessThan(WritingPinch.progress(-0.10), 0.5)
        XCTAssertFalse(WritingPinch.commits(-0.10))
    }

    func testDeliberateGestureTracksContinuouslyToTheSheet() {
        var previous: CGFloat = 0
        for step in 0...50 {
            let progress = WritingPinch.progress(-CGFloat(step) / 100)
            XCTAssertGreaterThanOrEqual(progress, previous)
            XCTAssertLessThanOrEqual(progress - previous, 0.09)
            XCTAssertLessThanOrEqual(progress, 1)
            previous = progress
        }
        XCTAssertEqual(previous, 1)
        XCTAssertTrue(WritingPinch.commits(-0.18))
    }

    func testReversingBeforeReleaseReturnsToWriting() {
        let outward = WritingPinch.progress(-0.3)
        let reversed = WritingPinch.progress(-0.08)
        XCTAssertLessThan(reversed, outward)
        XCTAssertFalse(WritingPinch.commits(-0.08))
        XCTAssertEqual(WritingPinch.progress(0), 0)
    }

    func testZoomOutDeceleratesTowardBoard() {
        let first = WritingPinch.progress(-0.15) - WritingPinch.progress(-0.03)
        let middle = WritingPinch.progress(-0.27) - WritingPinch.progress(-0.15)
        let last = WritingPinch.progress(-0.39) - WritingPinch.progress(-0.27)
        XCTAssertGreaterThan(first, middle)
        XCTAssertGreaterThan(middle, last)
    }

    func testPointerChoosesOtherPageAndEmptySpaceChoosesNothing() {
        let sheets = [("current", CGRect(x: 0, y: 0, width: 260, height: 340)),
                      ("other", CGRect(x: 300, y: 100, width: 260, height: 340))]
        XCTAssertEqual(BoardZoom.target(at: CGPoint(x: 350, y: 200), sheets: sheets), "other")
        XCTAssertNil(BoardZoom.target(at: CGPoint(x: 280, y: 80), sheets: sheets))
        let overlapping = sheets + [("top", CGRect(x: 320, y: 150, width: 100, height: 100))]
        XCTAssertEqual(BoardZoom.target(at: CGPoint(x: 350, y: 200), sheets: overlapping), "top")
    }

    func testZoomKeepsWorldPointUnderPointerIncludingAtLimits() {
        let size = CGSize(width: 1000, height: 700)
        let anchor = CGPoint(x: 730, y: 120)
        let start = BoardViewport(x: 120, y: -40, zoom: 0.7)
        let gesture = BoardZoom(start: start, anchor: anchor, draftID: "other")
        for factor in [0.01, 0.5, 1.0, 1.5, 10.0] {
            let result = gesture.viewport(magnification: factor, size: size)
            XCTAssertEqual(result.x + (anchor.x - size.width / 2) / result.zoom,
                           start.x + (anchor.x - size.width / 2) / start.zoom, accuracy: 0.0001)
            XCTAssertEqual(result.y + (anchor.y - size.height / 2) / result.zoom,
                           start.y + (anchor.y - size.height / 2) / start.zoom, accuracy: 0.0001)
            XCTAssertEqual(gesture.draftID, "other")
        }
    }

    func testCornersMatchTheBoardAtEndOfFlight() {
        for zoom: CGFloat in [0.08, 0.9, 1.4] {
            XCTAssertEqual(BoardPageStyle.radius(progress: 0, zoom: zoom), 0)
            XCTAssertGreaterThan(BoardPageStyle.radius(progress: 0.3, zoom: zoom), 0)
            XCTAssertEqual(BoardPageStyle.radius(progress: 1, zoom: zoom),
                           BoardPageStyle.cornerRadius * zoom, accuracy: 0.0001)
        }
    }
}
