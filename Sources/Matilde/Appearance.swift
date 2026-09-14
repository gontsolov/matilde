import SwiftUI
import AppKit

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
    }
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

struct AppAppearanceModifier: ViewModifier {
    @AppStorage(SettingKeys.appearance) private var selection = AppAppearance.system.rawValue
    private var appearance: AppAppearance { AppAppearance(rawValue: selection) ?? .system }
    func body(content: Content) -> some View {
        content.preferredColorScheme(appearance.colorScheme)
            .onAppear { appearance.apply() }
            .onChange(of: selection) { _, _ in appearance.apply() }
    }
}
