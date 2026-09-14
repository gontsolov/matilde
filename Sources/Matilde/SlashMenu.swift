import AppKit

struct SlashCommand {
    let title: String
    let symbol: String
    let keywords: String
    let template: String
    let placeholder: String?
    let block: Bool

    static let all: [SlashCommand] = (1...6).map {
        SlashCommand(title: "Heading \($0)", symbol: "textformat.size", keywords: "h\($0) title heading", template: String(repeating: "#", count: $0) + " Heading", placeholder: "Heading", block: true)
    } + [
        .init(title: "Bullet list", symbol: "list.bullet", keywords: "ul unordered bullet list", template: "- Item", placeholder: "Item", block: true),
        .init(title: "Numbered list", symbol: "list.number", keywords: "ol ordered numbered list", template: "1. Item", placeholder: "Item", block: true),
        .init(title: "Checkbox", symbol: "checkmark.square", keywords: "todo task checklist checkbox", template: "- [ ] Task", placeholder: "Task", block: true),
        .init(title: "Quote", symbol: "text.quote", keywords: "blockquote quote", template: "> Quote", placeholder: "Quote", block: true),
        .init(title: "Divider", symbol: "minus", keywords: "horizontal rule divider line", template: "---\n", placeholder: nil, block: true),
        .init(title: "Code block", symbol: "curlybraces", keywords: "fenced code block", template: "```\nCode\n```", placeholder: "Code", block: true),
        .init(title: "Bold", symbol: "bold", keywords: "strong bold", template: "**text**", placeholder: "text", block: false),
        .init(title: "Italic", symbol: "italic", keywords: "emphasis italic", template: "*text*", placeholder: "text", block: false),
        .init(title: "Inline code", symbol: "chevron.left.forwardslash.chevron.right", keywords: "inline code monospace", template: "`code`", placeholder: "code", block: false),
        .init(title: "Link", symbol: "link", keywords: "url link", template: "[text](https://example.com)", placeholder: "https://example.com", block: false),
        .init(title: "Image", symbol: "photo", keywords: "local image picture photo", template: "![Image](image.png)", placeholder: "image.png", block: true)
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

private final class SlashMenuStack: NSStackView {
    override var isFlipped: Bool { true }
}

/// Draw explicit content insets instead of relying on NSButtonCell's title margins.
private final class SlashMenuRow: NSButton {
    var symbol: NSImage?
    var headingLevel: String?

    override func draw(_ dirtyRect: NSRect) {
        let ink = contentTintColor ?? Paper.ink
        let iconRect = NSRect(x: 12, y: (bounds.height - 18) / 2, width: 18, height: 18)
        if let headingLevel {
            let mark = "H" + headingLevel
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: ink.withAlphaComponent(0.48)
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
                ink.withAlphaComponent(0.48).setFill()
                rect.fill(using: .sourceIn)
                return true
            }
            tinted.draw(in: rect)
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: ink
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: 40, y: (bounds.height - size.height) / 2),
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
        panel = nil; scroll = nil; rows = []; queryRange = nil
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
            let width: CGFloat = 248
            let inset: CGFloat = 6
            let rowHeight: CGFloat = 34
            let sectionCount = Set(commands.map(\.section)).count
            let contentHeight = CGFloat(commands.count) * rowHeight + CGFloat(sectionCount) * 28
            let height = min(contentHeight, 352) + inset * 2
            let shadowInset: CGFloat = 10
            let root = NSView(frame: NSRect(x: 0, y: 0, width: width + shadowInset * 2, height: height + shadowInset * 2))
            root.wantsLayer = true
            let container = NSView(frame: NSRect(x: shadowInset, y: shadowInset, width: width, height: height))
            container.wantsLayer = true
            container.layer?.cornerRadius = 8
            container.layer?.backgroundColor = Paper.background.cgColor
            container.layer?.borderWidth = 0.5
            container.layer?.borderColor = Paper.ink.withAlphaComponent(0.10).cgColor
            container.layer?.shadowColor = NSColor.black.cgColor
            container.layer?.shadowOpacity = 0.08
            container.layer?.shadowRadius = 5
            container.layer?.shadowOffset = CGSize(width: 0, height: -2)
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
                    label.font = .systemFont(ofSize: 11, weight: .semibold)
                    label.textColor = Paper.ink.withAlphaComponent(0.45)
                    label.frame = NSRect(x: 12, y: 6, width: width - 36, height: 16)
                    header.addSubview(label)
                    header.widthAnchor.constraint(equalToConstant: width - inset * 2).isActive = true
                    header.heightAnchor.constraint(equalToConstant: 28).isActive = true
                    stack.addArrangedSubview(header)
                    previousSection = command.section
                }
                let button = SlashMenuRow(title: command.title, target: self, action: #selector(clicked(_:)))
                button.symbol = NSImage(systemSymbolName: command.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
                button.headingLevel = command.title.hasPrefix("Heading ") ? String(command.title.suffix(1)) : nil
                button.tag = index
                button.isBordered = false
                button.alignment = .left
                button.font = .systemFont(ofSize: 12)
                button.setAccessibilityLabel(command.title)
                button.wantsLayer = true
                button.layer?.cornerRadius = 6
                button.widthAnchor.constraint(equalToConstant: width - inset * 2).isActive = true
                button.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
                stack.addArrangedSubview(button)
                return button
            }
            let scroll = NSScrollView(frame: container.bounds.insetBy(dx: inset, dy: inset))
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.scrollerStyle = .overlay
            scroll.autohidesScrollers = true
            scroll.documentView = stack
            container.addSubview(scroll)
            self.scroll = scroll
            panel.contentView = root
            let caret = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
            let screen = window.screen?.visibleFrame ?? window.frame
            let x = min(max(caret.minX, screen.minX + 4), screen.maxX - width - 4)
            let y = caret.minY - height - 4 >= screen.minY ? caret.minY - height - 4 : caret.maxY + 4
            panel.setFrame(NSRect(x: x - shadowInset, y: min(y, screen.maxY - height) - shadowInset, width: width + shadowInset * 2, height: height + shadowInset * 2), display: true, animate: false)
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
                row.layer?.backgroundColor = index == selected ? Paper.ink.withAlphaComponent(0.055).cgColor : NSColor.clear.cgColor
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
