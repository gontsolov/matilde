import Foundation

/// Process memory only. Coalesce reads, never persist secrets or cache failed authorizations.
final class CredentialSessionCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func cached(for id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[id]
    }
    func store(_ value: String?, for id: String) {
        lock.lock(); defer { lock.unlock() }
        values[id] = value
    }
    func load(for id: String, using read: () throws -> String?) rethrows -> String? {
        lock.lock(); defer { lock.unlock() }
        if let value = values[id] { return value }
        let value = try read()
        values[id] = value
        return value
    }
}
