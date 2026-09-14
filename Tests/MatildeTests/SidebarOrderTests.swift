import XCTest
@testable import Matilde

final class SidebarOrderTests: XCTestCase {
    func draft(_ id: String, family: String? = nil, parent: String? = nil, edited: Double) -> Draft {
        Draft(id: id, path: id + ".md", family: family ?? id, parent: parent, goal: "", cursor: 0, scroll: 0,
              editedAt: Date(timeIntervalSince1970: edited))
    }
    func testNewestFamilyAndBranchesFirstWithoutReplacingParent() {
        let root = draft("A", edited: 1)
        let old = draft("B", family: "A", parent: "A", edited: 2)
        let newest = draft("Z", family: "A", parent: "A", edited: 10)
        let standalone = draft("C", edited: 5)
        let groups = SidebarOrder.groups([standalone, old, newest, root])
        XCTAssertEqual(groups.map(\.root.id), ["A", "C"])
        XCTAssertEqual(groups[0].branches.map(\.id), ["Z", "B"])
        XCTAssertEqual(SidebarOrder.groups([root, standalone]).map(\.root.id), ["C", "A"])
    }
    func testFilteredOrphanAndEqualDatesHaveStableOrder() {
        let a = draft("A", family: "family", parent: "missing", edited: 5)
        let b = draft("B", family: "family", parent: "missing", edited: 9)
        let c = draft("C", edited: 9)
        XCTAssertEqual(SidebarOrder.groups([b, a]).first?.root.id, "A")
        XCTAssertEqual(SidebarOrder.groups([a, b, c]).map(\.id), SidebarOrder.groups([c, b, a]).map(\.id))
    }
    func testFamilySelectionPersistsAndFallsBackAfterRemoval() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/sidebar-family-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try Workspace(root: root)
        let original = try workspace.create(name: "Original", folder: "", goal: "", text: "Disposable")
        let branch = try workspace.branch(original, text: "Alternate")
        let other = try workspace.create(name: "Other", folder: "", goal: "")
        try workspace.rememberFamilyDraft(branch)
        try workspace.rememberFamilyDraft(other)
        let reopened = try Workspace(root: root)
        XCTAssertEqual(try reopened.lastFamilyDraft(original.family, among: [original, branch, other])?.id, branch.id)
        XCTAssertEqual(try reopened.lastFamilyDraft(original.family, among: [original, other])?.id, original.id)
        XCTAssertNil(try reopened.lastFamilyDraft(original.family, among: [other]))
        try reopened.rememberFamilyDraft(original)
        XCTAssertEqual(try reopened.lastFamilyDraft(original.family, among: [original, branch])?.id, original.id)
    }

}
