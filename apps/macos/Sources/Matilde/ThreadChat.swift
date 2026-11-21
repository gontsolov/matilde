import AppKit
import SwiftUI

/// "Stick to bottom" for a streaming thread: follow new text only while the reader is at (or a
/// few points from) the end. Scrolling up stops following; scrolling back to the end resumes.
/// Growth from streamed text keeps the current decision, so a new line never re-pins or un-pins
/// the view; moving towards the top while text grows still counts as the reader scrolling up.
struct BottomFollower: Equatable {
    static let tolerance: CGFloat = 12
    private(set) var following = true
    private var contentHeight: CGFloat?
    private var contentTop: CGFloat?
    /// Set by `follow()` until the view reaches the end, so the jump itself is not read as scrolling up.
    private var jumping = false

    /// `contentTop` is the content's top edge in the viewport (zero or negative when scrolled).
    /// Returns whether to scroll to the end: the reader is following and the content grew past it,
    /// for example when a suggested rewrite finishes laying out below a reply.
    @discardableResult
    mutating func observe(contentTop top: CGFloat, contentHeight height: CGFloat, viewportHeight: CGFloat) -> Bool {
        let grew = contentHeight.map { height > $0 + 0.5 } ?? false
        defer { contentHeight = height; contentTop = top }
        let distance = height + top - viewportHeight
        if height <= viewportHeight + Self.tolerance { following = true; jumping = false; return false }
        if jumping {
            following = true
            if distance <= Self.tolerance { jumping = false }
            return grew && distance > Self.tolerance
        }
        if let previous = contentHeight, abs(previous - height) > 0.5 {
            if let previousTop = contentTop, top > previousTop + 0.5, distance > Self.tolerance { following = false }
            return following && grew && distance > Self.tolerance
        }
        following = distance <= Self.tolerance
        return false
    }
    /// Sending a message returns to the end of the thread.
    mutating func follow() { following = true; jumping = true }
}

/// Holds followers outside SwiftUI state, so scroll measurements never trigger a re-render.
final class BottomFollowers {
    private var values: [UUID: BottomFollower] = [:]
    subscript(id: UUID) -> BottomFollower {
        get { values[id] ?? BottomFollower() }
        set { values[id] = newValue }
    }
}

struct ThreadScrollMetrics: Equatable {
    var top: CGFloat
    var height: CGFloat
}

struct ThreadScrollMetricsKey: PreferenceKey {
    static var defaultValue: [UUID: ThreadScrollMetrics] = [:]
    static func reduce(value: inout [UUID: ThreadScrollMetrics], nextValue: () -> [UUID: ThreadScrollMetrics]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

enum ThreadSpeaker {
    /// The assistant's name is shown where the speaker changes, not above every message.
    static func showsAssistantLabel(at index: Int, roles: [String]) -> Bool {
        guard roles.indices.contains(index), roles[index] != "user" else { return false }
        return index == 0 || roles[index - 1] == "user"
    }
}

/// Places one view at the trailing edge, at most `fraction` of the available width.
struct TrailingBubbleLayout: Layout {
    var fraction: CGFloat = 0.8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        let child = subviews.first?.sizeThatFits(ProposedViewSize(width: width * fraction, height: nil)) ?? .zero
        return CGSize(width: width, height: child.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let size = child.sizeThatFits(ProposedViewSize(width: bounds.width * fraction, height: nil))
        child.place(at: CGPoint(x: bounds.maxX - size.width, y: bounds.minY), proposal: ProposedViewSize(size))
    }
}

/// The writer's message: right-aligned in a soft warm bubble.
struct UserMessageBubble: View {
    let text: String
    var body: some View {
        TrailingBubbleLayout {
            Text(text).font(.body).lineSpacing(3).textSelection(.enabled)
                .foregroundStyle(Color(Paper.ink))
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(Color(Paper.accent).opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You: " + text)
    }
}

/// Behind the composer: messages scroll under it and fade into the paper. A material masked by
/// the same gradient softens them as they go, approximating a progressive blur with public API.
struct ComposerFade: View {
    /// Height of the fade above the composer.
    static let fadeHeight: CGFloat = 28
    var body: some View {
        let mask = LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.55),
                                          .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom)
        ZStack {
            Rectangle().fill(.ultraThinMaterial).mask(mask).opacity(0.7)
            LinearGradient(stops: [.init(color: Color(Paper.background).opacity(0), location: 0),
                                   .init(color: Color(Paper.background).opacity(0.85), location: 0.45),
                                   .init(color: Color(Paper.background), location: 0.7)],
                           startPoint: .top, endPoint: .bottom)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Text in a comment composer: one line matches the 24-point send button, so text and
    /// button share a center; extra lines grow upwards with the button staying on the last line.
    func composerText() -> some View {
        font(.body).lineSpacing(3).padding(.vertical, 4).frame(minHeight: 24)
    }
    /// The round send/done/stop button beside a composer.
    func composerButton() -> some View {
        frame(width: 24, height: 24).contentShape(Circle())
    }
}

/// What Return does in a reply or comment composer: plain ↩ (or ⌘↩) sends, ⇧↩, ⌥↩ and ⌃↩ add
/// a line, and while an input method is composing, Return only confirms the composition.
enum ComposerReturn: Equatable {
    case send, newline

    static func action(modifiers: NSEvent.ModifierFlags, composing: Bool) -> ComposerReturn? {
        guard !composing else { return nil }
        let held = modifiers.intersection([.shift, .option, .control, .command])
        return held.isDisjoint(with: [.shift, .option, .control]) ? .send : .newline
    }

    /// Call from a composer's `onSubmit`; SwiftUI submits on every Return, whatever the modifiers.
    @MainActor static func handle(send: () -> Void) {
        let editor = NSApp.keyWindow?.firstResponder as? NSTextView
        let event = NSApp.currentEvent
        let modifiers = event?.type == .keyDown ? event?.modifierFlags ?? [] : []
        switch action(modifiers: modifiers, composing: editor?.hasMarkedText() ?? false) {
        case .send: send()
        case .newline: editor?.insertNewlineIgnoringFieldEditor(nil)
        case nil: break
        }
    }
}
