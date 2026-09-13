import SwiftUI
import AppKit

/// Only the document list claims this responder. Text fields and the writing
/// view keep their native Command-Delete handling when they take focus.
struct SidebarKeyboardInput: NSViewRepresentable {
    let view: SidebarKeyboardView
    var onTrash: () -> Void
    func makeNSView(context: Context) -> SidebarKeyboardView { view }
    func updateNSView(_ view: SidebarKeyboardView, context: Context) { view.onTrash = onTrash }
}

final class SidebarKeyboardView: NSView {
    var onTrash: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func handles(_ event: NSEvent) -> Bool {
        window?.firstResponder === self && event.keyCode == 51 &&
            event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard handles(event) else { return super.performKeyEquivalent(with: event) }
        if !event.isARepeat { onTrash?() }
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard handles(event) else { super.keyDown(with: event); return }
        if !event.isARepeat { onTrash?() }
    }
}
