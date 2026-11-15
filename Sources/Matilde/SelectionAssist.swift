import AppKit

private final class SelectionAssistSurface: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Paper.background.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}

/// A nonactivating child window sits above the entire writing surface without taking its selection.
final class SelectionAssistPanel: NSPanel {
    private var observers: [NSObjectProtocol] = []
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(editor: WritingTextView, parent: NSWindow, anchor: NSRect) {
        let button = NSButton(title: "Ask Matilde", target: editor, action: #selector(WritingTextView.askAboutSelection))
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: NSFont.systemFontSize)
        button.toolTip = "Ask Matilde · ⇧⌘A"
        button.sizeToFit()
        let size = NSSize(width: button.frame.width + 8, height: button.frame.height + 8)
        let screen = parent.screen?.visibleFrame ?? parent.frame
        let origin = NSPoint(x: max(screen.minX + 4, min(anchor.minX, screen.maxX - size.width - 4)),
                             y: min(anchor.maxY + 8, screen.maxY - size.height - 4))
        super.init(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        appearance = parent.effectiveAppearance
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = true
        collectionBehavior = [.transient, .fullScreenAuxiliary]
        let surface = SelectionAssistSurface(frame: NSRect(origin: .zero, size: size))
        parent.effectiveAppearance.performAsCurrentDrawingAppearance {
            button.attributedTitle = NSAttributedString(string: "Ask Matilde", attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: Paper.ink.usingColorSpace(.deviceRGB) ?? .labelColor
            ])
        }
        button.isBordered = false
        button.frame.origin = NSPoint(x: 4, y: 4)
        surface.addSubview(button)
        contentView = surface
        for name in [NSWindow.didResignKeyNotification, NSWindow.didResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: parent, queue: .main) { [weak editor] _ in editor?.hideSelectionAssist() })
        }
        if let clip = editor.enclosingScrollView?.contentView {
            observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak editor] _ in editor?.hideSelectionAssist() })
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

extension WritingTextView {
    func hideSelectionAssist() {
        guard let panel = selectionAssistPanel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        selectionAssistPanel = nil
    }
    func showSelectionAssist() {
        hideSelectionAssist()
        let selection = selectedRange()
        guard onAskSelection != nil, selection.length > 0, window?.firstResponder === self,
              NSMaxRange(selection) <= (string as NSString).length, let window else { return }
        let anchor = firstRect(forCharacterRange: selection, actualRange: nil)
        guard visibleRect.intersects(convert(window.convertFromScreen(anchor), from: nil)) else { return }
        let panel = SelectionAssistPanel(editor: self, parent: window, anchor: anchor)
        selectionAssistPanel = panel
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
    }
    /// The selection, or else the paragraph around the insertion point without surrounding
    /// whitespace. Nil when that paragraph is empty.
    var askRange: NSRange? {
        let source = string as NSString
        let selection = selectedRange()
        guard selection.location != NSNotFound, NSMaxRange(selection) <= source.length else { return nil }
        if selection.length > 0 { return selection }
        guard source.length > 0 else { return nil }
        let paragraph = source.paragraphRange(for: NSRange(location: selection.location, length: 0))
        var start = paragraph.location, end = NSMaxRange(paragraph)
        let blank = CharacterSet.whitespacesAndNewlines
        func isBlank(_ index: Int) -> Bool { UnicodeScalar(source.character(at: index)).map { blank.contains($0) } ?? false }
        while start < end, isBlank(start) { start += 1 }
        while end > start, isBlank(end - 1) { end -= 1 }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }
    /// Ask Matilde about the selection or current paragraph; on an empty line, review the draft.
    @objc func askAboutSelection() {
        hideSelectionAssist()
        onAskSelection?(askRange)
    }
}
