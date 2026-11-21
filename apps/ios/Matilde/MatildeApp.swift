import SwiftUI

/// The Matilde iOS app (IOS-01 skeleton). Notes arrive through end-to-end encrypted sync from
/// the Mac; see ios-plan.md in the project files and IOS-* in ROADMAP.md.
@main
struct MatildeApp: App {
    @State private var library = NoteLibrary()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .tint(Paper.accent)
        }
    }
}
