import Foundation

/// Where the writing editor puts the caret and scroll when a draft opens, and when the body
/// shows its placeholder.
enum EditorLanding {
    /// Switching notes always lands at the top of the new note, caret at the start of the
    /// body, so nothing jumps after the text appears. Only a restored session or a new branch
    /// (which continues where its source was) keeps the saved position.
    static func position(cursor: Int, scroll: Double, restores: Bool) -> (cursor: Int, scroll: Double) {
        restores ? (max(0, cursor), max(0, scroll)) : (0, 0)
    }

    static let bodyPlaceholder = "Start writing…"

    /// Shown only while the body has no text at all; IME composition (marked text) counts as text.
    static func showsBodyPlaceholder(textLength: Int, hasMarkedText: Bool) -> Bool {
        textLength == 0 && !hasMarkedText
    }
}
