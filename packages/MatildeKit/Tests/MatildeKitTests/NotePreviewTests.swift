import XCTest
import MatildeKit

final class NotePreviewTests: XCTestCase {
    func testStripsBlockMarkersAndJoinsLines() {
        XCTAssertEqual(NotePreview.text("# Intro\n\nI like this a lot.\nLike, a lot.\n"), "Intro I like this a lot. Like, a lot.")
        XCTAssertEqual(NotePreview.text("- first\n  - [ ] nested task\n1. ordered\n> > quoted"), "first nested task ordered quoted")
    }
    func testStripsInlineMarkdownButKeepsWords() {
        XCTAssertEqual(NotePreview.text("**Bold**, *italic*, _under_, ~~gone~~ and `code` in snake_case"),
                       "Bold, italic, under, gone and code in snake_case")
        XCTAssertEqual(NotePreview.text("See [the site](https://example.com) ![pic](a.png) <https://x.dev> <b>hi</b>"),
                       "See the site https://x.dev hi")
        XCTAssertEqual(NotePreview.text(#"A literal \*star\* stays"#), "A literal *star* stays")
    }
    func testSkipsFencesRulesAndEmptyMarkers() {
        XCTAssertEqual(NotePreview.text("```swift\nlet x = 1\n```\n---\n#\n- \nAfter"), "let x = 1 After")
        XCTAssertEqual(NotePreview.text("\n\n   \n"), "")
    }
    func testTruncatesWithAnEllipsis() {
        let long = String(repeating: "word ", count: 100)
        let preview = NotePreview.text(long, limit: 20)
        XCTAssertEqual(preview, "word word word word…")
    }
}
