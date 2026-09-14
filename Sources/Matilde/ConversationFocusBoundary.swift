import SwiftUI
import AppKit

/// Observe focus leaving the whole card, including its scrollable transcript and fixed composer.
struct ConversationFocusBoundary: NSViewRepresentable {
    let onBlur: () -> Void
    func makeNSView(context: Context) -> Boundary { Boundary() }
    func updateNSView(_ view: Boundary, context: Context) { view.onBlur = onBlur }
    final class Boundary: NSView {
        var onBlur: (() -> Void)?
        private var monitor: Any?
        private var observer: NSObjectProtocol?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                guard let self, let window = self.window else { return event }
                if event.type == .keyDown {
                    if event.keyCode == 53 { DispatchQueue.main.async { [weak self] in self?.onBlur?() } }
                    else if event.keyCode == 48 {
                        DispatchQueue.main.async { [weak self] in
                            guard let self, let responder = self.window?.firstResponder as? NSView else { return }
                            let point = self.convert(NSPoint(x: responder.bounds.midX, y: responder.bounds.midY), from: responder)
                            if !self.bounds.contains(point) { self.onBlur?() }
                        }
                    }
                } else if let eventWindow = event.window,
                          eventWindow !== window || !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    DispatchQueue.main.async { [weak self] in self?.onBlur?() }
                }
                return event
            }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.onBlur?() }
        }
        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

/// Cursor region belongs only to the clickable preview, leaving the composer’s text cursor native.
struct ConversationPointer: NSViewRepresentable {
    func makeNSView(context: Context) -> Pointer { Pointer() }
    func updateNSView(_ view: Pointer, context: Context) { view.window?.invalidateCursorRects(for: view) }
    final class Pointer: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    }
}
