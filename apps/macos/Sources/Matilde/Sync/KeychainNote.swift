#if canImport(AppKit)
import AppKit
import MatildeKit

/// A short note before the macOS Keychain dialog, shown only when that dialog is likely: the
/// first read in an app session after an update changed Matilde's signature, or the one-time
/// move of the older items into one (`CredentialVault`). Never for a read that won't ask.
@MainActor
enum KeychainNote {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        CredentialVault.willAskForAccess = { migrating in
            MainActor.assumeIsolated { show(migrating: migrating) }
        }
    }

    private static func show(migrating: Int) {
        let alert = NSAlert()
        alert.messageText = KeychainNoteCopy.title
        alert.informativeText = KeychainNoteCopy.text(migrating: migrating)
        alert.addButton(withTitle: KeychainNoteCopy.button)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
#endif
