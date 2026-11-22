import Foundation

/// What the Mac app says just before macOS asks for the login password to open Matilde's
/// Keychain item (`CredentialVault.willAskForAccess`). Short, about the person's sign-in, and
/// pointing at the button that keeps the dialog from coming back.
public enum KeychainNoteCopy {
    public static let title = "macOS will ask about your keychain"
    public static let button = "Continue"

    /// `migrating`: older Keychain items about to be read once each (0 or 1: just the one item).
    public static func text(migrating: Int) -> String {
        if migrating > 1 {
            return "Matilde now keeps your sign-ins together in your keychain, where they stay safe. To move them, macOS asks once for each of the \(migrating) saved items. Enter your Mac password and choose Always Allow each time."
        }
        return "Matilde keeps your sign-ins safe in your keychain. macOS asks once to let Matilde open them. Enter your Mac password and choose Always Allow."
    }
}
