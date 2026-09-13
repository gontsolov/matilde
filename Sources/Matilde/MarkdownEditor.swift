import SwiftUI
import AppKit
import CoreText

extension NSAttributedString.Key {
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
        paragraph.paragraphSpacing = 8
        storage.setAttributes([.font: Paper.body(), .foregroundColor: Paper.ink, .paragraphStyle: paragraph], range: full)
        let source = storage.string as NSString
        var offset = 0
        var fence: String?
        var codeRanges: [NSRange] = []
        for line in storage.string.components(separatedBy: "\n") {
            let length = (line as NSString).length
            let range = NSRange(location: offset, length: length)
            defer { offset += length + 1 }
            guard length > 0 else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))
                if fence == nil { fence = marker } else if fence == marker { fence = nil }
                conceal(range, in: storage)
                codeRanges.append(range)
                continue
            }
            if fence != nil {
                storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular), .backgroundColor: NSColor.black.withAlphaComponent(0.035)], range: range)
                codeRanges.append(range)
                continue
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
                storage.addAttribute(.replacement, value: "•", range: NSRange(location: offset + match.range(at: 1).length, length: 1))
            } else if let match = first("^> ?", in: line) {
                storage.addAttribute(.foregroundColor, value: Paper.muted, range: range)
                let quoteStyle = paragraph.mutableCopy() as! NSMutableParagraphStyle
                quoteStyle.headIndent = 18; quoteStyle.firstLineHeadIndent = 18
                storage.addAttribute(.paragraphStyle, value: quoteStyle, range: range)
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
        for match in matches("(?<!!)\\[([^\\]\\n]+)\\]\\(([^\\s)]+)\\)", in: storage.string) {
            guard !codeRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            let label = match.range(at: 1), destination = source.substring(with: match.range(at: 2))
            if let url = URL(string: destination), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                storage.addAttributes([.link: url, .foregroundColor: Paper.accent, .underlineStyle: NSUnderlineStyle.single.rawValue], range: label)
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

final class WritingTextView: NSTextView {
    var onPosition: ((Int, Double) -> Void)?

    override func insertNewline(_ sender: Any?) {
        let source = string as NSString
        let selection = selectedRange()
        let lineRange = source.lineRange(for: NSRange(location: min(selection.location, source.length), length: 0))
        let line = source.substring(with: lineRange).trimmingCharacters(in: .newlines)
        if let match = MarkdownStyler.first("^(\\s*)([-*+] \\[[ xX]\\] |[-*+] |[0-9]+[.)] |>{1} ?)", in: line) {
            let prefix = (line as NSString).substring(with: match.range)
            if line.trimmingCharacters(in: .whitespaces) == prefix.trimmingCharacters(in: .whitespaces) {
                insertText("", replacementRange: NSRange(location: lineRange.location, length: match.range.length))
                return
            }
            var next = prefix.replacingOccurrences(of: "[x]", with: "[ ]").replacingOccurrences(of: "[X]", with: "[ ]")
            if let number = MarkdownStyler.first("[0-9]+", in: prefix), let value = Int((prefix as NSString).substring(with: number.range)) {
                next = (prefix as NSString).replacingCharacters(in: number.range, with: String(value + 1))
            }
            insertText("\n" + next, replacementRange: selection)
        } else { super.insertNewline(sender) }
    }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 1, let layoutManager, let textContainer else { return }
        var point = convert(event.locationInWindow, from: nil)
        point.x -= textContainerOrigin.x; point.y -= textContainerOrigin.y
        let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs else { return }
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
        let range = selectedRange(), selected = (string as NSString).substring(with: range)
        insertText(marker + selected + marker, replacementRange: range)
        setSelectedRange(NSRange(location: range.location + (marker as NSString).length, length: range.length))
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            if event.charactersIgnoringModifiers == "b" { wrap("**"); return true }
            if event.charactersIgnoringModifiers == "i" { wrap("*"); return true }
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

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.delegate = context.coordinator
        let container = NSTextContainer(containerSize: NSSize(width: 680, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        let view = WritingTextView(frame: .zero, textContainer: container)
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = true
        view.isContinuousSpellCheckingEnabled = true
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
        if context.coordinator.loadedID != draftID { context.coordinator.load(self, restore: true) }
        else if context.coordinator.view?.string != text { context.coordinator.load(self, restore: false) }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate {
        var parent: MarkdownEditor
        weak var view: WritingTextView?
        weak var scroll: NSScrollView?
        var loadedID = ""
        var updating = false
        var observer: NSObjectProtocol?
        init(_ parent: MarkdownEditor) { self.parent = parent }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
        func load(_ parent: MarkdownEditor, restore: Bool) {
            guard let view else { return }
            updating = true
            let selection = restore ? parent.initialCursor : view.selectedRange().location
            let position = restore ? parent.initialScroll : Double(scroll?.contentView.bounds.origin.y ?? 0)
            loadedID = parent.draftID
            view.string = parent.text
            restyle()
            view.setSelectedRange(NSRange(location: min(max(0, selection), (parent.text as NSString).length), length: 0))
            view.undoManager?.removeAllActions()
            // Wait for SwiftUI to size the scroll view and establish first responder.
            // Suppress temporary layout positions so they cannot overwrite the saved state.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, self.loadedID == parent.draftID, let scroll = self.scroll else { return }
                self.updating = true
                if restore { self.view?.window?.makeFirstResponder(self.view) }
                self.view?.layoutManager?.ensureLayout(for: self.view!.textContainer!)
                self.view?.sizeToFit()
                let maxY = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentSize.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: min(CGFloat(position), maxY)))
                scroll.reflectScrolledClipView(scroll.contentView)
                self.updating = false
            }
        }
        func restyle() {
            guard let view, let storage = view.textStorage else { return }
            storage.beginEditing(); MarkdownStyler.style(storage); storage.endEditing()
            view.layoutManager?.invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: storage.length), changeInLength: 0, actualCharacterRange: nil)
            view.layoutManager?.ensureLayout(for: view.textContainer!)
            view.sizeToFit()
            view.typingAttributes = [.font: Paper.body(), .foregroundColor: Paper.ink]
        }
        func textDidChange(_ notification: Notification) {
            guard !updating, let view else { return }
            updating = true; restyle(); updating = false
            parent.onChange(view.string)
            reportPosition()
        }
        func textViewDidChangeSelection(_ notification: Notification) { reportPosition() }
        func reportPosition() {
            guard !updating, let view else { return }
            parent.onPosition(view.selectedRange().location, Double(scroll?.contentView.bounds.origin.y ?? 0))
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
