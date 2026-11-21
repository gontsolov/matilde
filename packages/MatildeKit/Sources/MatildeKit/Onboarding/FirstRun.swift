import Foundation

/// The first-time tour on iPhone (welcome → three pages → start writing), shown once.
public struct FirstRunTour: Equatable, Sendable {
    public static let seenKey = "onboarding.firstRunSeen"
    public static let pageCount = 3

    public enum Screen: Equatable, Sendable {
        case welcome
        case page(Int)
        case finish
    }

    public private(set) var screen: Screen = .welcome

    public init() {}

    /// Shown when the flag isn't set yet.
    public static func shouldShow(_ defaults: UserDefaults) -> Bool { !defaults.bool(forKey: seenKey) }
    public static func markSeen(_ defaults: UserDefaults) { defaults.set(true, forKey: seenKey) }
    /// Settings → Show Welcome Again.
    public static func reset(_ defaults: UserDefaults) { defaults.removeObject(forKey: seenKey) }

    public mutating func next() {
        switch screen {
        case .welcome: screen = .page(0)
        case .page(let index): screen = index + 1 < Self.pageCount ? .page(index + 1) : .finish
        case .finish: break
        }
    }

    public mutating func back() {
        switch screen {
        case .welcome: break
        case .page(let index): screen = index == 0 ? .welcome : .page(index - 1)
        case .finish: screen = .page(Self.pageCount - 1)
        }
    }

    /// The carousel's index: pages 0…2, the finish page 3.
    public var carouselIndex: Int? {
        switch screen {
        case .welcome: return nil
        case .page(let index): return index
        case .finish: return Self.pageCount
        }
    }

    /// A swipe in the carousel landed on `index`.
    public mutating func show(carouselIndex index: Int) {
        if index >= Self.pageCount { screen = .finish } else { screen = .page(max(0, index)) }
    }
}

/// Pull down to search (iOS notes list): how far the list is pulled past its top decides whether
/// letting go opens search. Pure numbers, so it can be tested; the view feeds it the overscroll.
public struct PullToSearch: Equatable, Sendable {
    /// Points past the top at which letting go opens search.
    public static let threshold: Double = 72
    /// Below this, nothing is shown yet (ordinary bounces).
    public static let revealStart: Double = 8

    public enum Mode: Equatable, Sendable { case browsing, searching }

    public private(set) var mode: Mode = .browsing
    /// Current overscroll in points (0 when not pulled).
    public private(set) var pull: Double = 0
    /// Whether the pull is past the threshold; flips drive the haptic.
    public private(set) var armed = false
    /// Bumped each time `armed` flips while dragging (for `.sensoryFeedback`).
    public private(set) var armChanges = 0

    public init() {}

    /// 0…1: how far the affordance has grown toward the threshold.
    public var reveal: Double {
        guard pull > Self.revealStart else { return 0 }
        return min(1, (pull - Self.revealStart) / (Self.threshold - Self.revealStart))
    }

    /// The finger moved: `overscroll` is how far the content is pulled below its resting top.
    public mutating func dragged(overscroll: Double) {
        guard mode == .browsing else { return }
        pull = max(0, overscroll)
        let nowArmed = pull >= Self.threshold
        if nowArmed != armed {
            armed = nowArmed
            armChanges += 1
        }
    }

    /// The finger lifted. Returns true when that opened search.
    @discardableResult
    public mutating func released() -> Bool {
        defer { pull = 0; armed = false }
        guard mode == .browsing, armed else { return false }
        mode = .searching
        return true
    }

    /// The magnifier button or the VoiceOver action.
    public mutating func open() {
        mode = .searching
        pull = 0
        armed = false
    }

    /// Cancel, Escape, or the keyboard dismissed with an empty query.
    public mutating func close() {
        mode = .browsing
        pull = 0
        armed = false
    }

    /// Dismissing the keyboard leaves search only when nothing was typed.
    public mutating func keyboardDismissed(query: String) {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { close() }
    }
}
