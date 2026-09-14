import Foundation

struct SidebarDraftGroup: Identifiable {
    var root: Draft
    var branches: [Draft]
    var id: String { root.family }
    var latestEdit: Date { ([root] + branches).map(SidebarOrder.date).max() ?? .distantPast }
}

enum SidebarOrder {
    static func date(_ draft: Draft) -> Date { draft.editedAt ?? draft.createdAt ?? .distantPast }
    static func newestFirst(_ left: Draft, _ right: Draft) -> Bool {
        if date(left) != date(right) { return date(left) > date(right) }
        return left.id < right.id
    }
    static func groups(_ drafts: [Draft]) -> [SidebarDraftGroup] {
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
}

extension Workspace {
    func rememberFamilyDraft(_ draft: Draft) throws {
        try setState("familyActive:\(draft.family)", draft.id)
    }
    func lastFamilyDraft(_ family: String, among drafts: [Draft]) throws -> Draft? {
        let members = drafts.filter { $0.family == family }
        if let saved = try state("familyActive:\(family)"), let draft = members.first(where: { $0.id == saved }) {
            return draft
        }
        return members.sorted(by: SidebarOrder.newestFirst).first
    }
}
