import SwiftUI
import AppKit
import CoreText

extension NSAttributedString.Key {
    static let codeBlock = NSAttributedString.Key("MatildeCodeBlock")
    static let divider = NSAttributedString.Key("MatildeDivider")
    static let quoteBlock = NSAttributedString.Key("MatildeQuoteBlock")
    static let concealed = NSAttributedString.Key("MatildeConcealed")
    static let replacement = NSAttributedString.Key("MatildeReplacement")
}

enum Paper {
    static let background = NSColor(calibratedRed: 0.976, green: 0.965, blue: 0.938, alpha: 1)
    static let ink = NSColor(calibratedRed: 0.24, green: 0.25, blue: 0.22, alpha: 1)
    static let muted = NSColor(calibratedRed: 0.48, green: 0.48, blue: 0.43, alpha: 1)
    static let accent = NSColor(calibratedRed: 0.48, green: 0.32, blue: 0.23, alpha: 1)
    private static let fontBundle: Bundle = {
        if let url = Bundle.main.url(forResource: "Matilde_Matilde", withExtension: "bundle"), let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }()
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
    static func body(_ size: CGFloat = 19, bold: Bool = false, italic: Bool = false) -> NSFont {
        guard newsreader.count == 2 else { return .systemFont(ofSize: size) }
        let axes: [NSNumber: NSNumber] = [
            NSNumber(value: 0x77676874): NSNumber(value: bold ? 700 : 400),
            NSNumber(value: 0x6F70737A): NSNumber(value: Double(size))
        ]
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(newsreader[italic ? 1 : 0], [kCTFontVariationAttribute: axes] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
    }
    static func emphasize(_ font: NSFont, trait: NSFontTraitMask) -> NSFont {
        let traits = NSFontManager.shared.traits(of: font)
        return body(font.pointSize, bold: trait == .boldFontMask || traits.contains(.boldFontMask), italic: trait == .italicFontMask || traits.contains(.italicFontMask))
    }
}

/// The text storage remains lossless Markdown; only glyphs and attributes change.
/// Hidden delimiters consume no space, so no render/serialize cycle can rewrite a file.
enum MarkdownStyler {
    static func style(_ storage: NSMutableAttributedString) {
        let full = NSRange(location: 0, length: storage.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 7
        paragraph.paragraphSpacing = 16
        storage.setAttributes([.font: Paper.body(), .foregroundColor: Paper.ink, .paragraphStyle: paragraph], range: full)
        let source = storage.string as NSString
        var offset = 0
        var fence: String?
        var codeRanges: [NSRange] = []
        for line in storage.string.components(separatedBy: "\n") {
            let length = (line as NSString).length
            let range = NSRange(location: offset, length: length)
            defer { offset += length + 1 }
            guard length > 0 else {
                // Keep the normal font and caret height on empty editable lines.
                if offset < storage.length, fence == nil {
                    let gap = NSMutableParagraphStyle()
                    storage.addAttribute(.paragraphStyle, value: gap, range: NSRange(location: offset, length: 1))
                }
                continue
            }
            let paragraphRange = NSRange(location: offset, length: min(length + 1, storage.length - offset))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))
                if fence == nil { fence = marker } else if fence == marker { fence = nil }
                conceal(range, in: storage)
                codeRanges.append(range)
                continue
            }
            if fence != nil {
                storage.addAttribute(.codeBlock, value: true, range: range)
                storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular), .backgroundColor: NSColor.black.withAlphaComponent(0.035)], range: range)
                codeRanges.append(range)
                continue
            }
            if trimmed == "---" {
                // Keep ordinary glyph metrics for caret/line placement, but draw
                // a rule instead of the dashes. The Markdown stays untouched.
                storage.addAttributes([.divider: true, .foregroundColor: NSColor.clear], range: range)
                continue
            }
            if first("^(\\s*)([-*+] |[0-9]+[.)] )", in: line) != nil {
                let listStyle = paragraph.mutableCopy() as! NSMutableParagraphStyle
                listStyle.lineSpacing = 3
                listStyle.paragraphSpacing = 3
                listStyle.headIndent = 22
                storage.addAttribute(.paragraphStyle, value: listStyle, range: paragraphRange)
            }
            if let match = first("^(#{1,6}) ", in: line) {
                let level = match.range(at: 1).length
                let size: CGFloat = [31, 26, 23, 21, 20, 19][level - 1]
                storage.addAttribute(.font, value: Paper.body(size, bold: true), range: range)
                conceal(NSRange(location: offset, length: match.range.length), in: storage)
            } else if let match = first("^(\\s*)[-*+] \\[([ xX])\\] ", in: line) {
                let start = offset + match.range(at: 1).length
                let checked = (line as NSString).substring(with: match.range(at: 2)).lowercased() == "x"
                storage.addAttributes([.replacement: checked ? "☑" : "☐", .font: NSFont(name: "Apple Symbols", size: 23) ?? NSFont.systemFont(ofSize: 19)], range: NSRange(location: start, length: 1))
                conceal(NSRange(location: start + 1, length: 4), in: storage)
                if checked { storage.addAttribute(.foregroundColor, value: Paper.muted, range: range) }
            } else if let match = first("^(\\s*)[-*+] ", in: line) {
                storage.addAttributes([.replacement: "•", .foregroundColor: Paper.muted], range: NSRange(location: offset + match.range(at: 1).length, length: 1))
            } else if let match = first("^\\s*[0-9]+[.)]", in: line) {
                storage.addAttribute(.foregroundColor, value: Paper.muted, range: NSRange(location: offset, length: match.range.length))
            } else if let match = first("^> ?", in: line) {
                storage.addAttribute(.quoteBlock, value: true, range: paragraphRange)
                let quoteStyle = paragraph.mutableCopy() as! NSMutableParagraphStyle
                quoteStyle.headIndent = 24; quoteStyle.firstLineHeadIndent = 24
                quoteStyle.paragraphSpacing = 3
                storage.addAttribute(.paragraphStyle, value: quoteStyle, range: paragraphRange)
                conceal(NSRange(location: offset, length: match.range.length), in: storage)
            }
        }
        // Code spans are protected from subsequent inline styling.
        matches("`([^`\\n]+)`", in: storage.string).forEach { match in
            guard !codeRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { return }
            let content = match.range(at: 1)
            storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular), .backgroundColor: NSColor.black.withAlphaComponent(0.04)], range: content)
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

    func measure(at width: CGFloat) {
        guard measuredWidth != width else { return }
        measuredWidth = width
        rootView = AnyView(content.frame(width: width, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true))
    }
}

final class WritingTextView: NSTextView {
    var saveImage: ((Data) throws -> String)?
    var resolveImage: ((String) -> NSImage?)?
    var mediaError: ((String) -> Void)?
    var renderedImages: [EditorImage] = []
    var imageCache: [String: NSImage] = [:]
    private var imageLayoutWidth: CGFloat = -1

    override func paste(_ sender: Any?) {
        if !pasteMedia(from: .general) { super.paste(sender) }
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
    private var ordinarySelectionAttributes: [NSAttributedString.Key: Any]?
    override func setSelectedRange(_ range: NSRange, affinity: NSSelectionAffinity, stillSelecting flag: Bool) {
        if ordinarySelectionAttributes == nil { ordinarySelectionAttributes = selectedTextAttributes }
        let isDivider = range.length > 0 && dividerRange(at: range.location) == range
        selectedTextAttributes = isDivider ? [.backgroundColor: NSColor.clear, .foregroundColor: NSColor.clear]
            : ordinarySelectionAttributes ?? selectedTextAttributes
        super.setSelectedRange(range, affinity: affinity, stillSelecting: flag)
        needsDisplay = true
    }
    var onPosition: ((Int, Double) -> Void)?
    var scrollingHeader: WritingHeaderView?
    override func accessibilityChildren() -> [Any]? {
        var children = super.accessibilityChildren() ?? []
        if let scrollingHeader { children.append(scrollingHeader) }
        return children
    }
    private(set) var headerHeight: CGFloat = 0
    override func layout() {
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
            }
        }
        super.layout()
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
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

    override func moveUp(_ sender: Any?) { super.moveUp(sender); skipDivider(forward: false) }
    override func moveDown(_ sender: Any?) { super.moveDown(sender); skipDivider(forward: true) }
    override func moveLeft(_ sender: Any?) { super.moveLeft(sender); skipDivider(forward: false) }
    override func moveRight(_ sender: Any?) { super.moveRight(sender); skipDivider(forward: true) }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard dividerRange(at: selectedRange().location) == nil else { return }
        super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
    }

    override func deleteBackward(_ sender: Any?) {
        if selectedRange().length == 0, let range = dividerRange(at: selectedRange().location) {
            insertText("", replacementRange: range)
        } else {
            super.deleteBackward(sender)
        }
    }

    override func magnify(with event: NSEvent) {
        // The writing-space boundary owns pinch navigation, including tail events.
    }

    override func insertNewline(_ sender: Any?) {
        if let divider = dividerRange(at: selectedRange().location),
           selectedRange() == divider {
            setSelectedRange(NSRange(location: NSMaxRange(divider), length: 0))
        }
        let source = string as NSString
        let selection = selectedRange()
        let lineRange = source.lineRange(for: NSRange(location: min(selection.location, source.length), length: 0))
        let line = source.substring(with: lineRange).trimmingCharacters(in: .newlines)
        var fence: String?
        for previous in source.substring(to: lineRange.location).components(separatedBy: "\n") {
            let trimmed = previous.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))
                if fence == nil { fence = marker } else if fence == marker { fence = nil }
            }
        }
        guard fence == nil, !source.substring(with: selection).contains("\n") else {
            super.insertNewline(sender); return
        }
        if let match = MarkdownStyler.first("^(\\s*)([-*+] \\[[ xX]\\] |[-*+] |[0-9]+[.)] |>{1} ?)", in: line) {
            guard selection.location >= lineRange.location + match.range.length else {
                super.insertNewline(sender); return
            }
            let prefix = (line as NSString).substring(with: match.range)
            if line.trimmingCharacters(in: .whitespaces) == prefix.trimmingCharacters(in: .whitespaces) {
                insertText("", replacementRange: NSRange(location: lineRange.location, length: match.range.length))
                return
            }
            var next = prefix.replacingOccurrences(of: "[x]", with: "[ ]").replacingOccurrences(of: "[X]", with: "[ ]")
            if let number = MarkdownStyler.first("[0-9]+", in: prefix), let value = Int((prefix as NSString).substring(with: number.range)) {
                let increment = value.addingReportingOverflow(1)
                if !increment.overflow {
                    next = (prefix as NSString).replacingCharacters(in: number.range, with: String(increment.partialValue))
                }
            }
            insertText("\n" + next, replacementRange: selection)
        } else { super.insertNewline(sender) }
    }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
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
        guard index < (string as NSString).length else { return }
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

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.delegate = context.coordinator
        let container = NSTextContainer(containerSize: NSSize(width: 680, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
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
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.allowsUndo = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width]
        view.textContainerInset = NSSize(width: 28, height: 20)
        view.backgroundColor = Paper.background
        view.insertionPointColor = Paper.accent
        view.selectedTextAttributes = [.backgroundColor: Paper.accent.withAlphaComponent(0.16)]
        view.linkTextAttributes = [.foregroundColor: Paper.accent, .underlineStyle: NSUnderlineStyle.single.rawValue]
        view.font = Paper.body()
        view.delegate = context.coordinator
        view.setAccessibilityLabel("Writing editor")
        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.view = view
        context.coordinator.scroll = scroll
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak coordinator = context.coordinator] _ in
            coordinator?.reportPosition()
        }
        context.coordinator.load(self, restore: true)
        return scroll
    }
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
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
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate {
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
            updating = false
            // Wait for SwiftUI to size the scroll view and establish first responder.
            // Suppress temporary layout positions so they cannot overwrite the saved state.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, self.loadGeneration == generation, self.loadedID == parent.draftID, let scroll = self.scroll else { return }
                self.updating = true
                if restore && parent.focusOnLoad { self.view?.window?.makeFirstResponder(self.view) }
                self.view?.layoutManager?.ensureLayout(for: self.view!.textContainer!)
                self.view?.sizeToFit()
                let maxY = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentSize.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: min(CGFloat(position), maxY)))
                scroll.reflectScrolledClipView(scroll.contentView)
                self.updating = false
                self.restoringPosition = false
                self.reportPosition()
                self.parent.onReady(parent.draftID)
            }
        }
        func restyle() {
            guard let view, let storage = view.textStorage else { return }
            storage.beginEditing(); MarkdownStyler.style(storage); view.styleImages(); storage.endEditing()
            view.layoutManager?.invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: storage.length), changeInLength: 0, actualCharacterRange: nil)
            view.layoutManager?.ensureLayout(for: view.textContainer!)
            view.sizeToFit()
            view.typingAttributes = [.font: Paper.body(), .foregroundColor: Paper.ink]
        }
        func textDidChange(_ notification: Notification) {
            guard !updating, let view else { return }
            loadGeneration += 1
            let wasRestoring = restoringPosition
            restoringPosition = false
            updating = true; restyle(); updating = false
            if wasRestoring { parent.onReady(loadedID) }
            parent.onChange(view.string)
            reportPosition()
        }
        func textViewDidChangeSelection(_ notification: Notification) { reportPosition() }
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
                    properties[index] = .null
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
    }
}
