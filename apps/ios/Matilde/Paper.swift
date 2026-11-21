import SwiftUI
import UIKit

/// The Mac app's paper palette and writing typeface (`Paper` in apps/macos MarkdownEditor.swift),
/// with the same light and dark values.
enum Paper {
    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    static let background = adaptive(light: (0.976, 0.965, 0.938), dark: (0.13, 0.132, 0.135))
    static let ink = adaptive(light: (0.24, 0.25, 0.22), dark: (0.87, 0.87, 0.86))
    static let muted = adaptive(light: (0.48, 0.48, 0.43), dark: (0.62, 0.625, 0.63))
    static let accent = adaptive(light: (0.48, 0.32, 0.23), dark: (0.69, 0.65, 0.60))
    static let sidebar = adaptive(light: (0.955, 0.949, 0.933), dark: (0.105, 0.107, 0.11))

    /// Newsreader (bundled, registered through `UIAppFonts`), scaled with Dynamic Type.
    static func body(_ size: CGFloat = 19, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom("Newsreader", size: size, relativeTo: style)
    }
}
