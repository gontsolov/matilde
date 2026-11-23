import XCTest
@testable import Matilde

/// UI-13: where a note dragged in the sidebar lands.
final class SidebarDropTests: XCTestCase {
    // Documents header, two top-level notes, then folder "Essays" with one note, then "Empty".
    let sections: [(folder: String, rows: [String])] = [("", ["a", "b"]), ("Essays", ["c"]), ("Empty", [])]
    let frames: [String: CGRect] = [
        SidebarDropPlanner.headerKey(""): CGRect(x: 0, y: 80, width: 244, height: 30),
        SidebarDropPlanner.sectionKey(""): CGRect(x: 8, y: 110, width: 228, height: 100),
        SidebarDropPlanner.rowKey("a"): CGRect(x: 8, y: 110, width: 228, height: 50),
        SidebarDropPlanner.rowKey("b"): CGRect(x: 8, y: 160, width: 228, height: 50),
        SidebarDropPlanner.sectionKey("Essays"): CGRect(x: 8, y: 214, width: 228, height: 80),
        SidebarDropPlanner.headerKey("Essays"): CGRect(x: 8, y: 214, width: 228, height: 30),
        SidebarDropPlanner.rowKey("c"): CGRect(x: 8, y: 244, width: 228, height: 50),
        SidebarDropPlanner.sectionKey("Empty"): CGRect(x: 8, y: 298, width: 228, height: 30),
        SidebarDropPlanner.headerKey("Empty"): CGRect(x: 8, y: 298, width: 228, height: 30),
    ]
    func target(_ x: CGFloat, _ y: CGFloat) -> SidebarDropTarget? {
        SidebarDropPlanner.target(at: CGPoint(x: x, y: y), sections: sections, frames: frames)
    }

    func testReorderingWithinAFolderUsesRowMidpoints() {
        XCTAssertEqual(target(100, 120), SidebarDropTarget(folder: "", index: 0, onHeader: false, lineY: 109))
        XCTAssertEqual(target(100, 150), SidebarDropTarget(folder: "", index: 1, onHeader: false, lineY: 159))
        XCTAssertEqual(target(100, 200), SidebarDropTarget(folder: "", index: 2, onHeader: false, lineY: 211))
    }
    func testFolderRowsAndTheDocumentsHeaderTakeTheNote() {
        XCTAssertEqual(target(100, 225), SidebarDropTarget(folder: "Essays", index: 0, onHeader: true, lineY: nil))
        XCTAssertEqual(target(100, 90), SidebarDropTarget(folder: "", index: 0, onHeader: true, lineY: nil))
        XCTAssertEqual(target(100, 310)?.folder, "Empty")
    }
    func testBetweenAndBelowSectionsAndOutsideTheSidebar() {
        // The gap under the top-level notes still belongs to them; below the list, the last folder.
        XCTAssertEqual(target(100, 212)?.folder, "")
        XCTAssertEqual(target(100, 280), SidebarDropTarget(folder: "Essays", index: 1, onHeader: false, lineY: 295))
        XCTAssertEqual(target(100, 600)?.folder, "Empty")
        XCTAssertNil(target(400, 150))
        XCTAssertNil(target(100, 20))
    }
}
