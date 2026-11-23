import Foundation

/// The command palette's result model (UI-31): what it lists for a query, in which groups and
/// order. Pure values, so ranking is tested without a window; `CommandPaletteView.swift` draws it.

enum PaletteSection: String, CaseIterable {
    case recent = "Recent"
    case notes = "Notes"
    case actions = "Actions"
    case settings = "Settings"
}

/// One draft, as the palette searches it.
struct PaletteNote: Equatable {
    var id: String
    var family: String
    var title: String
    var folder: String
    var isRoot: Bool
    var edited: Date
    var isActive = false
    /// The draft's Markdown, when loaded; nil while the palette is still reading files.
    var body: String?
}

/// A command or a Settings destination, as the palette lists it.
struct PaletteEntry: Equatable {
    var id: String
    var title: String
    var keywords = ""
    var icon: MatildeIcon
    var section: PaletteSection = .actions
    var subtitle: String?
    var shortcut: String?
    var destructive = false
}

enum PaletteTarget: Hashable {
    /// A note's family: opens its last-open draft, like the sidebar row.
    case family(String)
    /// One draft, found by its title or text.
    case draft(String)
    case entry(String)
}

struct PaletteItem: Identifiable, Equatable {
    var target: PaletteTarget
    var section: PaletteSection
    var title: String
    var subtitle: String?
    var icon: MatildeIcon
    var shortcut: String?
    /// Matched character offsets in `title`.
    var highlights: [Int] = []
    var destructive = false
    var score = 0
    var id: PaletteTarget { target }
}

struct PaletteGroup: Identifiable, Equatable {
    var section: PaletteSection
    var items: [PaletteItem]
    var id: PaletteSection { section }
}

/// A Settings window tab or a named control on it.
struct SettingsDestination: Equatable {
    var id: String
    var title: String
    var keywords: String
    var tab: SettingsTab

    static let all: [SettingsDestination] = [
        .init(id: "general", title: "General Settings", keywords: "preferences options", tab: .general),
        .init(id: "appearance", title: "Appearance", keywords: "theme light dark mode color", tab: .general),
        .init(id: "app-icon", title: "App Icon", keywords: "dock icon", tab: .general),
        .init(id: "writing", title: "Writing Settings", keywords: "preferences editor", tab: .writing),
        .init(id: "text-size", title: "Text Size", keywords: "font bigger smaller zoom", tab: .writing),
        .init(id: "line-spacing", title: "Line Spacing", keywords: "leading line height", tab: .writing),
        .init(id: "spelling", title: "Spell Checking", keywords: "spelling typos", tab: .writing),
        .init(id: "ask-matilde", title: "Ask Matilde Settings", keywords: "ai assist", tab: .askMatilde),
        .init(id: "guidance", title: "Ask Matilde Guidance", keywords: "ai prompt instructions", tab: .askMatilde),
        .init(id: "connections", title: "Connections", keywords: "langdock api key model region ai", tab: .connections),
        .init(id: "sync", title: "Sync Settings", keywords: "cloud devices account sign in recovery key connected ai tools mcp", tab: .sync),
    ]

    var entry: PaletteEntry {
        PaletteEntry(id: "settings:\(id)", title: title, keywords: keywords, icon: tab.icon, section: .settings,
                     subtitle: "Settings › \(tab.title)")
    }
}

enum PaletteSearch {
    static let recentLimit = 6
    static let sectionLimit = 8
    /// Text matches rank below title matches at a word start, above scattered title matches.
    static let contentScore = 60
    static let phraseBonus = 20
    static let keywordScore = 120

    /// Groups for `query`; an empty query shows recent notes and `suggested` entries.
    static func results(query: String, notes: [PaletteNote], entries: [PaletteEntry], suggested: [String] = []) -> [PaletteGroup] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return emptyState(notes: notes, entries: entries, suggested: suggested) }
        var groups: [PaletteGroup] = []
        let noteItems = Array(matchingNotes(trimmed, notes).prefix(sectionLimit))
        if !noteItems.isEmpty { groups.append(PaletteGroup(section: .notes, items: noteItems)) }
        for section in [PaletteSection.actions, .settings] {
            let items = entries.filter { $0.section == section }.compactMap { item(for: $0, query: trimmed) }
                .sorted(by: ranked).prefix(sectionLimit)
            if !items.isEmpty { groups.append(PaletteGroup(section: section, items: Array(items))) }
        }
        // The group holding the best match leads; ties keep Notes, Actions, Settings.
        return groups.enumerated().sorted { left, right in
            let l = left.element.items.first?.score ?? .min, r = right.element.items.first?.score ?? .min
            return l != r ? l > r : left.offset < right.offset
        }.map(\.element)
    }

    /// All items in display order, for keyboard selection.
    static func flatten(_ groups: [PaletteGroup]) -> [PaletteItem] { groups.flatMap(\.items) }

    static func emptyState(notes: [PaletteNote], entries: [PaletteEntry], suggested: [String]) -> [PaletteGroup] {
        let families = Dictionary(grouping: notes, by: \.family).values.compactMap { members -> (PaletteNote, Date)? in
            guard !members.contains(where: \.isActive) else { return nil }
            let representative = members.first(where: \.isRoot) ?? members.sorted { $0.id < $1.id }[0]
            return (representative, members.map(\.edited).max() ?? representative.edited)
        }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id < $1.0.id }
        let recent = families.prefix(recentLimit).map { note, _ in
            PaletteItem(target: .family(note.family), section: .recent, title: note.title,
                        subtitle: note.folder.isEmpty ? nil : note.folder, icon: .document)
        }
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let actions = suggested.compactMap { byID[$0] }.map { entry in
            PaletteItem(target: .entry(entry.id), section: .actions, title: entry.title, subtitle: entry.subtitle,
                        icon: entry.icon, shortcut: entry.shortcut, destructive: entry.destructive)
        }
        var groups: [PaletteGroup] = []
        if !recent.isEmpty { groups.append(PaletteGroup(section: .recent, items: Array(recent))) }
        if !actions.isEmpty { groups.append(PaletteGroup(section: .actions, items: actions)) }
        return groups
    }

    /// Best draft per note family, matched by title (fuzzy) or text (every word present).
    static func matchingNotes(_ query: String, _ notes: [PaletteNote]) -> [PaletteItem] {
        var best: [String: PaletteItem] = [:]
        for note in notes {
            guard let item = item(for: note, query: query) else { continue }
            if let current = best[note.family], !ranked(item, current) { continue }
            best[note.family] = item
        }
        return best.values.sorted(by: ranked)
    }

    static func item(for note: PaletteNote, query: String) -> PaletteItem? {
        let title = FuzzySearch.match(query, in: note.title)
        let text = note.body.flatMap { contentMatch(query, in: $0) }
        guard title != nil || text != nil else { return nil }
        let titleScore = title?.score ?? .min
        let textScore = text?.score ?? .min
        // A text hit adds its snippet; a strong title match stays the reason it is listed.
        let subtitle = textScore > titleScore || (title?.score ?? 0) < FuzzySearch.substringBonus ? text?.snippet : nil
        return PaletteItem(target: .draft(note.id), section: .notes, title: note.title,
                           subtitle: subtitle ?? (note.folder.isEmpty ? nil : note.folder), icon: .document,
                           highlights: title?.positions ?? [], score: max(titleScore, textScore) + (note.isActive ? -5 : 0))
    }

    static func item(for entry: PaletteEntry, query: String) -> PaletteItem? {
        let title = FuzzySearch.match(query, in: entry.title)
        // Keywords find a command by its words' beginnings and rank below a title match at a word start.
        let keywordScore = FuzzySearch.wordPrefixes(query, in: entry.keywords + " " + entry.title)
            ? keywordScore + min(query.count, 10) * 4 : nil
        guard title != nil || keywordScore != nil else { return nil }
        let score = max(title?.score ?? .min, keywordScore ?? .min)
        return PaletteItem(target: .entry(entry.id), section: entry.section, title: entry.title, subtitle: entry.subtitle,
                           icon: entry.icon, shortcut: entry.shortcut, highlights: title?.positions ?? [],
                           destructive: entry.destructive, score: score)
    }

    /// Every query word appears in the text, ignoring case and diacritics; the snippet shows the first.
    static func contentMatch(_ query: String, in body: String) -> (score: Int, snippet: String)? {
        let words = FuzzySearch.words(query)
        guard query.count >= 2, !words.isEmpty else { return nil }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var first: Range<String.Index>?
        for word in words {
            guard let range = body.range(of: word, options: options) else { return nil }
            if first == nil || range.lowerBound < first!.lowerBound { first = range }
        }
        guard let first else { return nil }
        let phrase = words.count > 1 ? body.range(of: query, options: options) : first
        return (contentScore + (phrase != nil && words.count > 1 ? phraseBonus : 0), snippet(body, around: phrase ?? first))
    }

    /// One line of context around `range`, Markdown markers trimmed, at most about 80 characters.
    static func snippet(_ body: String, around range: Range<String.Index>, width: Int = 80) -> String {
        let line = body.lineRange(for: range)
        var start = range.lowerBound, end = range.upperBound
        let before = width / 3
        var count = 0
        while start > line.lowerBound && count < before { start = body.index(before: start); count += 1 }
        count = body.distance(from: start, to: end)
        while end < line.upperBound && count < width { end = body.index(after: end); count += 1 }
        var text = String(body[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        if start == line.lowerBound, let marker = text.range(of: #"^(#{1,6}\s+|[-*+]\s+\[[ xX]\]\s+|[-*+]\s+|>\s*|\d+[.)]\s+)"#, options: .regularExpression) {
            text.removeSubrange(marker)
        }
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let trailing = body[end..<line.upperBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return (start > line.lowerBound ? "…" : "") + text + (trailing.isEmpty ? "" : "…")
    }

    private static func ranked(_ left: PaletteItem, _ right: PaletteItem) -> Bool {
        if left.score != right.score { return left.score > right.score }
        return left.title.localizedStandardCompare(right.title) == .orderedAscending
    }
}
