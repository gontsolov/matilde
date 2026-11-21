import AppKit
import SwiftUI

struct ComparisonDifferences {
    let left: [NSRange]
    let right: [NSRange]
    static func between(_ left: String, _ right: String) -> Self {
        guard left != right else { return Self(left: [], right: []) }
        let lhs = left.components(separatedBy: "\n"), rhs = right.components(separatedBy: "\n")
        // Keep large manuscripts bounded; a contiguous replacement remains a correct coarse diff.
        guard lhs.count <= 2000, rhs.count <= 2000 else {
            let edit = WritingEdit.between(left, right)
            return Self(left: edit.range.length > 0 ? [edit.range] : [],
                        right: edit.insertedLength > 0 ? [NSRange(location: edit.range.location, length: edit.insertedLength)] : [])
        }
        func ranges(_ lines: [String]) -> [NSRange] {
            var offset = 0
            return lines.map { line in
                defer { offset += line.utf16.count + 1 }
                return NSRange(location: offset, length: line.utf16.count)
            }
        }
        let leftRanges = ranges(lhs), rightRanges = ranges(rhs)
        var removed: [NSRange] = [], inserted: [NSRange] = []
        for change in rhs.difference(from: lhs) {
            switch change {
            case .remove(let index, _, _): removed.append(leftRanges[index])
            case .insert(let index, _, _): inserted.append(rightRanges[index])
            }
        }
        return Self(left: removed, right: inserted)
    }
}

/// Persist native split proportions without moving the editor during ordinary re-layout.
struct ComparisonSplitPosition: NSViewRepresentable {
    let enabled: Bool
    let fraction: Double
    let changed: (Double) -> Void
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.enabled = enabled; view.fraction = fraction; view.changed = changed
        if !enabled { view.restored = false }
        view.schedule()
    }
    final class Probe: NSView {
        var enabled = false
        var fraction = 0.5
        var changed: ((Double) -> Void)?
        var restored = false
        private var applying = false
        private var observation: NSObjectProtocol?
        private weak var split: NSSplitView?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); schedule() }
        override func layout() { super.layout(); schedule() }
        func schedule() {
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }
        func attach() {
            guard enabled, let root = window?.contentView else { return }
            func find(_ view: NSView) -> NSSplitView? {
                func containsEditor(_ view: NSView) -> Bool {
                    view is WritingTextView || view.subviews.contains(where: containsEditor)
                }
                if let split = view as? NSSplitView, split.isVertical, split.arrangedSubviews.count == 2,
                   split.arrangedSubviews.allSatisfy(containsEditor) { return split }
                return view.subviews.lazy.compactMap(find).first
            }
            guard let target = find(root), target.bounds.width > 0 else { return }
            if split !== target {
                if let observation { NotificationCenter.default.removeObserver(observation) }
                split = target; restored = false
                observation = NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: target, queue: .main) { [weak self] _ in
                    guard let self, self.enabled, self.restored, !self.applying, let split = self.split, split.bounds.width > 0 else { return }
                    let proportion = split.arrangedSubviews[0].frame.width / split.bounds.width
                    DispatchQueue.main.async { [weak self] in self?.changed?(proportion) }
                }
            }
            if !restored {
                applying = true
                target.setPosition(target.bounds.width * min(0.8, max(0.2, fraction)), ofDividerAt: 0)
                restored = true; applying = false
            }
        }
        deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }
    }
}
