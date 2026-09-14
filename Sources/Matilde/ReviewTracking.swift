import Foundation

struct ReviewMessage: Codable, Identifiable, Equatable {
    var id = UUID()
    let role: String
    let text: String
    var delivery: String? = nil
}

extension ReviewComment {
    func matches(_ text: String) -> Bool {
        let source = text as NSString
        return status != "stale" && range.location >= 0 && NSMaxRange(range) <= source.length
            && source.substring(with: range) == suggestion.quote
    }
}

/// A native edit is one replacement. Find its UTF-16 span without splitting Unicode characters.
struct WritingEdit {
    let range: NSRange
    let insertedLength: Int
    var delta: Int { insertedLength - range.length }
    static func between(_ old: String, _ new: String) -> Self {
        let before = Array(old), after = Array(new)
        var prefix = 0
        while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(before.count, after.count) - prefix,
              before[before.count - suffix - 1] == after[after.count - suffix - 1] { suffix += 1 }
        return Self(range: NSRange(location: String(before.prefix(prefix)).utf16.count,
                                   length: String(before[prefix..<(before.count - suffix)]).utf16.count),
                    insertedLength: String(after[prefix..<(after.count - suffix)]).utf16.count)
    }
}

extension WritingReview {
    mutating func track(_ input: ReviewInput) {
        guard let previous = source, previous.title == input.title, previous.goal == input.goal else {
            stale = true
            for i in comments.indices where comments[i].status == "open" { comments[i].status = "stale" }
            return
        }
        let edit = WritingEdit.between(previous.body, input.body)
        for i in comments.indices where comments[i].status == "open" {
            let range = comments[i].range
            if NSMaxRange(edit.range) <= range.location {
                comments[i].location += edit.delta
            } else if edit.range.location < NSMaxRange(range) {
                comments[i].status = "stale"
            }
            if !comments[i].matches(input.body) { comments[i].status = "stale" }
        }
        source = input
        revision = Self.revision(input)
        stale = !comments.isEmpty && comments.allSatisfy { $0.status == "stale" }
    }
}

extension WritingReviewModel {
    static func meaningfulChange(from old: ReviewInput, to new: ReviewInput) -> Bool {
        func words(_ value: String) -> String {
            value.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        }
        return words(old.body) != words(new.body) || words(old.goal) != words(new.goal)
    }
}
