import XCTest
import AppKit
@testable import Matilde

final class SettingsTests: XCTestCase {
    func testWritingPreferencesChangeOnlyPresentation() {
        let source = "# Heading\n日本語 **bold** and ordinary writing."
        let text = NSMutableAttributedString(string: source)
        MarkdownStyler.style(text, textSize: 24, lineSpacing: 10)
        XCTAssertEqual(text.string, source)
        XCTAssertEqual((text.attribute(.font, at: text.length - 1, effectiveRange: nil) as? NSFont)?.pointSize, 24)
        XCTAssertEqual((text.attribute(.paragraphStyle, at: text.length - 1, effectiveRange: nil) as? NSParagraphStyle)?.lineSpacing, 10)
        MarkdownStyler.style(text)
        XCTAssertEqual((text.attribute(.font, at: text.length - 1, effectiveRange: nil) as? NSFont)?.pointSize, 19)
        XCTAssertEqual(text.string, source)
    }

    func testEmptyCredentialIsRejectedBeforeAccessingKeychain() {
        XCTAssertThrowsError(try APIKeyStore(service: "app.matilde.tests", account: "unused").save(" \n "))
    }

    func testIsolatedKeychainLifecycle() throws {
        guard ProcessInfo.processInfo.environment["MATILDE_TEST_KEYCHAIN"] == "1" else {
            throw XCTSkip("Run locally with MATILDE_TEST_KEYCHAIN=1 to exercise an unlocked login Keychain.")
        }
        let store = APIKeyStore(service: "app.matilde.tests.\(UUID().uuidString)", account: "disposable")
        defer { try? store.remove() }
        XCTAssertFalse(try store.containsKey())
        try store.save("dummy-not-a-real-api-key")
        XCTAssertTrue(try store.containsKey())
        XCTAssertTrue(try store.load() == "dummy-not-a-real-api-key")
        try store.save("replacement-dummy-key")
        XCTAssertTrue(try store.load() == "replacement-dummy-key")
        try store.remove()
        XCTAssertFalse(try store.containsKey())
        XCTAssertNil(try store.load())
    }
}
