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
/// shows a glass formatting bar above the keyboard. The title and goal (`NoteHeader`) sit inside
/// the text view above the text, so they scroll away with it; `NoteEditorModel.titleProgress`
/// tells the navigation bar when to show the small title.
struct NoteTextView: UIViewRepresentable {
    let model: NoteEditorModel
    let highlights: [TextHighlight]

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> UITextView {
        let view = NoteUITextView(usingTextLayoutManager: true)
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.isScrollEnabled = true
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        // Edge to edge: the safe area (bars, home indicator) comes in as content inset, so text
        // scrolls under the glass and fades out with the soft edge effect.
        view.contentInsetAdjustmentBehavior = .always
        view.automaticallyAdjustsScrollIndicatorInsets = true
        view.topEdgeEffect.style = .soft
        view.bottomEdgeEffect.style = .soft
        view.textContainerInset = UIEdgeInsets(top: 8, left: 22, bottom: 48, right: 22)
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
        let header = UIHostingController(rootView: NoteHeader(model: model) { [weak view] height, titleBottom in
            view?.headerMeasured(height: height, titleBottom: titleBottom)
        })
        header.safeAreaRegions = []
        header.view.backgroundColor = .clear
        view.header = header.view
        context.coordinator.header = header
        view.onScroll = { [weak model] progress in
            guard let model, abs(model.titleProgress - progress) > 0.001 else { return }
            model.titleProgress = progress
        }
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
        var header: UIHostingController<NoteHeader>?
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

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            (scrollView as? NoteUITextView)?.reportScroll()
        }

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

        /// A glass capsule floating above the keyboard on the page, with no band behind it (the
        /// text view runs under the keyboard, see `NoteUITextView.keyboardChanged`).
        func formattingBar() -> UIView {
            let bar = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: FormattingBar.height))
            bar.backgroundColor = .clear
            bar.autoresizingMask = .flexibleWidth
            let glass = UIVisualEffectView(effect: UIGlassEffect())
            glass.translatesAutoresizingMaskIntoConstraints = false
            glass.layer.cornerRadius = FormattingBar.capsuleHeight / 2
            glass.layer.cornerCurve = .continuous
            glass.clipsToBounds = true
            bar.addSubview(glass)
            func button(_ symbol: String, _ label: String, _ action: Selector) -> UIButton {
                let button = UIButton(type: .system)
                button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)), for: .normal)
                button.tintColor = UIColor(Paper.ink)
                button.accessibilityLabel = label
                button.addTarget(self, action: action, for: .touchUpInside)
                return button
            }
            let stack = UIStackView(arrangedSubviews: [
                button("number", "Heading", #selector(heading)),
                button("bold", "Bold", #selector(bold)),
                button("italic", "Italic", #selector(italic)),
                button("list.bullet", "List", #selector(list)),
                button("text.quote", "Quote", #selector(quote)),
                button("text.bubble", "Comment", #selector(comment)),
                button("sparkles", "Ask Matilde", #selector(ask)),
                button("keyboard.chevron.compact.down", "Hide Keyboard", #selector(done))
            ])
            stack.axis = .horizontal
            stack.distribution = .fillEqually
            stack.translatesAutoresizingMaskIntoConstraints = false
            glass.contentView.addSubview(stack)
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
                glass.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
                glass.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -FormattingBar.bottomGap),
                glass.heightAnchor.constraint(equalToConstant: FormattingBar.capsuleHeight),
                stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 6),
                stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -6),
                stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
                stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor)
            ])
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

enum FormattingBar {
    static let capsuleHeight: CGFloat = 46
    static let bottomGap: CGFloat = 6
    static let height: CGFloat = capsuleHeight + bottomGap + 4
}

/// The note's text view: hosts the scrolling header, keeps the caret clear of the keyboard and
/// reports how far the title has scrolled.
final class NoteUITextView: UITextView {
    /// Room kept between the line being typed and the formatting bar.
    static let caretMargin: CGFloat = 72
    static let headerGap: CGFloat = 12

    var header: UIView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let header { addSubview(header) }
            setNeedsLayout()
        }
    }
    var onScroll: ((Double) -> Void)?
    private var headerHeight: CGFloat = 120
    private var titleBottom: CGFloat = 60
    private var keyboardOverlap: CGFloat = 0

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        observeKeyboard()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        observeKeyboard()
    }

    /// Registers this text view as the screen's content scroll view, so the navigation bar
    /// tracks it (title, soft scroll edge) as it does a SwiftUI ScrollView. The nearest view
    /// controllers up to the navigation controller's child all point at it.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        var responder: UIResponder? = next
        while let current = responder {
            if let controller = current as? UIViewController {
                if controller is UINavigationController { break }
                controller.setContentScrollView(self, for: .top)
                controller.setContentScrollView(self, for: .bottom)
                if controller.parent is UINavigationController { break }
            }
            responder = current.next
        }
    }

    private func observeKeyboard() {
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    /// The header's SwiftUI content measured itself.
    func headerMeasured(height: CGFloat, titleBottom: CGFloat) {
        if titleBottom > 0 { self.titleBottom = titleBottom }
        let height = ceil(height)
        guard height > 0, height != headerHeight else { return }
        headerHeight = height
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let header else { return }
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        let top = headerHeight + Self.headerGap
        if textContainerInset.top != top { textContainerInset.top = top }
    }

    /// Touches on the title and goal belong to their fields, except for scrolling.
    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        if let header, gesture !== panGestureRecognizer, header.frame.contains(gesture.location(in: self)) { return false }
        return super.gestureRecognizerShouldBegin(gesture)
    }

    func reportScroll() {
        let offset = contentOffset.y + adjustedContentInset.top
        // The small title fades in over the second half of the big title passing under the bar.
        let start = titleBottom * 0.45
        let progress = min(1, max(0, (offset - start) / max(1, titleBottom - start)))
        onScroll?((progress * 50).rounded() / 50)
    }

    /// The text view runs under the keyboard; the inset keeps the caret `caretMargin` above it.
    @objc private func keyboardChanged(_ note: Notification) {
        guard let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect, window != nil else { return }
        let local = convert(end, from: nil)
        let hiding = note.name == UIResponder.keyboardWillHideNotification
        let overlap = hiding ? 0 : max(0, bounds.maxY - local.minY - safeAreaInsets.bottom)
        guard overlap != keyboardOverlap else { return }
        keyboardOverlap = overlap
        contentInset.bottom = overlap > 0 ? overlap + Self.caretMargin : 0
        verticalScrollIndicatorInsets.bottom = overlap
        if overlap > 0, isFirstResponder {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scrollRangeToVisible(self.selectedRange)
            }
        }
    }
}
