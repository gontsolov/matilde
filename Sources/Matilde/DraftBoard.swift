import SwiftUI

struct BoardFlight: Identifiable {
    let id = UUID()
    let draftID: String
    var opening: Bool
    var interactive = false
}

/// Keep the writing dead zone, then decelerate as the sheet approaches the board.
enum WritingPinch {
    static func progress(_ magnification: CGFloat) -> CGFloat {
        let distance = max(0, -magnification - 0.03)
        let t = min(1, distance / 0.36)
        return 1 - pow(1 - t, 3)
    }
    static func commits(_ magnification: CGFloat) -> Bool { magnification <= -0.18 }

    /// Limit travel per second, then ease toward the finger's target. Cap elapsed
    /// time too so a delayed frame cannot turn into a visible catch-up jump.
    static func advance(_ current: CGFloat, toward target: CGFloat, elapsed: TimeInterval) -> CGFloat {
        let dt = max(0, min(elapsed, 1.0 / 30))
        let difference = min(1, max(0, target)) - current
        let eased = difference * CGFloat(1 - exp(-dt / 0.06))
        let limit = CGFloat(dt) * 5
        return current + min(limit, max(-limit, eased))
    }

    static func settleDuration(from progress: CGFloat) -> TimeInterval {
        // A short settle even after an abrupt release; never a long slow tail.
        max(0.18, Double(1 - min(1, max(0, progress))) * 0.42)
    }
}

enum BoardPageStyle {
    static let cornerRadius: CGFloat = 16
    static func radius(progress: CGFloat, zoom: CGFloat) -> CGFloat {
        cornerRadius * progress * (1 + (zoom - 1) * progress)
    }
}

/// Freeze the pointer's page and world position before zoom moves any sheets.
struct BoardZoom {
    let start: BoardViewport
    let anchor: CGPoint
    let draftID: String?

    static func target(at point: CGPoint, sheets: [(String, CGRect)]) -> String? {
        sheets.reversed().first { $0.1.contains(point) }?.0
    }

    func viewport(magnification: Double, size: CGSize) -> BoardViewport {
        let zoom = min(max(start.zoom * magnification, 0.08), 1.4)
        let dx = anchor.x - size.width / 2, dy = anchor.y - size.height / 2
        return BoardViewport(x: start.x + dx / start.zoom - dx / zoom,
                             y: start.y + dy / start.zoom - dy / zoom, zoom: zoom)
    }
}

/// Capture the whole native gesture even after the page moves away from the pointer.
struct WritingPinchInput: NSViewRepresentable {
    var enabled: Bool
    var changed: (CGFloat, NSEvent.Phase) -> Void
    func makeNSView(context: Context) -> InputView { InputView() }
    func updateNSView(_ view: InputView, context: Context) {
        view.enabled = enabled; view.changed = changed
    }
    static func dismantleNSView(_ view: InputView, coordinator: ()) { view.stop() }
    final class InputView: NSView {
        var enabled = false
        var changed: ((CGFloat, NSEvent.Phase) -> Void)?
        private var monitor: Any?
        private var resignation: NSObjectProtocol?
        private var tracking = false
        private var total: CGFloat = 0
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            resignation = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                 object: window, queue: .main) { [weak self] _ in
                guard let self, self.tracking else { return }
                self.tracking = false
                self.changed?(self.total, .cancelled)
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .keyDown]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                if StashEventBoundary.Boundary.contains(event) { return event.type == .magnify ? nil : event }
                if event.type == .keyDown {
                    if self.tracking {
                        self.tracking = false
                        self.changed?(self.total, .cancelled)
                        return nil
                    }
                    return event
                }
                if event.phase == .began {
                    self.tracking = self.enabled && !self.isHiddenOrHasHiddenAncestor &&
                        self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                    self.total = 0
                }
                guard self.tracking else { return event }
                self.total += event.magnification
                self.changed?(self.total, event.phase)
                if event.phase == .ended || event.phase == .cancelled { self.tracking = false }
                return nil
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if let resignation { NotificationCenter.default.removeObserver(resignation) }
            resignation = nil
            if tracking { tracking = false; changed?(total, .cancelled) }
        }
        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let resignation { NotificationCenter.default.removeObserver(resignation) }
        }
    }
}

/// One mounted editor, rendered at a fixed layout size throughout the flight.
/// Only its composited scale and clipping bounds change; text never reflows.
struct BoardPageSurface<Editor: View>: View, Animatable {
    var amount: CGFloat
    let size: CGSize
    let target: CGRect
    let sheet: BoardSheet?
    let editor: Editor
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }
    var body: some View {
        let t = min(max(amount, 0), 1)
        let width = size.width + (target.width - size.width) * t
        let height = size.height + (target.height - size.height) * t
        let blend = min(max((t - 0.45) / 0.5, 0), 1)
        let cardOpacity = blend * blend * (3 - 2 * blend)
        let radius = BoardPageStyle.radius(progress: t, zoom: target.width / 260)
        ZStack(alignment: .topLeading) {
            Color(Paper.background)
            editor.frame(width: size.width, height: size.height)
                .scaleEffect(width / max(size.width, 1), anchor: .topLeading)
                .opacity(1 - cardOpacity)
            if let sheet {
                BoardPageContent(sheet: sheet, active: true)
                    .frame(width: 260, height: 340)
                    .scaleEffect(width / 260, anchor: .topLeading)
                    .opacity(cardOpacity)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: max(width, 1), height: max(height, 1), alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(Color(Paper.accent).opacity(0.65 * cardOpacity), lineWidth: 2 * target.width / 260))
        .shadow(color: .black.opacity(0.12 * t), radius: 9 * t * target.width / 260,
                x: t * target.width / 260, y: 5 * t * target.width / 260)
        .position(x: width / 2 + target.minX * t, y: height / 2 + target.minY * t)
    }
}

struct DraftBoard: View {
    @AppStorage(SettingKeys.canvasDots) private var showDots = true
    @ObservedObject var model: AppModel
    let open: (Draft) -> Void
    @FocusState private var focused: Bool
    @State private var panStart: BoardViewport?
    @State private var boardZoom: BoardZoom?
    @State private var selectedID = ""
    @State private var hoveredID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                Color(red: 0.916, green: 0.915, blue: 0.890)
                Canvas { context, dimensions in
                    var dots = Path()
                    // Screen-space spacing keeps the texture quiet at every zoom.
                    // Offset it with the viewport so panning never looks stationary.
                    let interval: CGFloat = 20
                    let dx = CGFloat(-model.boardViewport.x * model.boardViewport.zoom).truncatingRemainder(dividingBy: interval)
                    let dy = CGFloat(-model.boardViewport.y * model.boardViewport.zoom).truncatingRemainder(dividingBy: interval)
                    for x in stride(from: dx, to: dimensions.width, by: interval) {
                        for y in stride(from: dy, to: dimensions.height, by: interval) {
                            dots.addEllipse(in: CGRect(x: x, y: y, width: 1.6, height: 1.6))
                        }
                    }
                    if showDots { context.fill(dots, with: .color(Color(Paper.ink).opacity(0.25))) }
                    for sheet in model.boardSheets {
                        guard let parentID = sheet.draft.parent, let parent = model.boardSheets.first(where: { $0.id == parentID }) else { continue }
                        let a = model.sheetRect(parent.id, in: size), b = model.sheetRect(sheet.id, in: size)
                        var connection = Path()
                        connection.move(to: CGPoint(x: a.maxX, y: a.midY))
                        connection.addCurve(to: CGPoint(x: b.minX, y: b.midY), control1: CGPoint(x: a.maxX + 35, y: a.midY), control2: CGPoint(x: b.minX - 35, y: b.midY))
                        context.stroke(connection, with: .color(Color(Paper.ink).opacity(0.22)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    }
                }.allowsHitTesting(false)
                ForEach(model.boardSheets) { sheet in
                    let rect = model.sheetRect(sheet.id, in: size)
                    if rect.intersects(CGRect(origin: .zero, size: size).insetBy(dx: -300, dy: -400)) {
                        Button { selectedID = sheet.id; open(sheet.draft) } label: {
                            BoardPageContent(sheet: sheet, active: sheet.id == model.active?.id)
                                .frame(width: 260, height: 340)
                                .background(Color(Paper.background), in: RoundedRectangle(cornerRadius: BoardPageStyle.cornerRadius, style: .continuous))
                                .clipShape(RoundedRectangle(cornerRadius: BoardPageStyle.cornerRadius, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: BoardPageStyle.cornerRadius, style: .continuous).strokeBorder(Color(Paper.accent).opacity(selectedID == sheet.id ? 0.65 : 0.12), lineWidth: selectedID == sheet.id ? 2 : 1))
                                .shadow(color: .black.opacity(hoveredID == sheet.id ? 0.19 : 0.12), radius: hoveredID == sheet.id ? 16 : 9, x: 1, y: hoveredID == sheet.id ? 10 : 5)
                                .scaleEffect(model.boardViewport.zoom, anchor: .topLeading)
                                .frame(width: rect.width, height: rect.height, alignment: .topLeading)
                                .offset(y: hoveredID == sheet.id && !reduceMotion ? -4 : 0)
                                .animation(.easeOut(duration: 0.15), value: hoveredID == sheet.id)
                        }.buttonStyle(.plain)
                            .background(PagePointer())
                            .onHover { inside in
                                hoveredID = inside ? sheet.id : (hoveredID == sheet.id ? nil : hoveredID)
                            }
                            .accessibilityLabel("Open draft: \(sheet.draft.title)")
                            .contextMenu {
                                Button("Move to Trash", systemImage: "trash", role: .destructive) { model.trashDraft(sheet.draft) }
                            }
                            .position(x: rect.midX, y: rect.midY)
                            .opacity(model.boardFlight?.draftID == sheet.id ? 0 : 1)
                    }
                }
            }
            .clipped().contentShape(Rectangle())
            .background(BoardScrollInput(onScroll: { dx, dy in
                guard model.boardFlight == nil else { return }
                model.boardViewport.x -= dx / model.boardViewport.zoom
                model.boardViewport.y -= dy / model.boardViewport.zoom
            }, onEnd: { model.persistBoard() }, onMagnifyStart: { point in
                guard model.boardFlight == nil else { return }
                let target = BoardZoom.target(at: point, sheets: model.boardSheets.map {
                    ($0.id, model.sheetRect($0.id, in: size).offsetBy(dx: 0, dy: hoveredID == $0.id && !reduceMotion ? -4 : 0))
                })
                boardZoom = BoardZoom(start: model.boardViewport, anchor: point, draftID: target)
                if let target { selectedID = target }
            }))
            .simultaneousGesture(DragGesture(minimumDistance: 5).onChanged { value in
                if panStart == nil { panStart = model.boardViewport }
                guard let start = panStart else { return }
                model.boardViewport.x = start.x - value.translation.width / start.zoom
                model.boardViewport.y = start.y - value.translation.height / start.zoom
            }.onEnded { _ in panStart = nil; model.persistBoard() })
            .simultaneousGesture(MagnifyGesture().onChanged { value in
                guard model.boardFlight == nil, let boardZoom else { return }
                model.boardViewport = boardZoom.viewport(magnification: value.magnification, size: size)
            }.onEnded { value in
                let target = boardZoom?.draftID
                boardZoom = nil
                if value.magnification > 1, model.boardViewport.zoom > 1.2,
                   let sheet = model.boardSheets.first(where: { $0.id == target }) { open(sheet.draft) }
                else { model.persistBoard() }
            })
            .focusable().focused($focused).focusEffectDisabled()
            .onKeyPress(.escape) { if let active = model.active { open(active) }; return .handled }
            .onKeyPress(.return) { if let sheet = model.boardSheets.first(where: { $0.id == selectedID }) { open(sheet.draft) }; return .handled }
            .onKeyPress(.leftArrow) { select(-1, size: size); return .handled }
            .onKeyPress(.rightArrow) { select(1, size: size); return .handled }
            .overlay(alignment: .bottom) {
                HStack(spacing: 16) {
                    Button { zoom(0.8) } label: { Image(systemName: "minus") }.help("Zoom out").accessibilityLabel("Zoom out")
                    Text("\(Int(model.boardViewport.zoom * 100))% ").monospacedDigit().frame(width: 42)
                    Button { zoom(1.25) } label: { Image(systemName: "plus") }.help("Zoom in").accessibilityLabel("Zoom in")
                    Divider().frame(height: 14)
                    Button { model.fitBoard(size: size) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("Fit drafts").accessibilityLabel("Fit drafts")
                }.font(.system(size: 12)).buttonStyle(.plain).padding(.horizontal, 18).padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule()).padding(.bottom, 22)
            }
            .onAppear { selectedID = model.active?.id ?? ""; focused = true }
            .onChange(of: model.boardSheets.map(\.id)) { _, ids in
                if !ids.contains(selectedID) { selectedID = model.active?.id ?? "" }
            }
        }
    }
    private func zoom(_ factor: Double) {
        model.boardViewport.zoom = min(max(model.boardViewport.zoom * factor, 0.08), 1.4)
        model.persistBoard()
    }
    private func select(_ delta: Int, size: CGSize) {
        guard !model.boardSheets.isEmpty else { return }
        let index = model.boardSheets.firstIndex { $0.id == selectedID } ?? 0
        let sheet = model.boardSheets[min(max(index + delta, 0), model.boardSheets.count - 1)]
        selectedID = sheet.id
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            model.boardViewport.x = sheet.position.x + 130
            model.boardViewport.y = sheet.position.y + 170
        }
        model.persistBoard()
    }
}

private struct PagePointer: NSViewRepresentable {
    func makeNSView(context: Context) -> PointerView { PointerView() }
    func updateNSView(_ view: PointerView, context: Context) {
        view.window?.invalidateCursorRects(for: view)
    }
    final class PointerView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

/// Observe scrolling inside this canvas without intercepting sheet clicks or pinch gestures.
private struct BoardScrollInput: NSViewRepresentable {
    var onScroll: (Double, Double) -> Void
    var onEnd: () -> Void
    var onMagnifyStart: (CGPoint) -> Void

    func makeNSView(context: Context) -> ScrollView { ScrollView() }
    func updateNSView(_ view: ScrollView, context: Context) {
        view.onScroll = onScroll
        view.onEnd = onEnd
        view.onMagnifyStart = onMagnifyStart
    }
    static func dismantleNSView(_ view: ScrollView, coordinator: ()) { view.stop() }

    final class ScrollView: NSView {
        var onScroll: ((Double, Double) -> Void)?
        var onEnd: (() -> Void)?
        var onMagnifyStart: ((CGPoint) -> Void)?
        override var isFlipped: Bool { true }
        private var monitor: Any?
        private var saveWork: DispatchWorkItem?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      !self.isHiddenOrHasHiddenAncestor,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                if StashEventBoundary.Boundary.contains(event) { return event.type == .magnify ? nil : event }
                if event.type == .magnify {
                    if event.phase == .began { self.onMagnifyStart?(self.convert(event.locationInWindow, from: nil)) }
                    return event
                }
                let factor = event.hasPreciseScrollingDeltas ? 1.0 : 24.0
                self.onScroll?(event.scrollingDeltaX * factor, event.scrollingDeltaY * factor)
                self.saveWork?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.onEnd?() }
                self.saveWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
                return nil
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if saveWork != nil { saveWork?.cancel(); saveWork = nil; onEnd?() }
        }
        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            saveWork?.cancel()
        }
    }
}

struct BoardPageContent: View {
    let sheet: BoardSheet
    let active: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Spacer()
                Circle().fill(Color(Paper.accent).gradient).frame(width: 7, height: 7)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 2)
                Spacer()
            }.padding(.bottom, 5)
            Text(sheet.draft.title).font(Font(Paper.body(23, bold: true))).lineLimit(3)
            Text(sheet.excerpt.isEmpty ? "" : sheet.excerpt).font(Font(Paper.body(16))).lineSpacing(4).lineLimit(8).foregroundStyle(Color(Paper.ink).opacity(0.85))
            Spacer(minLength: 0)
            HStack {
                DraftTimestamp(draft: sheet.draft)
                Spacer(minLength: 4)
                if active {
                    Image(systemName: "pencil.tip").font(.system(size: 11)).foregroundStyle(Color(Paper.accent))
                }
            }
        }.padding(23).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
