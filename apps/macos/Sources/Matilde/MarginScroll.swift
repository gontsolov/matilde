import AppKit
import SwiftUI
import MatildeKit

/// The page scrolls as one surface: text and margin cards share the editor's scroll view.
/// Cards stay a SwiftUI overlay aligned to their passages; this supplies the two pieces the
/// overlay cannot provide by itself: scroll room below the text for cards that stack past its
/// end, and scrolling from anywhere in the writing space outside the editor.
enum MarginScroll {
    /// Space between stacked cards.
    static let gap: CGFloat = 12
    /// Card tops in passage order: each card sits at its passage unless the card above pushes it down.
    static func stack(anchors: [CGFloat], heights: [CGFloat], gap: CGFloat = MarginScroll.gap) -> [CGFloat] {
        var bottom = -CGFloat.infinity
        return zip(anchors, heights).map { anchor, height in
            let top = max(anchor, bottom + gap)
            bottom = top + height
            return top
        }
    }
    /// Bottom edge of the lowest card in the natural stack, or nil without cards.
    static func cardsBottom(anchors: [CGFloat], heights: [CGFloat], gap: CGFloat = MarginScroll.gap) -> CGFloat? {
        let tops = stack(anchors: anchors, heights: heights, gap: gap)
        return zip(tops, heights).map { $0 + $1 }.max()
    }
    /// The scrollable page height: the text with its bottom inset, or the lowest card with the
    /// same bottom padding, whichever reaches further.
    static func contentHeight(textHeight: CGFloat, bottomInset: CGFloat, cardsBottom: CGFloat?) -> CGFloat {
        max(textHeight + bottomInset, (cardsBottom ?? 0) + bottomInset)
    }
    /// The minimum page height the cards ask for. Growing applies at once; when cards leave, room
    /// that is on screen is kept until it scrolls out of view, so the page never jumps.
    static func retainedHeight(target: CGFloat, previous: CGFloat, visibleBottom: CGFloat) -> CGFloat {
        max(target, min(previous, visibleBottom))
    }
}

/// Sends scroll gestures over the margin (cards, gaps between them and the side padding) to the
/// editor's scroll view, so they scroll the page with native momentum and elasticity. Scroll views
/// under the pointer, such as the editor itself, a long thread or the stash, keep their own events.
struct MarginScrollForwarding: NSViewRepresentable {
    var enabled: Bool
    func makeNSView(context: Context) -> ForwardingView { ForwardingView() }
    func updateNSView(_ view: ForwardingView, context: Context) { view.enabled = enabled }
    static func dismantleNSView(_ view: ForwardingView, coordinator: ()) { view.stop() }
    final class ForwardingView: NSView {
        var enabled = false
        private var monitor: Any?
        /// Decided at the start of a gesture and kept through its momentum.
        private weak var target: NSScrollView?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return self.route(event)
            }
        }
        private func route(_ event: NSEvent) -> NSEvent? {
            guard event.window === window else { return event }
            let starts = event.phase == .mayBegin || event.phase == .began || (event.phase.isEmpty && event.momentumPhase.isEmpty)
            if starts { target = enabled ? pageScroll(for: event) : nil }
            guard let target else { return event }
            target.scrollWheel(with: event)
            return nil
        }
        private func pageScroll(for event: NSEvent) -> NSScrollView? {
            guard !isHiddenOrHasHiddenAncestor, !StashEventBoundary.Boundary.contains(event),
                  let content = window?.contentView,
                  bounds.contains(convert(event.locationInWindow, from: nil)),
                  let editor = Self.editor(in: content), let scroll = editor.enclosingScrollView else { return nil }
            let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
            var view = content.hitTest(point)
            while let current = view, !isDescendant(of: current) {
                if current is NSScrollView { return nil }
                view = current.superview
            }
            return scroll
        }
        private static func editor(in view: NSView) -> WritingTextView? {
            if let editor = view as? WritingTextView, editor.onEscape == nil { return editor }
            return view.subviews.lazy.compactMap(editor).first
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            target = nil
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
