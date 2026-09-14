import XCTest
import AppKit
@testable import Matilde

@MainActor
final class DraftComparisonTests: XCTestCase {
    private func workspace() throws -> Workspace {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/comparison-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try Workspace(root: root)
    }
    func testEditorsHaveIndependentUndoHistories() {
        let left = MarkdownEditor(draftID: "left", text: "", initialCursor: 0, initialScroll: 0, onChange: { _ in }, onPosition: { _, _ in }).makeCoordinator()
        let right = MarkdownEditor(draftID: "right", text: "", initialCursor: 0, initialScroll: 0, onChange: { _ in }, onPosition: { _, _ in }).makeCoordinator()
        let leftView = WritingTextView(); leftView.delegate = left; leftView.allowsUndo = true
        let rightView = WritingTextView(); rightView.delegate = right; rightView.allowsUndo = true
        leftView.undoManager?.beginUndoGrouping()
        leftView.insertText("Left", replacementRange: NSRange(location: 0, length: 0))
        leftView.undoManager?.endUndoGrouping()
        rightView.undoManager?.beginUndoGrouping()
        rightView.insertText("Right", replacementRange: NSRange(location: 0, length: 0))
        rightView.undoManager?.endUndoGrouping()
        rightView.undoManager?.undo()
        XCTAssertEqual(rightView.string, "")
        XCTAssertEqual(leftView.string, "Left")
        leftView.undoManager?.undo()
        XCTAssertEqual(leftView.string, "")
    }
    func testIndependentBuffersFlushAndPositionsDoNotChangeActiveDraft() throws {
        let workspace = try workspace()
        let first = try workspace.create(name: "First", folder: "", goal: "")
        let second = try workspace.branch(first, text: "Second version")
        try workspace.setState("active", first.id)
        let left = try DraftComparison(workspace: workspace, draft: first)
        let right = try DraftComparison(workspace: workspace, draft: second)
        left.edited("Left 🌱"); right.edited("Right 🐳")
        left.position(3, 10); right.position(4, 20)
        try right.flush(); try left.flush()
        XCTAssertEqual(try workspace.read(first), "Left 🌱")
        XCTAssertEqual(try workspace.read(second), "Right 🐳")
        XCTAssertEqual(try workspace.state("active"), first.id)
        let drafts = try workspace.allDrafts()
        XCTAssertEqual(drafts.first { $0.id == second.id }?.cursor, 4)
        XCTAssertEqual(drafts.first { $0.id == first.id }?.scroll, 10)
    }
    func testExternalConflictPreservesUnsavedComparisonText() throws {
        let workspace = try workspace()
        let draft = try workspace.create(name: "Conflict", folder: "", goal: "")
        let session = try DraftComparison(workspace: workspace, draft: draft)
        session.edited("Unsaved comparison")
        try workspace.save(draft, text: "External version")
        try session.flush()
        XCTAssertEqual(session.text, "External version")
        XCTAssertEqual(try workspace.read(draft), "External version")
        XCTAssertNotNil(session.error)
        let recovery = try FileManager.default.contentsOfDirectory(at: workspace.root.appendingPathComponent(".matilde/recovery"), includingPropertiesForKeys: nil)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(recovery.first), encoding: .utf8), "Unsaved comparison")
    }
    func testDebouncedAutosaveAndRenameUseCurrentIdentity() async throws {
        let workspace = try workspace()
        let draft = try workspace.create(name: "Original", folder: "", goal: "")
        let session = try DraftComparison(workspace: workspace, draft: draft)
        try workspace.rename(draft, name: "Renamed")
        session.edited("Saved after rename")
        try await Task.sleep(for: .milliseconds(900))
        let current = try XCTUnwrap(workspace.allDrafts().first { $0.id == draft.id })
        XCTAssertEqual(try workspace.read(current), "Saved after rename")
        XCTAssertEqual(session.draft.path, current.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.root.appendingPathComponent(draft.path).path))
    }
}
