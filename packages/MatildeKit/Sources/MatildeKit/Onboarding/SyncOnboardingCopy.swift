import Foundation

/// The words of the "Sync your notes" flow, shared by the Mac and iPhone so both say the same
/// thing in the landing page's voice (apps/web: "Your writing stays yours.").
public enum SyncOnboardingCopy {
    public struct Point: Identifiable, Sendable {
        public let symbol: String
        public let title: String
        public let text: String
        public var id: String { title }
    }

    public static let introTitle = "Your writing, wherever you are"
    public static let introText = "Turn on sync and your notes follow you between your Mac and iPhone."
    public static let points: [Point] = [
        Point(symbol: "laptopcomputer.and.iphone", title: "On your Mac and iPhone",
              text: "Start a page at your desk and pick it up on the train."),
        Point(symbol: "text.bubble", title: "Comments come along",
              text: "Your own notes in the margin and your Ask Matilde threads, too."),
        Point(symbol: "lock", title: "Locked before it leaves",
              text: "Encrypted on your devices. No one else can read your notes."),
        Point(symbol: "globe.europe.africa", title: "Kept in the EU",
              text: "Stored on servers in the EU. Your words stay encrypted there.")
    ]
    public static let introFootnote = "Sync is optional. You can sign out at any time."

    public static let emailTitle = "What’s your email?"
    public static let emailText = "You’ll get a code by email. There’s no password to remember."
    public static let codeTitle = "Check your email"
    public static func codeText(_ email: String) -> String { "A 6-digit code is on its way to \(email)." }
    public static let signingInTitle = "You’re in"
    public static let signingInText = "Getting your encryption key ready…"
    public static let saveKeyTitle = "Your Matilde key"
    public static let saveKeyText = "These 12 words unlock your notes on a new device. Keep them somewhere safe: no one can recover them for you."
    public static let savedConfirmation = "I’ve saved my Matilde key"
    public static let keyCardTitle = "Your Matilde key"
    public static let savedToICloud = "Also saved in your iCloud Keychain, so your other Apple devices can fill it in."
    public static let filledFromICloud = "Filled in from your iCloud Keychain."
    public static let enterKeyTitle = "Unlock your notes"
    public static let enterKeyText = "Enter the 12 words of your Matilde key, or paste them all at once."
    /// For accounts made before the 12-word key (0.2.x): the long `MTLD-` key still works.
    public static let enterLegacyKeyText = "Enter the Matilde key you saved when you first turned on sync. Spaces and dashes are fine."
    public static let useLegacyKey = "I have a key that starts with MTLD"
    public static let useWords = "Enter 12 words instead"
    public static let syncingTitle = "Bringing your notes over…"
    public static let syncingText = "This takes a moment the first time."
    public static let doneTitle = "All set"
    public static let doneText = "Your notes now stay in step across your devices."
    public static let updateTitle = "Update Matilde to sync"
    public static let updateText = "This version is too old for the sync server. Update Matilde, then try again."
    public static let callToActionTitle = "Sync your notes"
    public static let callToActionText = "Your writing on your Mac and iPhone, end-to-end encrypted."
}
