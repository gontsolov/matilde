import XCTest
@testable import Matilde

@MainActor
final class MarginLayoutTests: XCTestCase {
    func testTextAndCardsAreCenteredAsOneGroup() {
        for width in [900.0, 1100, 1400, 1800] as [CGFloat] {
            let layout = CommentMargin.layout(width: width, reserve: true)
            let textLeft = layout.leading + CommentMargin.textInset
            let cardsRight = layout.leading + layout.column - 28 + CommentMargin.cardGap + CommentMargin.cardWidth(for: width)
            XCTAssertEqual(textLeft, width - cardsRight, accuracy: 0.5, "width \(width)")
            XCTAssertGreaterThanOrEqual(width - cardsRight, CommentMargin.outerMargin, "width \(width)")
            XCTAssertLessThanOrEqual(layout.column, CommentMargin.maximumColumn)
        }
    }

    func testNarrowWindowsKeepTheOuterMarginAndWithoutCardsTheTextIsCentered() {
        let width: CGFloat = 800
        XCTAssertTrue(CommentMargin.fits(width: width))
        let layout = CommentMargin.layout(width: width, reserve: true)
        let cardsRight = layout.leading + layout.column - 28 + CommentMargin.cardGap + CommentMargin.cardWidth(for: width)
        XCTAssertEqual(width - cardsRight, CommentMargin.outerMargin, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(layout.column, CommentMargin.minimumEditorWidth)

        let plain = CommentMargin.layout(width: 1200, reserve: false)
        XCTAssertEqual(plain.column, CommentMargin.maximumColumn)
        XCTAssertEqual(plain.leading, (1200 - CommentMargin.maximumColumn) / 2)
        XCTAssertFalse(CommentMargin.fits(width: 700))
    }

    func testCardsAreWiderWhenThereIsRoomAndNarrowBeforeTheEditorShrinksBelowItsMinimum() {
        XCTAssertEqual(CommentMargin.cardWidth(for: 1400), CommentMargin.cardWidth)
        XCTAssertGreaterThanOrEqual(CommentMargin.cardWidth, 340)
        XCTAssertEqual(CommentMargin.cardWidth(for: 800), CommentMargin.reservedCardWidth)
        for width in stride(from: CGFloat(760), through: 1000, by: 10) {
            let card = CommentMargin.cardWidth(for: width)
            XCTAssertGreaterThanOrEqual(card, CommentMargin.reservedCardWidth)
            XCTAssertLessThanOrEqual(card, CommentMargin.cardWidth)
            if CommentMargin.fits(width: width) {
                XCTAssertGreaterThanOrEqual(CommentMargin.layout(width: width, reserve: true).column, CommentMargin.minimumEditorWidth - 0.5, "width \(width)")
            }
        }
    }

    func testBranchNamesCountUpInsteadOfStackingSuffixes() throws {
        XCTAssertEqual(Workspace.branchBase("Letter — Alternative 1"), "Letter")
        XCTAssertEqual(Workspace.branchBase("Letter — Alternative 1 — Alternative 1"), "Letter")
        XCTAssertEqual(Workspace.branchBase("Letter – Alternative 12"), "Letter")
        XCTAssertEqual(Workspace.branchBase("Letter"), "Letter")
        XCTAssertEqual(Workspace.branchBase("Alternative 1"), "Alternative 1")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MatildeBranchNames-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let workspace = try Workspace(root: root)
        let original = try workspace.create(name: "Letter", folder: "", goal: "", text: "Dear friend")
        let first = try workspace.branch(original, text: "Dear friend")
        let second = try workspace.branch(first, text: "Dear friend")
        XCTAssertEqual(first.title, "Letter — Alternative 1")
        XCTAssertEqual(second.title, "Letter — Alternative 2")
    }

    func testArchivedCommentsLeaveTheDraftButStayInTheDatabase() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MatildeArchive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let workspace = try Workspace(root: root)
        let body = "The harbor was quiet and the boats waited."
        let store = UserCommentStore()
        store.bind(workspace: workspace, draftID: "d", body: body)
        let kept = try XCTUnwrap(store.add(range: (body as NSString).range(of: "harbor")))
        store.update(kept.id, text: "Keep")
        let archived = try XCTUnwrap(store.add(range: (body as NSString).range(of: "boats")))
        store.update(archived.id, text: "Done with this")
        store.archive(archived.id)
        XCTAssertEqual(store.comments.map(\.id), [kept.id])

        let reopened = UserCommentStore()
        reopened.bind(workspace: try Workspace(root: root), draftID: "d", body: body)
        XCTAssertEqual(reopened.comments.map(\.text), ["Keep"])
        let rows = try workspace.db.execute("SELECT body FROM user_comments WHERE archived = 1")
        XCTAssertEqual(rows.map { $0["body"] }, ["Done with this"])
    }
}
