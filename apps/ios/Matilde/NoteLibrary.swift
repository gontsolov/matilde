import Foundation
import Observation
import MatildeKit

/// One note as the list and reader show it. Filled by sync in IOS-03; empty until then.
struct NoteSummary: Identifiable, Hashable {
    let id: String
    var title: String
    var goal: String
    var body: String
    var edited: Date
}

/// The notes on this device and the sync server they come from.
@Observable
final class NoteLibrary {
    var notes: [NoteSummary]
    /// Release builds always use production, as on the Mac (`SyncServerSelection` in MatildeKit).
    let server: SyncServer

    init(notes: [NoteSummary] = [], server: SyncServer = .production) {
        self.notes = notes
        self.server = server
    }

    /// Newest first, like the Mac sidebar (UI-09).
    func sorted(matching query: String = "") -> [NoteSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return notes
            .filter { trimmed.isEmpty || $0.title.localizedStandardContains(trimmed) || $0.body.localizedStandardContains(trimmed) }
            .sorted { $0.edited > $1.edited }
    }

    func note(id: NoteSummary.ID?) -> NoteSummary? {
        guard let id else { return nil }
        return notes.first { $0.id == id }
    }

    var serverHost: String { server.baseURL.host() ?? server.baseURL.absoluteString }
}
