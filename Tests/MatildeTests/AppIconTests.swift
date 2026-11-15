import XCTest
import AppKit
@testable import Matilde

final class AppIconTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "app.matilde.tests.appicon.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testEveryChoiceLoadsFromTheBundle() throws {
        XCTAssertEqual(AppIconChoice.allCases.first, .standard)
        XCTAssertEqual(Set(AppIconChoice.allCases.map(\.title)).count, AppIconChoice.allCases.count)
        for choice in AppIconChoice.allCases {
            let url = try XCTUnwrap(choice.resourceURL, "Missing AppIcons/\(choice.rawValue).png")
            let image = try XCTUnwrap(NSImage(contentsOf: url), "Unreadable \(choice.rawValue).png")
            let bitmap = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
            XCTAssertEqual(bitmap.pixelsWide, 512, "\(choice.rawValue).png should be 512 px")
            XCTAssertEqual(bitmap.pixelsHigh, 512)
            XCTAssertTrue(bitmap.hasAlpha, "\(choice.rawValue).png needs transparent margins")
            XCTAssertNotNil(choice.image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            // The macOS grid leaves the corners of the canvas transparent and fills the centre.
            XCTAssertLessThan(bitmap.colorAt(x: 4, y: 4)?.alphaComponent ?? 1, 0.05)
            XCTAssertGreaterThan(bitmap.colorAt(x: 256, y: 256)?.alphaComponent ?? 0, 0.95)
        }
    }

    func testStoredChoiceRoundTrips() {
        XCTAssertEqual(AppIconChoice.stored(in: defaults), .standard)
        for choice in AppIconChoice.allCases {
            choice.store(in: defaults)
            XCTAssertEqual(defaults.string(forKey: SettingKeys.appIcon), choice.rawValue)
            XCTAssertEqual(AppIconChoice.stored(in: defaults), choice)
        }
    }

    func testUnknownOrStaleValuesFallBackToTheDefault() {
        for stale in ["", "sparkle", "nib", "paper-plane", "matilde "] {
            defaults.set(stale, forKey: SettingKeys.appIcon)
            XCTAssertEqual(AppIconChoice.stored(in: defaults), .standard, "\(stale)")
        }
        defaults.set(42, forKey: SettingKeys.appIcon)
        XCTAssertEqual(AppIconChoice.stored(in: defaults), .standard)
        defaults.removeObject(forKey: SettingKeys.appIcon)
        XCTAssertEqual(AppIconChoice.stored(in: defaults), .standard)
        XCTAssertEqual(AppIconChoice.resolved(nil), .standard)
    }
}
