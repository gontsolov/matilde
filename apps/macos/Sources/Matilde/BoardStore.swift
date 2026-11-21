import Foundation

struct SheetPosition: Equatable {
    var x: Double
    var y: Double
}

struct BoardViewport: Equatable {
    var x: Double = 0
    var y: Double = 0
    var zoom: Double = 0.75
}

struct BoardSheet: Identifiable {
    let draft: Draft
    let excerpt: String
    let position: SheetPosition
    var id: String { draft.id }
}

extension Workspace {
    func prepareBoardTables() throws {
        try db.execute("CREATE TABLE IF NOT EXISTS board_sheets (draft TEXT PRIMARY KEY, x REAL NOT NULL, y REAL NOT NULL)")
        try db.execute("CREATE TABLE IF NOT EXISTS board_view (family TEXT PRIMARY KEY, x REAL NOT NULL, y REAL NOT NULL, zoom REAL NOT NULL)")
    }
    func boardPositions(for drafts: [Draft]) throws -> [String: SheetPosition] {
        try prepareBoardTables()
        let ids = Set(drafts.map(\.id))
        var positions = Dictionary(uniqueKeysWithValues: try db.execute("SELECT * FROM board_sheets").compactMap { row -> (String, SheetPosition)? in
            guard let id = row["draft"], ids.contains(id), let x = Double(row["x"] ?? ""), let y = Double(row["y"] ?? "") else { return nil }
            return (id, SheetPosition(x: x, y: y))
        })
        var pending = drafts.filter { positions[$0.id] == nil }
        while !pending.isEmpty {
            let index = pending.firstIndex { $0.parent == nil || positions[$0.parent ?? ""] != nil || !ids.contains($0.parent ?? "") } ?? 0
            let draft = pending.remove(at: index)
            let parent = draft.parent.flatMap { positions[$0] }
            var point = parent.map { SheetPosition(x: $0.x + 320, y: $0.y + 100) } ?? SheetPosition(x: 0, y: 0)
            while positions.values.contains(where: { abs($0.x - point.x) < 280 && abs($0.y - point.y) < 360 }) { point.y += 390 }
            try db.execute("INSERT INTO board_sheets VALUES (?,?,?)", [draft.id, String(point.x), String(point.y)])
            positions[draft.id] = point
        }
        return positions
    }
    func boardViewport(family: String) throws -> BoardViewport? {
        try prepareBoardTables()
        guard let row = try db.execute("SELECT * FROM board_view WHERE family=?", [family]).first,
              let x = Double(row["x"] ?? ""), let y = Double(row["y"] ?? ""), let zoom = Double(row["zoom"] ?? ""), x.isFinite, y.isFinite, zoom.isFinite else { return nil }
        return BoardViewport(x: x, y: y, zoom: min(max(zoom, 0.08), 1.4))
    }
    func saveBoardViewport(family: String, viewport: BoardViewport) throws {
        try prepareBoardTables()
        try db.execute("INSERT INTO board_view VALUES (?,?,?,?) ON CONFLICT(family) DO UPDATE SET x=excluded.x,y=excluded.y,zoom=excluded.zoom", [family, String(viewport.x), String(viewport.y), String(viewport.zoom)])
    }
}
