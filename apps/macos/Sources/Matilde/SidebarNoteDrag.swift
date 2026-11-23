import SwiftUI

/// A sidebar note being dragged (UI-13): onto a folder, back to the top level, or to a new
/// place among a folder's notes. The drag stays inside the sidebar, nothing goes on the
/// pasteboard, so letting go over the editor or Finder simply cancels it.
struct SidebarNoteDrag: Equatable {
    var family: String
    var folder: String
    var title: String
    /// Pointer position in the sidebar's coordinate space.
    var location: CGPoint = .zero
}

/// Where a dragged note would land: `index` among `folder`'s visible notes (top first).
/// `onHeader` means the pointer is over the folder's own row (or the Documents header), which
/// highlights it and drops the note at the top; otherwise `lineY` is where the insertion line goes.
struct SidebarDropTarget: Equatable {
    var folder: String
    var index: Int
    var onHeader: Bool
    var lineY: CGFloat?
}

enum SidebarDropPlanner {
    static let space = "sidebar"
    static func rowKey(_ family: String) -> String { "row:" + family }
    static func headerKey(_ folder: String) -> String { "head:" + folder }
    static func sectionKey(_ folder: String) -> String { "sec:" + folder }

    /// `sections` are the visible folders top to bottom with their note IDs; `frames` holds the
    /// rows, folder headers and sections measured in the sidebar's coordinate space.
    static func target(at point: CGPoint, sections: [(folder: String, rows: [String])], frames: [String: CGRect]) -> SidebarDropTarget? {
        for section in sections {
            if let header = frames[headerKey(section.folder)], header.contains(point) {
                return SidebarDropTarget(folder: section.folder, index: 0, onHeader: true, lineY: nil)
            }
        }
        let measured = sections.compactMap { section in frames[sectionKey(section.folder)].map { (section, $0) } }
        guard let first = measured.first, point.x >= first.1.minX, point.x <= first.1.maxX, point.y >= first.1.minY else { return nil }
        // The section under the pointer, or the one just above it (gaps and the empty space below the list).
        guard let (section, _) = measured.last(where: { $0.1.minY <= point.y }) else { return nil }
        let rows = section.rows.compactMap { id in frames[rowKey(id)].map { (id, $0) } }
        guard !rows.isEmpty else { return SidebarDropTarget(folder: section.folder, index: 0, onHeader: true, lineY: nil) }
        let index = rows.firstIndex { point.y < $0.1.midY } ?? rows.count
        let lineY = index < rows.count ? rows[index].1.minY - 1 : rows[rows.count - 1].1.maxY + 1
        return SidebarDropTarget(folder: section.folder, index: index, onHeader: false, lineY: lineY)
    }
}

struct SidebarFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Reports this view's frame in the sidebar's coordinate space under `key`.
    func sidebarFrame(_ key: String) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: SidebarFrameKey.self, value: [key: geometry.frame(in: .named(SidebarDropPlanner.space))])
        })
    }
}
