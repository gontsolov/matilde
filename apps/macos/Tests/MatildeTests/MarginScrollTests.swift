import XCTest
@testable import Matilde
import MatildeKit

final class MarginScrollTests: XCTestCase {
    func testCardsSitAtTheirPassagesUntilTheCardAbovePushesThemDown() {
        let tops = MarginScroll.stack(anchors: [100, 150, 600], heights: [120, 80, 40])
        XCTAssertEqual(tops, [100, 232, 600])
        XCTAssertEqual(MarginScroll.cardsBottom(anchors: [100, 150, 600], heights: [120, 80, 40]), 640)
    }

    func testStackedCardsCanEndBelowTheLastPassage() {
        // Three cards on the last line stack downwards past it.
        XCTAssertEqual(MarginScroll.cardsBottom(anchors: [900, 900, 900], heights: [120, 120, 120]), 900 + 3 * 120 + 2 * 12)
    }

    func testNoCardsAddNoHeight() {
        XCTAssertNil(MarginScroll.cardsBottom(anchors: [], heights: []))
        XCTAssertEqual(MarginScroll.contentHeight(textHeight: 800, bottomInset: 40, cardsBottom: nil), 840)
    }

    func testContentHeightReachesTheLowerOfTextAndCards() {
        XCTAssertEqual(MarginScroll.contentHeight(textHeight: 800, bottomInset: 40, cardsBottom: 500), 840)
        XCTAssertEqual(MarginScroll.contentHeight(textHeight: 800, bottomInset: 40, cardsBottom: 1_300), 1_340)
        XCTAssertEqual(MarginScroll.contentHeight(textHeight: 800, bottomInset: 40, cardsBottom: 800), 840)
    }

    func testRoomGrowsAtOnce() {
        XCTAssertEqual(MarginScroll.retainedHeight(target: 1_400, previous: 900, visibleBottom: 700), 1_400)
    }

    func testRoomOnScreenIsKeptWhenCardsLeave() {
        // Scrolled to the bottom of the card room: removing the last card must not jump.
        XCTAssertEqual(MarginScroll.retainedHeight(target: 1_000, previous: 1_400, visibleBottom: 1_400), 1_400)
        // Scrolling back up releases the room that left the screen.
        XCTAssertEqual(MarginScroll.retainedHeight(target: 1_000, previous: 1_400, visibleBottom: 1_200), 1_200)
        XCTAssertEqual(MarginScroll.retainedHeight(target: 1_000, previous: 1_200, visibleBottom: 800), 1_000)
        XCTAssertEqual(MarginScroll.retainedHeight(target: 0, previous: 1_000, visibleBottom: 0), 0)
    }

    func testElasticOverscrollKeepsTheRoom() {
        XCTAssertEqual(MarginScroll.retainedHeight(target: 0, previous: 1_400, visibleBottom: 1_460), 1_400)
    }
}
