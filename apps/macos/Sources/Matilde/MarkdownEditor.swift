import SwiftUI
import AppKit
import CoreText
import MatildeKit

extension NSAttributedString.Key {
    static let inlineCode = NSAttributedString.Key("MatildeInlineCode")
    static let codeBlock = NSAttributedString.Key("MatildeCodeBlock")
    static let divider = NSAttributedString.Key("MatildeDivider")
    static let quoteBlock = NSAttributedString.Key("MatildeQuoteBlock")
    static let concealed = NSAttributedString.Key("MatildeConcealed")
    static let replacement = NSAttributedString.Key("MatildeReplacement")
}

enum Paper {
    private static func adaptive(_ name: String, light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: NSColor.Name("Matilde." + name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
    static let background = adaptive("paper", light: NSColor(calibratedRed: 0.976, green: 0.965, blue: 0.938, alpha: 1),
                                     dark: NSColor(calibratedRed: 0.13, green: 0.132, blue: 0.135, alpha: 1))
    static let ink = adaptive("ink", light: NSColor(calibratedRed: 0.24, green: 0.25, blue: 0.22, alpha: 1),
                              dark: NSColor(calibratedRed: 0.87, green: 0.87, blue: 0.86, alpha: 1))
    static let muted = adaptive("muted", light: NSColor(calibratedRed: 0.48, green: 0.48, blue: 0.43, alpha: 1),
                                dark: NSColor(calibratedRed: 0.62, green: 0.625, blue: 0.63, alpha: 1))
    static let accent = adaptive("accent", light: NSColor(calibratedRed: 0.48, green: 0.32, blue: 0.23, alpha: 1),
                                 dark: NSColor(calibratedRed: 0.69, green: 0.65, blue: 0.60, alpha: 1))
    static let sidebar = adaptive("sidebar", light: NSColor(calibratedRed: 0.955, green: 0.949, blue: 0.933, alpha: 1),
                                  dark: NSColor(calibratedRed: 0.105, green: 0.107, blue: 0.11, alpha: 1))
    static let canvas = adaptive("canvas", light: NSColor(calibratedRed: 0.916, green: 0.915, blue: 0.890, alpha: 1),
                                 dark: NSColor(calibratedRed: 0.085, green: 0.087, blue: 0.09, alpha: 1))
    static let underside = adaptive("underside", light: NSColor(calibratedRed: 0.955, green: 0.940, blue: 0.900, alpha: 1),
                                    dark: NSColor(calibratedRed: 0.18, green: 0.182, blue: 0.185, alpha: 1))
    static let codeBackground = adaptive("code", light: NSColor.black.withAlphaComponent(0.04),
                                         dark: NSColor.white.withAlphaComponent(0.06))
    private static var fontBundle: Bundle { MatildeResources.bundle }
    private static let newsreader: [CTFontDescriptor] = {
        let fonts = ["Newsreader", "Newsreader-Italic"]
        for name in fonts {
            if let url = fontBundle.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
        return fonts.compactMap { name in
            guard let url = fontBundle.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts") else { return nil }
            return (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])?.first
        }
    }()
    static func body(_ size: CGFloat = 19, bold: Bool = false, italic: Bool = false, weight: Double? = nil) -> NSFont {
        guard newsreader.count == 2 else { return .systemFont(ofSize: size, weight: bold ? .bold : .regular) }
        let axes: [NSNumber: NSNumber] = [
            NSNumber(value: 0x77676874): NSNumber(value: weight ?? (bold ? 700 : 400)),
            NSNumber(value: 0x6F70737A): NSNumber(value: Double(size))
        ]
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(newsreader[italic ? 1 : 0], [kCTFontVariationAttribute: axes] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
    }
    static let headingWeight: Double = 600
    static func emphasize(_ font: NSFont, trait: NSFontTraitMask) -> NSFont {
        let traits = NSFontManager.shared.traits(of: font)
        // Keep a heading's own weight when only italics are added inside it.
        let axes = CTFontCopyVariation(font) as? [NSNumber: NSNumber]
        let weight = trait == .boldFontMask ? nil : axes?[NSNumber(value: 0x77676874)]?.doubleValue
        return body(font.pointSize, bold: trait == .boldFontMask || traits.contains(.boldFontMask),
                    italic: trait == .italicFontMask || traits.contains(.italicFontMask), weight: weight)
    }
}

/// The text storage remains lossless Markdown; only glyphs and attributes change.
/// Hidden delimiters consume no space, so no render/serialize cycle can rewrite a file.
enum MarkdownStyler {
    static func style(_ storage: NSMutableAttributedString, textSize: CGFloat = 19, lineSpacing: CGFloat = 9) {
        let textSize = min(26, max(16, textSize))
        let lineSpacing = min(12, max(2, lineSpacing))
        let full = NSRange(location: 0, length: storage.length)
        // Every line gets its own paragraph style below; vertical space comes only from
        // these styles (Typography), never from characters added to the Markdown.
        func blockStyle(_ block: Typography.Block) -> NSMutableParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = Typography.lineSpacing(for: block, bodyLineSpacing: lineSpacing, textSize: textSize)
            return style
        }
        storage.setAttributes([.font: Paper.body(textSize), .foregroundColor: Paper.ink, .paragraphStyle: blockStyle(.paragraph)], range: full)
        let source = storage.string as NSString
        let blankHeight = Typography.blankLineHeight(textSize: textSize)
        var lines: [(range: NSRange, block: Typography.Block?, style: NSMutableParagraphStyle)] = []
        var offset = 0
        var fence: String?
        var codeRanges: [NSRange] = []
        // Nested list items are indented by their depth, not by however many spaces they use.
        let listDepths = MarkdownEditing.listDepths(in: storage.string)
        for line in storage.string.components(separatedBy: "\n") {
            let length = (line as NSString).length
            let range = NSRange(location: offset, length: length)
            defer { offset += length + 1 }
            let paragraphRange = NSRange(location: offset, length: min(length + 1, storage.length - offset))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard fence != nil || !trimmed.isEmpty else {
                // An empty line keeps the normal font and caret height: exactly one body line,
                // with no spacing of its own. It counts toward the gap between its neighbours.
                let gap = NSMutableParagraphStyle()
                gap.minimumLineHeight = blankHeight
                gap.maximumLineHeight = blankHeight
                lines.append((paragraphRange, nil, gap))
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))
                if fence == nil { fence = marker } else if fence == marker { fence = nil }
                conceal(range, in: storage)
                codeRanges.append(range)
                lines.append((paragraphRange, .code, blockStyle(.code)))
                continue
            }
            if fence != nil {
                storage.addAttribute(.codeBlock, value: true, range: range)
                storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular), .backgroundColor: Paper.codeBackground], range: range)
                codeRanges.append(range)
                lines.append((paragraphRange, .code, blockStyle(.code)))
                continue
            }
            if trimmed == "---" {
                // Keep ordinary glyph metrics for caret/line placement, but draw
                // a rule instead of the dashes. The Markdown stays untouched.
                storage.addAttributes([.divider: true, .foregroundColor: NSColor.clear], range: range)
                lines.append((paragraphRange, .divider, blockStyle(.divider)))
                continue
            }
            var block: Typography.Block = .paragraph
            var style = blockStyle(.paragraph)
            if let marker = first("^(\\s*)([-*+] |[0-9]+[.)] )", in: line) {
                block = .list
                style = blockStyle(.list)
                // Match the rendered marker, not an arbitrary hanging indent.
                // Replacement glyphs and concealed task syntax change its width.
                let font = Paper.body(textSize)
                let indentation = marker.range(at: 1)
                let depth = CGFloat(listDepths[offset] ?? 0)
                let nesting = depth * textSize * 1.4
                if indentation.length > 0 { conceal(NSRange(location: offset, length: indentation.length), in: storage) }
                let prefix: String
                if first("^(\\s*)[-*+] \\[([ xX])\\] ", in: line) != nil {
                    let symbolFont = NSFont(name: "Apple Symbols", size: 23) ?? NSFont.systemFont(ofSize: 19)
                    let checked = first("^(\\s*)[-*+] \\[[xX]\\] ", in: line) != nil
                    style.headIndent = nesting
                        + ((checked ? "☑" : "☐") as NSString).size(withAttributes: [.font: symbolFont]).width
                        + (" " as NSString).size(withAttributes: [.font: font]).width
                } else {
                    prefix = first("^(\\s*)[-*+] ", in: line) != nil
                        ? "• " : (line as NSString).substring(with: marker.range(at: 2))
                    style.headIndent = nesting + (prefix as NSString).size(withAttributes: [.font: font]).width
                }
                style.firstLineHeadIndent = nesting
            } else if first(EditorImage.linePattern, in: line) != nil {
                // The image itself is laid out by styleImages, which keeps this spacing.
                block = .image
            }
            if let match = first("^(#{1,6}) ", in: line) {
                let level = match.range(at: 1).length
                block = .heading(level)
                style = blockStyle(block)
                // Headings sit clearly below the document title (31 pt, 700) in size and weight.
                let size = Typography.headingSize(level: level, textSize: textSize)
                storage.addAttribute(.font, value: Paper.body(size, bold: true, weight: Paper.headingWeight), range: range)
                conceal(NSRange(location: offset, length: match.range.length), in: storage)
            } else if let match = first("^(\\s*)[-*+] \\[([ xX])\\] ", in: line) {
                let start = offset + match.range(at: 1).length
                let checked = (line as NSString).substring(with: match.range(at: 2)).lowercased() == "x"
                storage.addAttributes([.replacement: checked ? "☑" : "☐", .font: NSFont(name: "Apple Symbols", size: 23) ?? NSFont.systemFont(ofSize: 19)], range: NSRange(location: start, length: 1))
                conceal(NSRange(location: start + 1, length: 4), in: storage)
                if checked { storage.addAttribute(.foregroundColor, value: Paper.muted, range: range) }
                storage.addAttribute(.foregroundColor, value: NSColor.clear, range: NSRange(location: start, length: 1))
            } else if let match = first("^(\\s*)[-*+] ", in: line) {
                storage.addAttributes([.replacement: "•", .foregroundColor: Paper.muted], range: NSRange(location: offset + match.range(at: 1).length, length: 1))
            } else if let match = first("^\\s*[0-9]+[.)]", in: line) {
                storage.addAttribute(.foregroundColor, value: Paper.muted, range: NSRange(location: offset, length: match.range.length))
            } else if let match = first("^> ?", in: line) {
                block = .quote
                style = blockStyle(.quote)
                storage.addAttribute(.quoteBlock, value: true, range: paragraphRange)
                style.headIndent = 24; style.firstLineHeadIndent = 24
                conceal(NSRange(location: offset, length: match.range.length), in: storage)
            }
            lines.append((paragraphRange, block, style))
        }
        let spacings = Typography.paragraphSpacings(for: lines.map { $0.block }, textSize: textSize, blankLineHeight: blankHeight)
        for (line, spacing) in zip(lines, spacings) where line.range.length > 0 {
            line.style.paragraphSpacing = spacing
            storage.addAttribute(.paragraphStyle, value: line.style, range: line.range)
        }
        // Code spans are protected from subsequent inline styling.
        matches("`([^`\\n]+)`", in: storage.string).forEach { match in
            guard !codeRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { return }
            let content = match.range(at: 1)
            let codeFont = NSFont.monospacedSystemFont(ofSize: textSize * 15 / 19, weight: .regular)
            let baselineOffset = (Paper.body(textSize).xHeight - codeFont.xHeight) / 2
            storage.addAttributes([.font: codeFont, .inlineCode: true, .baselineOffset: baselineOffset], range: content)
            conceal(NSRange(location: match.range.location, length: 1), in: storage)
            conceal(NSRange(location: NSMaxRange(content), length: 1), in: storage)
            codeRanges.append(match.range)
        }
        for (pattern, trait, marker) in [
            ("(?<![\\\\*])\\*\\*([^*\\n]+)\\*\\*", NSFontTraitMask.boldFontMask, 2),
            ("(?<![\\\\_])__([^_\\n]+)__", .boldFontMask, 2),
            ("(?<![\\\\*])\\*([^*\\n]+)\\*(?!\\*)", .italicFontMask, 1),
            ("(?<![\\w\\\\_])_([^_\\n]+)_(?!\\w)", .italicFontMask, 1)
        ] {
            for match in matches(pattern, in: storage.string) {
                guard !codeRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }), storage.attribute(.concealed, at: match.range.location, effectiveRange: nil) == nil else { continue }
                let content = match.range(at: 1)
                storage.enumerateAttribute(.font, in: content) { value, range, _ in
                    storage.addAttribute(.font, value: Paper.emphasize(value as? NSFont ?? Paper.body(), trait: trait), range: range)
                }
                conceal(NSRange(location: match.range.location, length: marker), in: storage)
                conceal(NSRange(location: NSMaxRange(content), length: marker), in: storage)
            }
        }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let explicitLinks = matches(EditorLinks.pattern, in: storage.string).map(\.range)
            for match in detector.matches(in: storage.string, range: full) {
                guard let url = match.url, EditorLinks.destination(url.absoluteString) != nil,
                      !explicitLinks.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                      !codeRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
                storage.addAttributes([.link: url, .foregroundColor: Paper.accent,
                                       .underlineStyle: NSUnderlineStyle.single.rawValue], range: match.range)
            }
        }
        for match in matches(EditorLinks.pattern, in: storage.string) {
            guard !codeRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            let label = match.range(at: 1), destination = source.substring(with: match.range(at: 2))
            if let url = URL(string: destination), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                storage.addAttributes([.link: url, .foregroundColor: Paper.accent, .underlineStyle: NSUnderlineStyle.single.rawValue], range: label)
                for escape in matches(#"\\[\\\[\]]"#, in: source.substring(with: label)) {
                    conceal(NSRange(location: label.location + escape.range.location, length: 1), in: storage)
                }
                conceal(NSRange(location: match.range.location, length: 1), in: storage)
                conceal(NSRange(location: NSMaxRange(label), length: NSMaxRange(match.range) - NSMaxRange(label)), in: storage)
            }
        }
    }
    static func conceal(_ range: NSRange, in storage: NSMutableAttributedString) {
        storage.addAttribute(.concealed, value: true, range: range)
    }
    static func first(_ pattern: String, in string: String) -> NSTextCheckingResult? { matches(pattern, in: string).first }
    static func matches(_ pattern: String, in string: String) -> [NSTextCheckingResult] {
        (try? NSRegularExpression(pattern: pattern))?.matches(in: string, range: NSRange(location: 0, length: (string as NSString).length)) ?? []
    }
}

/// Constrain the SwiftUI proposal before asking for fitting height. An unconstrained
/// fittingSize measures a single-line title, then centers wrapped content in that
/// undersized frame, moving the controls upward and overlapping the body.
final class WritingHeaderView: NSHostingView<AnyView> {
    private var content: AnyView
    private var measuredWidth: CGFloat = -1

    init(content: AnyView) {
        self.content = content
        super.init(rootView: content)
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    required init(rootView: AnyView) {
        content = rootView
        super.init(rootView: rootView)
    }

    func update(content: AnyView) {
        self.content = content
        let width = measuredWidth
        measuredWidth = -1
        measure(at: max(0, width))
    }

    /// SwiftUI reports later size changes of the header (a title rewrapping, the drafts tray)
    /// here; re-lay out the writing view now so the body follows in the same frame.
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        guard let editor = superview as? WritingTextView, !editor.isLayingOut else { return }
        editor.needsLayout = true
    }

    func measure(at width: CGFloat) {
        guard measuredWidth != width else { return }
        measuredWidth = width
        rootView = AnyView(content.frame(width: width, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true))
    }
}

final class WritingTextView: NSTextView {
    var onAskSelection: ((NSRange?) -> Void)?
    var selectionAssistPanel: SelectionAssistPanel?
    var commentStore: UserCommentStore? { didSet { if commentStore !== oldValue { observeComments() } } }
    var commentObservation: AnyObject?
    var commentPopover: NSPopover?
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        showSelectionAssist()
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        var items: [NSMenuItem] = []
        if onAskSelection != nil {
            let item = NSMenuItem(title: "Ask Matilde…", action: #selector(askAboutSelection), keyEquivalent: "a")
            item.keyEquivalentModifierMask = [.command, .shift]
            item.target = self
            items.append(item)
        }
        if let item = addCommentMenuItem { items.append(item) }
        if !items.isEmpty {
            menu.insertItem(.separator(), at: 0)
            for item in items.reversed() { menu.insertItem(item, at: 0) }
        }
        return menu
    }

    lazy var slashMenu: SlashMenuController = {
        let menu = SlashMenuController()
        menu.editor = self
        return menu
    }()
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "a", onAskSelection != nil {
            askAboutSelection(); return
        }
        if slashMenu.handle(event) { return }
        super.keyDown(with: event)
        slashMenu.update()
        showSelectionAssist()
    }
    override func resignFirstResponder() -> Bool {
        hideSelectionAssist()
        slashMenu.dismiss()
        return super.resignFirstResponder()
    }
    override func didChangeText() {
        super.didChangeText()
        updateSlashMenu()
        refreshBodyPlaceholder()
    }
    /// True between the text storage's beginEditing and the end of its processing, when layout
    /// and geometry queries are invalid (autocorrection can change text in that window).
    var isStorageEditing: Bool { !(textStorage?.editedMask.isEmpty ?? true) }
    func updateSlashMenu() {
        guard isStorageEditing else { slashMenu.update(); return }
        DispatchQueue.main.async { [weak self] in self?.slashMenu.update() }
    }

    var saveImage: ((Data) throws -> String)?
    var resolveImage: ((String) -> NSImage?)?
    var mediaError: ((String) -> Void)?
    var renderedImages: [EditorImage] = []
    var imageCache: [String: NSImage] = [:]
    private var imageLayoutWidth: CGFloat = -1

    override func paste(_ sender: Any?) {
        if pasteMedia(from: .general) { return }
        if !hasMarkedText(), let pasted = NSPasteboard.general.string(forType: .string),
           let edit = MarkdownEditing.paste(pasted, in: string, selection: selectedRange()) {
            applyMarkdownEdit(edit)
            return
        }
        super.paste(sender)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), isEditable, saveImage != nil,
           NSPasteboard.general.availableType(from: [.png, .tiff, .fileURL]) != nil { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.availableType(from: [.png, .tiff, .fileURL]) != nil { return .copy }
        return super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard saveImage != nil else { return super.performDragOperation(sender) }
        let pasteboard = sender.draggingPasteboard
        let point = convert(sender.draggingLocation, from: nil)
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first, urls.count == 1 {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32 * 1024 * 1024,
                  let data = try? Data(contentsOf: url), NSBitmapImageRep(data: data) != nil else { return false }
            do {
                let path = try saveImage!(data)
                let location = characterIndexForInsertion(at: point)
                insertText("\n\n![Image](\(path))\n\n", replacementRange: NSRange(location: location, length: 0))
                return true
            } catch { mediaError?(error.localizedDescription); return false }
        }
        if pasteboard.availableType(from: [.png, .tiff]) != nil {
            setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
            return pasteMedia(from: pasteboard)
        }
        return super.performDragOperation(sender)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        layoutManager?.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: (string as NSString).length))
    }
    private var ordinarySelectionAttributes: [NSAttributedString.Key: Any]?
    override func setSelectedRange(_ range: NSRange, affinity: NSSelectionAffinity, stillSelecting flag: Bool) {
        if ordinarySelectionAttributes == nil { ordinarySelectionAttributes = selectedTextAttributes }
        let isDivider = range.length > 0 && dividerRange(at: range.location) == range
        selectedTextAttributes = isDivider ? [.backgroundColor: NSColor.clear, .foregroundColor: NSColor.clear]
            : ordinarySelectionAttributes ?? selectedTextAttributes
        super.setSelectedRange(range, affinity: affinity, stillSelecting: flag)
        hideSelectionAssist()
        needsDisplay = true
    }
    var onPosition: ((Int, Double) -> Void)?
    var scrollingHeader: WritingHeaderView?
    override func accessibilityChildren() -> [Any]? {
        var children = super.accessibilityChildren() ?? []
        if let scrollingHeader { children.append(scrollingHeader) }
        return children
    }
    var onContentHeight: ((CGFloat) -> Void)?
    func reportContentHeight() {
        guard let onContentHeight, let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let used = max(layoutManager.usedRect(for: textContainer).maxY,
                       layoutManager.extraLineFragmentRect.maxY)
        onContentHeight(ceil(used + textContainerInset.height * 2))
    }
    /// Bottom of the lowest margin card in this view's coordinates; nil without cards.
    private var marginCardsBottom: CGFloat?
    /// Lets the page scroll far enough to show every margin card. The extra height is only
    /// scroll room: the text container is unchanged, and a click there puts the caret at the end.
    func setMarginCardsBottom(_ bottom: CGFloat?) {
        guard bottom != marginCardsBottom else { return }
        marginCardsBottom = bottom
        updateMarginRoom()
    }
    /// Re-evaluated on scrolling, so room kept for departed cards goes once it leaves the screen.
    func updateMarginRoom() {
        let visibleBottom = enclosingScrollView.map { convert($0.contentView.bounds, from: $0.contentView).maxY } ?? bounds.maxY
        // Same bottom padding as the text; contentHeight takes the larger with the text's own height.
        let target = marginCardsBottom.map { MarginScroll.contentHeight(textHeight: 0, bottomInset: textContainerInset.height, cardsBottom: $0) } ?? 0
        let height = MarginScroll.retainedHeight(target: target, previous: minSize.height, visibleBottom: visibleBottom)
        guard abs(height - minSize.height) > 0.5 else { return }
        minSize = NSSize(width: minSize.width, height: height)
        sizeToFit()
    }
    private(set) var headerHeight: CGFloat = 0
    private(set) var isLayingOut = false
    override func layout() {
        isLayingOut = true
        defer { isLayingOut = false }
        if imageLayoutWidth != bounds.width {
            imageLayoutWidth = bounds.width
            styleImages()
        }
        if let scrollingHeader {
            scrollingHeader.measure(at: bounds.width)
            scrollingHeader.frame.size.width = bounds.width
            let height = scrollingHeader.fittingSize.height
            scrollingHeader.frame = NSRect(x: 0, y: 0, width: bounds.width, height: height)
            if abs(height - headerHeight) > 0.5 {
                headerHeight = height
                textContainerInset = NSSize(width: 28, height: height + 20)
                sizeToFit()
                updateMarginRoom()
            }
        }
        super.layout()
        reportContentHeight()
    }
    /// Drawn, never inserted: the placeholder is not part of the text, the Markdown or undo.
    var bodyPlaceholder: String? {
        didSet {
            setAccessibilityPlaceholderValue(bodyPlaceholder)
            needsDisplay = true
        }
    }
    var showsBodyPlaceholder: Bool {
        bodyPlaceholder != nil && EditorLanding.showsBodyPlaceholder(textLength: (string as NSString).length, hasMarkedText: hasMarkedText())
    }
    /// The placeholder's first baseline and left edge match the caret on the empty first line.
    var bodyPlaceholderOrigin: NSPoint {
        let font = typingAttributes[.font] as? NSFont ?? Paper.body()
        var line = layoutManager?.extraLineFragmentRect ?? .zero
        if line.height <= 0 { line = NSRect(x: 0, y: 0, width: 0, height: layoutManager?.defaultLineHeight(for: font) ?? font.ascender - font.descender) }
        let baseline = layoutManager?.defaultBaselineOffset(for: font) ?? font.ascender
        return NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0),
                       y: textContainerOrigin.y + line.minY + baseline)
    }
    private func drawBodyPlaceholder() {
        guard showsBodyPlaceholder, let placeholder = bodyPlaceholder, let context = NSGraphicsContext.current?.cgContext else { return }
        let font = typingAttributes[.font] as? NSFont ?? Paper.body()
        let text = NSAttributedString(string: placeholder, attributes: [.font: font, .foregroundColor: Paper.muted.withAlphaComponent(0.7)])
        let line = CTLineCreateWithAttributedString(text)
        let origin = bodyPlaceholderOrigin
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: isFlipped ? -1 : 1)
        context.textPosition = origin
        CTLineDraw(line, context)
        context.restoreGState()
    }
    private var bodyPlaceholderWasShown = false
    func refreshBodyPlaceholder() {
        guard bodyPlaceholder != nil, showsBodyPlaceholder != bodyPlaceholderWasShown else { return }
        bodyPlaceholderWasShown = showsBodyPlaceholder
        needsDisplay = true
    }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        refreshBodyPlaceholder()
    }
    override func unmarkText() {
        super.unmarkText()
        refreshBodyPlaceholder()
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawBodyPlaceholder()
        bodyPlaceholderWasShown = showsBodyPlaceholder
        guard let storage = textStorage, let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        for item in renderedImages {
            let glyph = layoutManager.glyphIndexForCharacter(at: item.range.location)
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let rect = NSRect(x: origin.x + textContainer.lineFragmentPadding,
                              y: origin.y + line.minY + 6, width: item.size.width, height: item.size.height)
            guard rect.intersects(dirtyRect) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).addClip()
            item.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                            respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y), in: textContainer)
        let visibleCharacters = layoutManager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        storage.enumerateAttribute(.replacement, in: visibleCharacters) { value, range, _ in
            guard let symbol = value as? String, symbol == "☐" || symbol == "☑" else { return }
            let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let location = layoutManager.location(forGlyphAt: glyph)
            let bounds = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
            let side = min(bounds.width - 1, 15)
            let rect = NSRect(x: origin.x + bounds.minX + (bounds.width - side) / 2,
                              y: origin.y + line.minY + location.y - side + 1,
                              width: side, height: side)
            let box = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            let checked = symbol == "☑"
            (checked ? Paper.ink : Paper.ink.withAlphaComponent(0.12)).setFill()
            box.fill()
            if checked {
                let tick = NSBezierPath()
                tick.move(to: NSPoint(x: rect.minX + side * 0.24, y: rect.minY + side * 0.51))
                tick.line(to: NSPoint(x: rect.minX + side * 0.44, y: rect.minY + side * 0.71))
                tick.line(to: NSPoint(x: rect.minX + side * 0.77, y: rect.minY + side * 0.30))
                tick.lineWidth = 1.6
                tick.lineCapStyle = .round
                tick.lineJoinStyle = .round
                Paper.background.setStroke()
                tick.stroke()
            }
        }
        storage.enumerateAttribute(.divider, in: visibleCharacters) { value, range, _ in
            guard value != nil else { return }
            let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
            let rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let baseline = rect.minY + layoutManager.location(forGlyphAt: glyph).y
            let y = origin.y + baseline - Paper.body().xHeight / 2
            let padding = textContainer.lineFragmentPadding
            let selection = selectedRange()
            let selected = NSIntersectionRange(selection, range).length > 0 ||
                (selection.length == 0 && dividerRange(at: selection.location) == range)
            if selected {
                Paper.accent.withAlphaComponent(0.10).setFill()
                NSBezierPath(roundedRect: NSRect(x: origin.x + rect.minX + padding - 4, y: y - 8,
                                                width: max(0, rect.width - padding * 2 + 8), height: 16),
                             xRadius: 4, yRadius: 4).fill()
            }
            (selected ? Paper.accent.withAlphaComponent(0.65) : Paper.muted.withAlphaComponent(0.35)).setFill()
            NSBezierPath(rect: NSRect(x: origin.x + rect.minX + padding, y: y.rounded(),
                                     width: max(0, rect.width - padding * 2), height: 1)).fill()
        }
        storage.enumerateAttribute(.quoteBlock, in: visibleCharacters) { value, range, _ in
            guard value != nil else { return }
            // Null delimiter glyphs can belong to the preceding line fragment.
            // Anchor the rule to visible quote text instead.
            var start = range.location
            while start < NSMaxRange(range), storage.attribute(.concealed, at: start, effectiveRange: nil) != nil { start += 1 }
            guard start < NSMaxRange(range) else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: start, length: NSMaxRange(range) - start), actualCharacterRange: nil)
            var top: CGFloat?
            var bottom: CGFloat = 0
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, lineGlyphs, _ in
                let glyph = max(glyphs.location, lineGlyphs.location)
                let character = layoutManager.characterIndexForGlyph(at: glyph)
                let font = storage.attribute(.font, at: character, effectiveRange: nil) as? NSFont ?? Paper.body()
                let baseline = rect.minY + layoutManager.location(forGlyphAt: glyph).y
                // Align to the letters, excluding paragraph leading and spacing.
                top = min(top ?? .greatestFiniteMagnitude, baseline - font.capHeight - 3)
                bottom = max(bottom, baseline - font.descender + 3)
            }
            guard let top else { return }
            Paper.muted.withAlphaComponent(0.55).setFill()
            NSBezierPath(rect: NSRect(x: origin.x + textContainer.lineFragmentPadding, y: origin.y + top, width: 2, height: bottom - top)).fill()
        }
    }

    func dividerRange(at location: Int) -> NSRange? {
        let source = string as NSString
        guard location <= source.length, let storage = textStorage, source.length > 0 else { return nil }
        let line = source.lineRange(for: NSRange(location: location, length: 0))
        guard line.location < storage.length,
              storage.attribute(.divider, at: line.location, effectiveRange: nil) != nil else { return nil }
        let content = source.substring(with: line).trimmingCharacters(in: .newlines)
        return NSRange(location: line.location, length: (content as NSString).length)
    }

    /// Navigation never leaves a caret inside a divider. At document boundaries,
    /// select the block instead of inserting text merely to make a landing spot.
    func skipDivider(forward: Bool) {
        guard selectedRange().length == 0 else { return }
        let source = string as NSString
        var position = selectedRange().location
        while let divider = dividerRange(at: position) {
            let line = source.lineRange(for: NSRange(location: divider.location, length: 0))
            if forward, NSMaxRange(line) > NSMaxRange(divider) {
                position = NSMaxRange(line)
            } else if !forward, divider.location > 0 {
                position = divider.location - 1
            } else {
                setSelectedRange(divider)
                return
            }
        }
        setSelectedRange(NSRange(location: position, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    override func moveUp(_ sender: Any?) { super.moveUp(sender); skipDivider(forward: false); skipHiddenLineStart() }
    override func moveDown(_ sender: Any?) { super.moveDown(sender); skipDivider(forward: true); skipHiddenLineStart() }
    override func moveLeft(_ sender: Any?) {
        guard selectedRange().length == 0 else { super.moveLeft(sender); return }
        leaveConcealed(forward: false)
        super.moveLeft(sender)
        settleCaret(forward: false)
        skipDivider(forward: false)
    }
    override func moveRight(_ sender: Any?) {
        guard selectedRange().length == 0 else { super.moveRight(sender); return }
        leaveConcealed(forward: true)
        super.moveRight(sender)
        settleCaret(forward: true)
        skipDivider(forward: true)
    }
    override func moveToBeginningOfLine(_ sender: Any?) { super.moveToBeginningOfLine(sender); skipHiddenLineStart() }
    override func moveToLeftEndOfLine(_ sender: Any?) { super.moveToLeftEndOfLine(sender); skipHiddenLineStart() }

    // MARK: Hidden Markdown and the caret (EDIT-31)

    func isConcealed(_ index: Int) -> Bool {
        guard let storage = textStorage, index >= 0, index < storage.length,
              (string as NSString).character(at: index) != 10 else { return false }
        return storage.attribute(.concealed, at: index, effectiveRange: nil) != nil
    }

    /// Arrow keys never stop on positions the reader cannot see: hidden `**`, `#`, link
    /// destinations or list indentation are stepped over, so every press moves the caret
    /// visibly. Before the move, the caret leaves the hidden run it touches in that direction.
    func leaveConcealed(forward: Bool) {
        var position = selectedRange().location
        let start = position
        if forward { while isConcealed(position) { position += 1 } }
        else { while position > 0, isConcealed(position - 1) { position -= 1 } }
        if position != start { setSelectedRange(NSRange(location: position, length: 0)) }
    }

    /// After the move, a caret inside a hidden run goes to the run's edge in the direction of
    /// travel; a caret at the start of a line with hidden marks goes after them.
    func settleCaret(forward: Bool) {
        guard selectedRange().length == 0 else { return }
        var position = selectedRange().location
        let start = position
        guard isConcealed(position) else { return }
        guard isConcealed(position - 1) else { skipHiddenLineStart(); return }
        if forward { while isConcealed(position) { position += 1 } }
        else { while position > 0, isConcealed(position - 1) { position -= 1 } }
        if position != start { setSelectedRange(NSRange(location: position, length: 0)) }
    }

    /// A caret at the very start of a line whose first characters are hidden (a heading's `#`,
    /// a quote's `>`, a nested item's indentation) moves to after them, where typing belongs.
    func skipHiddenLineStart() {
        guard selectedRange().length == 0 else { return }
        let source = string as NSString
        var position = selectedRange().location
        guard position < source.length,
              source.lineRange(for: NSRange(location: position, length: 0)).location == position,
              textStorage?.attribute(.codeBlock, at: position, effectiveRange: nil) == nil else { return }
        while isConcealed(position) { position += 1 }
        // A fully hidden line (a code fence) keeps its caret where it was.
        guard position != selectedRange().location, position < source.length, source.character(at: position) != 10 else { return }
        setSelectedRange(NSRange(location: position, length: 0))
    }

    /// Applies one shared editing rule (MatildeKit's MarkdownEditing) as its own undo step.
    func applyMarkdownEdit(_ edit: MarkdownEdit) {
        breakUndoCoalescing()
        if !edit.isSelectionOnly {
            guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
            textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
            didChangeText()
        }
        setSelectedRange(edit.selection)
        scrollRangeToVisible(edit.selection)
        breakUndoCoalescing()
    }

    func alignedCaretRect(_ rect: NSRect) -> NSRect {
        guard let storage = textStorage, let layoutManager, storage.length > 0 else { return rect }
        let position = min(selectedRange().location, storage.length)
        // Native geometry remains appropriate for the trailing empty paragraph.
        guard position < storage.length || !(string.hasSuffix("\n")) else { return rect }
        let character = min(position, storage.length - 1)
        let glyph = layoutManager.glyphIndexForCharacter(at: character)
        guard glyph < layoutManager.numberOfGlyphs else { return rect }
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let font = storage.attribute(.font, at: character, effectiveRange: nil) as? NSFont ?? Paper.body()
        let offset = storage.attribute(.baselineOffset, at: character, effectiveRange: nil) as? CGFloat ?? 0
        let baseline = textContainerOrigin.y + line.minY + layoutManager.location(forGlyphAt: glyph).y - offset
        return NSRect(x: rect.minX, y: baseline - font.capHeight - 2,
                      width: rect.width, height: font.capHeight - font.descender + 4)
    }
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard dividerRange(at: selectedRange().location) == nil else { return }
        let aligned = alignedCaretRect(rect)
        super.drawInsertionPoint(in: aligned, color: color, turnedOn: flag)
        // AppKit erases a blinking-off caret only within its own rect; the aligned caret can
        // reach a pixel or two past it, which used to leave a dot behind on every blink.
        if !flag { setNeedsDisplay(aligned.union(rect).insetBy(dx: -1, dy: -1), avoidAdditionalLayout: true) }
    }

    override func deleteBackward(_ sender: Any?) {
        if selectedRange().length == 0, let range = dividerRange(at: selectedRange().location) {
            insertText("", replacementRange: range)
        } else if !hasMarkedText(), let edit = MarkdownEditing.deleteBackward(in: string, selection: selectedRange(), options: .concealed) {
            applyMarkdownEdit(edit)
        } else {
            super.deleteBackward(sender)
        }
    }

    override func deleteToBeginningOfLine(_ sender: Any?) {
        if let edit = markdownDeletion(lineStart: true) { applyMarkdownEdit(edit) } else { super.deleteToBeginningOfLine(sender) }
    }

    override func deleteWordBackward(_ sender: Any?) {
        if let edit = markdownDeletion(lineStart: false) { applyMarkdownEdit(edit) } else { super.deleteWordBackward(sender) }
    }

    /// ⌘⌫ and ⌥⌫ around block markers (EDIT-31). They stop at the start of a heading's,
    /// list item's or quote's text instead of eating its hidden marker, so ⌘⌫ in an item keeps
    /// the bullet, and pressed again at the start of the text they act like Backspace (the
    /// marker goes or the item moves out). Emptying a heading this way removes its `#` too, so
    /// nothing hidden is left to turn the next words into a heading. `nil`: AppKit's own
    /// behaviour applies (no marker on the line, a selection, code, or a wrapped line further down).
    func markdownDeletion(lineStart: Bool) -> MarkdownEdit? {
        let selection = selectedRange()
        guard !hasMarkedText(), selection.length == 0, selection.location != NSNotFound,
              let storage = textStorage else { return nil }
        let source = string as NSString
        let caret = selection.location
        let line = source.lineRange(for: NSRange(location: caret, length: 0))
        // At the very start of a line (an empty line included) both act like Backspace, as in
        // other Mac editors: the line break goes and the caret joins the line above.
        if caret == line.location, caret > 0 {
            if storage.attribute(.codeBlock, at: caret - 1, effectiveRange: nil) == nil,
               let edit = MarkdownEditing.deleteBackward(in: string, selection: selection, options: .concealed) { return edit }
            return MarkdownEdit(range: NSRange(location: caret - 1, length: 1), replacement: "", selection: NSRange(location: caret - 1, length: 0))
        }
        guard line.location < source.length,
              storage.attribute(.codeBlock, at: line.location, effectiveRange: nil) == nil else { return nil }
        let content = source.substring(with: line).trimmingCharacters(in: .newlines)
        let prefix = MarkdownLinePrefix.parse(content)
        guard prefix.length > 0 else { return nil }
        let contentStart = line.location + prefix.length
        guard caret >= contentStart else { return nil }
        if caret == contentStart {
            return MarkdownEditing.deleteBackward(in: string, selection: selection, options: .concealed)
        }
        var target: Int
        if lineStart {
            // The visual line: on a wrapped paragraph, ⌘⌫ only clears the fragment the caret is on.
            target = line.location
            if let layoutManager {
                let glyph = layoutManager.glyphIndexForCharacter(at: max(line.location, caret - 1))
                var fragment = NSRange()
                layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &fragment)
                target = layoutManager.characterRange(forGlyphRange: fragment, actualGlyphRange: nil).location
            }
            guard target <= contentStart else { return nil }
        } else {
            target = storage.nextWord(from: caret, forward: false)
        }
        target = max(target, contentStart)
        var range = NSRange(location: target, length: caret - target)
        let lineEnd = line.location + (content as NSString).length
        if case .heading = prefix.kind, target == contentStart, caret == lineEnd {
            range = NSRange(location: line.location, length: caret - line.location)
        }
        return MarkdownEdit(range: range, replacement: "", selection: NSRange(location: range.location, length: 0))
    }

    override func deleteForward(_ sender: Any?) {
        if !hasMarkedText(), let edit = MarkdownEditing.deleteForward(in: string, selection: selectedRange(), options: .concealed) {
            applyMarkdownEdit(edit)
        } else {
            super.deleteForward(sender)
        }
    }

    override func insertTab(_ sender: Any?) {
        if !hasMarkedText(), let edit = MarkdownEditing.indent(in: string, selection: selectedRange()) {
            applyMarkdownEdit(edit)
        } else {
            super.insertTab(sender)
        }
    }

    override func insertBacktab(_ sender: Any?) {
        if !hasMarkedText(), let edit = MarkdownEditing.outdent(in: string, selection: selectedRange()) {
            applyMarkdownEdit(edit)
        } else {
            super.insertBacktab(sender)
        }
    }

    override func insertLineBreak(_ sender: Any?) {
        guard !hasMarkedText() else { super.insertLineBreak(sender); return }
        applyMarkdownEdit(MarkdownEditing.insertLineBreak(in: string, selection: selectedRange()))
    }

    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) {
        if !hasMarkedText(), let onEscape { onEscape() } else { super.cancelOperation(sender) }
    }

    override func magnify(with event: NSEvent) {
        // The writing-space boundary owns pinch navigation, including tail events.
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let inserted = (insertString as? String) ?? (insertString as? NSAttributedString)?.string
        let range = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        if !hasMarkedText(), let inserted, ["-", "---"].contains(inserted), range.length == 0,
           NSMaxRange(range) <= (string as NSString).length {
            let proposed = (string as NSString).replacingCharacters(in: range, with: inserted)
            let caret = range.location + (inserted as NSString).length
            let source = proposed as NSString
            let line = source.lineRange(for: NSRange(location: max(0, caret - 1), length: 0))
            if source.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines) == "---",
               caret == NSMaxRange(line) || (caret == NSMaxRange(line) - 1 && source.character(at: caret) == 10) {
                let styled = NSMutableAttributedString(string: proposed)
                MarkdownStyler.style(styled)
                if styled.attribute(.divider, at: line.location, effectiveRange: nil) != nil {
                    super.insertText(inserted + "\n", replacementRange: replacementRange)
                    return
                }
            }
        }
        if !hasMarkedText(), let inserted, inserted.count == 1, range == selectedRange(),
           let edit = MarkdownEditing.insertText(inserted, in: string, selection: range, options: .concealed) {
            applyMarkdownEdit(edit)
            return
        }
        super.insertText(insertString, replacementRange: replacementRange)
    }

    @objc func insertCheckbox(_ sender: Any?) {
        let source = string as NSString
        let lineRange = source.lineRange(for: NSRange(location: min(selectedRange().location, source.length), length: 0))
        let line = source.substring(with: lineRange)
        let styled = NSMutableAttributedString(string: string)
        MarkdownStyler.style(styled)
        if lineRange.location < styled.length,
           styled.attribute(.codeBlock, at: lineRange.location, effectiveRange: nil) != nil { return }
        if let task = MarkdownStyler.first("^(\\s*)[-*+] \\[([ xX])\\] ", in: line) {
            let range = NSRange(location: lineRange.location + task.range(at: 2).location, length: 1)
            let selection = selectedRange()
            insertText(source.substring(with: range) == " " ? "x" : " ", replacementRange: range)
            setSelectedRange(selection)
        } else {
            let prefix = MarkdownStyler.first("^(\\s*)(?:[-*+] |[0-9]+[.)] )?", in: line)!
            let indent = (line as NSString).substring(with: prefix.range(at: 1))
            insertText(indent + "- [ ] ", replacementRange: NSRange(location: lineRange.location, length: prefix.range.length))
        }
    }

    override func insertNewline(_ sender: Any?) {
        if let divider = dividerRange(at: selectedRange().location),
           selectedRange() == divider {
            setSelectedRange(NSRange(location: NSMaxRange(divider), length: 0))
        }
        if !hasMarkedText(), let edit = MarkdownEditing.insertNewline(in: string, selection: selectedRange()) {
            applyMarkdownEdit(edit)
        } else {
            super.insertNewline(sender)
        }
    }
    override func mouseDown(with event: NSEvent) {
        defer { showSelectionAssist() }
        super.mouseDown(with: event)
        if event.clickCount == 1, selectedRange().length == 0, openComment(at: event) { return }
        if event.clickCount == 1 { skipHiddenLineStart() }
        if selectedRange().length == 0, let divider = dividerRange(at: selectedRange().location) {
            if event.clickCount == 1 { skipDivider(forward: true) }
            else { setSelectedRange(divider) }
            needsDisplay = true
            return
        }
        guard event.clickCount == 1, let layoutManager, let textContainer else { return }
        var point = convert(event.locationInWindow, from: nil)
        point.x -= textContainerOrigin.x; point.y -= textContainerOrigin.y
        let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs, selectedRange().length == 0,
              layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).contains(point) else { return }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < (string as NSString).length,
              textStorage?.attribute(.codeBlock, at: index, effectiveRange: nil) == nil else { return }
        let lineRange = (string as NSString).lineRange(for: NSRange(location: index, length: 0))
        let line = (string as NSString).substring(with: lineRange)
        if let match = MarkdownStyler.first("^(\\s*)[-*+] \\[([ xX])\\] ", in: line), index == lineRange.location + match.range(at: 1).length {
            let range = NSRange(location: lineRange.location + match.range(at: 2).location, length: 1)
            insertText((string as NSString).substring(with: range) == " " ? "x" : " ", replacementRange: range)
        }
    }
    func wrap(_ marker: String) {
        let source = string as NSString
        let range = selectedRange(), count = (marker as NSString).length
        guard range.location != NSNotFound, NSMaxRange(range) <= source.length else { return }
        func runLength(from start: Int, direction: Int) -> Int {
            var index = start, length = 0
            while index >= 0, index < source.length, source.character(at: index) == 42 {
                length += 1; index += direction
            }
            return length
        }
        let left = runLength(from: range.location - 1, direction: -1)
        let right = runLength(from: NSMaxRange(range), direction: 1)
        let surrounded = count == 1 ? left % 2 == 1 && right % 2 == 1 : left >= count && right >= count
        breakUndoCoalescing()
        let includesMarkers = range.length >= count * 2 &&
            (count == 1
             ? runLength(from: range.location, direction: 1) % 2 == 1 && runLength(from: NSMaxRange(range) - 1, direction: -1) % 2 == 1
             : runLength(from: range.location, direction: 1) >= count && runLength(from: NSMaxRange(range) - 1, direction: -1) >= count)
        if includesMarkers {
            let inner = NSRange(location: range.location + count, length: range.length - count * 2)
            insertText(source.substring(with: inner), replacementRange: range)
            setSelectedRange(NSRange(location: range.location, length: inner.length))
        } else if surrounded {
            let selected = source.substring(with: range)
            insertText(selected, replacementRange: NSRange(location: range.location - count, length: range.length + count * 2))
            setSelectedRange(NSRange(location: range.location - count, length: range.length))
        } else {
            let selected = source.substring(with: range)
            insertText(marker + selected + marker, replacementRange: range)
            setSelectedRange(NSRange(location: range.location + count, length: range.length))
        }
        breakUndoCoalescing()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            if event.charactersIgnoringModifiers == "b" { wrap("**"); return true }
            if event.charactersIgnoringModifiers == "i" { wrap("*"); return true }
            if event.charactersIgnoringModifiers == "k" { editLink(); return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct MarkdownEditor: NSViewRepresentable {
    let draftID: String
    let text: String
    let initialCursor: Int
    let initialScroll: Double
    var onChange: (String) -> Void
    var onPosition: (Int, Double) -> Void
    var focusOnLoad = true
    var onReady: (String) -> Void = { _ in }
    var header: AnyView? = nil
    var onHeaderVisibility: (Bool) -> Void = { _ in }
    var saveImage: ((Data) throws -> String)? = nil
    var resolveImage: ((String) -> NSImage?)? = nil
    var mediaError: (String) -> Void = { _ in }
    var textSize: Double = 19
    var lineSpacing: Double = 9
    var spellChecking = false

    var accessibilityName = "Writing editor"
    var onMount: (WritingTextView) -> Void = { _ in }
    var onEscape: (() -> Void)? = nil
    var textInsets = NSSize(width: 28, height: 20)
    var fragmentPadding: CGFloat = 5
    var onContentHeight: ((CGFloat) -> Void)? = nil

    var differenceRanges: [NSRange] = []
    var onAskSelection: ((NSRange?) -> Void)? = nil
    var commentStore: UserCommentStore? = nil
    /// Quiet hint drawn in an empty body.
    var placeholder: String? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = WritingLayoutManager()
        layout.delegate = context.coordinator
        let container = NSTextContainer(containerSize: NSSize(width: 680, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = fragmentPadding
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        let view = WritingTextView(frame: .zero, textContainer: container)
        view.saveImage = saveImage; view.resolveImage = resolveImage; view.mediaError = mediaError
        view.registerForDraggedTypes([.png, .tiff, .fileURL])
        if let header {
            let hosted = WritingHeaderView(content: header)
            view.scrollingHeader = hosted
            view.addSubview(hosted)
        }
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = true
        view.isContinuousSpellCheckingEnabled = spellChecking
        view.isGrammarCheckingEnabled = false
        view.allowsUndo = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width]
        view.textContainerInset = textInsets
        view.backgroundColor = Paper.background
        view.insertionPointColor = Paper.accent
        view.selectedTextAttributes = [.backgroundColor: Paper.accent.withAlphaComponent(0.16)]
        view.linkTextAttributes = [.foregroundColor: Paper.accent, .underlineStyle: NSUnderlineStyle.single.rawValue]
        view.font = Paper.body()
        view.delegate = context.coordinator
        view.setAccessibilityLabel(accessibilityName)
        view.onAskSelection = onAskSelection
        view.commentStore = commentStore
        view.bodyPlaceholder = placeholder
        view.onEscape = onEscape
        view.onContentHeight = onContentHeight
        onMount(view)
        let scroll = NSScrollView()
        scroll.documentView = view
        // The window has a full-size content view; insets for the floating title bar are
        // laid out explicitly, so AppKit must not add its own.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.view = view
        context.coordinator.scroll = scroll
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak coordinator = context.coordinator] _ in
            coordinator?.view?.updateMarginRoom()
            coordinator?.reportPosition()
        }
        context.coordinator.load(self, restore: true)
        return scroll
    }
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let styleChanged = context.coordinator.parent.textSize != textSize || context.coordinator.parent.lineSpacing != lineSpacing || context.coordinator.parent.differenceRanges != differenceRanges
        context.coordinator.parent = self
        context.coordinator.view?.onAskSelection = onAskSelection
        context.coordinator.view?.commentStore = commentStore
        if context.coordinator.view?.bodyPlaceholder != placeholder { context.coordinator.view?.bodyPlaceholder = placeholder }
        context.coordinator.view?.onContentHeight = onContentHeight
        // Assign only on change: re-enabling on every SwiftUI update restarts AppKit's
        // spell checking and autocorrection state while it is applying a correction.
        if let view = context.coordinator.view, view.isContinuousSpellCheckingEnabled != spellChecking {
            view.isContinuousSpellCheckingEnabled = spellChecking
        }
        context.coordinator.view?.saveImage = saveImage
        context.coordinator.view?.resolveImage = resolveImage
        context.coordinator.view?.mediaError = mediaError
        if context.coordinator.loadedID != draftID { context.coordinator.view?.imageCache = [:] }
        if let header, let view = context.coordinator.view {
            view.scrollingHeader?.update(content: header)
            view.needsLayout = true
        }
        if context.coordinator.loadedID != draftID { context.coordinator.load(self, restore: true) }
        else if context.coordinator.view?.string != text { context.coordinator.load(self, restore: false) }
        else if styleChanged { context.coordinator.restyle() }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate {
        private let editorUndoManager = UndoManager()
        func undoManager(for view: NSTextView) -> UndoManager? { editorUndoManager }
        var parent: MarkdownEditor
        weak var view: WritingTextView?
        weak var scroll: NSScrollView?
        var loadedID = ""
        var updating = false
        var restoringPosition = false
        var loadGeneration = 0
        var observer: NSObjectProtocol?
        init(_ parent: MarkdownEditor) { self.parent = parent }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
        func load(_ parent: MarkdownEditor, restore: Bool) {
            guard let view else { return }
            updating = true
            restoringPosition = true
            loadGeneration += 1
            let generation = loadGeneration
            let selection = restore ? parent.initialCursor : view.selectedRange().location
            let position = restore ? parent.initialScroll : Double(scroll?.contentView.bounds.origin.y ?? 0)
            loadedID = parent.draftID
            view.string = parent.text
            restyle()
            view.setSelectedRange(NSRange(location: min(max(0, selection), (parent.text as NSString).length), length: 0))
            view.undoManager?.removeAllActions()
            view.refreshBodyPlaceholder()
            // An editor already on screen (switching notes) lands synchronously, before the
            // next draw, so the new note never appears at the previous note's offset first.
            // Only the first load, before SwiftUI has sized the scroll view, waits for layout.
            if let scroll, view.window != nil, scroll.contentSize.height > 0 {
                land(at: position, in: scroll)
                updating = false
                restoringPosition = false
                DispatchQueue.main.async { [weak self] in
                    // Focus, toolbar title and readiness are SwiftUI state, so they follow
                    // on the next turn of the run loop rather than inside this view update.
                    guard let self, self.loadedID == parent.draftID else { return }
                    if restore && parent.focusOnLoad, self.loadGeneration == generation {
                        self.view?.window?.makeFirstResponder(self.view)
                    }
                    self.reportPosition()
                    self.parent.onReady(parent.draftID)
                }
                return
            }
            updating = false
            // Wait for SwiftUI to size the scroll view and establish first responder.
            // Suppress temporary layout positions so they cannot overwrite the saved state.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, self.loadGeneration == generation, self.loadedID == parent.draftID, let scroll = self.scroll else { return }
                self.updating = true
                if restore && parent.focusOnLoad { self.view?.window?.makeFirstResponder(self.view) }
                self.land(at: position, in: scroll)
                self.updating = false
                self.restoringPosition = false
                self.reportPosition()
                self.parent.onReady(parent.draftID)
            }
        }
        /// Lay the text out completely and scroll to `position` (clamped) in one step.
        private func land(at position: Double, in scroll: NSScrollView) {
            guard let view, let container = view.textContainer else { return }
            view.layoutManager?.ensureLayout(for: container)
            view.sizeToFit()
            let maxY = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentSize.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(CGFloat(position), maxY)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        func restyle() {
            guard let view, let storage = view.textStorage else { return }
            storage.beginEditing()
            MarkdownStyler.style(storage, textSize: CGFloat(parent.textSize), lineSpacing: CGFloat(parent.lineSpacing))
            if view.string == parent.text {
                for range in parent.differenceRanges where range.location >= 0 && NSMaxRange(range) <= storage.length {
                    storage.addAttribute(.backgroundColor, value: Paper.accent.withAlphaComponent(0.11), range: range)
                }
            }
            view.styleImages(); storage.endEditing()
            view.applyCommentHighlights()
            view.layoutManager?.invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: storage.length), changeInLength: 0, actualCharacterRange: nil)
            view.layoutManager?.ensureLayout(for: view.textContainer!)
            view.sizeToFit()
            view.reportContentHeight()
            view.typingAttributes = [.font: Paper.body(CGFloat(parent.textSize)), .foregroundColor: Paper.ink]
            // The placeholder follows the writing size.
            if view.showsBodyPlaceholder { view.needsDisplay = true }
        }
        private var changePending = false
        func textDidChange(_ notification: Notification) {
            guard !updating, let view else { return }
            // AppKit's autocorrection and text replacement can report a change while the text
            // storage is still inside its editing batch. Restyling then forces glyph generation
            // and layout mid-edit, which AppKit treats as a fatal inconsistency. Wait for the
            // batch to finish instead.
            if view.isStorageEditing {
                guard !changePending else { return }
                changePending = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.changePending = false
                    self.textDidChange(notification)
                }
                return
            }
            loadGeneration += 1
            let wasRestoring = restoringPosition
            restoringPosition = false
            updating = true; restyle(); updating = false
            if wasRestoring { parent.onReady(loadedID) }
            parent.onChange(view.string)
            reportPosition()
        }
        func textViewDidChangeSelection(_ notification: Notification) { reportPosition(); view?.updateSlashMenu() }
        func reportPosition() {
            guard !updating, !restoringPosition, let view else { return }
            let offset = scroll?.contentView.bounds.origin.y ?? 0
            parent.onHeaderVisibility(view.headerHeight > 0 && offset > view.headerHeight - 24)
            parent.onPosition(view.selectedRange().location, Double(offset))
        }
        func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>, properties props: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes charIndexes: UnsafePointer<Int>, font: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
            guard let storage = layoutManager.textStorage else { return 0 }
            var replacements = Array(UnsafeBufferPointer(start: glyphs, count: glyphRange.length))
            var properties = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
            for index in 0..<glyphRange.length {
                let character = charIndexes[index]
                guard character < storage.length else { continue }
                if storage.attribute(.concealed, at: character, effectiveRange: nil) != nil {
                    // Hidden Markdown is laid out as zero-width control characters, not null
                    // glyphs: a line that starts with null glyphs (a heading's `#`, a quote's `>`,
                    // a nested item's indentation) makes AppKit drop the previous paragraph's
                    // paragraphSpacing, collapsing the space above headings, quotes and nested items.
                    properties[index] = .controlCharacter
                } else if let replacement = storage.attribute(.replacement, at: character, effectiveRange: nil) as? String, var unicode = replacement.utf16.first {
                    var glyph: CGGlyph = 0
                    if CTFontGetGlyphsForCharacters(font as CTFont, &unicode, &glyph, 1) { replacements[index] = glyph }
                }
            }
            replacements.withUnsafeBufferPointer { glyphs in
                properties.withUnsafeBufferPointer { props in
                    layoutManager.setGlyphs(glyphs.baseAddress!, properties: props.baseAddress!, characterIndexes: charIndexes, font: font, forGlyphRange: glyphRange)
                }
            }
            return glyphRange.length
        }
        func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction, forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
            guard let storage = layoutManager.textStorage, charIndex < storage.length,
                  storage.attribute(.concealed, at: charIndex, effectiveRange: nil) != nil,
                  (storage.string as NSString).character(at: charIndex) != 10 else { return action }
            return .zeroAdvancement
        }
    }
}


/// Draw inline-code backgrounds around letters, excluding line/paragraph spacing.
final class WritingLayoutManager: NSLayoutManager {
    var commentRanges: [NSRange] = []
    var activeCommentRange: NSRange?
    func inlineCodeRects(forGlyphRange visible: NSRange) -> [NSRect] {
        guard let storage = textStorage else { return [] }
        var result: [NSRect] = []
        let characters = characterRange(forGlyphRange: visible, actualGlyphRange: nil)
        storage.enumerateAttribute(.inlineCode, in: characters) { value, range, _ in
            guard value != nil else { return }
            let codeGlyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            enumerateLineFragments(forGlyphRange: codeGlyphs) { line, _, container, fragment, _ in
                let run = NSIntersectionRange(fragment, codeGlyphs)
                guard run.length > 0 else { return }
                let character = self.characterIndexForGlyph(at: run.location)
                let font = storage.attribute(.font, at: character, effectiveRange: nil) as? NSFont ?? Paper.body()
                let offset = storage.attribute(.baselineOffset, at: character, effectiveRange: nil) as? CGFloat ?? 0
                let baseline = line.minY + self.location(forGlyphAt: run.location).y - offset
                let bounds = self.boundingRect(forGlyphRange: run, in: container)
                result.append(NSRect(x: bounds.minX - 2, y: baseline - font.capHeight - 2,
                                     width: bounds.width + 4, height: font.capHeight - font.descender + 4))
            }
        }
        return result
    }
    // AppKit draws spelling markers at the bottom of the line fragment, which includes the
    // writing line spacing, so they float well below the words. Hide them from AppKit's glyph
    // drawing and draw them just under the baseline instead.
    private var drawingGlyphs = false
    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        drawingGlyphs = true
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        drawingGlyphs = false
        drawSpellingMarkers(forGlyphRange: glyphsToShow, at: origin)
    }
    override func temporaryAttributes(atCharacterIndex charIndex: Int, effectiveRange effectiveCharRange: NSRangePointer?) -> [NSAttributedString.Key: Any] {
        var attributes = super.temporaryAttributes(atCharacterIndex: charIndex, effectiveRange: effectiveCharRange)
        if drawingGlyphs { attributes[.spellingState] = nil }
        return attributes
    }
    override func temporaryAttribute(_ attrName: NSAttributedString.Key, atCharacterIndex location: Int, effectiveRange range: NSRangePointer?) -> Any? {
        let value = super.temporaryAttribute(attrName, atCharacterIndex: location, effectiveRange: range)
        return drawingGlyphs && attrName == .spellingState ? nil : value
    }
    override func temporaryAttributes(atCharacterIndex location: Int, longestEffectiveRange range: NSRangePointer?, in rangeLimit: NSRange) -> [NSAttributedString.Key: Any] {
        var attributes = super.temporaryAttributes(atCharacterIndex: location, longestEffectiveRange: range, in: rangeLimit)
        if drawingGlyphs { attributes[.spellingState] = nil }
        return attributes
    }

    /// Dotted spelling (red) and grammar (green) markers, in container coordinates.
    func spellingMarkerRects(forGlyphRange visible: NSRange) -> [(rect: NSRect, grammar: Bool)] {
        guard let storage = textStorage, storage.length > 0 else { return [] }
        let characters = characterRange(forGlyphRange: visible, actualGlyphRange: nil)
        var result: [(NSRect, Bool)] = []
        var index = characters.location
        while index < NSMaxRange(characters) {
            var run = NSRange()
            let value = super.temporaryAttribute(.spellingState, atCharacterIndex: index, longestEffectiveRange: &run, in: characters)
            defer { index = max(index + 1, NSMaxRange(run)) }
            let state = (value as? Int) ?? (value as? NSNumber)?.intValue ?? 0
            let spelling = state & NSAttributedString.SpellingState.spelling.rawValue != 0
            let grammar = state & NSAttributedString.SpellingState.grammar.rawValue != 0
            guard spelling || grammar, run.length > 0 else { continue }
            let glyphs = glyphRange(forCharacterRange: run, actualCharacterRange: nil)
            enumerateLineFragments(forGlyphRange: glyphs) { line, _, container, fragment, _ in
                let part = NSIntersectionRange(fragment, glyphs)
                guard part.length > 0 else { return }
                let bounds = self.boundingRect(forGlyphRange: part, in: container)
                guard bounds.width > 1 else { return }
                let character = self.characterIndexForGlyph(at: part.location)
                let font = storage.attribute(.font, at: character, effectiveRange: nil) as? NSFont ?? Paper.body()
                let baseline = line.minY + self.location(forGlyphAt: part.location).y
                let y = baseline + max(2, min(-font.descender * 0.75, 4))
                result.append((NSRect(x: bounds.minX, y: y, width: bounds.width, height: 2.4), grammar && !spelling))
            }
        }
        return result
    }
    private func drawSpellingMarkers(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        for marker in spellingMarkerRects(forGlyphRange: glyphsToShow) {
            let rect = marker.rect.offsetBy(dx: origin.x, dy: origin.y)
            (marker.grammar ? NSColor.systemGreen : NSColor.systemRed).withAlphaComponent(0.8).setFill()
            let step: CGFloat = 4, diameter = rect.height
            let count = max(1, Int((rect.width + step - diameter) / step))
            let start = rect.minX + (rect.width - (CGFloat(count - 1) * step + diameter)) / 2
            for dot in 0..<count {
                NSBezierPath(ovalIn: NSRect(x: start + CGFloat(dot) * step, y: rect.minY, width: diameter, height: diameter)).fill()
            }
        }
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        drawCommentHighlights(forGlyphRange: glyphsToShow, at: origin)
        Paper.codeBackground.setFill()
        for rect in inlineCodeRects(forGlyphRange: glyphsToShow) {
            NSBezierPath(roundedRect: rect.offsetBy(dx: origin.x, dy: origin.y), xRadius: 2, yRadius: 2).fill()
        }
    }
}
