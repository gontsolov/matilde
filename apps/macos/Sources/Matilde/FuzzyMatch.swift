import Foundation

/// A fuzzy match of a query against one candidate string: a score (higher is better) and the
/// matched character offsets in the candidate, for highlighting.
struct FuzzyMatch: Equatable {
    var score: Int
    var positions: [Int]
}

/// Keyboard-first fuzzy matching for the command palette (UI-31).
///
/// The query is split on whitespace and every word must match, in any order. A word matches when
/// its characters appear in order in the candidate, ignoring case and diacritics. Contiguous runs,
/// word starts and an early first match score higher, so "nd" ranks "New Document" above
/// "Window", and an exact or prefix match always beats a scattered one.
enum FuzzySearch {
    /// Score tiers. A word that is a prefix of the whole candidate beats a word-start match,
    /// which beats an acronym, which beats a substring, which beats a scattered subsequence.
    static let exactBonus = 400
    static let prefixBonus = 300
    static let wordPrefixBonus = 200
    static let acronymBonus = 150
    static let substringBonus = 100
    /// Longer candidates only take part in contiguous matching.
    static let maxScatteredLength = 400

    static func fold(_ text: String) -> [Character] {
        Array(text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil))
    }

    static func words(_ query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// The best match of `query` against `candidate`, or nil when some query word does not match.
    /// An empty query matches nothing; callers show their empty state instead.
    static func match(_ query: String, in candidate: String) -> FuzzyMatch? {
        let words = words(query)
        guard !words.isEmpty else { return nil }
        let folded = fold(candidate)
        // Highlight offsets refer to the folded text; drop them if folding changed its length.
        let aligned = folded.count == candidate.count
        var total = 0
        var positions = Set<Int>()
        for word in words {
            guard let match = matchWord(fold(word), in: folded) else { return nil }
            total += match.score
            positions.formUnion(match.positions)
        }
        let whole = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        if whole == folded { total += exactBonus }
        // Shorter candidates win ties: "Save" over "Save a copy".
        total -= min(folded.count, 60) / 4
        return FuzzyMatch(score: total, positions: aligned ? positions.sorted() : [])
    }

    /// Whether every query word starts some word of `text`, for keyword lists, where scattered
    /// letters would match almost anything.
    static func wordPrefixes(_ query: String, in text: String) -> Bool {
        let targets = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let words = words(query).map { String(fold($0)) }
        return !words.isEmpty && words.allSatisfy { word in targets.contains { $0.hasPrefix(word) } }
    }

    static func isBoundary(_ characters: [Character], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = characters[index - 1]
        if previous.isWhitespace || previous.isPunctuation || previous.isSymbol { return true }
        return !previous.isLetter && characters[index].isLetter
    }

    /// One query word against the folded candidate.
    static func matchWord(_ word: [Character], in text: [Character]) -> FuzzyMatch? {
        guard !word.isEmpty, word.count <= text.count else { return nil }
        // Contiguous occurrences first: prefer the one at a word start, then the earliest.
        var best: FuzzyMatch?
        var start = 0
        while start + word.count <= text.count {
            if Array(text[start..<(start + word.count)]) == word {
                let tier = start == 0 ? prefixBonus : isBoundary(text, start) ? wordPrefixBonus : substringBonus
                let score = tier + word.count * 16 - min(start, 40)
                if score > (best?.score ?? .min) { best = FuzzyMatch(score: score, positions: Array(start..<(start + word.count))) }
            }
            start += 1
        }
        if let best { return best }
        return subsequence(word, in: text)
    }

    /// Scattered match by dynamic programming: each query character lands on a candidate
    /// character; consecutive landings and word starts earn bonuses, gaps cost a little.
    static func subsequence(_ word: [Character], in text: [Character]) -> FuzzyMatch? {
        let n = word.count, m = text.count
        guard m <= maxScatteredLength else { return nil }
        let none = Int.min / 4
        // score[i][j]: best score with word[i] landing on text[j]; from[i][j]: previous landing.
        var score = Array(repeating: Array(repeating: none, count: m), count: n)
        var from = Array(repeating: Array(repeating: -1, count: m), count: n)
        for j in 0..<m where text[j] == word[0] {
            score[0][j] = 10 + (isBoundary(text, j) ? 24 : 0) - min(j, 20)
        }
        if n > 1 {
            for i in 1..<n {
                var bestPrevious = none, bestIndex = -1
                for j in 1..<m {
                    // Best landing for word[i-1] anywhere before j, discounted by the gap.
                    let candidate = score[i - 1][j - 1]
                    if candidate > bestPrevious { bestPrevious = candidate; bestIndex = j - 1 }
                    guard text[j] == word[i] else { continue }
                    let base = 10 + (isBoundary(text, j) ? 24 : 0)
                    var value = none, previous = -1
                    if score[i - 1][j - 1] > none { value = score[i - 1][j - 1] + base + 20; previous = j - 1 }
                    if bestIndex >= 0 && bestIndex != j - 1 {
                        let gapped = bestPrevious + base - min(j - bestIndex - 1, 12)
                        if gapped > value { value = gapped; previous = bestIndex }
                    }
                    score[i][j] = value; from[i][j] = previous
                }
            }
        }
        guard let last = (0..<m).max(by: { score[n - 1][$0] < score[n - 1][$1] }), score[n - 1][last] > none else { return nil }
        var positions = [last]
        var j = last
        for i in stride(from: n - 1, to: 0, by: -1) {
            j = from[i][j]
            guard j >= 0 else { return nil }
            positions.append(j)
        }
        positions.reverse()
        // An acronym ("nd" in "New Document") ranks above a substring inside a word;
        // any other scattered match stays below every contiguous one.
        if positions.allSatisfy({ isBoundary(text, $0) }) {
            return FuzzyMatch(score: acronymBonus + n * 16 - min(positions[0], 40), positions: positions)
        }
        return FuzzyMatch(score: min(substringBonus - 1, score[n - 1][last] / 2), positions: positions)
    }
}
