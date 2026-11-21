import Foundation
import MatildeKit

extension WritingReviewModel {
    static func meaningfulChange(from old: ReviewInput, to new: ReviewInput) -> Bool {
        func words(_ value: String) -> String {
            value.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        }
        return words(old.body) != words(new.body) || words(old.goal) != words(new.goal)
    }
}
