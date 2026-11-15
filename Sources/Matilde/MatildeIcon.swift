import AppKit
import SwiftUI

/// Every interface icon, drawn from Tabler Icons (see `Resources/Icons/SOURCE.md`).
/// The raw value is the Tabler icon name; filled variants end in `-filled`.
/// Changing an icon is a one-line edit followed by `python3 scripts/tabler-icons.py`.
enum MatildeIcon: String, CaseIterable {
    // Toolbar and window
    case sidebar = "layout-sidebar"
    case newDocument = "edit"
    case document = "file-text"
    case board = "layout-grid"
    case more = "dots-circle-horizontal"
    case stash = "inbox"
    case askMatilde = "message"
    case askMatildeError = "message-exclamation"
    case stop = "player-stop"
    // Sidebar
    case search = "search"
    case clear = "circle-x"
    case newFolder = "folder-plus"
    case folder = "folder"
    case folderOpen = "folder-open"
    case settings = "settings"
    // Shared controls
    case chevronRight = "chevron-right"
    case chevronDown = "chevron-down"
    case chevronUp = "chevron-up"
    case plus = "plus"
    case minus = "minus"
    case close = "x"
    case check = "check"
    case branch = "git-branch"
    case goal = "flag"
    case compare = "layout-columns"
    case fit = "arrows-diagonal-2"
    case activeDraft = "pencil"
    // Comments
    case note = "note"
    case archive = "archive"
    case done = "circle-check-filled"
    case send = "circle-arrow-up-filled"
    case stopReply = "player-stop-filled"
    // Settings tabs
    case typography = "typography"
    case key = "key"
    // Slash menu
    case heading = "heading"
    case bulletList = "list"
    case numberedList = "list-numbers"
    case checkbox = "checkbox"
    case quote = "quote"
    case codeBlock = "braces"
    case bold = "bold"
    case italic = "italic"
    case inlineCode = "code"
    case link = "link"
    case photo = "photo"

    /// Design grid of every Tabler icon, in points. The glyphs leave 2 points of padding on each side.
    static let gridSize: CGFloat = 24
    /// Window toolbar buttons and menus.
    static let toolbarSize: CGFloat = 20
    /// Settings window tabs.
    static let tabSize: CGFloat = 24
    private static let cache = NSCache<NSString, NSImage>()

    /// The bundled vector PDF as a template image at its 24-point design size.
    var nsImage: NSImage { nsImage(size: Self.gridSize) }

    /// A template image drawn at `size` points; the vector source stays sharp at any size.
    func nsImage(size: CGFloat) -> NSImage {
        let key = "\(rawValue)@\(size)" as NSString
        if let image = Self.cache.object(forKey: key) { return image }
        let image: NSImage
        if let url = MatildeResources.bundle.url(forResource: rawValue, withExtension: "pdf", subdirectory: "Icons"),
           let source = NSImage(contentsOf: url), let copy = source.copy() as? NSImage {
            image = copy
        } else {
            assertionFailure("Missing icon resource \(rawValue).pdf")
            image = NSImage(size: NSSize(width: Self.gridSize, height: Self.gridSize))
        }
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        Self.cache.setObject(image, forKey: key)
        return image
    }

    /// Resizable template image that follows `foregroundStyle`, tint and appearance.
    var image: Image { Image(nsImage: nsImage).renderingMode(.template).resizable() }

    /// Fixed-size template image. Safe in toolbars, menus and tab items, which ignore frames.
    func image(size: CGFloat) -> Image { Image(nsImage: nsImage(size: size)).renderingMode(.template) }
}

enum MatildeResources {
    /// Resources live in `Contents/Resources` inside the app and beside the binary in `swift test`.
    static let bundle: Bundle = {
        if let url = Bundle.main.url(forResource: "Matilde_Matilde", withExtension: "bundle"), let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }()
}

extension Image {
    /// Tabler glyphs end about 3/24 above the frame bottom; align that edge with neighbouring text baselines.
    func iconBaseline() -> some View {
        alignmentGuide(.firstTextBaseline) { $0.height * 21 / 24 }
            .alignmentGuide(.lastTextBaseline) { $0.height * 21 / 24 }
    }
}
