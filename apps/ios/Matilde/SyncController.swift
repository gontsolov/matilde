import Foundation
import Observation
import UIKit
import MatildeKit

// IOS-03: sync on the phone. A port of the Mac app's SyncCenter (apps/macos Sync/SyncCenter.swift):
// email sign-in, the account key (create, load or recover), one SyncEngine for the phone's
// workspace and the triggers that run it (a local change, a server nudge, the app becoming
// active, pull to refresh and a slow poll). On iOS sync is the only way notes arrive, so there is
// no on/off switch: signing out stops it.
//
// Logs only counts and error types: never text, titles, paths, emails, codes or keys.

@MainActor
@Observable
final class SyncController {
    static let serverKey = "sync.serverURL"
    static let localChangeDelay: TimeInterval = 5
    static let pollInterval: TimeInterval = 60

    enum Phase: Equatable {
        case signedOut
        case awaitingCode(email: String)
        case checkingKey
        /// Another device made the account key; this phone needs the recovery key.
        case needsRecoveryKey
        /// A new account key was made here (no Mac signed in yet); show its recovery key once.
        case showRecoveryKey(code: String)
        case ready
        case updateRequired
    }

    private(set) var server: SyncServer
    private(set) var phase: Phase = .signedOut
    private(set) var status = ""
    private(set) var lastSynced: Date? = nil
    private(set) var syncing = false
    var message: String? = nil
    private(set) var busy = false

    /// Saves pending edits before a sync reads the files (set by the library).
    @ObservationIgnored var prepare: (@MainActor () -> Void)?
    /// Records were applied to the workspace; reload what's on screen (set by the library).
    @ObservationIgnored var remoteChanges: (@MainActor () -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keyStore = KeychainAccountKeyStore()
    @ObservationIgnored private var session: SyncSession
    @ObservationIgnored private var ring: AccountKeyRing?
    @ObservationIgnored private var root: URL?
    @ObservationIgnored private var engine: SyncEngine?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var live: SyncLiveChannel?
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var scheduledAt: Date?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var again = false
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []

    init(defaults: UserDefaults = .standard, startsAutomatically: Bool = true) {
        self.defaults = defaults
        let selection = SyncServerSelection.resolve(defaults: defaults, storedKey: Self.serverKey)
        let server = selection.server
        self.server = server
        if let replaced = selection.replaced {
            // The stored server isn't available in this build: sign out of it so accounts never mix.
            let old = Self.makeSession(replaced), current = Self.makeSession(server), keyStore = KeychainAccountKeyStore()
            Task {
                if let userId = await old.current?.userId, await current.current?.userId != userId {
                    try? keyStore.remove(userId: userId)
                }
                await old.signOut(serverSide: true)
            }
            NSLog("Matilde sync: server changed since the last launch; signed out of the previous one")
        }
        defaults.set(server.baseURL.absoluteString, forKey: Self.serverKey)
        session = Self.makeSession(server)
        guard startsAutomatically else { return }
        installHandlers()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.schedule(after: 1) }
        })
        Task { await self.resume() }
    }

    private static func makeSession(_ server: SyncServer) -> SyncSession {
        SyncSession(http: SyncHTTP(server: server), store: KeychainSyncTokenStore(server: server))
    }

    private func installHandlers() {
        let session = session
        Task {
            await session.setSignedOutHandler { [weak self] in Task { @MainActor in self?.sessionEnded(session) } }
        }
    }

    private var deviceId: String { SyncDevice.current(defaults) }

    static var deviceName: String { UIDevice.current.name }

    var serverHost: String { server.baseURL.host() ?? server.baseURL.absoluteString }

    /// Debug builds can switch to staging (Settings → Sync), as on the Mac.
    func setServer(_ server: SyncServer) {
        guard server != self.server else { return }
        signOut()
        self.server = server
        defaults.set(server.baseURL.absoluteString, forKey: Self.serverKey)
        session = Self.makeSession(server)
        installHandlers()
        Task { await resume() }
    }

    /// The workspace on this phone (`NoteLibrary`).
    func attach(_ root: URL) {
        guard root.standardizedFileURL != self.root?.standardizedFileURL else { return }
        stopEngine()
        self.root = root
        startEngine()
    }

    /// The app saved a local change.
    func localChange() { schedule(after: Self.localChangeDelay) }

    func syncNow() { schedule(after: 0) }

    /// Pull to refresh: sync now and return when that run is over.
    func refresh() async {
        guard engine != nil else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            schedule(after: 0)
        }
    }

    var statusText: String {
        if syncing { return "Syncing…" }
        if !status.isEmpty { return status }
        guard let last = lastSynced else { return "Waiting" }
        return "Synced \(last.formatted(date: .omitted, time: .shortened))"
    }

    /// Sync problems worth showing under the notes list; nil while all is well (the normal
    /// "Synced 9:41" status lives in Settings).
    var attention: String? {
        switch phase {
        case .updateRequired: return "Update Matilde to keep syncing"
        case .needsRecoveryKey, .showRecoveryKey, .checkingKey: return "Finish setting up sync"
        case .ready: return syncing || status.isEmpty ? nil : status
        case .signedOut, .awaitingCode: return nil
        }
    }

    var isSignedIn: Bool {
        switch phase {
        case .signedOut, .awaitingCode: return false
        default: return true
        }
    }

    // MARK: Sign-in and keys

    private func resume() async {
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

    func cancelSignIn() { phase = .signedOut; message = nil }

    private var transport: HTTPSyncTransport { HTTPSyncTransport(session: session, deviceId: deviceId) }

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
        phase = .signedOut
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
        phase = .signedOut
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
        guard phase == .ready, engine == nil, let root, let ring else { return }
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
                self.status = "Couldn’t open the notes for sync"
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
        finishWaiters()
    }

    private func startTriggers() {
        let live = SyncLiveChannel(session: session) { [weak self] event in
            Task { @MainActor in self?.handleLive(event) }
        }
        live.start()
        self.live = live
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.schedule(after: 0) }
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
        guard engine != nil else { finishWaiters(); return }
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

    private func finishWaiters() {
        let waiting = waiters
        waiters = []
        waiting.forEach { $0.resume() }
    }

    private func run() async {
        guard let engine else { finishWaiters(); return }
        guard !running else { again = true; return }
        running = true; syncing = true
        let generation = generation
        prepare?()
        do {
            let report = try await engine.sync()
            guard generation == self.generation else { running = false; syncing = false; finishWaiters(); return }
            attempt = 0
            lastSynced = Date()
            status = report.quotaExceeded ? "Sync storage is full" : ""
            if report.pushed + report.pulled + report.unreadable + report.conflicts > 0 {
                NSLog("Matilde sync: pushed %ld, pulled %ld, applied %ld, conflicts %ld, unreadable %ld, requests %ld",
                      report.pushed, report.pulled, report.applied, report.conflicts, report.unreadable, report.requests)
            }
            if report.applied > 0 { remoteChanges?() }
        } catch SyncEngineError.unknownKey(_) {
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
        if again { again = false; schedule(after: 0.5) } else { finishWaiters() }
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
