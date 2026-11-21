import SwiftUI
import UIKit
import MatildeKit

/// A highlighted passage in the text: a private comment (the Mac's highlighter yellow) or an
/// Ask Matilde thread (an accent underline).
struct TextHighlight: Equatable {
    enum Kind: Equatable { case comment, thread, unreadThread }
    let kind: Kind
    let range: NSRange
}

/// IOS-05: the writing surface, a TextKit 2 UITextView. It keeps the Markdown as typed and only
/// changes attributes (`MarkdownStyle`), adds "Comment" and "Ask Matilde" to the edit menu and
/// shows a formatting bar above the keyboard.
struct NoteTextView: UIViewRepresentable {
    let model: NoteEditorModel
    let highlights: [TextHighlight]

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.isScrollEnabled = true
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.textContainerInset = UIEdgeInsets(top: 8, left: 22, bottom: 40, right: 22)
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.autocapitalizationType = .sentences
        view.smartQuotesType = .yes
        view.smartDashesType = .yes
        view.allowsEditingTextAttributes = false
        view.typingAttributes = MarkdownStyle.baseAttributes()
        view.tintColor = UIColor(Paper.accent)
        view.text = model.text
        view.inputAccessoryView = context.coordinator.formattingBar()
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        model.textView = view
        context.coordinator.revision = model.externalRevision
        context.coordinator.restyle(view, highlights: highlights)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.revision != model.externalRevision {
            coordinator.revision = model.externalRevision
            let selection = view.selectedRange
            view.text = model.text
            let length = (model.text as NSString).length
            view.selectedRange = NSRange(location: min(selection.location, length), length: 0)
            coordinator.restyle(view, highlights: highlights)
        } else if coordinator.highlights != highlights {
            coordinator.restyle(view, highlights: highlights)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        let model: NoteEditorModel
        var revision = 0
        var highlights: [TextHighlight] = []

        init(model: NoteEditorModel) { self.model = model }

        func restyle(_ view: UITextView, highlights: [TextHighlight]) {
            self.highlights = highlights
            let storage = view.textStorage
            MarkdownStyle.apply(to: storage)
            storage.beginEditing()
            for highlight in highlights where NSMaxRange(highlight.range) <= storage.length {
                switch highlight.kind {
                case .comment:
                    storage.addAttribute(.backgroundColor, value: Paper.commentHighlight, range: highlight.range)
                case .thread, .unreadThread:
                    storage.addAttributes([.underlineStyle: NSUnderlineStyle.thick.rawValue,
                                           .underlineColor: UIColor(Paper.accent).withAlphaComponent(highlight.kind == .unreadThread ? 0.9 : 0.5)],
                                          range: highlight.range)
                }
            }
            storage.endEditing()
            view.typingAttributes = MarkdownStyle.baseAttributes()
        }

        func textViewDidChange(_ view: UITextView) {
            model.textChanged(view.text)
            // Leave text that is still being composed (marked text, e.g. Japanese input) alone.
            if view.markedTextRange == nil { restyle(view, highlights: highlights) }
        }

        func textViewDidChangeSelection(_ view: UITextView) {
            model.selection = view.selectedRange
        }

        func textViewDidEndEditing(_ view: UITextView) { model.flush() }

        func textView(_ view: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0 else { return UIMenu(children: suggestedActions) }
            let model = model
            let comment = UIAction(title: "Comment", image: UIImage(systemName: "text.bubble")) { _ in
                model.selection = range
                model.commentOnSelection()
            }
            let ask = UIAction(title: "Ask Matilde", image: UIImage(systemName: "sparkles")) { _ in
                model.selection = range
                model.askMatildeOnSelection()
            }
            return UIMenu(children: [comment, ask] + suggestedActions)
        }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? UITextView, view.selectedRange.length == 0 else { return }
            let point = gesture.location(in: view)
            guard let position = view.closestPosition(to: point) else { return }
            let index = view.offset(from: view.beginningOfDocument, to: position)
            let inside = highlights.contains { index >= $0.range.location && index < NSMaxRange($0.range) }
            guard inside else { return }
            model.tapped(at: index)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        // MARK: Formatting bar

        func formattingBar() -> UIView {
            let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
            bar.tintColor = UIColor(Paper.accent)
            func item(_ symbol: String, _ label: String, _ action: Selector) -> UIBarButtonItem {
                let button = UIBarButtonItem(image: UIImage(systemName: symbol), style: .plain, target: self, action: action)
                button.accessibilityLabel = label
                return button
            }
            let space = UIBarButtonItem.flexibleSpace()
            bar.items = [
                item("number", "Heading", #selector(heading)), space,
                item("bold", "Bold", #selector(bold)), space,
                item("italic", "Italic", #selector(italic)), space,
                item("list.bullet", "List", #selector(list)), space,
                item("text.quote", "Quote", #selector(quote)), space,
                item("text.bubble", "Comment", #selector(comment)), space,
                item("sparkles", "Ask Matilde", #selector(ask)), space,
                item("keyboard.chevron.compact.down", "Hide Keyboard", #selector(done))
            ]
            bar.sizeToFit()
            return bar
        }

        @objc private func heading() { model.apply(.heading) }
        @objc private func bold() { model.apply(.bold) }
        @objc private func italic() { model.apply(.italic) }
        @objc private func list() { model.apply(.list) }
        @objc private func quote() { model.apply(.quote) }
        @objc private func comment() { model.commentOnSelection() }
        @objc private func ask() { model.askMatildeOnSelection() }
        @objc private func done() { model.textView?.resignFirstResponder() }
    }
}
