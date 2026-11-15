import AppKit
import SwiftUI

/// The app icons a writer can choose in Settings. The raw value names the bundled PNG in
/// `Resources/AppIcons`; alternatives are rendered from `assets/app-icons/*.svg` by
/// `python3 scripts/app-icons.py`, the default from `assets/AppIcon.png`.
///
/// The choice changes the running app's icon (Dock, Command-Tab, alerts) through
/// `NSApplication.applicationIconImage` and is re-applied at launch. The bundle itself is never
/// modified, so the code signature and Sparkle updates are unaffected; Finder and the Dock show the
/// default icon while Matilde isn't running.
enum AppIconChoice: String, CaseIterable, Identifiable {
    case matilde = "matilde"
    case leather = "leather"
    case goldFoil = "gold-foil"
    case neon = "neon"
    case blueprint = "blueprint"
    case chalk = "chalk"

    static let standard = AppIconChoice.matilde
    var id: String { rawValue }

    var title: String {
        switch self {
        case .matilde: return "Matilde"
        case .leather: return "Leather"
        case .goldFoil: return "Gold Foil"
        case .neon: return "Neon"
        case .blueprint: return "Blueprint"
        case .chalk: return "Chalk"
        }
    }

    /// A stored value, or the default when it is missing or no longer offered.
    static func resolved(_ rawValue: String?) -> AppIconChoice {
        rawValue.flatMap(AppIconChoice.init(rawValue:)) ?? .standard
    }

    static func stored(in defaults: UserDefaults = .standard) -> AppIconChoice {
        resolved(defaults.string(forKey: SettingKeys.appIcon))
    }

    func store(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: SettingKeys.appIcon)
    }

    var resourceURL: URL? {
        MatildeResources.bundle.url(forResource: rawValue, withExtension: "png", subdirectory: "AppIcons")
    }

    private static let cache = NSCache<NSString, NSImage>()

    /// The full icon artwork, including the standard macOS margins and shadow.
    var image: NSImage? {
        if let image = Self.cache.object(forKey: rawValue as NSString) { return image }
        guard let url = resourceURL, let image = NSImage(contentsOf: url) else { return nil }
        Self.cache.setObject(image, forKey: rawValue as NSString)
        return image
    }

    /// Shows this icon for the running app. The default clears the override so AppKit uses the
    /// bundle's own `Matilde.icns` at every size.
    @MainActor func apply(to app: NSApplication = .shared) {
        app.applicationIconImage = self == .standard ? nil : image
    }
}

/// A row of icon thumbnails for Settings.
struct AppIconPicker: View {
    @Binding var selection: String

    var body: some View {
        let current = AppIconChoice.resolved(selection)
        HStack(alignment: .top, spacing: 4) {
            ForEach(AppIconChoice.allCases) { choice in
                let selected = choice == current
                Button { selection = choice.rawValue } label: {
                    VStack(spacing: 5) {
                        Group {
                            if let image = choice.image { Image(nsImage: image).resizable().interpolation(.high) }
                            else { Color.clear }
                        }
                        .frame(width: 52, height: 52)
                        .padding(5)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(Paper.accent).opacity(selected ? 0.12 : 0)))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color(Paper.accent).opacity(selected ? 0.9 : 0), lineWidth: 2))
                        Text(choice.title).font(.caption).lineLimit(1)
                            .foregroundStyle(selected ? Color.primary : Color.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("App icon")
    }
}
