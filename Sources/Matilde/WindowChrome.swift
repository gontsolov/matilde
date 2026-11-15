import SwiftUI
import AppKit

/// Geometry for the hidden title bar: one header row holds the traffic lights, the sidebar
/// toggle and the document actions. All values are in the window's content coordinates,
/// measured from its top-left corner; views that use them ignore the top safe area.
enum WindowChrome {
    /// Height of the header row. Sidebar content, the canvas and the drag bands start below it.
    static let headerHeight: CGFloat = 52
    /// Vertical center of the header row; the traffic lights and every control sit on it.
    static let rowCenter: CGFloat = headerHeight / 2
    /// Horizontal inset of the header on both sides: from the window's leading edge to the
    /// close button, and from the trailing edge to the last action icon.
    static let horizontalInset: CGFloat = 18
    /// Size of a floating control's frame; its icon is `MatildeIcon.toolbarSize` points wide.
    static let controlWidth: CGFloat = 28
    static let controlHeight: CGFloat = 24
    /// Space between a floating control's frame and its icon.
    static let iconMargin: CGFloat = (controlWidth - MatildeIcon.toolbarSize) / 2
    /// Padding of the top-right cluster's paper backing.
    static let clusterPadding: CGFloat = 3
    /// Top of a floating control, centering it on the row.
    static let controlTop: CGFloat = rowCenter - controlHeight / 2
    /// Width of the open sidebar, and the inset of its content (the search field).
    static let sidebarWidth: CGFloat = 244
    static let sidebarContentInset: CGFloat = 12
    /// Gap between the zoom button and the collapsed sidebar toggle's frame; with the icon
    /// margin, the zoom button is `horizontalInset` from the icon.
    static let toggleGap: CGFloat = horizontalInset - iconMargin
    /// Standard traffic-light button size and the distance between neighbouring buttons'
    /// leading edges, used until the real buttons are measured.
    static let defaultButtonSize: CGFloat = 14
    static let defaultButtonStride: CGFloat = 20
    /// Trailing edge of the traffic lights once placed at the header inset.
    static let defaultTrafficLightsTrailing: CGFloat = horizontalInset + 2 * defaultButtonStride + defaultButtonSize
    /// Gap between the header row and the first content below it on the canvas.
    static let canvasContentGap: CGFloat = 16
    /// Where the writing header starts, so resting text clears the header row.
    static let canvasTopInset: CGFloat = headerHeight + canvasContentGap
    /// Height of the paper fade that softens text scrolled under the controls.
    static let fadeHeight: CGFloat = headerHeight + 12
    /// Trailing padding of the top-right cluster, so its last icon ends `horizontalInset`
    /// from the window edge.
    static let clusterTrailing: CGFloat = horizontalInset - iconMargin - clusterPadding

    /// Origins (top-left content coordinates) for the close, minimize and zoom buttons: at the
    /// header inset, vertically centred on the row, keeping the system's spacing.
    static func trafficLightOrigins(buttonSize: CGSize, stride: CGFloat) -> [CGPoint] {
        let step = stride > buttonSize.width ? stride : defaultButtonStride
        let top = (rowCenter - buttonSize.height / 2).rounded()
        return (0..<3).map { CGPoint(x: horizontalInset + CGFloat($0) * step, y: top) }
    }

    /// Leading position of the sidebar toggle. Open: right-aligned with the sidebar's content
    /// (the search field's trailing edge). Collapsed: a fixed gap past the zoom button, or
    /// at the header inset when the traffic lights are hidden (full screen).
    static func toggleLeading(sidebarOpen: Bool, trafficLightsTrailing: CGFloat?) -> CGFloat {
        if sidebarOpen { return sidebarWidth - sidebarContentInset - controlWidth }
        guard let trailing = trafficLightsTrailing else { return horizontalInset - iconMargin }
        return trailing + toggleGap
    }

    /// The traffic lights' trailing edge from the zoom button's frame in top-left content
    /// coordinates; `nil` means they are hidden. Implausible frames (not laid out yet, or not
    /// in the header row) fall back to the default.
    static func trafficLightsTrailing(zoomFrame: CGRect?) -> CGFloat? {
        guard let frame = zoomFrame else { return nil }
        guard frame.width > 0, frame.height > 0, frame.minX >= 0, frame.minY >= 0,
              frame.maxY <= headerHeight, frame.maxX <= 200 else { return defaultTrafficLightsTrailing }
        return frame.maxX.rounded()
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

/// Window-level state for the hidden title bar: fade state, the traffic lights' placement,
/// and full-screen tracking.
@MainActor
final class WindowChromeModel: ObservableObject {
    @Published private(set) var hidden = false
    /// The traffic lights' trailing edge, measured from the zoom button; `nil` while hidden.
    @Published private(set) var trafficLightsTrailing: CGFloat? = WindowChrome.defaultTrafficLightsTrailing
    func toggleLeading(sidebarOpen: Bool) -> CGFloat {
        WindowChrome.toggleLeading(sidebarOpen: sidebarOpen, trafficLightsTrailing: trafficLightsTrailing)
    }
    private var fade = ChromeFade() { didSet { if fade.hidden != hidden { hidden = fade.hidden } } }
    private weak var window: NSWindow?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var placing = false

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
        // AppKit puts the buttons back at their default spot when it lays out the title bar:
        // on resize, key/main changes, full-screen transitions and appearance changes.
        let names: [Notification.Name] = [NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification,
                                          NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
                                          NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                                          NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                                          NSWindow.didChangeScreenNotification]
        observers = names.map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    if note.name == NSWindow.didResignKeyNotification { self?.reveal() }
                    self?.placeTrafficLights()
                    // The title bar re-lays out its buttons after these, e.g. full-screen exit.
                    DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.placeTrafficLights() } }
                }
            }
        }
        // Catch any other relayout that moves the buttons back.
        if let close = window.standardWindowButton(.closeButton) {
            close.postsFrameChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: close, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.placeTrafficLights() }
            })
        }
        placeTrafficLights()
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

    /// Moves the traffic lights into the header row: the title-bar container grows to the
    /// header height and the buttons sit at the header inset, centred on the row. Full screen
    /// is left alone (the buttons live in the menu-bar overlay there). Afterwards the zoom
    /// button's real frame is measured so the collapsed toggle follows wherever they ended up.
    func placeTrafficLights() {
        guard let window, !placing else { return }
        placing = true
        defer { placing = false }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
        if !window.styleMask.contains(.fullScreen), buttons.count == 3,
           let titlebar = buttons[0].superview, let container = titlebar.superview, let frameView = container.superview {
            // Title-bar container: the top `headerHeight` points of the window frame.
            var frame = container.frame
            frame.size.height = WindowChrome.headerHeight
            frame.origin.y = frameView.isFlipped ? 0 : frameView.bounds.height - WindowChrome.headerHeight
            if container.frame != frame { container.frame = frame }
            let size = buttons[0].frame.size
            let stride = buttons[1].frame.minX - buttons[0].frame.minX
            for (button, origin) in zip(buttons, WindowChrome.trafficLightOrigins(buttonSize: size, stride: stride)) {
                let y = titlebar.isFlipped ? origin.y : titlebar.bounds.height - origin.y - size.height
                let target = CGPoint(x: origin.x, y: y)
                if button.frame.origin != target { button.setFrameOrigin(target) }
            }
        }
        measureTrafficLights()
    }

    /// Reads the zoom button's real frame in the content view's top-left coordinates, the
    /// space the floating controls are laid out in.
    private func measureTrafficLights() {
        guard let window, let content = window.contentView else { return }
        var zoomFrame: CGRect?
        if !window.styleMask.contains(.fullScreen), let zoom = window.standardWindowButton(.zoomButton),
           !zoom.isHidden, zoom.superview != nil {
            var frame = zoom.convert(zoom.bounds, to: content)
            if !content.isFlipped { frame.origin.y = content.bounds.height - frame.maxY }
            zoomFrame = frame
        }
        let measured = WindowChrome.trafficLightsTrailing(zoomFrame: zoomFrame)
        if measured != trafficLightsTrailing { trafficLightsTrailing = measured }
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
            DispatchQueue.main.async { [weak self] in self?.chrome.placeTrafficLights() }
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
                               .init(color: Color(Paper.background), location: 0.5),
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
            .frame(width: WindowChrome.controlWidth, height: WindowChrome.controlHeight)
            .background(Color(Paper.ink).opacity(pressed ? 0.12 : selected ? 0.09 : hovered && enabled ? 0.05 : 0),
                        in: RoundedRectangle(cornerRadius: 6))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}
