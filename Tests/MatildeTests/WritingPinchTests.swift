import XCTest
@testable import Matilde

final class WritingPinchTests: XCTestCase {
    func testIncidentalAndOppositeGesturesStayInWriting() {
        for amount: CGFloat in [0.3, 0, -0.01, -0.03] {
            XCTAssertEqual(WritingPinch.progress(amount), 0)
            XCTAssertFalse(WritingPinch.commits(amount))
        }
        XCTAssertLessThan(WritingPinch.progress(-0.10), 0.05)
        XCTAssertFalse(WritingPinch.commits(-0.10))
    }

    func testDeliberateGestureTracksContinuouslyToTheSheet() {
        var previous: CGFloat = 0
        for step in 0...50 {
            let progress = WritingPinch.progress(-CGFloat(step) / 100)
            XCTAssertGreaterThanOrEqual(progress, previous)
            XCTAssertLessThanOrEqual(progress - previous, 0.06)
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
}
