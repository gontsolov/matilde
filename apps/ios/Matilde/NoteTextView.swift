import SwiftUI
import UIKit
import MatildeKit

/// A highlighted passage in the text: a private comment (the Mac's highlighter yellow), an
/// Ask Matilde thread (an accent underline), or the passage a comment or thread sheet is open on.
struct TextHighlight: Equatable {
    enum Kind: Equatable { case comment, thread, unreadThread, focus }
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
                case .focus:
                    storage.addAttribute(.backgroundColor, value: Paper.focusHighlight, range: highlight.range)
                }
            }
            storage.endEditing()
            view.typingAttributes = MarkdownStyle.baseAttributes()
        }

        func textViewDidChange(_ view: UITextView) {
            model.textChanged(view.text)
            // Leave text that is still being composed (marked text, e.g. Japanese input) alone.
            if view.markedTextRange == nil { restyle(view, highlights: highlights) }
            (view as? NoteUITextView)?.ensureCaretVisibleSoon()
        }

        /// The caret before the latest selection change, to tell which way it moved.
        private var lastCaret = 0
        private var adjustingSelection = false

        func textViewDidChangeSelection(_ view: UITextView) {
            guard !adjustingSelection else { return }
            var range = view.selectedRange
            // Keep the caret out of hidden line marks (a heading's `#`, a nested item's
            // indentation): typing there would land before or inside them. Moving left out of
            // the line's text goes on to the line above.
            if range.length == 0, view.markedTextRange == nil,
               let marker = MarkdownStyle.hiddenLineStart(in: view.text, at: range.location),
               range.location < NSMaxRange(marker) {
                let backward = range.location < lastCaret && lastCaret == NSMaxRange(marker) && marker.location > 0
                range = NSRange(location: backward ? marker.location - 1 : NSMaxRange(marker), length: 0)
                adjustingSelection = true
                view.selectedRange = range
                adjustingSelection = false
            }
            lastCaret = range.location
            model.selection = range
            if range.length == 0 { (view as? NoteUITextView)?.ensureCaretVisibleSoon() }
        }

        func textViewDidEndEditing(_ view: UITextView) { model.flush() }

        /// EDIT-31: Backspace, Delete, Return, Tab and typed brackets follow the shared Markdown
        /// editing rules (MatildeKit's MarkdownEditing), as on the Mac: Backspace at the start of
        /// a heading, item or quote removes its marker (nested items move out first), Return
        /// continues or ends lists, Tab nests an item. Text being composed is left alone.
        func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard view.markedTextRange == nil, let view = view as? NoteUITextView, !view.isApplyingMarkdownEdit,
                  let edit = markdownEdit(in: view, range: range, text: text) else { return true }
            view.applyMarkdownEdit(edit)
            return false
        }

        private func markdownEdit(in view: NoteUITextView, range: NSRange, text: String) -> MarkdownEdit? {
            let source = view.text ?? ""
            let string = source as NSString
            let selection = view.selectedRange
            let options = MarkdownEditingOptions.visibleMarkers
            guard selection.location != NSNotFound, NSMaxRange(selection) <= string.length else { return nil }
            if text.isEmpty {
                if selection.length > 0 {
                    guard range == selection else { return nil }
                    return MarkdownEditing.deleteBackward(in: source, selection: selection, options: options)
                }
                let caret = selection.location
                if caret > 0, range == string.rangeOfComposedCharacterSequence(at: caret - 1), NSMaxRange(range) == caret {
                    // Before a nested item's hidden indentation, Backspace moves the item out.
                    if let indent = MarkdownStyle.hiddenListIndent(in: source, at: caret), caret == NSMaxRange(indent) {
                        return MarkdownEditing.outdent(in: source, selection: selection)
                    }
                    return MarkdownEditing.deleteBackward(in: source, selection: selection, options: options)
                }
                if caret < string.length, range == string.rangeOfComposedCharacterSequence(at: caret) {
                    return MarkdownEditing.deleteForward(in: source, selection: selection, options: options)
                }
                return nil
            }
            guard range == selection else { return nil }
            switch text {
            case "\n": return MarkdownEditing.insertNewline(in: source, selection: selection)
            case "\t": return MarkdownEditing.indent(in: source, selection: selection)
            default:
                guard text.count == 1 else { return nil }
                return MarkdownEditing.insertText(text, in: source, selection: selection, options: options)
            }
        }

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
                button("decrease.indent", "Outdent", #selector(outdent)),
                button("increase.indent", "Indent", #selector(indent)),
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
        @objc private func indent() { model.apply(.indent) }
        @objc private func outdent() { model.apply(.outdent) }
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

/// The note's text view: hosts the scrolling header, keeps the caret clear of the keyboard
/// (following it as it moves) and reports how far the title has scrolled.
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
    private var laidOutSize: CGSize = .zero

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
        if bounds.size != laidOutSize {
            laidOutSize = bounds.size
            updateKeyboardInsets()
        }
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

    // MARK: Keyboard and caret

    /// The keyboard's frame in screen coordinates (zero while hidden). Its top includes the
    /// formatting bar, the input accessory view.
    private var keyboardFrame: CGRect = .zero

    /// How much of the view the keyboard covers, from the bottom edge.
    private var keyboardOverlapHeight: CGFloat {
        guard keyboardFrame.height > 0, let screen = window?.windowScene?.screen else { return 0 }
        let local = convert(keyboardFrame, from: screen.coordinateSpace)
        return max(0, bounds.maxY - local.minY)
    }

    /// The text view runs under the keyboard. With `contentInsetAdjustmentBehavior = .always`
    /// UIKit adds the safe area to `contentInset`, so the inset is the keyboard's overlap less the
    /// safe area plus `caretMargin`: the last line can scroll that far above the formatting bar.
    @objc private func keyboardChanged(_ note: Notification) {
        guard let info = note.userInfo, let end = info[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let hiding = note.name == UIResponder.keyboardWillHideNotification
        keyboardFrame = hiding ? .zero : end
        guard window != nil else { return }
        let duration = info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        let curve = info[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? UInt(UIView.AnimationCurve.easeInOut.rawValue)
        UIView.animate(withDuration: duration, delay: 0, options: [UIView.AnimationOptions(rawValue: curve << 16), .beginFromCurrentState, .allowUserInteraction]) {
            self.updateKeyboardInsets()
            if !hiding { self.ensureCaretVisible(animated: false) }
        }
    }

    private func updateKeyboardInsets() {
        let overlap = keyboardOverlapHeight
        let covered = max(0, overlap - safeAreaInsets.bottom)
        let inset = overlap > 0 ? covered + Self.caretMargin : 0
        if contentInset.bottom != inset { contentInset.bottom = inset }
        // The indicator stops at the formatting bar (the safe area is added automatically).
        if verticalScrollIndicatorInsets.bottom != covered { verticalScrollIndicatorInsets.bottom = covered }
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        updateKeyboardInsets()
    }


    /// Scrolls the caret into view after the text view has laid out the latest change.
    func ensureCaretVisibleSoon() {
        DispatchQueue.main.async { [weak self] in self?.ensureCaretVisible(animated: true) }
    }

    /// Keeps the caret between the top bar and `caretMargin` above the keyboard.
    func ensureCaretVisible(animated: Bool) {
        guard isFirstResponder, selectedRange.length == 0, let end = selectedTextRange?.end else { return }
        layoutIfNeeded()
        let caret = caretRect(for: end)
        guard !caret.isNull, !caret.isInfinite, caret.height > 0 else { return }
        let inset = adjustedContentInset
        let top = contentOffset.y + inset.top
        let bottom = contentOffset.y + bounds.height - inset.bottom
        var y = contentOffset.y
        if caret.maxY > bottom {
            y += caret.maxY - bottom
        } else if caret.minY < top {
            y -= top - caret.minY + 8
        } else {
            return
        }
        let maxY = max(-inset.top, contentSize.height + inset.bottom - bounds.height)
        y = min(max(y, -inset.top), maxY)
        guard abs(y - contentOffset.y) > 0.5 else { return }
        setContentOffset(CGPoint(x: contentOffset.x, y: y), animated: animated)
    }

    /// Scrolls `range` to the top third of the part of the screen a medium sheet leaves
    /// uncovered, so the passage a comment or thread is about stays in view above the sheet.
    func reveal(_ range: NSRange) {
        guard NSMaxRange(range) <= (text as NSString).length,
              let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length),
              let textRange = textRange(from: start, to: end) else { return }
        layoutIfNeeded()
        let rect = firstRect(for: textRange)
        guard !rect.isNull, !rect.isInfinite else { return }
        let inset = adjustedContentInset
        // A medium detent covers about the lower half of the screen.
        let uncovered = max(0, bounds.height / 2 - inset.top)
        let maxY = max(-inset.top, contentSize.height + inset.bottom - bounds.height)
        let y = min(max(rect.minY - inset.top - uncovered / 3, -inset.top), maxY)
        setContentOffset(CGPoint(x: contentOffset.x, y: y), animated: true)
    }

    // MARK: Markdown editing rules (EDIT-31)

    /// True while a shared editing rule is being applied, so its own replacement isn't
    /// checked against the rules again.
    private(set) var isApplyingMarkdownEdit = false

    /// Applies one shared editing rule as a single undoable change, then restyles.
    func applyMarkdownEdit(_ edit: MarkdownEdit) {
        if !edit.isSelectionOnly {
            guard let start = position(from: beginningOfDocument, offset: edit.range.location),
                  let end = position(from: start, offset: edit.range.length),
                  let range = textRange(from: start, to: end) else { return }
            isApplyingMarkdownEdit = true
            replace(range, withText: edit.replacement)
            isApplyingMarkdownEdit = false
        }
        selectedRange = edit.selection
        if !edit.isSelectionOnly { delegate?.textViewDidChange?(self) }
    }

    /// A hardware keyboard's Tab and Shift-Tab nest and un-nest list items; elsewhere Tab
    /// types a tab as before.
    override var keyCommands: [UIKeyCommand]? {
        let tab = UIKeyCommand(title: "Indent", action: #selector(indentLine), input: "\t")
        let backtab = UIKeyCommand(title: "Outdent", action: #selector(outdentLine), input: "\t", modifierFlags: .shift)
        tab.wantsPriorityOverSystemBehavior = true
        backtab.wantsPriorityOverSystemBehavior = true
        return (super.keyCommands ?? []) + [tab, backtab]
    }

    @objc func indentLine() {
        guard markedTextRange == nil, let edit = MarkdownEditing.indent(in: text, selection: selectedRange) else {
            insertText("\t"); return
        }
        applyMarkdownEdit(edit)
    }

    @objc func outdentLine() {
        guard markedTextRange == nil, let edit = MarkdownEditing.outdent(in: text, selection: selectedRange) else { return }
        applyMarkdownEdit(edit)
    }

    /// Pasting list items or a heading into an empty item replaces its marker instead of
    /// stacking a second one; Windows line endings become plain ones.
    override func paste(_ sender: Any?) {
        if markedTextRange == nil, let pasted = UIPasteboard.general.string,
           let edit = MarkdownEditing.paste(pasted, in: text, selection: selectedRange) {
            applyMarkdownEdit(edit)
            return
        }
        super.paste(sender)
    }

    /// A caret at the start of a heading's text sits right after its hidden `#` marks, whose
    /// font is tiny; it takes the height of the heading's text instead.
    override func caretRect(for position: UITextPosition) -> CGRect {
        let rect = super.caretRect(for: position)
        guard rect.height < 4, let next = self.position(from: position, offset: 1) else { return rect }
        let fixed = super.caretRect(for: next)
        guard abs(fixed.minY - rect.minY) < fixed.height + 4 else { return rect }
        return CGRect(x: rect.minX, y: fixed.minY, width: rect.width, height: fixed.height)
    }
}
