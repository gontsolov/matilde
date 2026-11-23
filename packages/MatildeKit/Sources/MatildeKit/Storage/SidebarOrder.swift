import Foundation

/// One folder in the sidebar and the note rows it currently shows.
public struct SidebarSection: Identifiable {
    public var folder: String
    public var groups: [SidebarDraftGroup]
    public var id: String { folder }

    public init(folder: String, groups: [SidebarDraftGroup]) {
        self.folder = folder
        self.groups = groups
    }
}

public struct SidebarDraftGroup: Identifiable {
    public var root: Draft
    public var branches: [Draft]
    public var id: String { root.family }
    public var latestEdit: Date { ([root] + branches).map(SidebarOrder.date).max() ?? .distantPast }

    public init(root: Draft, branches: [Draft]) {
        self.root = root
        self.branches = branches
    }
}

public enum SidebarOrder {
    public static func date(_ draft: Draft) -> Date { draft.editedAt ?? draft.createdAt ?? .distantPast }
    public static func newestFirst(_ left: Draft, _ right: Draft) -> Bool {
        if date(left) != date(right) { return date(left) > date(right) }
        return left.id < right.id
    }
    public static func groups(_ drafts: [Draft]) -> [SidebarDraftGroup] {
        Dictionary(grouping: drafts, by: \.family).values.map { family in
            // Keep the representative stable even when a branch becomes newest.
            let stable = family.sorted { $0.path == $1.path ? $0.id < $1.id : $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            let root = stable.first { $0.parent == nil } ?? stable[0]
            return SidebarDraftGroup(root: root, branches: family.filter { $0.id != root.id }.sorted(by: newestFirst))
        }.sorted {
            if $0.latestEdit != $1.latestEdit { return $0.latestEdit > $1.latestEdit }
            return $0.id < $1.id
        }
    }

    /// The note rows the sidebar shows, top to bottom, with their folders: folders in workspace
    /// order, notes newest first, collapsed folders hidden unless searching, and search matching
    /// a note's title or any of its drafts' titles.
    public static func visible(_ drafts: [Draft], folders: [String], collapsed: Set<String>, search: String,
                               order: [String: [String]] = [:]) -> [SidebarSection] {
        folders.compactMap { folder in
            let rows = arranged(SidebarOrder.groups(drafts.filter { $0.folder == folder }), order: order[folder] ?? []).filter { group in
                search.isEmpty || ([group.root] + group.branches).contains { $0.title.localizedCaseInsensitiveContains(search) }
            }
            guard !rows.isEmpty || search.isEmpty else { return nil }
            let expanded = folder.isEmpty || !collapsed.contains(folder) || !search.isEmpty
            return SidebarSection(folder: folder, groups: expanded ? rows : [])
        }
    }

    /// A folder's notes in the order the writer dragged them into (family IDs, top first).
    /// Notes the saved order doesn't know yet (new ones, or ones moved in from elsewhere) come
    /// first, newest first, so a fresh note still shows up at the top; IDs no longer in the
    /// folder are ignored. With no saved order the folder stays newest first.
    public static func arranged(_ groups: [SidebarDraftGroup], order: [String]) -> [SidebarDraftGroup] {
        guard !order.isEmpty else { return groups }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let unknown = groups.filter { rank[$0.id] == nil }
        let known = groups.filter { rank[$0.id] != nil }.sorted { rank[$0.id]! < rank[$1.id]! }
        return unknown + known
    }

    /// The order after dropping `family` at `index` among `current` (the folder's visible
    /// family IDs, top first, which may or may not already contain `family`).
    public static func reordered(_ current: [String], moving family: String, to index: Int) -> [String] {
        var ids = current
        var target = max(0, min(index, ids.count))
        if let from = ids.firstIndex(of: family) {
            ids.remove(at: from)
            if from < target { target -= 1 }
        }
        ids.insert(family, at: min(target, ids.count))
        return ids
    }

    /// The note (family) after or before `current` in the visible order, wrapping at the ends.
    /// A note that is not visible (filtered out or in a collapsed folder) starts from the edge.
    public static func neighbor(of current: String?, in order: [String], forward: Bool) -> String? {
        guard !order.isEmpty else { return nil }
        guard let current, let index = order.firstIndex(of: current) else {
            return forward ? order.first : order.last
        }
        let next = order[(index + (forward ? 1 : order.count - 1)) % order.count]
        return next == current ? nil : next
    }
}

extension Workspace {
    /// Manually arranged note order per folder (`""` is the top level), kept in workspace state.
    public func sidebarOrder(folders: [String]) throws -> [String: [String]] {
        var orders: [String: [String]] = [:]
        for folder in folders {
            if let saved = try state("sidebarOrder:\(folder)"), !saved.isEmpty {
                orders[folder] = saved.split(separator: "\n").map(String.init)
            }
        }
        return orders
    }
    public func setSidebarOrder(_ families: [String], folder: String) throws {
        try setState("sidebarOrder:\(folder)", families.joined(separator: "\n"))
    }
    public func rememberFamilyDraft(_ draft: Draft) throws {
        try setState("familyActive:\(draft.family)", draft.id)
    }
    public func lastFamilyDraft(_ family: String, among drafts: [Draft]) throws -> Draft? {
        let members = drafts.filter { $0.family == family }
        if let saved = try state("familyActive:\(family)"), let draft = members.first(where: { $0.id == saved }) {
            return draft
        }
        return members.sorted(by: SidebarOrder.newestFirst).first
    }
}
