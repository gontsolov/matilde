import Foundation

/// Where an app's sync controller is in setting up an account. The macOS `SyncCenter` and the
/// iOS `SyncController` map their own phases onto this for the shared onboarding flow.
public enum SyncSetupPhase: Equatable, Sendable {
    case signedOut
    case awaitingCode(email: String)
    case checkingKey
    /// Another device made the account key; this one needs the recovery key.
    case needsRecoveryKey
    /// A new account key was made here; its recovery key is shown once.
    case showRecoveryKey(code: String)
    case ready
    case updateRequired
}

/// The guided "Sync your notes" flow, one step per screen:
/// intro → email → code → (save key | enter key) → syncing → done.
///
/// Pure state: the app feeds it the controller's phase and sync progress (`update`) and the
/// user's taps (`begin`, `failed`); the UI shows `step`. The sync protocol and keys stay in the
/// controllers.
public struct SyncOnboardingFlow: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        case intro
        case email
        case code(email: String)
        /// Signed in; checking or creating the account key.
        case signingIn
        case saveKey(code: String)
        case enterKey
        /// The first sync after setup is running.
        case syncing
        case done
        case updateRequired
    }

    public private(set) var step: Step
    /// Bumped when the server rejected a code or the key didn't unlock; the UI shakes on change.
    public private(set) var failures = 0
    /// When this flow started; a sync finished after it counts as the first sync.
    public let startedAt: Date

    /// Starts at the intro when signed out, else where setup stands (e.g. reopened while a
    /// recovery key is still needed).
    public init(phase: SyncSetupPhase, startedAt: Date = Date()) {
        self.startedAt = startedAt
        step = .intro
        if phase != .signedOut { update(phase: phase, syncing: false, lastSynced: nil) }
    }

    /// The intro's Continue.
    public mutating func begin() {
        if step == .intro { step = .email }
    }

    /// The server turned down the code, or the recovery key didn't open the account.
    public mutating func failed() {
        switch step {
        case .code, .enterKey, .email: failures += 1
        default: break
        }
    }

    public mutating func update(phase: SyncSetupPhase, syncing: Bool, lastSynced: Date?) {
        switch phase {
        case .signedOut:
            if step != .intro { step = .email }
        case .awaitingCode(let email):
            step = .code(email: email)
        case .checkingKey:
            step = .signingIn
        case .needsRecoveryKey:
            step = .enterKey
        case .showRecoveryKey(let code):
            step = .saveKey(code: code)
        case .ready:
            if step == .done { return }
            if let lastSynced, lastSynced >= startedAt, !syncing { step = .done } else { step = .syncing }
        case .updateRequired:
            step = .updateRequired
        }
    }

    /// For a step indicator: 0 at the intro, 1 when done.
    public var progress: Double {
        switch step {
        case .intro: return 0
        case .email: return 0.2
        case .code: return 0.4
        case .signingIn: return 0.55
        case .saveKey, .enterKey: return 0.7
        case .syncing: return 0.85
        case .done, .updateRequired: return 1
        }
    }

    /// Steps that are waiting on the network, with nothing to type.
    public var isWorking: Bool { step == .signingIn || step == .syncing }
}

/// Email entry: a light plausibility check before asking the server for a code.
public enum EmailInput {
    public static func normalized(_ input: String) -> String {
        input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// One `@`, something before it, a dot in the domain, no spaces.
    public static func isPlausible(_ input: String) -> Bool {
        let email = normalized(input)
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !email.contains(where: \.isWhitespace) else { return false }
        let domain = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        return domain.count >= 2 && domain.allSatisfy { !$0.isEmpty }
    }
}

/// The 6-digit email code (server: `auth/email.ts`), entered in separate boxes.
public enum OneTimeCodeInput {
    public static let length = 6

    /// Keeps the digits of whatever was typed, pasted or filled in ("123 456", "Code: 123-456"),
    /// up to `length`.
    public static func sanitize(_ input: String) -> String {
        String(input.compactMap { character -> Character? in
            guard let value = character.wholeNumberValue, (0...9).contains(value) else { return nil }
            return Character(String(value))
        }.prefix(length))
    }

    public static func isComplete(_ code: String) -> Bool { sanitize(code).count == length }

    /// One entry per box; nil for boxes still empty.
    public static func boxes(_ code: String) -> [Character?] {
        let digits = Array(sanitize(code))
        return (0..<length).map { $0 < digits.count ? digits[$0] : nil }
    }

    /// The box that takes the next digit (the last box when full).
    public static func activeBox(_ code: String) -> Int { min(sanitize(code).count, length - 1) }
}

/// Editing the code box by box, for a field that draws the six boxes itself and takes keys one at
/// a time (the Mac setup sheet): a caret box, typing that advances, Backspace that steps back,
/// arrow keys, and paste or AutoFill of a whole code ("123 456", "123-456") from any box.
public struct OneTimeCodeEditor: Equatable, Sendable {
    public private(set) var digits: [Character?]
    /// The box that takes the next digit; it has the focus ring.
    public private(set) var cursor = 0

    public init(_ code: String = "") {
        digits = Array(repeating: nil, count: OneTimeCodeInput.length)
        insert(code)
    }

    private var last: Int { OneTimeCodeInput.length - 1 }

    public var isComplete: Bool { digits.allSatisfy { $0 != nil } }
    /// The digits typed so far, in order; the full code once `isComplete`.
    public var code: String { String(digits.compactMap { $0 }) }

    /// Typed, pasted or filled-in text. A whole code replaces every box; anything shorter fills
    /// from the caret on. Spaces, dashes and other non-digits are dropped.
    public mutating func insert(_ text: String) {
        let clean = Array(OneTimeCodeInput.sanitize(text))
        guard !clean.isEmpty else { return }
        if clean.count == OneTimeCodeInput.length {
            digits = clean.map { Optional($0) }
            cursor = last
            return
        }
        for digit in clean {
            digits[cursor] = digit
            if cursor == last { break }
            cursor += 1
        }
    }

    /// Clears the caret box, or, when it is already empty, steps back and clears that one.
    public mutating func deleteBackward() {
        if digits[cursor] != nil {
            digits[cursor] = nil
        } else if cursor > 0 {
            cursor -= 1
            digits[cursor] = nil
        }
    }

    public mutating func deleteForward() { digits[cursor] = nil }
    public mutating func moveLeft() { cursor = max(0, cursor - 1) }
    public mutating func moveRight() { cursor = min(last, cursor + 1) }
    public mutating func move(to box: Int) { cursor = min(max(0, box), last) }
    public mutating func clear() { self = OneTimeCodeEditor() }
}

/// Seconds until another code may be requested.
public struct ResendCooldown: Equatable, Sendable {
    public static let seconds: TimeInterval = 30
    public private(set) var sentAt: Date

    public init(sentAt: Date = Date()) { self.sentAt = sentAt }

    public mutating func restart(at date: Date = Date()) { sentAt = date }

    public func remaining(at date: Date = Date()) -> Int {
        max(0, Int((Self.seconds - date.timeIntervalSince(sentAt)).rounded(.up)))
    }

    public func canResend(at date: Date = Date()) -> Bool { remaining(at: date) == 0 }
}

/// Typing or pasting a recovery key (`SyncRecoveryKey`): accepts any case, spaces, dashes and the
/// `MTLD` prefix, checks as you type and formats into groups of four.
public enum RecoveryKeyInput {
    public static let characterCount = SyncRecoveryKey.groupCount * 4

    public enum State: Equatable, Sendable {
        case empty
        case incomplete(remaining: Int)
        case invalidCharacter(Character)
        case tooLong
        /// Complete, but the check digit doesn't match: a typo somewhere.
        case typo
        case valid
    }

    /// The key's own characters: uppercased, without separators or the prefix, look-alikes
    /// (O, I, L) read as 0 and 1 like `SyncRecoveryKey(code:)` does.
    public static func normalize(_ input: String) -> String {
        var characters = input.uppercased().filter { !$0.isWhitespace && !"-–—_.".contains($0) }
        // L isn't in the key alphabet, so a leading "MTLD" is always the prefix.
        if characters.hasPrefix(SyncRecoveryKey.prefix) { characters.removeFirst(SyncRecoveryKey.prefix.count) }
        return String(characters.map { character -> Character in
            switch character { case "O": "0"; case "I", "L": "1"; default: character }
        })
    }

    public static func state(of input: String) -> State {
        let characters = normalize(input)
        if characters.isEmpty { return .empty }
        if let bad = characters.first(where: { !SyncRecoveryKey.alphabet.contains($0) }) { return .invalidCharacter(bad) }
        if characters.count > characterCount { return .tooLong }
        if characters.count < characterCount { return .incomplete(remaining: characterCount - characters.count) }
        do {
            _ = try SyncRecoveryKey(code: characters)
            return .valid
        } catch {
            return .typo
        }
    }

    /// Groups of four joined by dashes, for showing what was typed ("7KQ2-M9XA-3…").
    public static func formatted(_ input: String) -> String {
        groups(normalize(input)).joined(separator: "-")
    }

    /// A key (with or without prefix and dashes) split into its groups of four, for display.
    public static func groups(_ code: String) -> [String] {
        let characters = Array(normalize(code))
        return stride(from: 0, to: characters.count, by: 4).map { String(characters[$0..<min($0 + 4, characters.count)]) }
    }

    /// A short message for the state, or nil when there's nothing to say yet.
    public static func message(for state: State) -> String? {
        switch state {
        case .empty, .incomplete, .valid: return nil
        case .invalidCharacter(let character): return "“\(character)” isn’t part of a recovery key."
        case .tooLong: return "That’s longer than a recovery key."
        case .typo: return "One of the characters isn’t right. Check the key and try again."
        }
    }
}

/// The text file offered by "Save to Files" for a new recovery key.
public enum RecoveryKeyDocument {
    public static let fileName = "Matilde Recovery Key.txt"

    public static func text(code: String, email: String?, date: Date = Date()) -> String {
        var lines = [
            "Matilde recovery key",
            "",
            code,
            "",
            "You need this key to add another device to your Matilde sync account.",
            "Keep it somewhere safe, such as a password manager. Nobody else can read your notes without it, not even us."
        ]
        if let email { lines.append(contentsOf: ["", "Account: \(email)"]) }
        lines.append("Saved: \(date.formatted(date: .long, time: .omitted))")
        return lines.joined(separator: "\n") + "\n"
    }
}
