// WritingReviewModel needs Combine (Apple platforms only); the pure parts are in ReviewContextTests.
#if canImport(Combine)
import XCTest
@testable import MatildeKit
import MatildeKit

private final class RecordingReviewClient: LangdockServing {
    var received: [ExistingComment]?
    let suggestions: [ReviewSuggestion]
    init(suggestions: [ReviewSuggestion]) { self.suggestions = suggestions }
    func models(configuration: LangdockConfiguration, key: String) async throws -> [String] { [] }
    func review(_ input: ReviewInput, configuration: LangdockConfiguration, key: String) async throws -> [ReviewSuggestion] { suggestions }
    func review(_ input: ReviewInput, existing: [ExistingComment], configuration: LangdockConfiguration, key: String) async throws -> [ReviewSuggestion] {
        received = existing
        return suggestions
    }
}

@MainActor
final class ReviewContextModelTests: XCTestCase {
    func testReviewSendsExistingCommentsAndDropsRepeats() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("matilde-review-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try Workspace(root: root)
        let body = "Tides rise twice a day. Most coastal towns rely on them. The moon pulls the sea toward it."
        let input = ReviewInput(title: "Tides", goal: "", body: body)
        var earlier = try WritingReview.make(draftID: "d", input: input, model: "m", suggestions: [
            ReviewSuggestion(quote: "Tides rise twice a day.", prefix: "", suffix: "", explanation: "Which tides?", replacement: nil)
        ])
        earlier.comments[0].status = "dismissed"
        try workspace.saveReview(earlier)
        let notePassage = (body as NSString).range(of: "coastal towns")
        try workspace.saveUserComments([CommentAnchor.refreshed(UserComment(id: UUID(), draftID: "d", text: "Check the count", location: 0, length: 0,
                                                                            quote: "", prefix: "", suffix: "", created: Date(), modified: Date()),
                                                                range: notePassage, in: body)])

        let client = RecordingReviewClient(suggestions: [
            ReviewSuggestion(quote: "Tides rise twice a day.", prefix: "", suffix: "", explanation: "Say which tides you mean.", replacement: nil),
            ReviewSuggestion(quote: "The moon pulls the sea toward it.", prefix: "", suffix: "", explanation: "Name the force.", replacement: nil)
        ])
        let model = WritingReviewModel(client: client)
        model.bind(workspace: workspace, draftID: "d", input: input)
        model.start(input: input, configuration: LangdockConfiguration(baseURL: "https://api.langdock.com", region: "eu", model: "m"), key: "k")
        for _ in 0..<200 where model.isRunning { try await Task.sleep(for: .milliseconds(10)) }

        XCTAssertEqual(client.received?.map(\.status), [.dismissed, .open])
        XCTAssertEqual(client.received?.map(\.kind), [.suggestion, .note])
        XCTAssertEqual(model.history.first?.comments.map(\.suggestion.explanation), ["Name the force."])
    }
}
#endif
