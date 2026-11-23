import SwiftUI
import AppKit
import Combine
import MatildeKit

@MainActor
final class AppModel: ObservableObject {
    let stash = StashModel()
    let review = WritingReviewModel()
    let comments = UserCommentStore()
    @Published var comparison: DraftComparison? { didSet { observeComparison() } }
    @Published private(set) var comparisonDifferences: [NSRange] = []
    @Published var showsComparisonChanges = true { didSet { updateComparisonDifferences() } }
    var comparisonFraction = 0.5
    private var comparisonObservation: AnyCancellable?
    private var differenceTask: Task<Void, Never>?

    @Published var workspace: Workspace?
    @Published var drafts: [Draft] = []
    @Published var folders: [String] = [""]
    @Published var active: Draft?
    @Published var text = "" { didSet { if text != oldValue { review.changed(workspace: workspace, draftID: active?.id, input: reviewInput); comments.changed(workspace: workspace, draftID: active?.id, body: text); updateComparisonDifferences() } } }
    @Published var sidebar = true
    @Published var status = "Saved"
    @Published var error: String?
    @Published var sheet: Sheet?
    @Published var search = ""
    /// Sidebar folders the writer collapsed this session.
    @Published var collapsedFolders: Set<String> = []
    /// Note order per folder the writer arranged by dragging (family IDs, top first).
    @Published var sidebarOrders: [String: [String]] = [:]
    /// Plain-text openings of drafts (by ID) for sidebar rows without a writing goal.
    @Published private(set) var previews: [String: String] = [:]
    private var previewStamps: [String: Date] = [:]
    @Published var headerTitle = "" { didSet { if headerTitle != oldValue { review.changed(workspace: workspace, draftID: active?.id, input: reviewInput) } } }
    @Published var headerGoal = "" { didSet { if headerGoal != oldValue { review.changed(workspace: workspace, draftID: active?.id, input: reviewInput) } } }
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
    @Published var editorReadyID: String? {
        didSet {
            // Branching another note waits until its page is on screen, so the curl shows it.
            guard let id = editorReadyID, id == pendingBranchID else { return }
            pendingBranchID = nil
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active?.id == id else { return }
                self.branch()
            }
        }
    }
    private var pendingBranchID: String?
    /// The folder a folder sheet acts on: the parent for New Folder, the folder for Rename Folder.
    var sheetFolder: String?
    private var headerDirty = false
    var cursor = 0
    var scroll = 0.0
    /// The one draft whose saved cursor and scroll the editor restores when it loads: the
    /// session's draft at launch and a new branch (which inherits its source's position).
    /// Every other switch lands at the top of the note.
    private(set) var restoresPositionID: String?
    private var savedText = ""
    private var saveTask: Task<Void, Never>?
    private var positionTask: Task<Void, Never>?
    private var timer: Timer?
    private var scopedURL: URL?
    enum Sheet: String, Identifiable { case document, folder, rename, goal, renameFolder; var id: String { rawValue } }

    init() {
        stash.reportError = { [weak self] in self?.error = $0 }
        comments.reportError = { [weak self] in self?.error = $0 }
        review.reportError = { [weak self] in self?.error = $0 }
        review.automaticAllowed = { [weak self] in
            guard let self else { return false }
            return NSApp.isActive && !self.boardVisible && !self.isBranching && self.boardFlight == nil && self.sheet == nil
        }
        SyncCenter.shared.prepare = { [weak self] in self?.attempt { try self?.save() } }
        SyncCenter.shared.remoteChanges = { [weak self] in self?.syncApplied() }
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
        _ = try newWorkspace.welcomeDocument()
        let contents = try newWorkspace.scan()
        // SYNC-02: give existing data sync records (the migration) and record changes made while closed.
        newWorkspace.trackSyncChangesLogged()
        let last = try newWorkspace.state("active")
        let selected = contents.drafts.first { $0.id == last } ?? contents.drafts.first
        let content = try selected.map { try newWorkspace.read($0) } ?? ""
        try stash.load(workspace: newWorkspace, family: selected?.family)
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = url.startAccessingSecurityScopedResource() ? url : nil
        comparison = nil
        workspace = newWorkspace; drafts = contents.drafts; folders = contents.folders
        sidebar = try newWorkspace.state("sidebar") != "false"
        collapsedFolders = []
        sidebarOrders = try newWorkspace.sidebarOrder(folders: contents.folders)
        previews = [:]; previewStamps = [:]
        updatePreviews()
        restoresPositionID = selected?.id
        active = selected; text = content; savedText = content
        if let selected { try newWorkspace.rememberFamilyDraft(selected) }
        boardVisible = false; boardSheets = []; boardFlight = nil; editorReadyID = nil
        try loadHeader()
        cursor = selected?.cursor ?? 0; scroll = selected?.scroll ?? 0
        comparisonFraction = Double(try newWorkspace.state("comparisonFraction") ?? "") ?? 0.5
        showsComparisonChanges = try newWorkspace.state("comparisonChanges") != "false"
        if let id = try newWorkspace.state("comparisonDraft"), id != selected?.id,
           let draft = contents.drafts.first(where: { $0.id == id }) {
            comparison = try? DraftComparison(workspace: newWorkspace, draft: draft)
        }
        status = "Saved"
        SyncCenter.shared.attach(url)
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
        if drafts != contents.drafts {
            drafts = contents.drafts
            let current = Dictionary(uniqueKeysWithValues: drafts.map { ($0.id, $0) })
            boardSheets = boardSheets.map { sheet in
                BoardSheet(draft: current[sheet.id] ?? sheet.draft, excerpt: sheet.excerpt, position: sheet.position)
            }
        }
        if folders != contents.folders { folders = contents.folders }
        updatePreviews()
        let orders = try workspace.sidebarOrder(folders: folders)
        if orders != sidebarOrders { sidebarOrders = orders }
        if let id = active?.id, let updated = drafts.first(where: { $0.id == id }), updated != active { active = updated }
    }
    func initialPosition(for draft: Draft) -> (cursor: Int, scroll: Double) {
        EditorLanding.position(cursor: draft.cursor, scroll: draft.scroll, restores: draft.id == restoresPositionID)
    }
    func select(_ draft: Draft, keepingPosition: Bool = false) {
        guard draft.id != active?.id else { return }
        pendingBranchID = nil
        attempt {
            try flush()
            guard let workspace else { return }
            // Position may have changed since the menu/list was constructed.
            let current = try workspace.allDrafts().first { $0.id == draft.id } ?? draft
            let content = try workspace.read(current)
            try stash.load(workspace: workspace, family: current.family)
            editorReadyID = nil
            if comparison?.draft.id == current.id { comparison = nil; try workspace.setState("comparisonDraft", "") }
            restoresPositionID = keepingPosition ? current.id : nil
            active = current; text = content; savedText = content
            try loadHeader()
            let landing = initialPosition(for: current)
            cursor = landing.cursor; scroll = landing.scroll; status = "Saved"
            try workspace.setState("active", draft.id)
            try workspace.rememberFamilyDraft(current)
        }
    }
    private func observeComparison() {
        comparisonObservation = comparison?.$text.dropFirst().sink { [weak self] value in
            self?.updateComparisonDifferences(right: value)
        }
        updateComparisonDifferences()
    }
    private func updateComparisonDifferences(right: String? = nil) {
        differenceTask?.cancel()
        comparisonDifferences = []; comparison?.differences = []
        guard showsComparisonChanges, let comparison else { return }
        let left = text, right = right ?? comparison.text
        differenceTask = Task { [weak self, weak comparison] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            let difference = await Task.detached(priority: .utility) { ComparisonDifferences.between(left, right) }.value
            guard !Task.isCancelled, let self, let comparison, self.comparison === comparison,
                  self.text == left, comparison.text == right else { return }
            self.comparisonDifferences = difference.left; comparison.differences = difference.right
        }
    }
    func compare(_ draft: Draft) {
        guard draft.id != active?.id, !isBranching, boardFlight == nil else { return }
        attempt {
            try flush()
            guard let workspace else { return }
            let next = try DraftComparison(workspace: workspace, draft: draft)
            boardVisible = false
            comparison = next
            try workspace.setState("comparisonDraft", next.draft.id)
        }
    }
    func closeComparison() {
        attempt { try comparison?.flush(); try workspace?.setState("comparisonDraft", ""); comparison = nil }
    }
    func selectFamily(_ family: String) {
        attempt {
            guard let workspace else { return }
            try flush()
            let destination = active?.family == family ? active : try workspace.lastFamilyDraft(family, among: drafts)
            guard let destination else { return }
            select(destination)
            guard active?.id == destination.id else { return }
            if boardVisible { persistBoard(); boardVisible = false; boardFlight = nil }
        }
    }

    /// Open one draft found in the command palette, leaving the board like a sidebar row does.
    func openDraft(_ draft: Draft) {
        guard !isBranching, boardFlight == nil else { return }
        select(draft)
        guard active?.id == draft.id else { return }
        if boardVisible { persistBoard(); boardVisible = false; boardFlight = nil }
    }

    /// Note (family) IDs in the sidebar's visible order.
    var visibleNotes: [String] {
        SidebarOrder.visible(drafts, folders: folders, collapsed: collapsedFolders, search: search, order: sidebarOrders)
            .flatMap { $0.groups.map(\.id) }
    }
    var canCycleNotes: Bool {
        workspace != nil && !isBranching && boardFlight == nil && SidebarOrder.neighbor(of: active?.family, in: visibleNotes, forward: true) != nil
    }
    /// Open the next or previous note in the sidebar, wrapping at the ends. Switching flushes
    /// unsaved writing through the normal path (`selectFamily` → `flush`).
    func cycleNote(forward: Bool) {
        guard workspace != nil, !isBranching, boardFlight == nil,
              let family = SidebarOrder.neighbor(of: active?.family, in: visibleNotes, forward: forward) else { return }
        selectFamily(family)
    }

    var reviewInput: ReviewInput { ReviewInput(title: headerTitle, goal: headerGoal, body: text) }
    func reviewNow() {
        review.bind(workspace: workspace, draftID: active?.id, input: reviewInput)
        review.start(input: reviewInput)
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
            try workspace.rememberFamilyDraft(active)
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
            SyncCenter.shared.localChange()
        } catch { status = "Couldn’t save"; throw error }
    }
    func flush() throws {
        try comparison?.flush()
        try workspace?.setState("comparisonDraft", comparison?.draft.id ?? "")
        try workspace?.setState("comparisonFraction", String(comparisonFraction))
        try workspace?.setState("comparisonChanges", String(showsComparisonChanges))
        try stash.flush()
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
    /// Sync wrote to the workspace: pick up new and changed drafts, the stash and the active
    /// draft's comments and review now rather than at the next poll.
    private func syncApplied() {
        guard workspace != nil, sheet == nil else { return }
        poll()
        comments.reload()
        review.reload()
    }
    private func poll() {
        guard let workspace, error == nil, sheet == nil else { return }
        attempt {
            try comparison?.poll()
            try stash.poll()
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
    /// Move a sidebar note (its drafts in `source`) into `folder`.
    func moveNote(family: String, from source: String, to folder: String) {
        guard source != folder, !isBranching, boardFlight == nil else { return }
        attempt {
            try flush()
            guard let workspace else { return }
            let note = try workspace.movableNote(family: family, folder: source)
            guard !note.isEmpty else { return }
            let moved = try workspace.move(note, to: folder)
            try refresh()
            if let active, moved[active.id] != nil, try workspace.state("untitled:\(active.id)") != "true" {
                headerTitle = active.title
            }
            try comparison?.poll()
        }
    }
    /// The sidebar's line under a note's title when it has no goal: the start of its text,
    /// live for the open draft.
    func preview(for draft: Draft) -> String {
        draft.id == active?.id ? NotePreview.text(text) : previews[draft.id] ?? ""
    }
    /// Re-reads only drafts that changed since their preview was made.
    func updatePreviews() {
        guard let workspace else { return }
        var next: [String: String] = [:]
        var stamps: [String: Date] = [:]
        for draft in drafts {
            let stamp = SidebarOrder.date(draft)
            if previewStamps[draft.id] == stamp, let cached = previews[draft.id] {
                next[draft.id] = cached
            } else {
                next[draft.id] = (try? workspace.read(draft)).map { NotePreview.text($0) } ?? ""
            }
            stamps[draft.id] = stamp
        }
        previewStamps = stamps
        if next != previews { previews = next }
    }
    /// Drop a sidebar note at `index` among `folder`'s notes: moves it there on disk when it
    /// comes from another folder, then remembers the folder's new order.
    func placeNote(family: String, from source: String, to folder: String, at index: Int) {
        guard !isBranching, boardFlight == nil, let workspace else { return }
        let current = SidebarOrder.visible(drafts, folders: folders, collapsed: [], search: "", order: sidebarOrders)
            .first { $0.folder == folder }?.groups.map(\.id) ?? []
        if source != folder {
            moveNote(family: family, from: source, to: folder)
            guard drafts.contains(where: { $0.family == family && $0.folder == folder }) else { return }
        }
        let order = SidebarOrder.reordered(current, moving: family, to: index)
        // Dropped back where it was: keep the folder newest first rather than freezing it.
        if source == folder, order == current { return }
        attempt {
            try workspace.setSidebarOrder(order, folder: folder)
            sidebarOrders[folder] = order
        }
    }
    func newDocument(in folder: String) {
        attempt {
            try flush()
            guard let workspace else { return }
            boardVisible = false; boardFlight = nil
            let draft = try workspace.createUntitled(folder: folder)
            try refresh(); select(draft)
            focusTitleID = draft.id
        }
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
    func showWelcomeDocument() {
        attempt {
            try flush()
            guard let workspace, let draft = try workspace.welcomeDocument(explicit: true) else { return }
            boardVisible = false; boardFlight = nil
            try refresh(); select(draft)
        }
    }
    func trashDraft(_ draft: Draft) {
        guard !isBranching, boardFlight == nil else { return }
        attempt {
            try flush()
            guard let workspace,
                  let current = try workspace.allDrafts().first(where: { $0.id == draft.id }) else { return }
            let order = visibleNotes
            let previousFamily = active?.family
            try workspace.trash(current)
            if comparison?.draft.id == current.id { comparison = nil }
            try refresh()
            if active?.id == current.id { try replaceRemovedActive(current, order: order) }
            try refreshBoard(previousFamily: previousFamily)
        }
    }
    /// Move a sidebar folder, its subfolders and every note inside to the macOS Trash.
    func trashFolder(_ folder: String) {
        guard !folder.isEmpty, !isBranching, boardFlight == nil else { return }
        attempt {
            try flush()
            guard let workspace else { return }
            let order = visibleNotes
            let previousFamily = active?.family
            let removed = try Set(workspace.trashFolder(folder).map(\.id))
            if let comparison, removed.contains(comparison.draft.id) { self.comparison = nil }
            collapsedFolders = collapsedFolders.filter { $0 != folder && !$0.hasPrefix(folder + "/") }
            try refresh()
            if let active, removed.contains(active.id) { try replaceRemovedActive(active, order: order) }
            try refreshBoard(previousFamily: previousFamily)
        }
    }
    /// Open a sensible neighbour after the open draft was removed: its parent, another draft of
    /// its family, then the next note in the sidebar's visible `order` (taken before removal).
    private func replaceRemovedActive(_ removed: Draft, order: [String]) throws {
        guard let workspace else { return }
        active = nil; text = ""; savedText = ""
        headerTitle = ""; headerGoal = ""; headerDirty = false
        cursor = 0; scroll = 0; editorReadyID = nil; focusTitleID = nil
        let families = Set(drafts.map(\.family))
        let neighbour = try SidebarActions.successor(of: removed.family, removing: Set(order.filter { !families.contains($0) }), in: order)
            .flatMap { try workspace.lastFamilyDraft($0, among: drafts) }
        if let next = drafts.first(where: { $0.id == removed.parent })
            ?? drafts.first(where: { $0.family == removed.family })
            ?? neighbour ?? drafts.first {
            select(next)
        } else {
            try stash.load(workspace: workspace, family: nil)
            try workspace.setState("active", "")
        }
    }
    private func refreshBoard(previousFamily: String?) throws {
        guard let workspace else { return }
        if boardVisible, let active, active.family == previousFamily {
            try stash.close(restoreFocus: false)
            let positions = try workspace.boardPositions(for: related)
            boardSheets = try related.map {
                BoardSheet(draft: $0, excerpt: DraftTray.excerpt(try workspace.read($0)), position: positions[$0.id]!)
            }.sorted { $0.position.x == $1.position.x ? $0.position.y < $1.position.y : $0.position.x < $1.position.x }
        } else if boardVisible {
            boardVisible = false; boardSheets = []
        }
    }
    /// Branch `draft`: right away when it is open, otherwise once its page has loaded.
    func branch(from draft: Draft) {
        guard !isBranching, boardFlight == nil else { return }
        if draft.id == active?.id && !boardVisible { branch(); return }
        if boardVisible { persistBoard(); boardVisible = false; boardSheets = [] }
        select(draft)
        guard active?.id == draft.id else { return }
        if editorReadyID == draft.id { branch() } else { pendingBranchID = draft.id }
    }
    func duplicate(_ draft: Draft) {
        guard !isBranching, boardFlight == nil else { return }
        attempt {
            try flush()
            guard let workspace,
                  let current = try workspace.allDrafts().first(where: { $0.id == draft.id }) else { return }
            boardVisible = false; boardFlight = nil
            let copy = try workspace.duplicate(current, text: try workspace.read(current))
            try refresh(); select(copy)
        }
    }
    /// Open `draft` and show a sheet that acts on the open draft (rename, goal).
    func present(_ sheet: Sheet, for draft: Draft) {
        if draft.id != active?.id { select(draft) }
        guard active?.id == draft.id else { return }
        self.sheet = sheet
    }
    func presentFolderSheet(_ sheet: Sheet, folder: String) {
        sheetFolder = folder
        self.sheet = sheet
    }
    func renameFolder(_ folder: String, to name: String) throws {
        guard let workspace else { return }
        try flush()
        let renamed = try workspace.renameFolder(folder, to: name)
        collapsedFolders = Set(collapsedFolders.map { SidebarActions.path($0, movingFolder: folder, to: renamed) })
        try refresh()
        try comparison?.poll()
    }
    func createFolder(name: String, parent: String) throws {
        guard let workspace else { return }
        try workspace.createFolder(name: name, parent: parent)
        collapsedFolders.remove(parent)
        try refresh()
    }
    func copyMarkdown(of draft: Draft) {
        let content = draft.id == active?.id ? text : (try? workspace?.read(draft))
        guard let content else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
    }
    func copyPath(of draft: Draft) {
        guard let url = try? workspace?.url(for: draft.path) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }
    func reveal(_ draft: Draft) {
        if let url = try? workspace?.url(for: draft.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
    func revealFolder(_ folder: String) {
        guard let workspace, let url = try? workspace.validFolder(folder) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    private func loadHeader() throws {
        defer {
            review.bind(workspace: workspace, draftID: active?.id, input: reviewInput)
            comments.bind(workspace: workspace, draftID: active?.id, body: text)
        }
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
            try stash.close(restoreFocus: false)
            let image = capturePage?()
            var source = active
            source.cursor = cursor; source.scroll = scroll
            let draft = try workspace.branch(source, text: text)
            try refresh(); select(draft, keepingPosition: true)
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
    func copyMarkdown() {
        guard active != nil else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func reveal() {
        if let workspace, let active, let url = try? workspace.url(for: active.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func toggleBoard() {
        guard boardFlight == nil, !isBranching else { return }
        if boardVisible { if let active { openBoardDraft(active) }; return }
        showBoard()
    }
    func showBoard(interactive: Bool = false) {
        guard !boardVisible, boardFlight == nil, !isBranching, boardSize.width > 0 else { return }
        attempt {
            try flush()
            guard let workspace, let active else { return }
            let positions = try workspace.boardPositions(for: related)
            boardSheets = try related.map { draft in
                BoardSheet(draft: draft, excerpt: DraftTray.excerpt(try workspace.read(draft)), position: positions[draft.id]!)
            }.sorted { a, b in a.position.x == b.position.x ? a.position.y < b.position.y : a.position.x < b.position.x }
            try stash.close(restoreFocus: false)
            if let saved = try workspace.boardViewport(family: active.family) { boardViewport = saved }
            else { fitBoard(size: boardSize) }
            let rect = sheetRect(active.id, in: boardSize)
            if !CGRect(origin: .zero, size: boardSize).contains(rect), let sheet = boardSheets.first(where: { $0.id == active.id }) {
                boardViewport.x = sheet.position.x + 130; boardViewport.y = sheet.position.y + 170
            }
            boardVisible = true
            if !reduceBoardMotion || interactive { boardFlight = BoardFlight(draftID: active.id, opening: false, interactive: interactive) }
            persistBoard()
        }
    }
    func openBoardDraft(_ draft: Draft) {
        guard boardFlight == nil else { return }
        do { try stash.close(restoreFocus: false) } catch { self.error = error.localizedDescription; return }
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
