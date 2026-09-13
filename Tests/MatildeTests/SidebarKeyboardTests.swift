import XCTest
import AppKit
@testable import Matilde

final class SidebarKeyboardTests: XCTestCase {
    @MainActor
    func testTrashShortcutRequiresActualSidebarFocus() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let sidebar = SidebarKeyboardView(frame: NSRect(x: 0, y: 0, width: 100, height: 300))
        let editor = NSTextView(frame: NSRect(x: 100, y: 0, width: 300, height: 300))
        window.contentView?.addSubview(sidebar)
        window.contentView?.addSubview(editor)
        var calls = 0
        sidebar.onTrash = { calls += 1 }
        func event(_ modifiers: NSEvent.ModifierFlags, repeatKey: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                            timestamp: 0, windowNumber: window.windowNumber, context: nil,
                            characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}",
                            isARepeat: repeatKey, keyCode: 51)!
        }
        XCTAssertTrue(window.makeFirstResponder(sidebar))
        XCTAssertTrue(sidebar.performKeyEquivalent(with: event(.command)))
        XCTAssertEqual(calls, 1)
        _ = sidebar.performKeyEquivalent(with: event(.command, repeatKey: true))
        _ = sidebar.performKeyEquivalent(with: event([]))
        _ = sidebar.performKeyEquivalent(with: event([.command, .shift]))
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertFalse(sidebar.performKeyEquivalent(with: event(.command)))
        XCTAssertEqual(calls, 1)
        window.makeFirstResponder(nil)
    }
}
