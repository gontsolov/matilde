import Foundation

/// Where an app's sync controller is in setting up an account. The macOS `SyncCenter` and the
/// iOS `SyncController` map their own phases onto this for the shared onboarding flow.
public enum SyncSetupPhase: Equatable, Sendable {
    case signedOut
    case awaitingCode(email: String)
    case checkingKey
    /// Another device made the account key; this one needs the Matilde key.
    case needsRecoveryKey
    /// A new account key was made here; its Matilde key is shown once.
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
    /// Matilde key is still needed).
    public init(phase: SyncSetupPhase, startedAt: Date = Date()) {
        self.startedAt = startedAt
        step = .intro
        if phase != .signedOut { update(phase: phase, syncing: false, lastSynced: nil) }
    }

    /// The intro's Continue.
    public mutating func begin() {
        if step == .intro { step = .email }
    }

    /// The server turned down the code, or the Matilde key didn't open the account.
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

/// Typing or pasting a Matilde key (`SyncRecoveryKey`) in either format, checked as you type.
///
/// Words (new accounts): any case, separated by spaces, newlines, commas or numbering; a word may
/// be shortened to its first four letters. Legacy `MTLD-` keys (accounts from 0.2.x): any case,
/// spaces, dashes and the prefix are fine, look-alikes O, I, L read as 0 and 1, formatted into
/// groups of four.
public enum RecoveryKeyInput {
    /// Characters in a legacy key.
    public static let characterCount = SyncRecoveryKey.groupCount * 4

    public enum State: Equatable, Sendable {
        case empty
        /// A legacy key with characters still to type.
        case incomplete(remaining: Int)
        case invalidCharacter(Character)
        case tooLong
        /// A Matilde key with words still to type (or the last word still being typed).
        case incompleteWords(remaining: Int)
        /// A word that isn't in the Matilde key's list.
        case unknownWord(String)
        /// More than 12 words.
        case tooManyWords
        /// Complete, but the checksum doesn't match: a typo or two words swapped.
        case typo
        case valid
    }

    public static func format(of input: String) -> SyncRecoveryKey.Format? { SyncRecoveryKey.format(of: input) }

    /// The key in canonical form, ready for `SyncRecoveryKey(code:)`: the words in full, lowercased
    /// and separated by single spaces (shortened words expanded, unknown ones kept as typed), or a
    /// legacy key's own characters, uppercased without separators or the prefix, look-alikes read
    /// as 0 and 1.
    public static func normalize(_ input: String) -> String {
        if format(of: input) == .words {
            return MatildeKeyPhrase.letterRuns(input).map { MatildeKeyPhrase.resolve($0) ?? $0 }.joined(separator: " ")
        }
        var characters = input.uppercased().filter { !$0.isWhitespace && !"-–—_.".contains($0) }
        // L isn't in the key alphabet, so a leading "MTLD" is always the prefix.
        if characters.hasPrefix(SyncRecoveryKey.prefix) { characters.removeFirst(SyncRecoveryKey.prefix.count) }
        return String(characters.map { character -> Character in
            switch character { case "O": "0"; case "I", "L": "1"; default: character }
        })
    }

    public static func state(of input: String) -> State {
        switch format(of: input) {
        case nil: return .empty
        case .words: return wordsState(MatildeKeyPhrase.letterRuns(input), typing: input.last.map { $0.isLetter } ?? false)
        case .legacy: return legacyState(normalize(input))
        }
    }

    /// `typing` is true while the last word may still grow (no separator after it yet).
    static func wordsState(_ words: [String], typing: Bool) -> State {
        let count = SyncRecoveryKey.wordCount
        if words.isEmpty { return .empty }
        if words.count > count { return .tooManyWords }
        for (index, word) in words.enumerated() where MatildeKeyPhrase.resolve(word) == nil {
            let last = index == words.count - 1
            if last, typing || words.count < count, MatildeKeyPhrase.isPrefix(word) { return .incompleteWords(remaining: count - index) }
            return .unknownWord(word)
        }
        if words.count < count { return .incompleteWords(remaining: count - words.count) }
        do {
            _ = try MatildeKeyPhrase.entropy(from: words.joined(separator: " "))
            return .valid
        } catch {
            return .typo
        }
    }

    static func legacyState(_ characters: String) -> State {
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

    /// What was typed, tidied for showing: words separated by single spaces, or a legacy key in
    /// groups of four joined by dashes ("7KQ2-M9XA-3…").
    public static func formatted(_ input: String) -> String {
        if format(of: input) == .words { return MatildeKeyPhrase.letterRuns(input).joined(separator: " ") }
        return groups(input).joined(separator: "-")
    }

    /// A legacy key (with or without prefix and dashes) split into its groups of four, for display.
    public static func groups(_ code: String) -> [String] {
        let characters = Array(normalize(code))
        return stride(from: 0, to: characters.count, by: 4).map { String(characters[$0..<min($0 + 4, characters.count)]) }
    }

    /// A short message for the state, or nil when there's nothing to say yet.
    public static func message(for state: State) -> String? {
        switch state {
        case .empty, .incomplete, .incompleteWords, .valid: return nil
        case .invalidCharacter(let character): return "“\(character)” isn’t part of a Matilde key."
        case .tooLong: return "That’s longer than a Matilde key."
        case .unknownWord(let word): return "“\(word)” isn’t one of the Matilde key words. Check the spelling."
        case .tooManyWords: return "A Matilde key has 12 words."
        case .typo: return "One of the words or characters isn’t right, or two are swapped. Check the key and try again."
        }
    }
}

/// Entering a Matilde key word by word: 12 slots, each with autocomplete from the list and a flag
/// for a word that isn't in it. Pasting or filling in the whole key (in any form, numbered or not)
/// into any slot fills every slot; several words fill from that slot on.
public struct MatildeKeyWordsEditor: Equatable, Sendable {
    public private(set) var words: [String]

    public init(_ text: String = "") {
        words = Array(repeating: "", count: SyncRecoveryKey.wordCount)
        if !text.isEmpty { set(text, at: 0) }
    }

    private var count: Int { SyncRecoveryKey.wordCount }

    /// The text of slot `slot` changed to `text`. Returns the slot to move the focus to: the next
    /// one after a separator or a pasted run of words, else `slot`.
    @discardableResult public mutating func set(_ text: String, at slot: Int) -> Int {
        guard (0..<count).contains(slot) else { return slot }
        let runs = MatildeKeyPhrase.letterRuns(text)
        if runs.count >= count {
            words = Array(runs.prefix(count))
            return count - 1
        }
        if runs.count <= 1 {
            words[slot] = runs.first ?? ""
            // A space or return after a word moves on.
            if let run = runs.first, let last = text.last, !last.isLetter, MatildeKeyPhrase.resolve(run) != nil {
                words[slot] = MatildeKeyPhrase.resolve(run)!
                return min(slot + 1, count - 1)
            }
            return slot
        }
        var position = slot
        for run in runs where position < count {
            words[position] = run
            position += 1
        }
        return min(position, count - 1)
    }

    /// Accepts an autocomplete suggestion for a slot; returns the next slot.
    public mutating func complete(_ slot: Int, with word: String) -> Int {
        guard (0..<count).contains(slot) else { return slot }
        words[slot] = word
        return min(slot + 1, count - 1)
    }

    public mutating func clear() { self = MatildeKeyWordsEditor() }

    /// Whether a slot's word should be flagged: filled, not a word (or the start of one) from the list.
    public func isUnknown(_ slot: Int) -> Bool {
        let word = words[slot]
        return !word.isEmpty && MatildeKeyPhrase.resolve(word) == nil && !MatildeKeyPhrase.isPrefix(word)
    }

    /// Suggestions for a slot's partial word.
    public func suggestions(_ slot: Int, limit: Int = 4) -> [String] {
        let word = words[slot]
        guard !word.isEmpty, MatildeKeyPhrase.wordlist.contains(word) == false else { return [] }
        return MatildeKeyPhrase.completions(for: word, limit: limit)
    }

    /// The words joined by spaces, for `RecoveryKeyInput` and `SyncRecoveryKey(code:)`.
    public var phrase: String {
        words.map { MatildeKeyPhrase.resolve($0) ?? $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    public var state: RecoveryKeyInput.State {
        let filled = words.filter { !$0.isEmpty }
        if filled.isEmpty { return .empty }
        return RecoveryKeyInput.wordsState(filled, typing: false)
    }
}

/// The text file offered by Save for a new Matilde key.
public enum RecoveryKeyDocument {
    public static let fileName = "Matilde Key.txt"

    public static func text(code: String, email: String?, date: Date = Date()) -> String {
        let words = SyncRecoveryKey.format(of: code) == .words ? MatildeKeyPhrase.letterRuns(code) : []
        var lines = ["Your Matilde key", ""]
        if words.isEmpty {
            lines.append(code)
        } else {
            lines.append(contentsOf: words.enumerated().map { ($0.offset < 9 ? " " : "") + "\($0.offset + 1). \($0.element)" })
        }
        lines.append(contentsOf: [
            "",
            "You need this key to add another device to your Matilde sync account.",
            "Keep it somewhere safe, such as a password manager. No one else can read your notes without it."
        ])
        if let email { lines.append(contentsOf: ["", "Account: \(email)"]) }
        lines.append("Saved: \(date.formatted(date: .long, time: .omitted))")
        return lines.joined(separator: "\n") + "\n"
    }
}
