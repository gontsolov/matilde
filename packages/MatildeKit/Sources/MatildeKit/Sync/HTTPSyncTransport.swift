import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

// SYNC-07: the sync server over HTTPS (server/PROTOCOL.md): sign-in, tokens, the record and blob
// endpoints, and the change-nudge WebSocket. Never logs or describes tokens, emails or bodies.

/// Where the sync server lives.
public struct SyncServer: Equatable, Sendable {
    public static let production = SyncServer(baseURL: URL(string: "https://sync.matilde.page/v1/")!)
    public static let staging = SyncServer(baseURL: URL(string: "https://sync-staging.matilde.page/v1/")!)
    /// Ends in `/v1/`.
    public var baseURL: URL

    public func url(_ path: String) -> URL { URL(string: path, relativeTo: baseURL)!.absoluteURL }

    /// `wss://…/v1/sync/ws`.
    public var liveURL: URL {
        var components = URLComponents(url: url("sync/ws"), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        return components.url!
    }

    public var isStaging: Bool { baseURL.host?.contains("staging") == true }

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }
}

/// Which sync server this launch uses. Release builds only offer the real server; staging is
/// for testing and is chosen with a launch argument (`--sync-server staging`) or a hidden
/// default (`defaults write app.matilde.local sync.server staging`). Debug builds also show a
/// Server picker in Settings → Sync, stored in `sync.serverURL`.
public enum SyncServerSelection {
    /// Hidden UserDefaults key: `staging` or `production`. Also settable for one launch as `-sync.server staging`.
    public static let overrideKey = "sync.server"
    public static let launchArgument = "--sync-server"

    public static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Debug builds show the Server picker in Settings.
    public static var showsPicker: Bool { isDebugBuild }

    public struct Resolution: Equatable {
        public var server: SyncServer
        /// The server stored from an earlier launch when it differs from `server`: sign out of
        /// that one (its session belongs to another account store) before using `server`.
        public var replaced: SyncServer?

        public init(server: SyncServer, replaced: SyncServer? = nil) {
            self.server = server
            self.replaced = replaced
        }
    }

    public static func server(named name: String?) -> SyncServer? {
        switch name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "staging": return .staging
        case "production", "matilde": return .production
        default: return nil
        }
    }

    public static func server(storedURL: String?) -> SyncServer? {
        switch storedURL {
        case SyncServer.staging.baseURL.absoluteString: return .staging
        case SyncServer.production.baseURL.absoluteString: return .production
        default: return nil
        }
    }

    /// The launch argument wins, then the hidden default; otherwise debug builds keep the
    /// picker's stored choice and release builds always use production.
    public static func resolve(arguments: [String], override: String?, storedURL: String?, debug: Bool) -> Resolution {
        var requested: SyncServer?
        if let index = arguments.firstIndex(of: launchArgument), arguments.count > index + 1 {
            requested = server(named: arguments[index + 1])
        }
        if requested == nil { requested = server(named: override) }
        let stored = server(storedURL: storedURL)
        let chosen = requested ?? (debug ? stored : nil) ?? .production
        return Resolution(server: chosen, replaced: stored.flatMap { $0 == chosen ? nil : $0 })
    }

    public static func resolve(defaults: UserDefaults, storedKey: String, arguments: [String] = CommandLine.arguments) -> Resolution {
        resolve(arguments: arguments, override: defaults.string(forKey: overrideKey),
                storedURL: defaults.string(forKey: storedKey), debug: isDebugBuild)
    }
}

public enum SyncBuild {
    /// `X-Matilde-Build`: the app version as one integer (0.1.19 → 119; 1.2.3 → 10203). 0 for
    /// development builds without a bundle version, which the server accepts unless it sets a minimum.
    public static func number(_ version: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) -> Int {
        guard let version else { return 0 }
        let parts = version.split(separator: ".").map { Int($0) ?? 0 }
        guard parts.count == 3 else { return 0 }
        return parts[0] * 10_000 + parts[1] * 100 + parts[2]
    }
}

/// The tokens of one signed-in device. Stored only in the Keychain.
public struct SyncTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var accessExpiry: Date
    public var refreshToken: String
    public var sessionId: String
    public var userId: String

    public init(accessToken: String, accessExpiry: Date, refreshToken: String, sessionId: String, userId: String) {
        self.accessToken = accessToken
        self.accessExpiry = accessExpiry
        self.refreshToken = refreshToken
        self.sessionId = sessionId
        self.userId = userId
    }
}

extension SyncTokens: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "SyncTokens(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public protocol SyncTokenStore: AnyObject, Sendable {
    func load() throws -> SyncTokens?
    func save(_ tokens: SyncTokens) throws
    func remove() throws
}

public final class MemorySyncTokenStore: SyncTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: SyncTokens?
    public init(_ tokens: SyncTokens? = nil) { self.tokens = tokens }
    public func load() throws -> SyncTokens? { lock.lock(); defer { lock.unlock() }; return tokens }
    public func save(_ tokens: SyncTokens) throws { lock.lock(); defer { lock.unlock() }; self.tokens = tokens }
    public func remove() throws { lock.lock(); defer { lock.unlock() }; tokens = nil }
}

#if canImport(Security)
/// One Keychain item per server, never migrated off the device.
public final class KeychainSyncTokenStore: SyncTokenStore, @unchecked Sendable {
    public static let service = "app.matilde.local.sync.session"
    public let account: String

    public init(server: SyncServer) { account = server.baseURL.host ?? "sync" }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: account]
    }

    public func load() throws -> SyncTokens? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SyncCryptoError.keyStore(status) }
        return try JSONDecoder().decode(SyncTokens.self, from: data)
    }

    public func save(_ tokens: SyncTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecAttrLabel as String] = "Matilde — sync session"
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw SyncCryptoError.keyStore(added) }
        } else if status != errSecSuccess {
            throw SyncCryptoError.keyStore(status)
        }
    }

    public func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SyncCryptoError.keyStore(status) }
    }
}
#endif

/// Plain HTTP plumbing shared by sign-in and the authorized endpoints.
public struct SyncHTTP: Sendable {
    public let server: SyncServer
    public let session: URLSession
    public let build: Int

    public init(server: SyncServer, session: URLSession = .shared, build: Int = SyncBuild.number()) {
        self.server = server
        self.session = session
        self.build = build
    }

    public func request(_ method: String, _ path: String, json: Data? = nil, body: Data? = nil, token: String? = nil) -> URLRequest {
        var request = URLRequest(url: server.url(path))
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue(String(build), forHTTPHeaderField: "X-Matilde-Build")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = json
        } else if let body {
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    /// Sends a request; non-2xx responses become `SyncServerError`.
    public func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncServerError(status: 0, code: "bad_response") }
        guard (200..<300).contains(http.statusCode) else {
            throw SyncServerError.from(status: http.statusCode, data: data, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        }
        return data
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }
    public static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T { try JSONDecoder().decode(type, from: data) }
}

/// Email-code sign-in and the token endpoints.
public struct SyncAuthClient: Sendable {
    public let http: SyncHTTP

    public struct TokenResponse: Decodable {
        public var accessToken: String
        public var accessTokenExpiresIn: Double
        public var refreshToken: String
        public var sessionId: String
        public var userId: String
        public var isNewAccount: Bool?

        public func tokens(now: Date = Date()) -> SyncTokens {
            SyncTokens(accessToken: accessToken, accessExpiry: now.addingTimeInterval(accessTokenExpiresIn), refreshToken: refreshToken,
                       sessionId: sessionId.lowercased(), userId: userId.lowercased())
        }

        public init(accessToken: String, accessTokenExpiresIn: Double, refreshToken: String, sessionId: String, userId: String, isNewAccount: Bool? = nil) {
            self.accessToken = accessToken
            self.accessTokenExpiresIn = accessTokenExpiresIn
            self.refreshToken = refreshToken
            self.sessionId = sessionId
            self.userId = userId
            self.isNewAccount = isNewAccount
        }
    }

    public func startEmail(_ email: String) async throws {
        _ = try await http.send(http.request("POST", "auth/email/start", json: try SyncHTTP.encode(["email": email])))
    }

    /// The `platform` this build signs in as (the server lists devices by it).
    public static var currentPlatform: String {
        #if os(iOS)
        return "ios"
        #else
        return "macos"
        #endif
    }

    public func verifyEmail(_ email: String, code: String, deviceId: String, deviceNameCt: String? = nil, platform: String = SyncAuthClient.currentPlatform) async throws -> TokenResponse {
        var body = ["email": email, "code": code, "deviceId": deviceId, "platform": platform]
        body["deviceNameCt"] = deviceNameCt
        return try SyncHTTP.decode(TokenResponse.self, try await http.send(http.request("POST", "auth/email/verify", json: try SyncHTTP.encode(body))))
    }

    public func refresh(_ refreshToken: String) async throws -> TokenResponse {
        try SyncHTTP.decode(TokenResponse.self, try await http.send(http.request("POST", "auth/refresh", json: try SyncHTTP.encode(["refreshToken": refreshToken]))))
    }

    public init(http: SyncHTTP) {
        self.http = http
    }
}

public enum SyncSessionError: Error, Equatable {
    case signedOut
}

/// Holds the tokens and hands out a valid access token: refreshes shortly before expiry or after a
/// 401, one refresh at a time, and stores each rotated refresh token before using it.
public actor SyncSession {
    public static let refreshMargin: TimeInterval = 60

    public let http: SyncHTTP
    public let store: SyncTokenStore
    /// Read from the store on first use, not at init, so creating a session never touches the
    /// Keychain (an app with sync off never reads it).
    private var tokens: SyncTokens?
    private var loaded = false
    private var refreshing: Task<SyncTokens, Error>?
    private let now: @Sendable () -> Date
    /// Called once when the server ends the session (revoked, reused refresh token, account deleted).
    private var onSignedOut: (@Sendable () -> Void)?

    public init(http: SyncHTTP, store: SyncTokenStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.http = http
        self.store = store
        self.now = now
    }

    /// One attempt per session: a refused Keychain read isn't retried by every sync trigger.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        tokens = try? store.load()
    }

    public func setSignedOutHandler(_ handler: @escaping @Sendable () -> Void) { onSignedOut = handler }

    public var current: SyncTokens? {
        loadIfNeeded()
        return tokens
    }

    public func signIn(_ tokens: SyncTokens) throws {
        try store.save(tokens)
        loaded = true
        self.tokens = tokens
    }

    /// Forget the tokens locally; `serverSide` also revokes the session (best effort).
    public func signOut(serverSide: Bool) async {
        if serverSide { loadIfNeeded() }
        if serverSide, let token = tokens?.accessToken {
            _ = try? await http.send(http.request("POST", "auth/logout", token: token))
        }
        loaded = true
        tokens = nil
        try? store.remove()
    }

    public func accessToken(forceRefresh: Bool = false) async throws -> String {
        loadIfNeeded()
        guard let tokens else { throw SyncSessionError.signedOut }
        if !forceRefresh, tokens.accessExpiry.timeIntervalSince(now()) > Self.refreshMargin { return tokens.accessToken }
        return try await refresh(from: tokens).accessToken
    }

    private func refresh(from old: SyncTokens) async throws -> SyncTokens {
        if let refreshing { return try await refreshing.value }
        let http = http, store = store, now = now
        let task = Task<SyncTokens, Error> {
            let response = try await SyncAuthClient(http: http).refresh(old.refreshToken)
            let fresh = response.tokens(now: now())
            // Store the rotated refresh token before anything uses the new access token.
            try store.save(fresh)
            return fresh
        }
        refreshing = task
        defer { refreshing = nil }
        do {
            let fresh = try await task.value
            tokens = fresh
            return fresh
        } catch let error as SyncServerError where error.endsSession || error.status == 401 {
            await endSession()
            throw error
        }
    }

    public func endSession() async {
        loaded = true
        tokens = nil
        try? store.remove()
        onSignedOut?()
    }

    /// Sends an authorized request, refreshing once on `401 unauthorized`.
    public func send(_ make: @Sendable (String) -> URLRequest) async throws -> Data {
        let token = try await accessToken()
        do {
            return try await http.send(make(token))
        } catch let error as SyncServerError where error.status == 401 {
            if error.endsSession { await endSession(); throw error }
            let fresh = try await accessToken(forceRefresh: true)
            do { return try await http.send(make(fresh)) }
            catch let error as SyncServerError where error.endsSession { await endSession(); throw error }
        } catch let error as SyncServerError where error.endsSession {
            await endSession()
            throw error
        }
    }
}

/// `SyncTransport` over HTTPS.
public struct HTTPSyncTransport: SyncTransport {
    public let session: SyncSession
    public let deviceId: String

    private var http: SyncHTTP { session.http }

    public func push(_ changes: [SyncWireChange]) async throws -> SyncPushResponse {
        let body = try SyncHTTP.encode(SyncPushRequest(deviceId: deviceId, changes: changes))
        let http = http
        return try SyncHTTP.decode(SyncPushResponse.self, try await session.send { http.request("POST", "sync/push", json: body, token: $0) })
    }

    public func pull(since: Int, limit: Int) async throws -> SyncPullResponse {
        let http = http
        return try SyncHTTP.decode(SyncPullResponse.self, try await session.send { http.request("GET", "sync/pull?since=\(since)&limit=\(limit)", token: $0) })
    }

    public func uploadBlob(id: String, data: Data) async throws {
        try SyncIdentifiers.validate(id, "blobId")
        let http = http
        _ = try await session.send { http.request("PUT", "blobs/\(id)", body: data, token: $0) }
    }

    public func downloadBlob(id: String) async throws -> Data {
        try SyncIdentifiers.validate(id, "blobId")
        let http = http
        return try await session.send { http.request("GET", "blobs/\(id)", token: $0) }
    }

    public func keys() async throws -> SyncKeysResponse {
        let http = http
        return try SyncHTTP.decode(SyncKeysResponse.self, try await session.send { http.request("GET", "keys", token: $0) })
    }

    public func putKeys(_ request: SyncPutKeysRequest) async throws {
        let body = try SyncHTTP.encode(request)
        let http = http
        _ = try await session.send { http.request("PUT", "keys", json: body, token: $0) }
    }

    /// The account's signed-in devices (`GET /v1/devices`); names are sealed, see `SyncSignedInDevice.name`.
    public func devices() async throws -> [SyncSignedInDevice] {
        let http = http
        return try SyncHTTP.decode(SyncDeviceList.self, try await session.send { http.request("GET", "devices", token: $0) }).devices
    }

    public func renameDevice(_ nameCt: Data) async throws {
        guard let sessionId = await session.current?.sessionId else { throw SyncSessionError.signedOut }
        try SyncIdentifiers.validate(sessionId, "sessionId")
        let body = try SyncHTTP.encode(["deviceNameCt": nameCt.base64EncodedString()])
        let http = http
        _ = try await session.send { http.request("PATCH", "devices/\(sessionId)", json: body, token: $0) }
    }

    public init(session: SyncSession, deviceId: String) {
        self.session = session
        self.deviceId = deviceId
    }
}

/// A signed-in device as the server lists it.
public struct SyncSignedInDevice: Decodable, Sendable, Identifiable, Equatable {
    public let sessionId: String
    public let deviceId: String
    public let platform: String
    public let nameCt: String?
    public let createdAt: Double
    public let lastSeenDay: String
    public let current: Bool

    public var id: String { sessionId }

    public init(sessionId: String, deviceId: String, platform: String, nameCt: String?, createdAt: Double, lastSeenDay: String, current: Bool) {
        self.sessionId = sessionId
        self.deviceId = deviceId
        self.platform = platform
        self.nameCt = nameCt
        self.createdAt = createdAt
        self.lastSeenDay = lastSeenDay
        self.current = current
    }

    /// The device's own name, opened with the account key; a platform name when it can't be read.
    public func name(ring: AccountKeyRing?) -> String {
        if let ring, let nameCt, let sealed = Data(base64Encoded: nameCt),
           let name = try? SyncFieldCrypto.openDeviceName(sealed, deviceId: deviceId, ring: ring), !name.isEmpty {
            return name
        }
        switch platform.lowercased() {
        case "ios": return "iPhone"
        case "macos": return "Mac"
        default: return "Device"
        }
    }

    /// "iphone" / "laptopcomputer" for SF Symbols.
    public var symbolName: String { platform.lowercased() == "ios" ? "iphone" : "laptopcomputer" }
}

/// What Settings → Sync shows for a device.
public struct SyncDeviceSummary: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let symbolName: String
    public let isCurrent: Bool
    /// "2026-11-21", the last day the device talked to the server.
    public let lastSeenDay: String

    public init(_ device: SyncSignedInDevice, ring: AccountKeyRing?) {
        id = device.sessionId
        name = device.name(ring: ring)
        symbolName = device.symbolName
        isCurrent = device.current
        lastSeenDay = device.lastSeenDay
    }
}

struct SyncDeviceList: Decodable { let devices: [SyncSignedInDevice] }

/// Backoff for retries and reconnects: exponential from 1 s to 60 s with ±20 % jitter, or the
/// server's `Retry-After` when it sent one.
public enum SyncBackoff {
    public static func delay(attempt: Int, retryAfter: TimeInterval? = nil, random: Double = Double.random(in: 0.8...1.2)) -> TimeInterval {
        if let retryAfter { return min(max(retryAfter, 1), 3600) }
        let base = min(60, pow(2, Double(max(0, min(attempt, 10)))))
        return base * random
    }
}

#if canImport(Darwin)
/// The change-nudge WebSocket. Reconnects with backoff; delivers events on its own task.
public final class SyncLiveChannel: @unchecked Sendable {
    public static let pingInterval: TimeInterval = 45

    private let session: SyncSession
    private let urlSession: URLSession
    private let onEvent: @Sendable (SyncLiveEvent) -> Void
    private var task: Task<Void, Never>?

    public init(session: SyncSession, urlSession: URLSession = .shared, onEvent: @escaping @Sendable (SyncLiveEvent) -> Void) {
        self.session = session
        self.urlSession = urlSession
        self.onEvent = onEvent
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [session, urlSession, onEvent] in
            var attempt = 0
            while !Task.isCancelled {
                do {
                    let token = try await session.accessToken()
                    var request = session.http.request("GET", "sync/ws", token: token)
                    request.url = session.http.server.liveURL
                    let socket = urlSession.webSocketTask(with: request)
                    socket.resume()
                    let code = await Self.run(socket, onEvent: onEvent, connected: { attempt = 0 })
                    if code == SyncLiveEvent.sessionRevokedCode || code == SyncLiveEvent.accountDeletedCode {
                        onEvent(.closed(code: code))
                        return
                    }
                } catch SyncSessionError.signedOut {
                    return
                } catch {}
                attempt += 1
                try? await Task.sleep(nanoseconds: UInt64(SyncBackoff.delay(attempt: attempt) * 1_000_000_000))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Reads until the socket closes; returns its close code.
    private static func run(_ socket: URLSessionWebSocketTask, onEvent: @escaping @Sendable (SyncLiveEvent) -> Void,
                            connected: () -> Void) async -> Int {
        let pinger = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(pingInterval * 1_000_000_000))
                try? await socket.send(.string("ping"))
            }
        }
        defer {
            pinger.cancel()
            socket.cancel(with: .goingAway, reason: nil)
        }
        var first = true
        while !Task.isCancelled {
            guard let message = try? await socket.receive() else { break }
            if first { connected(); first = false }
            if case .string(let text) = message, let event = SyncLiveEvent.parse(text) { onEvent(event) }
        }
        return socket.closeCode.rawValue
    }
}
#endif
