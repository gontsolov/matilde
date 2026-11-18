import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The mandatory recovery key: 256 random bits shown to the user once as
/// `MTLD-XXXX-XXXX-…` (13 groups of 4 Crockford Base32 characters). The 52 characters carry
/// 260 bits: the key plus 4 check bits (the top bits of SHA-256(key)) that catch most typos
/// before any network request. It wraps the account key in a `recovery` key slot.
struct SyncRecoveryKey: Equatable {
    static let prefix = "MTLD"
    static let groupCount = 13
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    let key: SymmetricKey

    init(bytes: Data) throws {
        guard bytes.count == SyncCryptoConstants.keySize else { throw SyncCryptoError.malformed }
        key = SymmetricKey(data: bytes)
    }

    private init(key: SymmetricKey) { self.key = key }

    static func generate() -> SyncRecoveryKey { SyncRecoveryKey(key: SymmetricKey(size: .bits256)) }

    /// Parses what the user typed: case-insensitive, ignores spaces and dashes, the `MTLD` prefix is
    /// optional, and the Crockford look-alikes O→0 and I/L→1 are accepted.
    init(code: String) throws {
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

    /// The full code to show or print once. Never log it.
    var code: String {
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

    /// The last group, for the "type the last group" confirmation.
    var lastGroup: String { String(code.suffix(4)) }

    /// Compares a typed last group with this key's, using the same normalisation as parsing.
    func confirms(lastGroup typed: String) -> Bool {
        let cleaned = typed.uppercased().filter { !$0.isWhitespace && $0 != "-" }.map { (c: Character) -> Character in
            switch c { case "O": "0"; case "I", "L": "1"; default: c }
        }
        return String(cleaned) == lastGroup
    }
}

extension SyncRecoveryKey: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "SyncRecoveryKey(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}
