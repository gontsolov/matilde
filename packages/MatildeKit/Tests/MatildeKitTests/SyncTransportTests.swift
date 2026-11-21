import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import MatildeKit
import MatildeKitTesting

/// Answers requests from a handler instead of the network.
final class SyncStubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { var status: Int; var body: Data; var headers: [String: String] = [:] }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest) -> Reply)?
    nonisolated(unsafe) private(set) static var requests: [URLRequest] = []

    static func install(_ handler: @escaping (URLRequest) -> Reply) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
        requests = []
    }

    static var seen: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        var stored = request
        if stored.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let read = stream.read(&buffer, maxLength: buffer.count); if read <= 0 { break }; data.append(buffer, count: read) }
            stream.close()
            stored.httpBody = data
        }
        Self.requests.append(stored)
        let handler = Self.handler
        Self.lock.unlock()
        let reply = handler?(stored) ?? Reply(status: 500, body: Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class SyncTransportTests: XCTestCase {
    private let userId = "0b6f1c2d-3e4a-4b5c-8d6e-7f8091a2b3c4"
    private let sessionId = "1c2d3e4f-5a6b-4c7d-8e9f-a0b1c2d3e4f5"

    private func http() -> SyncHTTP {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyncStubProtocol.self]
        return SyncHTTP(server: .staging, session: URLSession(configuration: configuration), build: 119)
    }

    private func tokens(expiry: Date, access: String = "access-1", refresh: String = "mrt1.a.b") -> SyncTokens {
        SyncTokens(accessToken: access, accessExpiry: expiry, refreshToken: refresh, sessionId: sessionId, userId: userId)
    }

    private func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }

    private func refreshReply(_ n: Int) -> SyncStubProtocol.Reply {
        .init(status: 200, body: json(["accessToken": "access-\(n)", "accessTokenExpiresIn": 900, "refreshToken": "mrt1.r.\(n)",
                                       "sessionId": sessionId, "userId": userId]))
    }

    private let emptyPull: [String: Any] = ["rows": [], "hasMore": false, "maxSeq": 0, "nextSince": 0, "epoch": "e", "resync": false]

    func testRequestsCarryBuildAndBearer() async throws {
        SyncStubProtocol.install { _ in .init(status: 200, body: self.json(self.emptyPull)) }
        let session = SyncSession(http: http(), store: MemorySyncTokenStore(tokens(expiry: Date().addingTimeInterval(600))))
        let transport = HTTPSyncTransport(session: session, deviceId: userId)
        let page = try await transport.pull(since: 7, limit: 500)
        XCTAssertEqual(page.epoch, "e")
        let request = try XCTUnwrap(SyncStubProtocol.seen.first)
        XCTAssertEqual(request.url?.absoluteString, "https://sync-staging.matilde.page/v1/sync/pull?since=7&limit=500")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Matilde-Build"), "119")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-1")
    }

    func testUnauthorizedRefreshesOnceAndStoresTheRotatedToken() async throws {
        let store = MemorySyncTokenStore(tokens(expiry: Date().addingTimeInterval(600)))
        SyncStubProtocol.install { request in
            if request.url!.path.hasSuffix("auth/refresh") { return self.refreshReply(2) }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1" {
                return .init(status: 401, body: self.json(["error": ["code": "unauthorized", "message": "x"]]))
            }
            return .init(status: 200, body: self.json(self.emptyPull))
        }
        let session = SyncSession(http: http(), store: store)
        _ = try await HTTPSyncTransport(session: session, deviceId: userId).pull(since: 0, limit: 500)
        XCTAssertEqual(SyncStubProtocol.seen.count, 3)
        XCTAssertEqual(try store.load()?.refreshToken, "mrt1.r.2")
        XCTAssertEqual(try store.load()?.accessToken, "access-2")
    }

    func testConcurrentCallsShareOneRefresh() async throws {
        SyncStubProtocol.install { request in
            request.url!.path.hasSuffix("auth/refresh") ? self.refreshReply(2) : .init(status: 200, body: self.json(self.emptyPull))
        }
        let session = SyncSession(http: http(), store: MemorySyncTokenStore(tokens(expiry: Date().addingTimeInterval(10))))
        let transport = HTTPSyncTransport(session: session, deviceId: userId)
        async let one = transport.pull(since: 0, limit: 500)
        async let two = transport.pull(since: 0, limit: 500)
        async let three = transport.pull(since: 0, limit: 500)
        _ = try await (one, two, three)
        XCTAssertEqual(SyncStubProtocol.seen.filter { $0.url!.path.hasSuffix("auth/refresh") }.count, 1)
    }

    func testReusedRefreshTokenSignsOut() async throws {
        let store = MemorySyncTokenStore(tokens(expiry: Date().addingTimeInterval(-1)))
        SyncStubProtocol.install { _ in .init(status: 401, body: self.json(["error": ["code": "refresh_token_reused", "message": "x"]])) }
        let session = SyncSession(http: http(), store: store)
        let expectation = expectation(description: "signed out")
        await session.setSignedOutHandler { expectation.fulfill() }
        do { _ = try await HTTPSyncTransport(session: session, deviceId: userId).pull(since: 0, limit: 500); XCTFail() }
        catch let error as SyncServerError { XCTAssertTrue(error.endsSession) }
        await fulfillment(of: [expectation], timeout: 1)
        XCTAssertNil(try store.load())
        let current = await session.current
        XCTAssertNil(current)
    }

    func testServerErrorsParse() {
        let limited = SyncServerError.from(status: 429, data: json(["error": ["code": "rate_limited", "message": "slow down"]]), retryAfter: "30")
        XCTAssertEqual(limited, SyncServerError(status: 429, code: "rate_limited", retryAfter: 30))
        XCTAssertTrue(limited.isTransient)
        XCTAssertFalse(limited.description.contains("slow down"), "server messages are never logged")
        XCTAssertTrue(SyncServerError.from(status: 426, data: json(["error": ["code": "upgrade_required"]]), retryAfter: nil).needsUpgrade)
        XCTAssertEqual(SyncServerError.from(status: 502, data: Data("<html>".utf8), retryAfter: nil).code, "internal_error")
    }

    func testVerifySendsDeviceAndPlatform() async throws {
        SyncStubProtocol.install { _ in
            .init(status: 200, body: self.json(["accessToken": "a", "accessTokenExpiresIn": 900, "refreshToken": "mrt1.x.y",
                                                "sessionId": self.sessionId.uppercased(), "userId": self.userId, "isNewAccount": true]))
        }
        let response = try await SyncAuthClient(http: http()).verifyEmail("anna@example.com", code: "123456", deviceId: userId)
        XCTAssertEqual(response.isNewAccount, true)
        XCTAssertEqual(response.tokens().sessionId, sessionId, "ids are lowercased")
        let body = try XCTUnwrap(SyncStubProtocol.seen.first?.httpBody)
        let sent = try JSONSerialization.jsonObject(with: body) as? [String: String]
        XCTAssertEqual(sent?["platform"], "macos")
        XCTAssertEqual(sent?["deviceId"], userId)
        XCTAssertEqual(sent?["code"], "123456")
    }

    func testTokensNeverDescribeThemselves() {
        let value = tokens(expiry: Date(), access: "secret-access", refresh: "mrt1.secret")
        XCTAssertFalse(String(describing: value).contains("secret"))
        XCTAssertFalse(String(reflecting: value).contains("secret"))
    }

    func testLiveEventsAndHelpers() {
        XCTAssertEqual(SyncLiveEvent.parse(#"{"type":"hello","seq":4,"epoch":"e1"}"#), .hello(seq: 4, epoch: "e1"))
        XCTAssertEqual(SyncLiveEvent.parse(#"{"type":"changed","seq":9}"#), .changed(seq: 9))
        XCTAssertNil(SyncLiveEvent.parse("pong"))
        XCTAssertEqual(SyncBuild.number("0.1.19"), 119)
        XCTAssertEqual(SyncBuild.number("1.2.3"), 10203)
        XCTAssertEqual(SyncBuild.number(nil), 0)
        XCTAssertEqual(SyncServer.production.liveURL.absoluteString, "wss://sync.matilde.page/v1/sync/ws")
        XCTAssertEqual(SyncBackoff.delay(attempt: 0, random: 1), 1)
        XCTAssertEqual(SyncBackoff.delay(attempt: 3, random: 1), 8)
        XCTAssertEqual(SyncBackoff.delay(attempt: 20, random: 1), 60)
        XCTAssertEqual(SyncBackoff.delay(attempt: 1, retryAfter: 120), 120)
    }
}
