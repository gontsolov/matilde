import XCTest
@testable import MatildeKit
import MatildeKit

/// AI-19: reviews know the draft's existing comments and don't repeat them.
final class ReviewContextTests: XCTestCase {
    private let body = "Tides rise twice a day. Most coastal towns rely on them. The moon pulls the sea toward it."

    private func range(_ text: String) -> NSRange { (body as NSString).range(of: text) }
    private func review(_ quote: String, _ explanation: String, status: String = "open", replacement: String? = nil,
                        userInitiated: Bool? = nil, messages: [ReviewMessage]? = nil, in text: String? = nil) -> ReviewComment {
        let source = text ?? body
        let found = (source as NSString).range(of: quote)
        var comment = CommentAnchor.refreshed(ReviewComment(id: UUID(), suggestion: ReviewSuggestion(quote: quote, prefix: "", suffix: "",
                                                            explanation: explanation, replacement: replacement),
                                                            location: found.location, length: found.length), range: found, in: source)
        comment.status = status; comment.userInitiated = userInitiated; comment.messages = messages
        comment.reviewedQuote = comment.quote
        return comment
    }
    private func run(_ comments: [ReviewComment], stale: Bool = false, created: Date = Date()) -> WritingReview {
        WritingReview(id: UUID(), draftID: "d", created: created, model: "m", revision: "r", stale: stale, comments: comments,
                      source: ReviewInput(title: "", goal: "", body: body))
    }
    private func note(_ quote: String, _ text: String, author: String? = nil) -> UserComment {
        CommentAnchor.refreshed(UserComment(id: UUID(), draftID: "d", text: text, location: 0, length: 0, quote: "", prefix: "", suffix: "",
                                            created: Date(), modified: Date(), author: author), range: range(quote), in: body)
    }

    // MARK: Context building

    func testIncludesOpenResolvedDismissedAndPrivateCommentsWithStatus() {
        let open = review("Tides rise twice a day.", "Which tides? Some coasts have one a day.")
        let dismissed = review("Most coastal towns rely on them.", "Rely how? Add an example.", status: "dismissed")
        let accepted = review("The moon pulls", "Name the force.", status: "accepted", replacement: "Gravity from the moon pulls")
        let removed = review("sea", "Which sea?", status: "removed")
        let own = note("coastal towns", "Check the number of towns")
        let archived = note("toward it", "Too vague?")
        let existing = ReviewContext.existingComments(history: [run([open, dismissed, accepted, removed])], notes: [own],
                                                      archivedNotes: [archived], body: body)
        XCTAssertEqual(existing.map(\.comment), ["Which tides? Some coasts have one a day.", "Rely how? Add an example.",
                                                 "Check the number of towns", "Name the force.", "Too vague?"])
        XCTAssertEqual(existing.map(\.status), [.open, .dismissed, .open, .resolved, .dismissed])
        XCTAssertEqual(existing.map(\.kind), [.suggestion, .suggestion, .note, .suggestion, .note])
        XCTAssertEqual(existing[0].passage, "Tides rise twice a day.")
        XCTAssertEqual(existing[0].range, range("Tides rise twice a day."))
        XCTAssertEqual(existing[2].passage, "coastal towns")
        XCTAssertEqual(existing[3].suggestedRewrite, "Gravity from the moon pulls")
        XCTAssertFalse(existing.contains { $0.comment == "Which sea?" }, "deleted passages are left out")
    }

    func testThreadsCarryRepliesAndWriterQuestionsAndNewestCopyWins() {
        let older = review("Tides rise twice a day.", "Which tides?")
        var newer = older
        newer.status = "dismissed"
        newer.messages = [ReviewMessage(role: "user", text: "Semidiurnal, I think"), ReviewMessage(role: "assistant", text: "Then say so."),
                          ReviewMessage(role: "user", text: "lost", delivery: "failed")]
        let question = review("The moon pulls the sea", "", userInitiated: true,
                              messages: [ReviewMessage(role: "user", text: "Is this accurate?"), ReviewMessage(role: "assistant", text: "Roughly.")])
        let staleOpen = review("Most coastal towns", "Stale and open")
        let history = [run([newer, question]), run([older, staleOpen], stale: true, created: Date(timeIntervalSinceNow: -60))]
        let existing = ReviewContext.existingComments(history: history, notes: [], body: body)
        XCTAssertEqual(existing.count, 2, "one copy per thread; open comments of superseded reviews are not current")
        XCTAssertEqual(existing[0].status, .dismissed)
        XCTAssertEqual(existing[0].replies, [.init(role: "writer", text: "Semidiurnal, I think"), .init(role: "matilde", text: "Then say so.")])
        XCTAssertEqual(existing[1].kind, .question)
        XCTAssertEqual(existing[1].author, .writer)
        XCTAssertEqual(existing[1].comment, "Is this accurate?")
        XCTAssertEqual(existing[1].replies, [.init(role: "matilde", text: "Roughly.")])
    }

    func testReworkedPassageIsMarkedChangedAndMCPNoteIsFromAITool() {
        var open = review("Tides rise twice a day.", "Which tides?")
        let edited = "Tides here rise once daily on this coast. " + body.dropFirst("Tides rise twice a day. ".count)
        let found = (edited as NSString).range(of: "Tides here rise once daily on this coast.")
        open = CommentAnchor.refreshed(open, range: found, in: edited)
        let fromTool = CommentAnchor.refreshed(UserComment(id: UUID(), draftID: "d", text: "Cite a source", location: 0, length: 0, quote: "",
                                                           prefix: "", suffix: "", created: Date(), modified: Date(), author: "Claude"),
                                               range: (edited as NSString).range(of: "coastal towns"), in: edited)
        let existing = ReviewContext.existingComments(history: [run([open])], notes: [fromTool], body: edited)
        XCTAssertTrue(existing[0].passageChanged)
        XCTAssertEqual(existing[0].passageWhenCommented, "Tides rise twice a day.")
        XCTAssertEqual(existing[0].passage, "Tides here rise once daily on this coast.")
        XCTAssertEqual(existing[1].author, .aiTool)
        XCTAssertFalse(existing[1].passageChanged)
    }

    func testDetachedAndEmptyNotesAreLeftOut() {
        var detached = note("coastal towns", "Gone")
        detached.quote = "a passage that was deleted"; detached.prefix = ""; detached.suffix = ""; detached.length = 0
        let empty = note("moon", "   ")
        XCTAssertTrue(ReviewContext.existingComments(history: [], notes: [detached, empty], body: body).isEmpty)
    }

    // MARK: Request layout

    func testRequestKeepsStablePrefixAndAppendsCommentsLast() throws {
        let input = ReviewInput(title: "Tides", goal: "Explain", body: body)
        let bare = ReviewContext.messages(input: input, existing: [], guidance: "Be brief.")
        XCTAssertEqual(bare.map(\.role), ["system", "user"])
        let existing = ReviewContext.existingComments(history: [run([review("Tides rise twice a day.", "Which tides?")])],
                                                      notes: [note("coastal towns", "Check ![x](/Users/a/b.png)")], body: body)
        let full = ReviewContext.messages(input: input, existing: existing, guidance: "Be brief.")
        XCTAssertEqual(full.map(\.role), ["system", "user", "user"])
        XCTAssertEqual(Array(full.prefix(2)), bare, "system prompt and draft stay byte-identical, so the provider can cache them")
        XCTAssertEqual(full[1].content, ReplyPrompt.encode(input.transmitted))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(full[2].content.utf8)) as? [String: Any])
        let comments = try XCTUnwrap(payload["existing_comments"] as? [[String: Any]])
        XCTAssertEqual(comments.count, 2)
        XCTAssertEqual(comments[0]["status"] as? String, "open")
        XCTAssertEqual(comments[0]["by"] as? String, "matilde")
        XCTAssertEqual(comments[0]["passage"] as? String, "Tides rise twice a day.")
        XCTAssertNil(comments[0]["passage_when_commented"])
        XCTAssertEqual(comments[1]["kind"] as? String, "note")
        XCTAssertEqual(comments[1]["comment"] as? String, "Check [Image omitted]", "comments are scrubbed like the draft")
        XCTAssertEqual(ReviewContext.message(existing), ReviewContext.message(existing), "deterministic bytes")
        XCTAssertTrue(WritingAssistPrompt.reviewFormat.contains("existing_comments"))
    }

    func testMessageIsBoundedAndKeepsOpenCommentsFirst() throws {
        let long = String(repeating: "word ", count: 400)
        var comments: [ExistingComment] = []
        for index in 0..<200 {
            comments.append(ExistingComment(id: UUID(), author: .matilde, kind: .suggestion, status: index.isMultiple(of: 2) ? .dismissed : .open,
                                            passage: long, comment: long, range: NSRange(location: index, length: 1)))
        }
        let message = try XCTUnwrap(ReviewContext.message(comments))
        XCTAssertLessThanOrEqual(message.utf8.count, ReviewContext.maximumBytes + 100)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
        let kept = try XCTUnwrap(payload["existing_comments"] as? [[String: Any]])
        XCTAssertFalse(kept.isEmpty)
        XCTAssertTrue(kept.allSatisfy { $0["status"] as? String == "open" })
        XCTAssertLessThanOrEqual((kept[0]["comment"] as? String)?.count ?? 0, 601)
    }

    // MARK: Deduplication

    private func suggestion(_ quote: String, _ explanation: String, in text: String? = nil) -> ReviewComment {
        review(quote, explanation, in: text)
    }

    func testSamePassageIsDuplicateWhateverTheWording() {
        let existing = ReviewContext.existingComments(history: [run([review("Most coastal towns rely on them.", "Rely how?", status: "dismissed")])],
                                                      notes: [], body: body)
        XCTAssertTrue(ReviewDeduplication.isDuplicate(suggestion("coastal towns rely on them.", "Give a concrete example of dependence."), of: existing))
        XCTAssertFalse(ReviewDeduplication.isDuplicate(suggestion("The moon pulls the sea toward it.", "Rely how?"), of: existing),
                       "no overlap, no duplicate")
    }

    func testOverlapWithSimilarPointIsDuplicateButDifferentPointIsKept() {
        let existing = ReviewContext.existingComments(history: [], notes: [note("Tides rise twice a day. Most coastal towns rely on them.",
                                                                                "Which tides? Some coasts get one tide a day.")], body: body)
        XCTAssertTrue(ReviewDeduplication.isDuplicate(suggestion("twice a day", "Not every coast gets two tides a day; say which tides."), of: existing))
        XCTAssertFalse(ReviewDeduplication.isDuplicate(suggestion("twice a day", "Start with a scene instead of a fact."), of: existing))
    }

    func testChangedPassageNoLongerBlocks() {
        var open = review("Tides rise twice a day.", "Which tides?")
        let edited = "Tides here rise once daily on this coast. " + body.dropFirst("Tides rise twice a day. ".count)
        open = CommentAnchor.refreshed(open, range: (edited as NSString).range(of: "Tides here rise once daily on this coast."), in: edited)
        let existing = ReviewContext.existingComments(history: [run([open])], notes: [], body: edited)
        XCTAssertFalse(ReviewDeduplication.isDuplicate(suggestion("Tides here rise once daily on this coast.", "Which tides?", in: edited), of: existing))

        let unchanged = ReviewContext.existingComments(history: [run([review("Tides rise twice a day.", "Which tides?")])], notes: [], body: body)
        XCTAssertTrue(ReviewDeduplication.isDuplicate(suggestion("Tides rise twice a day.", "Which tides?"), of: unchanged))
    }

    func testFilterKeepsOnlyNewPoints() {
        let existing = ReviewContext.existingComments(history: [run([review("Tides rise twice a day.", "Which tides?")])],
                                                      notes: [note("The moon pulls the sea toward it.", "Explain the gravity here")], body: body)
        let fresh = [suggestion("Tides rise twice a day.", "Which tides exactly?"),
                     suggestion("Most coastal towns rely on them.", "Which towns? Name one."),
                     suggestion("moon pulls", "Explain how gravity pulls here.")]
        XCTAssertEqual(ReviewDeduplication.filter(fresh, against: existing).map(\.suggestion.explanation), ["Which towns? Name one."])
    }

    func testWordingHelpers() {
        XCTAssertTrue(ReviewDeduplication.similarWording("This claim needs a source.", "Add a source for the claims here"))
        XCTAssertFalse(ReviewDeduplication.similarWording("This claim needs a source.", "The rhythm of this sentence drags."))
        XCTAssertFalse(ReviewDeduplication.similarWording("", "anything"))
        XCTAssertTrue(ReviewDeduplication.sameWording("Tides rise twice a day, mostly.", "Tides rise twice a day, mostly!"))
        XCTAssertFalse(ReviewDeduplication.sameWording("Tides rise twice a day.", "Tides here rise once daily on this coast."))
    }

    // MARK: Storage

    func testArchivedPrivateCommentsLoadSeparately() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("matilde-review-context-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try Workspace(root: root)
        let kept = note("coastal towns", "Keep"), archived = note("moon", "Archive me")
        try workspace.saveUserComments([kept, archived])
        try workspace.archiveUserComment(archived.id)
        XCTAssertEqual(try workspace.userComments(draftID: "d").map(\.id), [kept.id])
        XCTAssertEqual(try workspace.archivedUserComments(draftID: "d").map(\.id), [archived.id])
    }

    func testReviewedQuoteIsKeptThroughSaveAndOlderPayloadsDecode() throws {
        let made = try WritingReview.make(draftID: "d", input: ReviewInput(title: "", goal: "", body: body), model: "m",
                                          suggestions: [ReviewSuggestion(quote: "twice a day", prefix: "", suffix: "", explanation: "?", replacement: nil)])
        XCTAssertEqual(made.comments[0].reviewedQuote, "twice a day")
        let decoded = try JSONDecoder().decode(WritingReview.self, from: JSONEncoder().encode(made))
        XCTAssertEqual(decoded.comments[0].reviewedQuote, "twice a day")
        let legacy = #"{"id":"\#(UUID().uuidString)","suggestion":{"quote":"a","prefix":"","suffix":"","explanation":"b"},"location":0,"length":1,"status":"open"}"#
        XCTAssertNil(try JSONDecoder().decode(ReviewComment.self, from: Data(legacy.utf8)).reviewedQuote)
    }
}
