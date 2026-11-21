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

    /// Also the launch screen's colour: keep `LaunchBackground` in Assets.xcassets on the same values.
    static let background = adaptive(light: (0.976, 0.965, 0.938), dark: (0.13, 0.132, 0.135))
    static let ink = adaptive(light: (0.24, 0.25, 0.22), dark: (0.87, 0.87, 0.86))
    static let muted = adaptive(light: (0.48, 0.48, 0.43), dark: (0.62, 0.625, 0.63))
    static let accent = adaptive(light: (0.48, 0.32, 0.23), dark: (0.69, 0.65, 0.60))
    /// A card raised above the page (Matilde's comment in the tour): a touch lighter than `background`.
    static let elevated = adaptive(light: (0.995, 0.99, 0.978), dark: (0.19, 0.192, 0.196))
    static let sidebar = adaptive(light: (0.955, 0.949, 0.933), dark: (0.105, 0.107, 0.11))

    /// Private comments: the Mac's highlighter yellow (WritingLayoutManager.commentHighlight).
    static let commentHighlight = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.78, green: 0.60, blue: 0.30, alpha: 0.24)
            : UIColor(red: 0.97, green: 0.80, blue: 0.40, alpha: 0.34)
    }
    /// The passage a comment or thread sheet is open on, kept visible above the sheet.
    static let focusHighlight = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.69, green: 0.65, blue: 0.60, alpha: 0.28)
            : UIColor(red: 0.48, green: 0.32, blue: 0.23, alpha: 0.16)
    }
    /// The comment's quote rule.
    static let commentRule = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.86, green: 0.67, blue: 0.33, alpha: 0.85)
            : UIColor(red: 0.91, green: 0.69, blue: 0.24, alpha: 0.9)
    })

    /// Newsreader's names inside the bundled files (a variable font; family "Newsreader 16pt").
    static let family = "Newsreader 16pt"
    static let regularFace = "Newsreader16pt-Regular"
    static let italicFace = "Newsreader16pt-Italic"

    /// Newsreader (bundled, registered through `UIAppFonts`), scaled with Dynamic Type. By
    /// family name, so `.italic()` and weights pick the matching face.
    static func body(_ size: CGFloat = 19, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(family, size: size, relativeTo: style)
    }
}
