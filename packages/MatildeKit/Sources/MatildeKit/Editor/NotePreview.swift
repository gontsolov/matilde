import Foundation

/// A note's opening words as plain text, for the sidebar line under its title when it has no
/// writing goal. Markdown syntax (headings, list and quote markers, emphasis, code fences,
/// links, images, HTML, rules) is stripped and whitespace collapsed to single spaces.
public enum NotePreview {
    public static func text(_ markdown: String, limit: Int = 160) -> String {
        // Only the opening matters; don't scan a whole long draft on every keystroke.
        var lines: [String] = []
        var words = 0
        for raw in markdown.prefix(4000).split(separator: "\n", omittingEmptySubsequences: false) {
            let line = plainLine(String(raw))
            guard !line.isEmpty else { continue }
            lines.append(line)
            words += line.count
            if words > limit { break }
        }
        let joined = lines.joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard joined.count > limit else { return joined }
        return String(joined.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func plainLine(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        // Code fences and horizontal rules carry no words.
        if text.hasPrefix("```") || text.hasPrefix("~~~") { return "" }
        if text.range(of: #"^([-*_])(\s*\1){2,}$"#, options: .regularExpression) != nil { return "" }
        let rules: [(String, String)] = [
            (#"^(>\s?)+"#, ""),                              // quotes, nested too
            (#"^#{1,6}\s+"#, ""),                            // headings
            (#"^([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?"#, ""),    // list items and tasks
            (#"!\[[^\]]*\]\([^)]*\)"#, ""),                   // images
            (#"\[([^\]]*)\]\([^)]*\)"#, "$1"),                // links keep their label
            (#"<(https?://[^>]+)>"#, "$1"),                   // autolinks
            (#"</?[A-Za-z][^>]*>"#, ""),                      // HTML tags
            (#"(\*\*|__|~~|`)"#, ""),                         // strong, strike, code
            (#"(?<![\p{L}\p{N}\\])[*_](?=\S)|(?<=\S)(?<!\\)[*_](?![\p{L}\p{N}])"#, ""), // emphasis, not snake_case
            (#"\\([\\`*_{}\[\]()#+\-.!>~|])"#, "$1"),         // escapes
        ]
        for (pattern, template) in rules {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        // A heading or marker with nothing after it leaves only stray marks.
        if text.trimmingCharacters(in: CharacterSet(charactersIn: "#>-*+ ")).isEmpty { return "" }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
