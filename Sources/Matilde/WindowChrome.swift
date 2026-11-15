import SwiftUI
import AppKit

/// Geometry for the hidden title bar: the traffic lights float over the content, and the
/// window controls share their row. All values are in the window's content coordinates,
/// measured from its top-left corner; views that use them ignore the top safe area.
enum WindowChrome {
    /// Minimum height of the band the traffic lights sit in.
    static let barHeight: CGFloat = 28
    /// Fallback vertical center of the traffic lights, measured from the window's top edge.
    static let defaultTrafficLightsCenter: CGFloat = 14
    /// Height of a floating control; controls are centered on the traffic lights.
    static let controlHeight: CGFloat = 24
    /// Fallback trailing edge of the traffic lights, measured from the window's leading edge.
    static let defaultTrafficLightsTrailing: CGFloat = 69
    /// Gap between the zoom button and the sidebar toggle's frame.
    static let toggleGap: CGFloat = 10
    /// Leading position of the sidebar toggle while the traffic lights are hidden (full screen).
    static let fullScreenToggleLeading: CGFloat = 12
    /// Room kept below the control row before sidebar content starts.
    static let rowBottomGap: CGFloat = 2
    /// Room kept free at the top of the canvas so resting text clears the floating controls.
    static let canvasTopInset: CGFloat = barHeight
    /// Height of the paper fade that softens text scrolled under the controls.
    static let fadeHeight: CGFloat = 40

    /// Where the traffic lights are: their vertical center and trailing edge, or no trailing
    /// edge while they are hidden.
    struct Row: Equatable {
        var center: CGFloat = WindowChrome.defaultTrafficLightsCenter
        var trafficLightsTrailing: CGFloat? = WindowChrome.defaultTrafficLightsTrailing

        var toggleLeading: CGFloat { WindowChrome.toggleLeading(trafficLightsTrailing: trafficLightsTrailing) }
        var controlTop: CGFloat { WindowChrome.controlTop(trafficLightsCenter: center) }
        var bandHeight: CGFloat { WindowChrome.bandHeight(trafficLightsCenter: center) }
    }

    /// The row for the zoom button's frame in top-left content coordinates; `nil` means the
    /// traffic lights are hidden. Implausible frames (not laid out yet) fall back to defaults.
    static func row(zoomFrame: CGRect?) -> Row {
        guard let frame = zoomFrame else { return Row(trafficLightsTrailing: nil) }
        guard frame.width > 0, frame.height > 0, frame.minX >= 0, frame.minY >= 0,
              frame.midY <= barHeight + 20, frame.maxX <= 200 else { return Row() }
        return Row(center: frame.midY.rounded(), trafficLightsTrailing: frame.maxX.rounded())
    }

    /// Leading position for the sidebar toggle: a fixed gap past the zoom button, or flush
    /// with the content when the traffic lights are hidden (full screen).
    static func toggleLeading(trafficLightsTrailing: CGFloat?) -> CGFloat {
        guard let trailing = trafficLightsTrailing else { return fullScreenToggleLeading }
        return trailing + toggleGap
    }
    /// Top offset that centers a control on the traffic lights, staying inside the band.
    static func controlTop(trafficLightsCenter: CGFloat) -> CGFloat {
        min(max(2, (trafficLightsCenter - controlHeight / 2).rounded()), barHeight + 8)
    }
    /// Height of the top band: the control row plus a small gap, never less than `barHeight`.
    static func bandHeight(trafficLightsCenter: CGFloat) -> CGFloat {
        max(barHeight, controlTop(trafficLightsCenter: trafficLightsCenter) + controlHeight + rowBottomGap)
    }
}

/// Whether the floating window controls are faded out while the user writes.
/// Typing in the editor hides them; pointer movement, hovering them or leaving the editor
/// brings them back.
struct ChromeFade: Equatable {
    private(set) var hidden = false
    private(set) var hovering = false
    private var travel: CGFloat = 0
    /// Accumulated pointer travel needed to reveal, so trackpad jitter while typing doesn't.
    static let revealDistance: CGFloat = 6

    /// Command shortcuts are not typing; Control and Option still edit text.
    static func isTyping(modifiers: NSEvent.ModifierFlags) -> Bool {
        !modifiers.intersection(.deviceIndependentFlagsMask).contains(.command)
    }

    mutating func typed(inEditor: Bool) {
        guard inEditor, !hovering else { return }
        hidden = true
        travel = 0
    }
    mutating func pointerMoved(by distance: CGFloat) {
        guard hidden else { return }
        travel += abs(distance)
        if travel >= Self.revealDistance { reveal() }
    }
    mutating func hover(_ inside: Bool) {
        hovering = inside
        if inside { reveal() }
    }
    mutating func editorFocusChanged(focused: Bool) {
        if !focused { reveal() }
    }
    mutating func reveal() {
        hidden = false
        travel = 0
    }
}

/// Window-level state for the hidden title bar: fade state, the traffic lights' position,
/// and full-screen tracking.
@MainActor
final class WindowChromeModel: ObservableObject {
    @Published private(set) var hidden = false
    /// The traffic lights' row, measured from the zoom button.
    @Published private(set) var row = WindowChrome.Row()
    var controlTop: CGFloat { row.controlTop }
    var toggleLeading: CGFloat { row.toggleLeading }
    var bandHeight: CGFloat { row.bandHeight }
    private var fade = ChromeFade() { didSet { if fade.hidden != hidden { hidden = fade.hidden } } }
    private weak var window: NSWindow?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    func typed(inEditor: Bool) { fade.typed(inEditor: inEditor) }
    func pointerMoved(by distance: CGFloat) { fade.pointerMoved(by: distance) }
    func hover(_ inside: Bool) { fade.hover(inside) }
    func reveal() { fade.reveal() }

    func attach(to window: NSWindow?) {
        guard window !== self.window else { return }
        detach()
        guard let window else { return }
        self.window = window
        window.acceptsMouseMovedEvents = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .mouseMoved, .leftMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window === self.window { self.handle(event) }
            }
            return event
        }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [NSWindow.didResignKeyNotification, NSWindow.didEnterFullScreenNotification,
                                          NSWindow.didExitFullScreenNotification, NSWindow.didResizeNotification]
        observers = names.map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    if note.name == NSWindow.didResignKeyNotification { self?.reveal(); return }
                    self?.measureTrafficLights()
                    // The title bar re-lays out its buttons after full-screen transitions.
                    DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.measureTrafficLights() } }
                }
            }
        }
        measureTrafficLights()
    }
    func detach() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        window = nil
    }

    private var editorFocused: Bool { window?.firstResponder is WritingTextView }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            if ChromeFade.isTyping(modifiers: event.modifierFlags) { fade.typed(inEditor: editorFocused) }
            // Tab, Escape or a shortcut may move focus out of the editor.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.fade.editorFocusChanged(focused: self.editorFocused)
            }
        case .mouseMoved:
            fade.pointerMoved(by: hypot(event.deltaX, event.deltaY))
        case .leftMouseDown:
            fade.reveal()
        default: break
        }
    }

    /// Reads the zoom button's real frame and converts it into the content view's top-left
    /// coordinates, the space the floating controls are laid out in.
    func measureTrafficLights() {
        guard let window, let content = window.contentView else { return }
        var zoomFrame: CGRect?
        if !window.styleMask.contains(.fullScreen), let zoom = window.standardWindowButton(.zoomButton),
           !zoom.isHidden, zoom.superview != nil {
            var frame = zoom.convert(zoom.bounds, to: content)
            if !content.isFlipped { frame.origin.y = content.bounds.height - frame.maxY }
            zoomFrame = frame
        }
        let measured = WindowChrome.row(zoomFrame: zoomFrame)
        if measured != row { row = measured }
    }
}

/// Connects a `WindowChromeModel` to the hosting window.
struct WindowChromeAttachment: NSViewRepresentable {
    let chrome: WindowChromeModel
    func makeNSView(context: Context) -> AttachmentView { AttachmentView(chrome: chrome) }
    func updateNSView(_ nsView: AttachmentView, context: Context) {}
    static func dismantleNSView(_ nsView: AttachmentView, coordinator: ()) { nsView.chrome.detach() }

    final class AttachmentView: NSView {
        let chrome: WindowChromeModel
        init(chrome: WindowChromeModel) { self.chrome = chrome; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            chrome.attach(to: window)
            // The title bar lays out its buttons after the window appears.
            DispatchQueue.main.async { [weak self] in self?.chrome.measureTrafficLights() }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Empty title-bar space that moves the window, and zooms or minimizes it on double-click
/// following the system setting.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        private var passThrough = false
        override func hitTest(_ point: NSPoint) -> NSView? { passThrough ? nil : super.hitTest(point) }
        /// Scrolling over the band still scrolls whatever lies underneath.
        override func scrollWheel(with event: NSEvent) {
            guard let content = window?.contentView else { return super.scrollWheel(with: event) }
            passThrough = true
            let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
            let target = content.hitTest(point)
            passThrough = false
            if let target, target !== self { target.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
        }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": window.miniaturize(nil)
                case "None": break
                default: window.zoom(nil)
                }
            } else {
                window.performDrag(with: event)
            }
        }
    }
}

/// Paper fade at the top of the canvas so text scrolled under the floating controls recedes.
struct CanvasTopFade: View {
    var body: some View {
        LinearGradient(stops: [.init(color: Color(Paper.background), location: 0),
                               .init(color: Color(Paper.background), location: 0.45),
                               .init(color: Color(Paper.background).opacity(0), location: 1)],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: WindowChrome.fadeHeight)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Quiet icon button for the floating window controls.
struct FloatingIconButtonStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        FloatingIconLabel(label: configuration.label, selected: selected, pressed: configuration.isPressed)
    }
}

private struct FloatingIconLabel<Label: View>: View {
    let label: Label
    let selected: Bool
    let pressed: Bool
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        label
            .foregroundStyle(Color(Paper.muted))
            .frame(width: 28, height: 24)
            .background(Color(Paper.ink).opacity(pressed ? 0.12 : selected ? 0.09 : hovered && enabled ? 0.05 : 0),
                        in: RoundedRectangle(cornerRadius: 6))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}
