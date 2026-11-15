import AppKit

struct SlashCommand {
    let title: String
    let icon: MatildeIcon
    let keywords: String
    let template: String
    let placeholder: String?
    let block: Bool

    static let all: [SlashCommand] = (1...6).map {
        SlashCommand(title: "Heading \($0)", icon: .heading, keywords: "h\($0) title heading", template: String(repeating: "#", count: $0) + " Heading", placeholder: "Heading", block: true)
    } + [
        .init(title: "Bullet list", icon: .bulletList, keywords: "ul unordered bullet list", template: "- Item", placeholder: "Item", block: true),
        .init(title: "Numbered list", icon: .numberedList, keywords: "ol ordered numbered list", template: "1. Item", placeholder: "Item", block: true),
        .init(title: "Checkbox", icon: .checkbox, keywords: "todo task checklist checkbox", template: "- [ ] Task", placeholder: "Task", block: true),
        .init(title: "Quote", icon: .quote, keywords: "blockquote quote", template: "> Quote", placeholder: "Quote", block: true),
        .init(title: "Divider", icon: .minus, keywords: "horizontal rule divider line", template: "---\n", placeholder: nil, block: true),
        .init(title: "Code block", icon: .codeBlock, keywords: "fenced code block", template: "```\nCode\n```", placeholder: "Code", block: true),
        .init(title: "Bold", icon: .bold, keywords: "strong bold", template: "**text**", placeholder: "text", block: false),
        .init(title: "Italic", icon: .italic, keywords: "emphasis italic", template: "*text*", placeholder: "text", block: false),
        .init(title: "Inline code", icon: .inlineCode, keywords: "inline code monospace", template: "`code`", placeholder: "code", block: false),
        .init(title: "Link", icon: .link, keywords: "url link", template: "[text](https://example.com)", placeholder: "https://example.com", block: false),
        .init(title: "Image", icon: .photo, keywords: "local image picture photo", template: "![Image](image.png)", placeholder: "image.png", block: true)
    ]

    static func query(in text: String, selection: NSRange) -> (range: NSRange, filter: String)? {
        let source = text as NSString
        guard selection.length == 0, selection.location <= source.length else { return nil }
        let line = source.lineRange(for: NSRange(location: selection.location, length: 0))
        let before = source.substring(with: NSRange(location: line.location, length: selection.location - line.location))
        guard let match = MarkdownStyler.first("(?:^|\\s)(/[^\\s/]*)$", in: before) else { return nil }
        let range = NSRange(location: line.location + match.range(at: 1).location, length: match.range(at: 1).length)
        let styled = NSMutableAttributedString(string: text)
        MarkdownStyler.style(styled)
        guard styled.attribute(.codeBlock, at: range.location, effectiveRange: nil) == nil,
              styled.attribute(.inlineCode, at: range.location, effectiveRange: nil) == nil else { return nil }
        return (range, String(source.substring(with: range).dropFirst()).lowercased())
    }

    var section: String {
        if title.hasPrefix("Heading") { return "Format" }
        if ["Bold", "Italic", "Inline code"].contains(title) { return "Style" }
        if ["Bullet list", "Numbered list", "Checkbox"].contains(title) { return "Lists" }
        return "Insert"
    }

    static func matching(_ query: String) -> [SlashCommand] {
        ["Format", "Lists", "Insert", "Style"].flatMap { section in
            all.filter { $0.section == section && (query.isEmpty || $0.title.lowercased().contains(query) || $0.keywords.contains(query)) }
        }
    }
}

enum SlashMenuPlacement: Equatable {
    case above, below
}

/// Pure placement in AppKit screen coordinates (y grows upward).
enum SlashMenuLayout {
    static let gap: CGFloat = 4
    static let margin: CGFloat = 4

    /// Above the caret line unless the menu at its full height cannot fit there.
    /// When neither side fits, the side with more room wins.
    static func placement(caret: NSRect, maxHeight: CGFloat, visible: NSRect) -> SlashMenuPlacement {
        let roomAbove = visible.maxY - margin - (caret.maxY + gap)
        if roomAbove >= maxHeight { return .above }
        let roomBelow = caret.minY - gap - (visible.minY + margin)
        if roomBelow >= maxHeight { return .below }
        return roomAbove >= roomBelow ? .above : .below
    }

    /// Above anchors the menu's bottom edge just over the line; below anchors its top edge under it.
    static func frame(caret: NSRect, size: NSSize, visible: NSRect, placement: SlashMenuPlacement) -> NSRect {
        let minX = visible.minX + margin
        let maxX = visible.maxX - margin - size.width
        let x = maxX < minX ? minX : min(max(caret.minX, minX), maxX)
        let y: CGFloat
        switch placement {
        case .above: y = min(caret.maxY + gap, visible.maxY - margin - size.height)
        case .below: y = max(caret.minY - gap - size.height, visible.minY + margin)
        }
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// Decides the side once when the menu opens and keeps it while the list is filtered.
struct SlashMenuPositioner {
    private(set) var placement: SlashMenuPlacement?

    mutating func frame(caret: NSRect, size: NSSize, maxHeight: CGFloat, visible: NSRect) -> NSRect {
        let side = placement ?? SlashMenuLayout.placement(caret: caret, maxHeight: maxHeight, visible: visible)
        placement = side
        return SlashMenuLayout.frame(caret: caret, size: size, visible: visible, placement: side)
    }

    mutating func reset() { placement = nil }
}

private enum SlashMenuStyle {
    private static func adaptive(_ name: String, light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: NSColor.Name("Matilde.slash." + name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
    static let surface = adaptive("surface", light: .white,
                                  dark: NSColor(calibratedRed: 0.195, green: 0.197, blue: 0.2, alpha: 1))
    static let border = adaptive("border", light: NSColor.black.withAlphaComponent(0.13),
                                 dark: NSColor.white.withAlphaComponent(0.13))
    static let selection = adaptive("selection", light: NSColor.black.withAlphaComponent(0.06),
                                    dark: NSColor.white.withAlphaComponent(0.08))
    static let glyph = adaptive("glyph", light: NSColor(calibratedRed: 0.24, green: 0.25, blue: 0.22, alpha: 0.56),
                                dark: NSColor(calibratedRed: 0.87, green: 0.87, blue: 0.86, alpha: 0.52))
    static func isDark(_ appearance: NSAppearance) -> Bool { appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    static let width: CGFloat = 236
    static let inset: CGFloat = 5
    static let rowHeight: CGFloat = 28
    static let headerHeight: CGFloat = 22
    static let maxContentHeight: CGFloat = 352
    static let shadowInset: CGFloat = 24

    static func contentHeight(_ commands: [SlashCommand]) -> CGFloat {
        CGFloat(commands.count) * rowHeight + CGFloat(Set(commands.map(\.section)).count) * headerHeight
    }
    static func menuHeight(_ commands: [SlashCommand]) -> CGFloat {
        min(contentHeight(commands), maxContentHeight) + inset * 2
    }
}

private final class SlashMenuStack: NSStackView {
    override var isFlipped: Bool { true }
}

/// Draw explicit content insets instead of relying on NSButtonCell's title margins.
private final class SlashMenuRow: NSButton {
    var symbol: NSImage?
    var headingLevel: String?

    override func draw(_ dirtyRect: NSRect) {
        let ink = contentTintColor ?? Paper.ink
        let glyph = SlashMenuStyle.glyph
        let iconRect = NSRect(x: 10, y: (bounds.height - 16) / 2, width: 16, height: 16)
        if let headingLevel {
            let mark = "H" + headingLevel
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: glyph
            ]
            let size = (mark as NSString).size(withAttributes: attributes)
            (mark as NSString).draw(at: NSPoint(x: iconRect.midX - size.width / 2,
                                               y: (bounds.height - size.height) / 2), withAttributes: attributes)
        } else if let symbol {
            let size = symbol.size
            let scale = min(iconRect.width / size.width, iconRect.height / size.height)
            let rect = NSRect(x: iconRect.midX - size.width * scale / 2,
                              y: iconRect.midY - size.height * scale / 2,
                              width: size.width * scale, height: size.height * scale)
            let tinted = NSImage(size: size, flipped: false) { rect in
                symbol.draw(in: rect)
                glyph.setFill()
                rect.fill(using: .sourceIn)
                return true
            }
            tinted.draw(in: rect)
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13.5), .foregroundColor: ink
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: 34, y: (bounds.height - size.height) / 2),
                                 withAttributes: attributes)
    }
}

/// A nonactivating child panel keeps the native text view focused. No transitions.
final class SlashMenuController: NSObject {
    weak var editor: WritingTextView?
    private var panel: NSPanel?
    private var rows: [NSButton] = []
    private var scroll: NSScrollView?
    private(set) var commands: [SlashCommand] = []
    private var queryRange: NSRange?
    private var dismissedRange: NSRange?
    private var selected = 0
    private var positioner = SlashMenuPositioner()
    var isOpen: Bool { panel?.isVisible == true }

    func update() {
        guard let editor, editor.window?.firstResponder === editor, !editor.hasMarkedText(),
              let query = SlashCommand.query(in: editor.string, selection: editor.selectedRange()) else {
            dismiss(); dismissedRange = nil; return
        }
        if dismissedRange?.location == query.range.location { return }
        let next = SlashCommand.matching(query.filter)
        guard !next.isEmpty else { dismiss(); return }
        if queryRange != query.range { selected = 0 }
        if queryRange?.location != query.range.location { positioner.reset() }
        queryRange = query.range
        commands = next
        selected = min(selected, commands.count - 1)
        show()
    }

    func handle(_ event: NSEvent) -> Bool {
        guard isOpen, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        switch event.keyCode {
        case 125: selected = (selected + 1) % commands.count; highlight(); return true
        case 126: selected = (selected + commands.count - 1) % commands.count; highlight(); return true
        case 36, 76: accept(); return true
        case 53: dismissedRange = queryRange; dismiss(); return true
        default: return false
        }
    }

    func dismiss() {
        if let panel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
        panel = nil; scroll = nil; rows = []; queryRange = nil; positioner.reset()
    }

    private func show() {
        guard let editor, let window = editor.window else { return }
        if panel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isReleasedWhenClosed = false
            p.hasShadow = false
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hidesOnDeactivate = true
            p.animationBehavior = .none
            panel = p
            window.addChildWindow(p, ordered: .above)
        }
        guard let panel else { return }
        panel.appearance = editor.effectiveAppearance
        editor.effectiveAppearance.performAsCurrentDrawingAppearance {
            let width = SlashMenuStyle.width
            let inset = SlashMenuStyle.inset
            let rowHeight = SlashMenuStyle.rowHeight
            let headerHeight = SlashMenuStyle.headerHeight
            let contentHeight = SlashMenuStyle.contentHeight(commands)
            let height = SlashMenuStyle.menuHeight(commands)
            let shadowInset = SlashMenuStyle.shadowInset
            let dark = SlashMenuStyle.isDark(editor.effectiveAppearance)
            let root = NSView(frame: NSRect(x: 0, y: 0, width: width + shadowInset * 2, height: height + shadowInset * 2))
            root.wantsLayer = true
            let card = NSRect(x: shadowInset, y: shadowInset, width: width, height: height)
            let cardPath = CGPath(roundedRect: CGRect(origin: .zero, size: card.size), cornerWidth: 8, cornerHeight: 8, transform: nil)
            // A tight contact shadow plus a larger diffuse one.
            for (opacity, radius, offset) in [(dark ? 0.45 : 0.10, 1.5 as CGFloat, -1 as CGFloat),
                                              (dark ? 0.50 : 0.14, 14 as CGFloat, -7 as CGFloat)] {
                let shadow = CALayer()
                shadow.frame = card
                shadow.shadowPath = cardPath
                shadow.shadowColor = NSColor.black.cgColor
                shadow.shadowOpacity = Float(opacity)
                shadow.shadowRadius = radius
                shadow.shadowOffset = CGSize(width: 0, height: offset)
                root.layer?.addSublayer(shadow)
            }
            let container = NSView(frame: card)
            container.wantsLayer = true
            container.layer?.cornerRadius = 8
            container.layer?.masksToBounds = true
            container.layer?.backgroundColor = SlashMenuStyle.surface.cgColor
            container.layer?.borderWidth = 0.75
            container.layer?.borderColor = SlashMenuStyle.border.cgColor
            root.addSubview(container)
            let stack = SlashMenuStack()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 0
            stack.frame = NSRect(x: 0, y: 0, width: width - inset * 2, height: contentHeight)
            var previousSection: String?
            rows = commands.enumerated().map { index, command in
                if command.section != previousSection {
                    let header = NSView()
                    let label = NSTextField(labelWithString: command.section)
                    label.font = .systemFont(ofSize: 10.5, weight: .semibold)
                    label.textColor = Paper.muted
                    label.frame = NSRect(x: 10, y: 3, width: width - 32, height: 14)
                    header.addSubview(label)
                    header.widthAnchor.constraint(equalToConstant: width - inset * 2).isActive = true
                    header.heightAnchor.constraint(equalToConstant: headerHeight).isActive = true
                    stack.addArrangedSubview(header)
                    previousSection = command.section
                }
                let button = SlashMenuRow(title: command.title, target: self, action: #selector(clicked(_:)))
                button.symbol = command.icon.nsImage
                button.headingLevel = command.title.hasPrefix("Heading ") ? String(command.title.suffix(1)) : nil
                button.tag = index
                button.isBordered = false
                button.alignment = .left
                button.font = .systemFont(ofSize: 12)
                button.setAccessibilityLabel(command.title)
                button.wantsLayer = true
                button.layer?.cornerRadius = 5
                button.widthAnchor.constraint(equalToConstant: width - inset * 2).isActive = true
                button.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
                stack.addArrangedSubview(button)
                return button
            }
            let scroll = NSScrollView(frame: container.bounds.insetBy(dx: inset, dy: inset))
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = false
            scroll.hasHorizontalScroller = false
            scroll.documentView = stack
            container.addSubview(scroll)
            self.scroll = scroll
            panel.contentView = root
            let anchor = NSRange(location: queryRange?.location ?? editor.selectedRange().location, length: 0)
            let caret = editor.firstRect(forCharacterRange: anchor, actualRange: nil)
            let screen = window.screen?.visibleFrame ?? window.frame
            let editorArea = window.convertToScreen(editor.convert(editor.visibleRect, to: nil))
            let visible = editorArea.intersection(screen).isEmpty ? screen : editorArea.intersection(screen)
            let frame = positioner.frame(caret: caret, size: NSSize(width: width, height: height),
                                         maxHeight: SlashMenuStyle.menuHeight(SlashCommand.all), visible: visible)
            panel.setFrame(frame.insetBy(dx: -shadowInset, dy: -shadowInset), display: true, animate: false)
            container.layoutSubtreeIfNeeded()
            stack.layoutSubtreeIfNeeded()
            highlight()
            panel.orderFront(nil)
        }
    }

    private func highlight() {
        guard let editor else { return }
        editor.effectiveAppearance.performAsCurrentDrawingAppearance {
            for (index, row) in rows.enumerated() {
                row.contentTintColor = Paper.ink
                row.layer?.backgroundColor = index == selected ? SlashMenuStyle.selection.cgColor : NSColor.clear.cgColor
            }
            if rows.indices.contains(selected) { rows[selected].scrollToVisible(rows[selected].bounds) }
        }
    }

    @objc private func clicked(_ sender: NSButton) { selected = sender.tag; accept() }

    private func accept() {
        guard let editor, let range = queryRange, commands.indices.contains(selected),
              let current = SlashCommand.query(in: editor.string, selection: editor.selectedRange()), current.range == range else { dismiss(); return }
        let command = commands[selected]
        dismiss()
        editor.insertSlashCommand(command, replacing: range)
    }
}

extension WritingTextView {
    func insertSlashCommand(_ command: SlashCommand, replacing range: NSRange) {
        let source = string as NSString
        guard NSMaxRange(range) <= source.length else { return }
        let prefix = command.block && range.location > 0 && source.character(at: range.location - 1) != 10 ? "\n" : ""
        let suffix = command.block && NSMaxRange(range) < source.length && source.character(at: NSMaxRange(range)) != 10 && !command.template.hasSuffix("\n") ? "\n" : ""
        breakUndoCoalescing()
        insertText(prefix + command.template + suffix, replacementRange: range)
        if let placeholder = command.placeholder {
            let target = (command.template as NSString).range(of: placeholder)
            setSelectedRange(NSRange(location: range.location + (prefix as NSString).length + target.location, length: target.length))
        }
        window?.makeFirstResponder(self)
    }
}
