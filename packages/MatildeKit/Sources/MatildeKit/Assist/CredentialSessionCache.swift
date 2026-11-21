import Foundation

/// Process memory only. Coalesce reads, never persist secrets or cache failed authorizations.
public final class CredentialSessionCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    public init() {}
    public func cached(for id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[id]
    }
    public func store(_ value: String?, for id: String) {
        lock.lock(); defer { lock.unlock() }
        values[id] = value
    }
    public func load(for id: String, using read: () throws -> String?) rethrows -> String? {
        lock.lock(); defer { lock.unlock() }
        if let value = values[id] { return value }
        let value = try read()
        values[id] = value
        return value
    }
}
