import AppKit

enum EditorLinks {
    static let pattern = #"(?<!!)\[((?:\\.|[^\]\\\n])+)\]\(([^\s)]+)\)"#
    static func destination(_ text: String) -> URL? {
        guard !text.contains(where: { $0.isWhitespace }), let url = URL(string: text),
              ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        if url.scheme != "mailto", url.host == nil { return nil }
        return url
    }
    static func markdown(label: String, destination: URL) -> String {
        let label = label.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        let url = destination.absoluteString.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
        return "[\(label)](\(url))"
    }
}

extension Workspace {
    func importImage(_ data: Data, beside draft: Draft) throws -> String {
        guard data.count <= 32 * 1024 * 1024, let bitmap = NSBitmapImageRep(data: data),
              bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
              Double(bitmap.pixelsWide) * Double(bitmap.pixelsHigh) <= 40_000_000,
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw WorkspaceError.message("Choose an image smaller than 32 MB and 40 megapixels.")
        }
        let relative = ".assets/\(UUID().uuidString).png"
        let path = draft.folder.isEmpty ? relative : draft.folder + "/" + relative
        let target = try url(for: path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: target, options: .withoutOverwriting)
        return relative
    }

    func image(at reference: String, beside draft: Draft) -> NSImage? {
        guard !reference.hasPrefix("/"), !reference.contains(":"),
              let decoded = reference.removingPercentEncoding else { return nil }
        let path = draft.folder.isEmpty ? decoded : draft.folder + "/" + decoded
        guard let target = try? url(for: path),
              let size = try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32 * 1024 * 1024,
              let data = try? Data(contentsOf: target), let bitmap = NSBitmapImageRep(data: data),
              Double(bitmap.pixelsWide) * Double(bitmap.pixelsHigh) <= 40_000_000 else { return nil }
        let image = NSImage(size: NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        image.addRepresentation(bitmap)
        return image
    }
}

struct EditorImage {
    let range: NSRange
    let image: NSImage
    let size: NSSize
}

extension WritingTextView {
    func styleImages() {
        guard let storage = textStorage else { return }
        renderedImages = []
        let available = max(1, bounds.width - textContainerInset.width * 2 - 10)
        for match in MarkdownStyler.matches("(?m)^!\\[([^\\]\\n]*)\\]\\(([^\\s)]+)\\)[ \\t]*$", in: string) {
            guard storage.attribute(.codeBlock, at: match.range.location, effectiveRange: nil) == nil else { continue }
            let reference = (string as NSString).substring(with: match.range(at: 2))
            guard let image = imageCache[reference] ?? resolveImage?(reference), image.size.width > 0, image.size.height > 0 else { continue }
            imageCache[reference] = image
            let factor = min(1, available / image.size.width, 500 / image.size.height)
            let size = NSSize(width: image.size.width * factor, height: image.size.height * factor)
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = size.height + 12
            paragraph.maximumLineHeight = size.height + 12
            paragraph.paragraphSpacing = 16
            storage.addAttributes([.paragraphStyle: paragraph, .foregroundColor: NSColor.clear,
                                   .font: NSFont.systemFont(ofSize: 1)], range: match.range)
            renderedImages.append(EditorImage(range: match.range, image: image, size: size))
        }
    }

    func pasteMedia(from pasteboard: NSPasteboard) -> Bool {
        var imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
        if imageData == nil,
           let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           files.count == 1, let file = files.first,
           let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32 * 1024 * 1024,
           let data = try? Data(contentsOf: file), NSBitmapImageRep(data: data) != nil { imageData = data }
        if let data = imageData, let saveImage {
            do {
                let path = try saveImage(data)
                let range = selectedRange()
                let source = string as NSString
                let prefix = range.location > 0 && source.character(at: range.location - 1) != 10 ? "\n\n" : ""
                insertText(prefix + "![Image](\(path))\n\n", replacementRange: range)
            } catch { mediaError?(error.localizedDescription) }
            return true
        }
        if let text = pasteboard.string(forType: .string), let url = EditorLinks.destination(text), selectedRange().length > 0 {
            let label = (string as NSString).substring(with: selectedRange())
            insertText(EditorLinks.markdown(label: label, destination: url), replacementRange: selectedRange())
            return true
        }
        return false
    }

    func editLink() {
        var range = selectedRange()
        var destination = ""
        var label = (string as NSString).substring(with: range)
        for match in MarkdownStyler.matches(EditorLinks.pattern, in: string) {
            if range.location >= match.range.location, NSMaxRange(range) <= NSMaxRange(match.range) {
                range = match.range
                label = (string as NSString).substring(with: match.range(at: 1))
                    .replacingOccurrences(of: "\\]", with: "]").replacingOccurrences(of: "\\[", with: "[")
                    .replacingOccurrences(of: "\\\\", with: "\\")
                destination = (string as NSString).substring(with: match.range(at: 2))
                break
            }
        }
        let alert = NSAlert()
        alert.messageText = "Link"
        let field = NSTextField(string: destination)
        field.placeholderString = "https://…"
        field.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save Link"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let url = EditorLinks.destination(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            mediaError?("Enter an http, https, or mailto URL."); return
        }
        insertText(EditorLinks.markdown(label: label.isEmpty ? url.absoluteString : label, destination: url), replacementRange: range)
    }
}
