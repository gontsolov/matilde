import XCTest
import AppKit
@testable import Matilde

final class AppearanceTests: XCTestCase {
    func testPaperPaletteResolvesWithReadableContrastInBothAppearances() throws {
        func luminance(_ color: NSColor, appearance: NSAppearance) -> Double {
            var result = 0.0
            appearance.performAsCurrentDrawingAppearance {
                let rgb = color.usingColorSpace(.sRGB)!
                func linear(_ v: CGFloat) -> Double {
                    let x = Double(v)
                    return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
                }
                result = 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
            }
            return result
        }
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        XCTAssertGreaterThan(luminance(Paper.background, appearance: light), 0.8)
        XCTAssertLessThan(luminance(Paper.background, appearance: dark), 0.05)
        for appearance in [light, dark] {
            let bg = luminance(Paper.background, appearance: appearance)
            let fg = luminance(Paper.ink, appearance: appearance)
            XCTAssertGreaterThan((max(bg, fg) + 0.05) / (min(bg, fg) + 0.05), 7)
        }
        XCTAssertNil(AppAppearance.system.colorScheme)
        XCTAssertEqual(AppAppearance.dark.colorScheme, .dark)
        XCTAssertEqual(AppAppearance.light.colorScheme, .light)
    }
}
