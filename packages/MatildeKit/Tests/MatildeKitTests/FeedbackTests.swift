import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import MatildeKit

final class FeedbackTests: XCTestCase {
    private let diagnostics = FeedbackDiagnostics(app: "macos", appVersion: "0.3.0", build: "0.3.0", osVersion: "macOS 15.2",
                                                  deviceModel: "Mac14,2", locale: "de_DE")

    private func http() -> SyncHTTP {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyncStubProtocol.self]
        return SyncHTTP(server: .staging, session: URLSession(configuration: configuration), build: 300)
    }

    private func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }

    func testDraftValidation() {
        var draft = FeedbackDraft()
        XCTAssertFalse(draft.canSend)
        draft.message = "   \n "
        XCTAssertFalse(draft.canSend)
        draft.message = "  Hello  "
        XCTAssertTrue(draft.canSend)
        XCTAssertEqual(draft.trimmedMessage, "Hello")
        draft.replyEmail = "not an email"
        XCTAssertFalse(draft.canSend)
        draft.replyEmail = " anna@example.com "
        XCTAssertTrue(draft.canSend)
        draft.message = String(repeating: "😀", count: FeedbackDraft.maxMessageLength)
        XCTAssertTrue(draft.canSend)
        draft.message += "x"
        XCTAssertTrue(draft.isTooLong)
        XCTAssertFalse(draft.canSend)
    }

    func testRequestCarriesOnlyWhatTheUserChose() throws {
        var draft = FeedbackDraft(kind: .bug, message: " It crashed ", replyEmail: "", includeDiagnostics: false)
        var body = try JSONSerialization.jsonObject(with: try SyncHTTP.encode(draft.request(diagnostics: diagnostics))) as! [String: Any]
        XCTAssertEqual(Set(body.keys), ["kind", "message", "includeDiagnostics"])
        XCTAssertEqual(body["message"] as? String, "It crashed")
        XCTAssertEqual(body["includeDiagnostics"] as? Bool, false)

        draft.includeDiagnostics = true
        draft.replyEmail = "anna@example.com"
        body = try JSONSerialization.jsonObject(with: try SyncHTTP.encode(draft.request(diagnostics: diagnostics))) as! [String: Any]
        XCTAssertEqual(body["replyEmail"] as? String, "anna@example.com")
        let sent = try XCTUnwrap(body["diagnostics"] as? [String: Any])
        XCTAssertEqual(sent["deviceModel"] as? String, "Mac14,2")
        XCTAssertEqual(Set(sent.keys), ["app", "appVersion", "build", "osVersion", "deviceModel", "locale"])
    }

    func testDisclosureShowsEverythingThatIsSent() {
        let values = diagnostics.lines.map(\.value).joined(separator: " ")
        for field in [diagnostics.appVersion, diagnostics.build, diagnostics.osVersion, diagnostics.deviceModel!, diagnostics.locale!] {
            XCTAssertTrue(values.contains(field), field)
        }
    }

    func testCurrentDiagnosticsFitTheServerRules() {
        let current = FeedbackDiagnostics.current()
        XCTAssertTrue(["macos", "ios"].contains(current.app))
        XCTAssertFalse(current.appVersion.isEmpty)
        XCTAssertLessThanOrEqual(current.osVersion.count, 64)
        XCTAssertEqual(FeedbackDiagnostics.clean(" Mac<14>,2 ", allowed: FeedbackDiagnostics.modelCharacters, max: 64), "Mac14,2")
        XCTAssertNil(FeedbackDiagnostics.clean("<>", allowed: FeedbackDiagnostics.modelCharacters, max: 64))
        XCTAssertEqual(FeedbackDiagnostics.clean(String(repeating: "1", count: 40), allowed: FeedbackDiagnostics.buildCharacters, max: 32)?.count, 32)
    }

    func testMailtoKeepsTheTextIntact() throws {
        let draft = FeedbackDraft(kind: .idea, message: "A & B = C + D #1?", includeDiagnostics: false)
        let url = draft.mailtoURL(diagnostics: diagnostics)
        XCTAssertTrue(url.absoluteString.hasPrefix("mailto:feedback@matilde.page?subject=Matilde%20feedback%3A%20Idea&body="))
        let body = try XCTUnwrap(url.absoluteString.components(separatedBy: "&body=").last?.removingPercentEncoding)
        XCTAssertEqual(body, "A & B = C + D #1?")
        XCTAssertFalse(url.absoluteString.contains("Mac14"))
        XCTAssertTrue(FeedbackDraft(message: "x").mailtoURL(diagnostics: diagnostics).absoluteString.contains("Mac14%2C2"))
    }

    func testClientPostsToTheSelectedServer() async throws {
        SyncStubProtocol.install { _ in .init(status: 201, body: self.json(["ok": true, "id": "x", "status": "sent"])) }
        let request = FeedbackDraft(kind: .bug, message: "Hi").request(diagnostics: diagnostics)
        let outcome = try await FeedbackClient(http: http()).send(request, accessToken: "access-1")
        XCTAssertEqual(outcome, .sent)
        let seen = try XCTUnwrap(SyncStubProtocol.seen.first)
        XCTAssertEqual(seen.url?.absoluteString, "https://sync-staging.matilde.page/v1/feedback")
        XCTAssertEqual(seen.httpMethod, "POST")
        XCTAssertEqual(seen.value(forHTTPHeaderField: "Authorization"), "Bearer access-1")
        XCTAssertEqual(seen.value(forHTTPHeaderField: "X-Matilde-Build"), "300")
    }

    func testClientTreatsAStoredMessageAsSaved() async throws {
        SyncStubProtocol.install { _ in
            .init(status: 502, body: self.json(["error": ["code": "feedback_delivery_failed", "message": "x"], "id": "x", "queued": true]))
        }
        let outcome = try await FeedbackClient(http: http()).send(FeedbackDraft(message: "Hi").request(diagnostics: diagnostics))
        XCTAssertEqual(outcome, .saved)
        XCTAssertNil(SyncStubProtocol.seen.first?.value(forHTTPHeaderField: "Authorization"))
    }

    func testClientReportsRateLimits() async {
        SyncStubProtocol.install { _ in
            .init(status: 429, body: self.json(["error": ["code": "rate_limited", "message": "x"]]), headers: ["Retry-After": "60"])
        }
        do {
            _ = try await FeedbackClient(http: http()).send(FeedbackDraft(message: "Hi").request(diagnostics: diagnostics))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as? SyncServerError)?.code, "rate_limited")
            XCTAssertTrue(FeedbackCopy.failure(error).contains("try again later") || FeedbackCopy.failure(error).contains("Try again later"))
        }
    }
}
