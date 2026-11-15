import XCTest
import AppKit
@testable import Matilde

/// Screen coordinates: y grows upward, so "above" the caret means larger y.
final class SlashMenuLayoutTests: XCTestCase {
    private let visible = NSRect(x: 100, y: 100, width: 800, height: 600) // y 100...700
    private let maxHeight: CGFloat = 362
    private let size = NSSize(width: 236, height: 200)

    private func line(y: CGFloat, x: CGFloat = 300) -> NSRect { NSRect(x: x, y: y, width: 1, height: 20) }

    func testPrefersAboveWhenFullMenuFits() {
        let caret = line(y: 300) // room above: 700 - 4 - 324 = 372
        XCTAssertEqual(SlashMenuLayout.placement(caret: caret, maxHeight: maxHeight, visible: visible), .above)
        let frame = SlashMenuLayout.frame(caret: caret, size: size, visible: visible, placement: .above)
        XCTAssertEqual(frame.minY, caret.maxY + SlashMenuLayout.gap)
        XCTAssertEqual(frame.size, size)
    }

    func testPlacesBelowOnlyWhenFullMenuCannotFitAbove() {
        let caret = line(y: 500) // room above: 700 - 4 - 524 = 172 < 362
        XCTAssertEqual(SlashMenuLayout.placement(caret: caret, maxHeight: maxHeight, visible: visible), .below)
        let frame = SlashMenuLayout.frame(caret: caret, size: size, visible: visible, placement: .below)
        XCTAssertEqual(frame.maxY, caret.minY - SlashMenuLayout.gap)
        // A short filtered menu would fit above, but the decision uses the full height.
        XCTAssertEqual(SlashMenuLayout.placement(caret: caret, maxHeight: 120, visible: visible), .above)
    }

    func testPicksRoomierSideWhenNeitherFits() {
        let small = NSRect(x: 100, y: 100, width: 800, height: 300) // y 100...400
        XCTAssertEqual(SlashMenuLayout.placement(caret: line(y: 150), maxHeight: maxHeight, visible: small), .above)
        XCTAssertEqual(SlashMenuLayout.placement(caret: line(y: 330), maxHeight: maxHeight, visible: small), .below)
        let clamped = SlashMenuLayout.frame(caret: line(y: 150), size: NSSize(width: 236, height: 362), visible: small, placement: .above)
        XCTAssertEqual(clamped.maxY, small.maxY - SlashMenuLayout.margin)
    }

    func testClampsHorizontallyToVisibleArea() {
        let right = SlashMenuLayout.frame(caret: line(y: 300, x: 880), size: size, visible: visible, placement: .above)
        XCTAssertEqual(right.maxX, visible.maxX - SlashMenuLayout.margin)
        let left = SlashMenuLayout.frame(caret: line(y: 300, x: 20), size: size, visible: visible, placement: .above)
        XCTAssertEqual(left.minX, visible.minX + SlashMenuLayout.margin)
        let inside = SlashMenuLayout.frame(caret: line(y: 300, x: 400), size: size, visible: visible, placement: .above)
        XCTAssertEqual(inside.minX, 400)
    }

    func testAboveKeepsBottomEdgeFixedWhileFiltering() {
        var positioner = SlashMenuPositioner()
        let caret = line(y: 300)
        let bottoms = [362, 120, 46, 200].map { height -> CGFloat in
            let frame = positioner.frame(caret: caret, size: NSSize(width: 236, height: CGFloat(height)), maxHeight: maxHeight, visible: visible)
            XCTAssertEqual(positioner.placement, .above)
            return frame.minY
        }
        XCTAssertEqual(Set(bottoms), [caret.maxY + SlashMenuLayout.gap])
    }

    func testDoesNotFlipWhileFilteringUntilReset() {
        var positioner = SlashMenuPositioner()
        let caret = line(y: 500)
        let opened = positioner.frame(caret: caret, size: NSSize(width: 236, height: maxHeight), maxHeight: maxHeight, visible: visible)
        XCTAssertEqual(positioner.placement, .below)
        XCTAssertEqual(opened.maxY, caret.minY - SlashMenuLayout.gap)
        // Filtering shrinks the list enough to fit above; it must stay below with its top fixed.
        for height in [120, 46, 300] as [CGFloat] {
            let frame = positioner.frame(caret: caret, size: NSSize(width: 236, height: height), maxHeight: maxHeight, visible: visible)
            XCTAssertEqual(positioner.placement, .below)
            XCTAssertEqual(frame.maxY, opened.maxY)
        }
        // Reopening after the menu closes decides again.
        positioner.reset()
        _ = positioner.frame(caret: line(y: 200), size: size, maxHeight: maxHeight, visible: visible)
        XCTAssertEqual(positioner.placement, .above)
    }
}
