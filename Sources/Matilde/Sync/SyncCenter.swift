#if canImport(AppKit)
import AppKit
import SystemConfiguration

// SYNC-07: the app side of sync. Owns the settings (off by default), sign-in, the account key, one
// `SyncEngine` for the open workspace and the triggers that run it: a local change (debounced),
// a change nudge from the server, app activation, wake and a slow poll. Sync itself runs on the
// engine's actor; this class only schedules it and publishes a short status for Settings.
//
// Logs only counts and error types: never text, titles, paths, emails, codes or keys.

@MainActor
final class SyncCenter: ObservableObject {
    static let shared = SyncCenter()

    static let enabledKey = "sync.enabled"
    static let serverKey = "sync.serverURL"
    static let localChangeDelay: TimeInterval = 5
    static let pollInterval: TimeInterval = 60

    enum Phase: Equatable {
        case off
        case signedOut
        case awaitingCode(email: String)
        case checkingKey
        /// Another device made the account key; this Mac needs the recovery key.
        case needsRecoveryKey
        /// A new account key was made here; show its recovery key once.
        case showRecoveryKey(code: String)
        case ready
        case updateRequired
    }

    @Published private(set) var enabled: Bool
    @Published private(set) var server: SyncServer
    @Published private(set) var phase: Phase = .off
    @Published private(set) var status = ""
    @Published private(set) var lastSynced: Date?
    @Published private(set) var syncing = false
    @Published var message: String?
    @Published private(set) var busy = false

    /// Saves pending edits before a sync reads the files (set by `AppModel`).
    var prepare: (@MainActor () -> Void)?
    /// Records were applied to the workspace; reload what's on screen (set by `AppModel`).
    var remoteChanges: (@MainActor () -> Void)?

    private let defaults: UserDefaults
    private let keyStore = KeychainAccountKeyStore()
    private var session: SyncSession
    private var ring: AccountKeyRing?
    private var root: URL?
    private var engine: SyncEngine?
    private var generation = 0
    private var live: SyncLiveChannel?
    private var pollTimer: Timer?
    private var scheduled: Task<Void, Never>?
    private var scheduledAt: Date?
    private var running = false
    private var again = false
    private var attempt = 0
    private var observers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: Self.enabledKey)
        let server: SyncServer = defaults.string(forKey: Self.serverKey) == SyncServer.staging.baseURL.absoluteString ? .staging : .production
        self.server = server
        session = Self.makeSession(server)
        installHandlers()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in SyncCenter.shared.schedule(after: 1) }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in SyncCenter.shared.schedule(after: 3) }
        })
        if enabled { Task { await self.resume() } }
    }

    private static func makeSession(_ server: SyncServer) -> SyncSession {
        SyncSession(http: SyncHTTP(server: server), store: KeychainSyncTokenStore(server: server))
    }

    private func installHandlers() {
        let session = session
        Task {
            await session.setSignedOutHandler { Task { @MainActor in SyncCenter.shared.sessionEnded(session) } }
        }
    }

    private var deviceId: String { SyncDevice.current(defaults) }

    static var deviceName: String {
        SCDynamicStoreCopyComputerName(nil, nil).map { $0 as String } ?? Host.current().localizedName ?? "this Mac"
    }

    // MARK: Settings

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        defaults.set(on, forKey: Self.enabledKey)
        if on { Task { await resume() } } else { stopEngine(); phase = .off; status = "" }
    }

    func setServer(_ server: SyncServer) {
        guard server != self.server else { return }
        stopEngine()
        self.server = server
        defaults.set(server.baseURL.absoluteString, forKey: Self.serverKey)
        session = Self.makeSession(server)
        installHandlers()
        ring = nil
        if enabled { Task { await resume() } }
    }

    /// The workspace the app opened (`AppModel.open`).
    func attach(_ root: URL) {
        guard root.standardizedFileURL != self.root?.standardizedFileURL else { return }
        stopEngine()
        self.root = root
        startEngine()
    }

    /// The app saved a local change.
    func localChange() { schedule(after: Self.localChangeDelay) }

    func syncNow() { schedule(after: 0) }

    // MARK: Sign-in and keys

    private func resume() async {
        guard enabled else { return }
        if await session.current == nil { phase = .signedOut; return }
        await setUpKey()
    }

    func requestCode(email: String) {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !email.isEmpty else { return }
        perform {
            try await SyncAuthClient(http: self.session.http).startEmail(email)
            self.phase = .awaitingCode(email: email)
        }
    }

    func verify(code: String) {
        guard case .awaitingCode(let email) = phase else { return }
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        perform {
            let response = try await SyncAuthClient(http: self.session.http).verifyEmail(email, code: code, deviceId: self.deviceId)
            try await self.session.signIn(response.tokens())
            NSLog("Matilde sync: signed in")
            await self.setUpKey()
        }
    }

    func cancelSignIn() { phase = enabled ? .signedOut : .off }

    private var transport: HTTPSyncTransport { HTTPSyncTransport(session: session, deviceId: deviceId) }

    /// Loads the account key from the Keychain and checks it against the server, or makes the
    /// first one, or asks for the recovery key.
    private func setUpKey() async {
        guard let userId = await session.current?.userId else { phase = .signedOut; return }
        phase = .checkingKey
        do {
            var keys = try await transport.keys()
            if keys.keyId == nil {
                let made = try SyncKeyEnrollment.create(userId: userId)
                do {
                    try await transport.putKeys(made.request)
                    try keyStore.save(made.ring)
                    NSLog("Matilde sync: account key created")
                    ring = made.ring
                    phase = made.recoveryKey.map { Phase.showRecoveryKey(code: $0.code) } ?? Phase.ready
                    renameDevice()
                    if phase == .ready { startEngine() }
                    return
                } catch let error as SyncServerError where error.code == "key_conflict" {
                    keys = try await transport.keys()
                }
            }
            if let stored = try keyStore.load(userId: userId),
               let refreshed = try? SyncKeyEnrollment.ring(userId: userId, current: stored.current, keys: keys) {
                try keyStore.save(refreshed)
                ring = refreshed
                phase = .ready
                startEngine()
            } else {
                phase = .needsRecoveryKey
            }
        } catch {
            handle(error)
            if phase == .checkingKey { phase = .signedOut }
        }
    }

    func recover(code: String) {
        perform {
            guard let userId = await self.session.current?.userId else { self.phase = .signedOut; return }
            let keys = try await self.transport.keys()
            let ring = try SyncKeyEnrollment.recover(userId: userId, keys: keys, recoveryCode: code)
            try self.keyStore.save(ring)
            NSLog("Matilde sync: account key recovered")
            self.ring = ring
            self.phase = .ready
            self.renameDevice()
            self.startEngine()
        }
    }

    /// The user typed the last group of the recovery key shown once.
    func confirmRecoveryKey(lastGroup: String) -> Bool {
        guard case .showRecoveryKey(let code) = phase, let key = try? SyncRecoveryKey(code: code),
              key.confirms(lastGroup: lastGroup) else { return false }
        phase = .ready
        startEngine()
        return true
    }

    func signOut() {
        let session = session
        let userId = ring?.userId
        stopEngine()
        ring = nil
        phase = enabled ? .signedOut : .off
        status = ""
        lastSynced = nil
        if let userId { try? keyStore.remove(userId: userId) }
        Task { await session.signOut(serverSide: true) }
        NSLog("Matilde sync: signed out")
    }

    private func sessionEnded(_ ended: SyncSession) {
        guard ended === session else { return }
        stopEngine()
        ring = nil
        phase = enabled ? .signedOut : .off
        status = ""
        NSLog("Matilde sync: session ended by the server")
    }

    private func renameDevice() {
        guard let ring else { return }
        let transport = transport, name = Self.deviceName, deviceId = deviceId
        Task.detached {
            guard let sealed = try? SyncFieldCrypto.sealDeviceName(name, deviceId: deviceId, ring: ring) else { return }
            try? await transport.renameDevice(sealed)
        }
    }

    // MARK: Engine

    private func startEngine() {
        guard enabled, phase == .ready, engine == nil, let root, let ring else { return }
        generation += 1
        let generation = generation
        let transport = transport, name = Self.deviceName
        Task {
            let made: Result<SyncEngine, Error> = await Task.detached {
                do {
                    let store = try WorkspaceSyncStore(workspace: try Workspace(root: root))
                    store.deviceName = name
                    return .success(SyncEngine(transport: transport, store: store, ring: ring))
                } catch {
                    return .failure(error)
                }
            }.value
            guard generation == self.generation else { return }
            switch made {
            case .success(let engine):
                self.engine = engine
                self.startTriggers()
                self.schedule(after: 0)
            case .failure(let error):
                NSLog("Matilde sync: couldn’t open the workspace for sync (%@)", String(describing: type(of: error)))
                self.status = "Couldn’t open this workspace for sync"
            }
        }
    }

    private func stopEngine() {
        generation += 1
        engine = nil
        live?.stop(); live = nil
        pollTimer?.invalidate(); pollTimer = nil
        scheduled?.cancel(); scheduled = nil; scheduledAt = nil
        attempt = 0
    }

    private func startTriggers() {
        let live = SyncLiveChannel(session: session) { event in
            Task { @MainActor in SyncCenter.shared.handleLive(event) }
        }
        live.start()
        self.live = live
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { _ in
            Task { @MainActor in SyncCenter.shared.schedule(after: 0) }
        }
    }

    private func handleLive(_ event: SyncLiveEvent) {
        switch event {
        case .hello, .changed: schedule(after: 0.3)
        case .closed: sessionEnded(session)
        }
    }

    /// Runs a sync after `delay` seconds unless one is already due sooner.
    func schedule(after delay: TimeInterval) {
        guard engine != nil else { return }
        let due = Date().addingTimeInterval(delay)
        if let scheduledAt, scheduledAt <= due { return }
        scheduled?.cancel()
        scheduledAt = due
        scheduled = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            self?.fire()
        }
    }

    private func fire() {
        scheduled = nil; scheduledAt = nil
        Task { await run() }
    }

    private func run() async {
        guard let engine else { return }
        guard !running else { again = true; return }
        running = true; syncing = true
        let generation = generation
        prepare?()
        do {
            let report = try await engine.sync()
            guard generation == self.generation else { running = false; syncing = false; return }
            attempt = 0
            lastSynced = Date()
            status = report.quotaExceeded ? "Sync storage is full" : ""
            if report.pushed + report.pulled + report.unreadable + report.conflicts > 0 {
                NSLog("Matilde sync: pushed %ld, pulled %ld, applied %ld, conflicts %ld, unreadable %ld, requests %ld",
                      report.pushed, report.pulled, report.applied, report.conflicts, report.unreadable, report.requests)
            }
            if report.applied > 0 { remoteChanges?() }
        } catch SyncEngineError.unknownKey(_) {
            // Another device rotated the account key: fetch the new ring and run again.
            await refreshRing(engine)
            again = engine === self.engine && phase == .ready
        } catch {
            if generation == self.generation {
                remoteChanges?()
                handle(error)
                if engine === self.engine, phase == .ready {
                    attempt += 1
                    let retryAfter = (error as? SyncServerError)?.retryAfter
                    schedule(after: SyncBackoff.delay(attempt: attempt, retryAfter: retryAfter))
                }
            }
        }
        running = false; syncing = false
        if again { again = false; schedule(after: 0.5) }
    }

    private func refreshRing(_ engine: SyncEngine) async {
        guard let ring else { return }
        do {
            let keys = try await transport.keys()
            let fresh = try SyncKeyEnrollment.ring(userId: ring.userId, current: ring.current, keys: keys)
            try keyStore.save(fresh)
            self.ring = fresh
            await engine.updateRing(fresh)
        } catch {
            // The key moved to a new epoch this device can't unwrap: ask for the recovery key.
            NSLog("Matilde sync: account key changed (%@)", String(describing: type(of: error)))
            stopEngine()
            self.ring = nil
            phase = .needsRecoveryKey
        }
    }

    private func handle(_ error: Error) {
        if let error = error as? SyncServerError {
            if error.needsUpgrade {
                stopEngine()
                phase = .updateRequired
            } else if error.endsSession {
                sessionEnded(session)
            } else {
                status = error.isTransient ? "Sync server unavailable" : "Couldn’t sync"
            }
            NSLog("Matilde sync: server error %ld %@", error.status, error.code)
        } else if error is SyncSessionError {
            sessionEnded(session)
        } else if error is URLError {
            status = "Offline"
            NSLog("Matilde sync: network unavailable")
        } else {
            status = "Couldn’t sync"
            NSLog("Matilde sync: failed (%@)", String(describing: type(of: error)))
        }
    }

    /// Runs a sign-in or key step, showing a short message on failure.
    private func perform(_ step: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true; message = nil
        Task {
            defer { busy = false }
            do { try await step() } catch {
                message = Self.message(for: error)
                if let error = error as? SyncServerError, error.needsUpgrade { phase = .updateRequired }
                NSLog("Matilde sync: step failed (%@)", String(describing: error is SyncServerError ? "\(error)" : "\(type(of: error))"))
            }
        }
    }

    static func message(for error: Error) -> String {
        switch error {
        case SyncCryptoError.recoveryCodeTypo, SyncCryptoError.invalidRecoveryCode: return "That recovery key doesn’t look right."
        case SyncCryptoError.authenticationFailed: return "That recovery key doesn’t match this account."
        case let error as SyncServerError:
            switch error.code {
            case "invalid_code": return "That code didn’t work. Request a new one."
            case "invalid_email": return "That email address doesn’t look right."
            case "rate_limited": return "Too many attempts. Try again in a little while."
            default: return error.needsUpgrade ? "Update Matilde to keep syncing." : "Something went wrong. Try again."
            }
        case is URLError: return "You’re offline."
        default: return "Something went wrong. Try again."
        }
    }
}
#endif
