import Foundation

/// An AI tool (Langdock, claude.ai, ChatGPT, Cursor, …) the user connected to their notes through the MCP
/// server (docs/mcp.md), as `GET /v1/connections` lists it. Settings → Sync shows these under
/// "Connected AI tools" with Revoke, on the Mac and the iPhone.
public struct ConnectedAITool: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    /// The name the tool gave itself. Only `clientDomain` is verified.
    public let clientName: String
    public let clientDomain: String?
    /// Where the connection sends its answers (the tool's redirect host).
    public let redirectHost: String
    public let scopes: [String]
    /// Milliseconds since 1970.
    public let createdAt: Double
    public let expiresAt: Double
    /// "2026-11-21", or nil when never used.
    public let lastUsedDay: String?

    public init(id: String, clientName: String, clientDomain: String?, redirectHost: String, scopes: [String], createdAt: Double, expiresAt: Double, lastUsedDay: String?) {
        self.id = id
        self.clientName = clientName
        self.clientDomain = clientDomain
        self.redirectHost = redirectHost
        self.scopes = scopes
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.lastUsedDay = lastUsedDay
    }

    public var created: Date { Date(timeIntervalSince1970: createdAt / 1000) }
    public var expires: Date { Date(timeIntervalSince1970: expiresAt / 1000) }

    /// The verified domain when there is one, otherwise the tool's own name.
    public var displayName: String { clientName.isEmpty ? (clientDomain ?? redirectHost) : clientName }

    /// "Read, comment, create notes · feedback": what the connection may do, in the consent page's words.
    public var permissionsSummary: String {
        Self.summary(of: scopes)
    }

    public static func summary(of scopes: [String]) -> String {
        let notes = [("notes:read", "read"), ("notes:comment", "comment"), ("notes:create", "create"), ("notes:edit", "edit")]
            .filter { scopes.contains($0.0) }.map(\.1)
        var parts: [String] = []
        if !notes.isEmpty {
            let joined = notes.count == 1 ? notes[0] : notes.dropLast().joined(separator: ", ") + " and " + notes.last!
            parts.append(joined.prefix(1).uppercased() + joined.dropFirst() + " notes")
        }
        if scopes.contains("feedback") { parts.append(parts.isEmpty ? "Send feedback" : "send feedback") }
        return parts.joined(separator: " · ")
    }

    /// True when the connection can reach notes (any notes scope), false for feedback only.
    public var canReachNotes: Bool { scopes.contains { $0.hasPrefix("notes:") } }
}

struct ConnectedAIToolList: Decodable { let connections: [ConnectedAITool] }

extension HTTPSyncTransport {
    /// The account's active AI tool connections (`GET /v1/connections`).
    public func connections() async throws -> [ConnectedAITool] {
        let http = session.http
        return try SyncHTTP.decode(ConnectedAIToolList.self, try await session.send { http.request("GET", "connections", token: $0) }).connections
    }

    /// Ends a connection at once (`DELETE /v1/connections/{id}`): the tool's next call fails and
    /// the server drops the copy of the key ring it held for that connection.
    public func revokeConnection(_ id: String) async throws {
        try SyncIdentifiers.validate(id, "connectionId")
        let http = session.http
        _ = try await session.send { http.request("DELETE", "connections/\(id)", token: $0) }
    }
}
