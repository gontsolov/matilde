import Foundation

/// One change to the Markdown text: replace `range` (UTF-16, in the old text) with
/// `replacement`, then select `selection` (UTF-16, in the new text).
///
/// The editors apply it as a single native replacement, so it is one undo step and keeps the
/// rest of the text (and its comment anchors) untouched. `MarkdownEditing` returns the smallest
/// such change; an edit whose range is empty and whose replacement is empty only moves the caret
/// (or does nothing, which still tells the editor the key was handled).
public struct MarkdownEdit: Equatable, Sendable, CustomStringConvertible {
    public var range: NSRange
    public var replacement: String
    public var selection: NSRange

    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }

    /// True when the edit changes no characters.
    public var isSelectionOnly: Bool { range.length == 0 && replacement.isEmpty }

    /// The text after the edit.
    public func applied(to text: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: replacement)
    }

    /// The smallest edit turning `old` into `new`, with `selection` in `new`. Common leading and
    /// trailing UTF-16 units are left out, never splitting a surrogate pair.
    public static func between(_ old: String, _ new: String, selection: NSRange) -> MarkdownEdit {
        let a = old as NSString, b = new as NSString
        var prefix = 0
        let limit = min(a.length, b.length)
        while prefix < limit, a.character(at: prefix) == b.character(at: prefix) { prefix += 1 }
        // Don't end the shared prefix between the halves of a surrogate pair.
        if prefix > 0, prefix < limit, UTF16.isLeadSurrogate(a.character(at: prefix - 1)) { prefix -= 1 }
        var suffix = 0
        while suffix < limit - prefix,
              a.character(at: a.length - 1 - suffix) == b.character(at: b.length - 1 - suffix) { suffix += 1 }
        if suffix > 0, suffix < limit - prefix, UTF16.isTrailSurrogate(a.character(at: a.length - suffix)) { suffix -= 1 }
        let range = NSRange(location: prefix, length: a.length - prefix - suffix)
        let replacement = b.substring(with: NSRange(location: prefix, length: b.length - prefix - suffix))
        return MarkdownEdit(range: range, replacement: replacement, selection: selection)
    }

    public var description: String {
        "MarkdownEdit(\(range.location),\(range.length) → \(replacement.debugDescription), selection \(selection.location),\(selection.length))"
    }
}
