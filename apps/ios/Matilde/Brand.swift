import SwiftUI
import UIKit

/// The landing page's button colours (apps/web: dark ink capsule on paper), for the onboarding
/// and first-run screens. Light and dark values swap so the button always stands out.
enum Brand {
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: Double((hex >> 16) & 0xff) / 255,
                           green: Double((hex >> 8) & 0xff) / 255,
                           blue: Double(hex & 0xff) / 255, alpha: 1)
        })
    }

    static let button = adaptive(light: 0x2b2724, dark: 0xebe5da)
    static let buttonPressed = adaptive(light: 0x3a3531, dark: 0xf6f2ea)
    static let buttonInk = adaptive(light: 0xf6f2ea, dark: 0x2b2724)
}

/// The main action on onboarding screens: a dark capsule with a light tap.
struct MatildePrimaryButtonStyle: ButtonStyle {
    var fullWidth = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(Brand.buttonInk)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 50)
            .background(configuration.isPressed ? Brand.buttonPressed : Brand.button, in: Capsule())
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .light), trigger: configuration.isPressed) { _, pressed in pressed }
            .contentShape(Capsule())
    }
}

/// The quieter action beside a primary one ("Not now", "Change email").
struct MatildeSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Paper.accent)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .opacity(configuration.isPressed ? 0.55 : 1)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == MatildePrimaryButtonStyle {
    static var matildePrimary: MatildePrimaryButtonStyle { MatildePrimaryButtonStyle() }
}

extension ButtonStyle where Self == MatildeSecondaryButtonStyle {
    static var matildeSecondary: MatildeSecondaryButtonStyle { MatildeSecondaryButtonStyle() }
}

/// A side-to-side shake for a wrong code or key; animate `shakes` to play it.
struct Shake: GeometryEffect {
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 9 * sin(shakes * .pi * 4), y: 0))
    }
}
