import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The Matilde key (called the recovery key before 0.3): the secret that wraps the account key in
/// a `recovery` key slot. It is shown to the user once and is the only way to add a device without
/// another one at hand. Two formats, told apart when it is entered (`init(code:)`):
///
/// - **Words** (new accounts): 12 words from the BIP-0039 English list, 128 random bits plus the
///   4-bit BIP-0039 checksum. The 256-bit slot secret is
///   `HKDF-SHA256(ikm: entropy, salt: "matilde/matilde-key/v1", info: "matilde/matilde-key/v1/slot-secret")`.
///   The BIP-0039 seed (PBKDF2 over the sentence) is not used: the entropy is already uniformly random.
/// - **Legacy** (accounts made by 0.2.x): 256 random bits shown as `MTLD-XXXX-…`, 13 groups of 4
///   Crockford Base32 characters (260 bits: the key plus 4 check bits from SHA-256(key)). The key is
///   the slot secret itself. These keep working unchanged.
///
/// Either way the slot format and the server stay the same (docs/sync-encryption.md).
public struct SyncRecoveryKey: Equatable {
    public enum Format: String, Equatable, Sendable {
        case words
        case legacy
    }

    public static let prefix = "MTLD"
    public static let groupCount = 13
    public static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Words in a Matilde key, and the random bytes they carry.
    public static let wordCount = 12
    public static let entropySize = 16
    /// HKDF salt and info for the words format's slot secret. Versioned: a future format gets new labels.
    static let wordsSalt = Data("matilde/matilde-key/v1".utf8)
    static let wordsInfo = "matilde/matilde-key/v1/slot-secret"

    /// The secret that wraps the account key in the recovery slot.
    public let key: SymmetricKey
    public let format: Format
    /// The 16 random bytes behind the words; nil for a legacy key.
    private let entropy: Data?

    /// A legacy key from its 32 bytes.
    public init(bytes: Data) throws {
        guard bytes.count == SyncCryptoConstants.keySize else { throw SyncCryptoError.malformed }
        key = SymmetricKey(data: bytes)
        format = .legacy
        entropy = nil
    }

    /// A words key from its 16 random bytes.
    public init(entropy: Data) throws {
        guard entropy.count == Self.entropySize else { throw SyncCryptoError.malformed }
        self.entropy = Data(entropy)
        format = .words
        key = Self.slotSecret(entropy: entropy)
    }

    /// The slot secret for a words key's entropy.
    static func slotSecret(entropy: Data) -> SymmetricKey {
        SyncAEAD.deriveKey(SymmetricKey(data: entropy), salt: wordsSalt, info: wordsInfo)
    }

    /// A new Matilde key in the words format.
    public static func generate() -> SyncRecoveryKey {
        // swiftlint:disable:next force_try
        try! SyncRecoveryKey(entropy: SymmetricKey(size: .bits128).syncBytes)
    }

    /// A new key in the legacy format, for tests of accounts made by 0.2.x.
    public static func generateLegacy() -> SyncRecoveryKey {
        // swiftlint:disable:next force_try
        try! SyncRecoveryKey(bytes: SymmetricKey(size: .bits256).syncBytes)
    }

    /// Which format some typed or pasted text is in, or nil when there is nothing to tell yet.
    /// Words when there is no `MTLD` prefix, no digits run into letters ("7KQ2") and either two or
    /// more whole words from the list or every run of letters is the start of one (each but the
    /// last at least three letters long); anything else is read as a legacy key.
    public static func format(of input: String) -> Format? {
        let runs = MatildeKeyPhrase.letterRuns(input)
        let compact = input.uppercased().filter { $0.isLetter || $0.isNumber }
        guard !compact.isEmpty else { return nil }
        if compact.hasPrefix(prefix) { return .legacy }
        // Digits glued to letters ("7KQ2") belong to a legacy key; "1. word" numbering doesn't.
        let tokens = input.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if tokens.contains(where: { $0.contains(where: \.isLetter) && $0.contains(where: \.isNumber) }) { return .legacy }
        guard !runs.isEmpty else { return .legacy }
        // Two or more whole words: a sentence with a misspelt word in it, still words.
        if runs.filter({ MatildeKeyPhrase.resolve($0) != nil }).count >= 2 { return .words }
        for (index, run) in runs.enumerated() {
            guard MatildeKeyPhrase.isPrefix(run) else { return .legacy }
            if index < runs.count - 1, run.count < 3 { return .legacy }
        }
        return .words
    }

    /// Parses what the user typed, in either format.
    ///
    /// Words: any case, separated by spaces, newlines, commas or numbering ("1. abandon 2. …"); a
    /// word may be shortened to its first four letters (unique in the list).
    /// Legacy: case-insensitive, ignores spaces and dashes, the `MTLD` prefix is optional, and the
    /// Crockford look-alikes O→0 and I/L→1 are accepted.
    ///
    /// Throws `invalidRecoveryCode` for the wrong length or an unknown word or character and
    /// `recoveryCodeTypo` when everything parses but the checksum doesn't match.
    public init(code: String) throws {
        if Self.format(of: code) == .words {
            let entropy = try MatildeKeyPhrase.entropy(from: code)
            try self.init(entropy: entropy)
        } else {
            try self.init(legacyCode: code)
        }
    }

    private init(legacyCode code: String) throws {
        var characters = code.uppercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "–" && $0 != "—" }
        if characters.count == 52 + Self.prefix.count, characters.hasPrefix(Self.prefix) { characters.removeFirst(Self.prefix.count) }
        guard characters.count == 52 else { throw SyncCryptoError.invalidRecoveryCode }
        var bits: [UInt8] = []
        bits.reserveCapacity(260)
        for character in characters {
            let normalized: Character = switch character { case "O": "0"; case "I", "L": "1"; default: character }
            guard let value = Self.alphabet.firstIndex(of: normalized) else { throw SyncCryptoError.invalidRecoveryCode }
            for shift in stride(from: 4, through: 0, by: -1) { bits.append(UInt8((value >> shift) & 1)) }
        }
        var bytes = Data(count: 32)
        for index in 0..<256 where bits[index] == 1 { bytes[index / 8] |= 0x80 >> (index % 8) }
        let check = bits[256] << 3 | bits[257] << 2 | bits[258] << 1 | bits[259]
        guard check == Self.checkBits(bytes) else { throw SyncCryptoError.recoveryCodeTypo }
        try self.init(bytes: bytes)
    }

    private static func checkBits(_ bytes: Data) -> UInt8 {
        Array(SHA256.hash(data: bytes))[0] >> 4
    }

    /// The 12 words, in order; empty for a legacy key.
    public var words: [String] {
        guard let entropy else { return [] }
        return MatildeKeyPhrase.words(entropy: entropy)
    }

    /// The key to show, print or save once: the words separated by spaces, or the legacy
    /// `MTLD-…` code. Never log it.
    public var code: String {
        if format == .words { return words.joined(separator: " ") }
        let bytes = key.syncBytes
        var bits: [UInt8] = []
        bits.reserveCapacity(260)
        for byte in bytes { for shift in stride(from: 7, through: 0, by: -1) { bits.append((byte >> UInt8(shift)) & 1) } }
        let check = Self.checkBits(bytes)
        for shift in stride(from: 3, through: 0, by: -1) { bits.append((check >> UInt8(shift)) & 1) }
        var characters: [Character] = []
        for start in stride(from: 0, to: 260, by: 5) {
            let value = bits[start..<(start + 5)].reduce(0) { $0 << 1 | Int($1) }
            characters.append(Self.alphabet[value])
        }
        let groups = stride(from: 0, to: 52, by: 4).map { String(characters[$0..<($0 + 4)]) }
        return ([Self.prefix] + groups).joined(separator: "-")
    }
}

extension SyncRecoveryKey: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "SyncRecoveryKey(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The 12-word sentence of a Matilde key: BIP-0039 encoding of 128 bits with the English list.
public enum MatildeKeyPhrase {
    /// The 2048 words, sorted.
    public static var wordlist: [String] { MatildeKeyWords.english }

    private static let index: [String: Int] = Dictionary(uniqueKeysWithValues: MatildeKeyWords.english.enumerated().map { ($1, $0) })

    /// The words for 16 bytes of entropy: 128 bits plus the first 4 bits of SHA-256(entropy),
    /// read as twelve 11-bit indexes into the list.
    public static func words(entropy: Data) -> [String] {
        precondition(entropy.count == SyncRecoveryKey.entropySize)
        var bits = [Bool]()
        bits.reserveCapacity(132)
        for byte in entropy { for shift in stride(from: 7, through: 0, by: -1) { bits.append((byte >> UInt8(shift)) & 1 == 1) } }
        let check = Array(SHA256.hash(data: entropy))[0]
        for shift in stride(from: 7, through: 4, by: -1) { bits.append((check >> UInt8(shift)) & 1 == 1) }
        return stride(from: 0, to: 132, by: 11).map { start in
            MatildeKeyWords.english[bits[start..<(start + 11)].reduce(0) { $0 << 1 | ($1 ? 1 : 0) }]
        }
    }

    /// The runs of letters in some text, lowercased: the words someone typed or pasted, without
    /// spaces, newlines, punctuation or numbering.
    public static func letterRuns(_ input: String) -> [String] {
        input.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    /// The list word a typed word stands for: the word itself, or a unique start of at least four
    /// letters (every BIP-0039 word is identified by its first four).
    public static func resolve(_ typed: String) -> String? {
        let word = typed.lowercased()
        if index[word] != nil { return word }
        guard word.count >= 4 else { return nil }
        let matches = completions(for: word, limit: 2)
        return matches.count == 1 ? matches[0] : nil
    }

    /// Whether some word in the list starts with `typed`.
    public static func isPrefix(_ typed: String) -> Bool { !completions(for: typed, limit: 1).isEmpty }

    /// Words starting with `prefix`, in list order, for autocomplete.
    public static func completions(for prefix: String, limit: Int = 4) -> [String] {
        let prefix = prefix.lowercased()
        guard !prefix.isEmpty else { return [] }
        let list = MatildeKeyWords.english
        // The list is sorted: binary search for the first word >= prefix.
        var low = 0, high = list.count
        while low < high {
            let mid = (low + high) / 2
            if list[mid] < prefix { low = mid + 1 } else { high = mid }
        }
        var out: [String] = []
        var position = low
        while position < list.count, out.count < limit, list[position].hasPrefix(prefix) {
            out.append(list[position]); position += 1
        }
        return out
    }

    /// The 16 bytes behind a typed sentence. Throws `invalidRecoveryCode` unless there are exactly
    /// 12 known words, and `recoveryCodeTypo` when the checksum doesn't match (a wrong or swapped word).
    public static func entropy(from input: String) throws -> Data {
        let typed = letterRuns(input)
        guard typed.count == SyncRecoveryKey.wordCount else { throw SyncCryptoError.invalidRecoveryCode }
        var bits = [Bool]()
        bits.reserveCapacity(132)
        for word in typed {
            guard let resolved = resolve(word), let value = index[resolved] else { throw SyncCryptoError.invalidRecoveryCode }
            for shift in stride(from: 10, through: 0, by: -1) { bits.append((value >> shift) & 1 == 1) }
        }
        var entropy = Data(count: SyncRecoveryKey.entropySize)
        for position in 0..<128 where bits[position] { entropy[position / 8] |= 0x80 >> UInt8(position % 8) }
        let check = Array(SHA256.hash(data: entropy))[0] >> 4
        let typedCheck = bits[128...131].reduce(UInt8(0)) { $0 << 1 | ($1 ? 1 : 0) }
        guard check == typedCheck else { throw SyncCryptoError.recoveryCodeTypo }
        return entropy
    }
}
