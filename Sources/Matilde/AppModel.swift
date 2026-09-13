import SwiftUI
import AppKit

@MainActor
final class AppModel: ObservableObject {
    @Published var workspace: Workspace?
    @Published var drafts: [Draft] = []
    @Published var folders: [String] = [""]
    @Published var active: Draft?
    @Published var text = ""
    @Published var sidebar = true
    @Published var status = "Saved"
    @Published var error: String?
    @Published var sheet: Sheet?
    @Published var search = ""
    @Published var headerTitle = ""
    @Published var headerGoal = ""
    @Published var focusTitleID: String?
    @Published var branchMoment: BranchMoment?
    @Published var isBranching = false
    var capturePage: (() -> NSImage?)?
    @Published var boardVisible = false
    @Published var boardSheets: [BoardSheet] = []
    @Published var boardViewport = BoardViewport()
    @Published var boardFlight: BoardFlight?
    @Published var boardRequest = 0
    var boardSize = CGSize.zero
    var reduceBoardMotion = false
    @Published var editorReadyID: String?
    private var headerDirty = false
    var cursor = 0
    var scroll = 0.0
    private var savedText = ""
    private var saveTask: Task<Void, Never>?
    private var positionTask: Task<Void, Never>?
    private var timer: Timer?
    private var scopedURL: URL?
    enum Sheet: String, Identifiable { case document, folder, rename, goal; var id: String { rawValue } }

    init() {
        restore()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }
    var related: [Draft] { drafts.filter { $0.family == active?.family } }
    var wordCount: Int { text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }.count }

    func attempt(_ operation: () throws -> Void) {
        do { try operation() } catch { self.error = error.localizedDescription }
    }
    func startWriting() {
        attempt {
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let folder = documents.appendingPathComponent("Matilde", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try open(folder)
            if active == nil { newDocument() }
        }
    }
    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.title = "Choose your writing folder"
        panel.message = "Choose a home for your writing. You can use an existing folder or create a new one."
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { attempt { try open(url) } }
    }
    func open(_ url: URL) throws {
        try flush()
        let newWorkspace = try Workspace(root: url)
        let contents = try newWorkspace.scan()
        let last = try newWorkspace.state("active")
        let selected = contents.drafts.first { $0.id == last } ?? contents.drafts.first
        let content = try selected.map { try newWorkspace.read($0) } ?? ""
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = url.startAccessingSecurityScopedResource() ? url : nil
        workspace = newWorkspace; drafts = contents.drafts; folders = contents.folders
        sidebar = try newWorkspace.state("sidebar") != "false"
        active = selected; text = content; savedText = content
        boardVisible = false; boardSheets = []; boardFlight = nil; editorReadyID = nil
        try loadHeader()
        cursor = selected?.cursor ?? 0; scroll = selected?.scroll ?? 0
        status = "Saved"
        UserDefaults.standard.set(url.path, forKey: "workspacePath")
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: "workspaceBookmark")
        }
    }
    private func restore() {
        // A launch argument is useful for UI verification with an isolated workspace.
        if let index = CommandLine.arguments.firstIndex(of: "--workspace"), CommandLine.arguments.count > index + 1 {
            attempt { try open(URL(fileURLWithPath: CommandLine.arguments[index + 1])) }; return
        }
        if let data = UserDefaults.standard.data(forKey: "workspaceBookmark") {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                attempt { try open(url) }; return
            }
        }
        if let path = UserDefaults.standard.string(forKey: "workspacePath") { attempt { try open(URL(fileURLWithPath: path)) } }
    }
    func refresh() throws {
        guard let workspace else { return }
        let contents = try workspace.scan()
        if drafts != contents.drafts { drafts = contents.drafts }
        if folders != contents.folders { folders = contents.folders }
        if let id = active?.id, let updated = drafts.first(where: { $0.id == id }), updated != active { active = updated }
    }
    func select(_ draft: Draft) {
        guard draft.id != active?.id else { return }
        attempt {
            try flush()
            guard let workspace else { return }
            // Position may have changed since the menu/list was constructed.
            let current = try workspace.allDrafts().first { $0.id == draft.id } ?? draft
            let content = try workspace.read(current)
            editorReadyID = nil
            active = current; text = content; savedText = content
            try loadHeader()
            cursor = current.cursor; scroll = current.scroll; status = "Saved"
            try workspace.setState("active", draft.id)
        }
    }
    func edited(_ value: String) {
        text = value; status = "Saving…"
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            guard let self else { return }
            self.attempt { try self.save() }
        }
    }
    func position(_ cursor: Int, _ scroll: Double) {
        guard !boardVisible else { return }
        self.cursor = cursor; self.scroll = scroll
        positionTask?.cancel()
        positionTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self else { return }
            self.attempt { try self.persistPosition() }
        }
    }
    private func persistPosition() throws {
        if let workspace, let active {
            try workspace.position(active, cursor: cursor, scroll: scroll)
            try workspace.setState("active", active.id)
            try workspace.setState("sidebar", String(sidebar))
        }
    }
    func toggleSidebar() {
        sidebar.toggle()
        attempt { try workspace?.setState("sidebar", String(sidebar)) }
    }
    func save() throws {
        saveTask?.cancel()
        try saveHeader()
        guard let workspace, let active, text != savedText else { return }
        let disk = try workspace.read(active)
        if disk != savedText {
            try reloadExternal(disk)
            return
        }
        do {
            try workspace.save(active, text: text)
            savedText = text; status = "Saved"
        } catch { status = "Couldn’t save"; throw error }
    }
    func flush() throws {
        try save()
        if boardVisible, let workspace, let active { try workspace.saveBoardViewport(family: active.family, viewport: boardViewport) }
        else { try persistPosition() }
    }
    private func reloadExternal(_ disk: String) throws {
        guard let workspace, let active else { return }
        if text != savedText {
            // No merge UI in v1. Keep a recovery copy before honoring external reload.
            let recovery = workspace.root.appendingPathComponent(".matilde/recovery", isDirectory: true)
            try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
            let copy = recovery.appendingPathComponent("\(active.id)-\(UUID().uuidString).md")
            try text.write(to: copy, atomically: true, encoding: .utf8)
            error = "The file changed outside Matilde and was reloaded. Your unsaved text was preserved at \(copy.path)."
        }
        text = disk; savedText = disk; status = "Reloaded from disk"
    }
    private func poll() {
        guard let workspace, error == nil, sheet == nil else { return }
        attempt {
            try refresh()
            if let active {
                if !drafts.contains(where: { $0.id == active.id }) {
                    status = "File moved or removed"
                    return
                }
                let disk = try workspace.read(active)
                if disk != savedText { try reloadExternal(disk) }
            }
        }
    }
    func create(name: String, folder: String, goal: String) throws {
        guard let workspace else { return }
        try flush()
        let draft = try workspace.create(name: name, folder: folder, goal: goal)
        try refresh(); select(draft)
    }
    func newDocument() {
        attempt {
            try flush()
            guard let workspace else { return }
            boardVisible = false; boardFlight = nil
            let draft = try workspace.createUntitled(folder: active?.folder ?? "")
            try refresh(); select(draft)
            focusTitleID = draft.id
        }
    }
    func trashDraft(_ draft: Draft) {
        guard !isBranching, boardFlight == nil else { return }
        attempt {
            try flush()
            guard let workspace,
                  let current = try workspace.allDrafts().first(where: { $0.id == draft.id }) else { return }
            try workspace.trash(current)
            let wasActive = active?.id == current.id
            let previousFamily = active?.family
            try refresh()
            if wasActive {
                active = nil; text = ""; savedText = ""
                headerTitle = ""; headerGoal = ""; headerDirty = false
                cursor = 0; scroll = 0; editorReadyID = nil; focusTitleID = nil
                if let next = drafts.first(where: { $0.id == current.parent })
                    ?? drafts.first(where: { $0.family == current.family }) ?? drafts.first {
                    select(next)
                } else {
                    try workspace.setState("active", "")
                }
            }
            if boardVisible, let active, active.family == previousFamily {
                let positions = try workspace.boardPositions(for: related)
                boardSheets = try related.map {
                    BoardSheet(draft: $0, excerpt: DraftTray.excerpt(try workspace.read($0)), position: positions[$0.id]!)
                }.sorted { $0.position.x == $1.position.x ? $0.position.y < $1.position.y : $0.position.x < $1.position.x }
            } else if boardVisible {
                boardVisible = false; boardSheets = []
            }
        }
    }
    private func loadHeader() throws {
        headerTitle = try active.map { try workspace?.state("untitled:\($0.id)") == "true" ? "" : $0.title } ?? ""
        headerGoal = active?.goal ?? ""
        headerDirty = false
        focusTitleID = nil
    }
    func editHeader(title: String? = nil, goal: String? = nil) {
        if let title { headerTitle = title }
        if let goal { headerGoal = goal }
        headerDirty = true
        // Use the same autosave cadence as the document body.
        edited(text)
    }
    private func saveHeader() throws {
        guard headerDirty, let workspace, let active else { return }
        let name = headerTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            try workspace.rename(active, name: name)
            try workspace.setState("untitled:\(active.id)", "false")
        }
        try workspace.goal(active, text: headerGoal)
        headerDirty = false
        try refresh()
        status = "Saved"
    }
    func branch() {
        guard !isBranching, !boardVisible else { return }
        attempt {
            try flush()
            guard let workspace, let active else { return }
            let image = capturePage?()
            var source = active
            source.cursor = cursor; source.scroll = scroll
            let draft = try workspace.branch(source, text: text)
            try refresh(); select(draft)
            guard self.active?.id == draft.id else { return }
            let moment = BranchMoment(sourceTitle: source.title, image: image)
            branchMoment = moment
            isBranching = true
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1050))
                self?.isBranching = false
                try? await Task.sleep(for: .milliseconds(850))
                if self?.branchMoment?.id == moment.id { self?.branchMoment = nil }
            }
        }
    }
    func rename(_ name: String) throws {
        try flush()
        if let workspace, let active {
            try workspace.rename(active, name: name)
            try workspace.setState("untitled:\(active.id)", "false")
            try refresh(); try loadHeader()
        }
    }
    func setGoal(_ value: String) throws {
        if let workspace, let active { try workspace.goal(active, text: value); headerGoal = value; try refresh() }
    }
    func reveal() {
        if let workspace, let active, let url = try? workspace.url(for: active.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func toggleBoard() {
        guard boardFlight == nil, !isBranching else { return }
        if boardVisible { if let active { openBoardDraft(active) }; return }
        showBoard()
    }
    func showBoard() {
        guard !boardVisible, boardFlight == nil, !isBranching, boardSize.width > 0 else { return }
        attempt {
            try flush()
            guard let workspace, let active else { return }
            let positions = try workspace.boardPositions(for: related)
            boardSheets = try related.map { draft in
                BoardSheet(draft: draft, excerpt: DraftTray.excerpt(try workspace.read(draft)), position: positions[draft.id]!)
            }.sorted { a, b in a.position.x == b.position.x ? a.position.y < b.position.y : a.position.x < b.position.x }
            if let saved = try workspace.boardViewport(family: active.family) { boardViewport = saved }
            else { fitBoard(size: boardSize) }
            let rect = sheetRect(active.id, in: boardSize)
            if !CGRect(origin: .zero, size: boardSize).contains(rect), let sheet = boardSheets.first(where: { $0.id == active.id }) {
                boardViewport.x = sheet.position.x + 130; boardViewport.y = sheet.position.y + 170
            }
            boardVisible = true
            if !reduceBoardMotion { boardFlight = BoardFlight(draftID: active.id, opening: false) }
            persistBoard()
        }
    }
    func openBoardDraft(_ draft: Draft) {
        guard boardFlight == nil else { return }
        select(draft)
        guard active?.id == draft.id else { return }
        persistBoard()
        if !reduceBoardMotion { boardFlight = BoardFlight(draftID: draft.id, opening: true) }
        else { boardVisible = false }
    }
    func finishBoardFlight(_ id: UUID) {
        guard boardFlight?.id == id else { return }
        if boardFlight?.opening == true { boardVisible = false }
        boardFlight = nil
    }
    func sheetRect(_ id: String, in size: CGSize) -> CGRect {
        guard let sheet = boardSheets.first(where: { $0.id == id }) else { return .zero }
        let zoom = boardViewport.zoom
        return CGRect(x: (sheet.position.x - boardViewport.x) * zoom + size.width / 2,
                      y: (sheet.position.y - boardViewport.y) * zoom + size.height / 2,
                      width: 260 * zoom, height: 340 * zoom)
    }
    func fitBoard(size: CGSize) {
        guard !boardSheets.isEmpty else { return }
        let left = boardSheets.map(\.position.x).min()!, top = boardSheets.map(\.position.y).min()!
        let right = boardSheets.map(\.position.x).max()! + 260, bottom = boardSheets.map(\.position.y).max()! + 340
        boardViewport = BoardViewport(x: (left + right) / 2, y: (top + bottom) / 2,
                                      zoom: max(0.08, min(0.9, (size.width - 100) / (right - left), (size.height - 150) / (bottom - top))))
        persistBoard()
    }
    func persistBoard() {
        attempt { if let workspace, let active { try workspace.saveBoardViewport(family: active.family, viewport: boardViewport) } }
    }
}
