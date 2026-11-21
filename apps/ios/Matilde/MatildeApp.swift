import SwiftUI
import MatildeKit

/// The Matilde iOS app. Notes arrive through end-to-end encrypted sync from the Mac and can be
/// read, edited, commented on and talked through with Matilde here; see ios-plan.md in the
/// project files and IOS-* in ROADMAP.md.
@main
struct MatildeApp: App {
    @State private var library: NoteLibrary
    @State private var sync: SyncController

    init() {
        let library = NoteLibrary()
        let sync = SyncController()
        library.onLocalChange = { [weak sync] in sync?.localChange() }
        sync.prepare = { [weak library] in library?.flushOpenNote?() }
        sync.remoteChanges = { [weak library] in library?.remoteChangesApplied() }
        if let root = library.root { sync.attach(root) }
        _library = State(initialValue: library)
        _sync = State(initialValue: sync)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(sync)
                .tint(Paper.accent)
        }
    }
}
