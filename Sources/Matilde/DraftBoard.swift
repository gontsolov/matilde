import SwiftUI

struct BoardFlight: Identifiable {
    let id = UUID()
    let draftID: String
    let opening: Bool
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
        .clipShape(RoundedRectangle(cornerRadius: 3 * t))
        .overlay(RoundedRectangle(cornerRadius: 3 * t)
            .strokeBorder(Color(Paper.accent).opacity(0.65 * cardOpacity), lineWidth: 2 * target.width / 260))
        .shadow(color: .black.opacity(0.12 * t), radius: 9 * t * target.width / 260,
                x: t * target.width / 260, y: 5 * t * target.width / 260)
        .position(x: width / 2 + target.minX * t, y: height / 2 + target.minY * t)
    }
}

struct DraftBoard: View {
    @ObservedObject var model: AppModel
    let open: (Draft) -> Void
    @FocusState private var focused: Bool
    @State private var panStart: BoardViewport?
    @State private var zoomStart: Double?
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
                    let interval: CGFloat = 28
                    let dx = CGFloat(-model.boardViewport.x * model.boardViewport.zoom).truncatingRemainder(dividingBy: interval)
                    let dy = CGFloat(-model.boardViewport.y * model.boardViewport.zoom).truncatingRemainder(dividingBy: interval)
                    for x in stride(from: dx, to: dimensions.width, by: interval) {
                        for y in stride(from: dy, to: dimensions.height, by: interval) {
                            dots.addEllipse(in: CGRect(x: x, y: y, width: 1.1, height: 1.1))
                        }
                    }
                    context.fill(dots, with: .color(Color(Paper.ink).opacity(0.12)))
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
                                .background(Color(Paper.background), in: RoundedRectangle(cornerRadius: 3))
                                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(Paper.accent).opacity(selectedID == sheet.id ? 0.65 : 0.12), lineWidth: selectedID == sheet.id ? 2 : 1))
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
                            .position(x: rect.midX, y: rect.midY)
                            .opacity(model.boardFlight?.draftID == sheet.id ? 0 : 1)
                            .accessibilityLabel("Open draft: \(sheet.draft.title)")
                    }
                }
            }
            .clipped().contentShape(Rectangle())
            .background(BoardScrollInput(onScroll: { dx, dy in
                guard model.boardFlight == nil else { return }
                model.boardViewport.x -= dx / model.boardViewport.zoom
                model.boardViewport.y -= dy / model.boardViewport.zoom
            }, onEnd: { model.persistBoard() }))
            .simultaneousGesture(DragGesture(minimumDistance: 5).onChanged { value in
                if panStart == nil { panStart = model.boardViewport }
                guard let start = panStart else { return }
                model.boardViewport.x = start.x - value.translation.width / start.zoom
                model.boardViewport.y = start.y - value.translation.height / start.zoom
            }.onEnded { _ in panStart = nil; model.persistBoard() })
            .simultaneousGesture(MagnifyGesture().onChanged { value in
                if zoomStart == nil { zoomStart = model.boardViewport.zoom }
                model.boardViewport.zoom = min(max((zoomStart ?? 1) * value.magnification, 0.08), 1.4)
            }.onEnded { _ in
                zoomStart = nil
                if model.boardViewport.zoom > 1.2, let sheet = model.boardSheets.first(where: { $0.id == selectedID }) { open(sheet.draft) }
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

    func makeNSView(context: Context) -> ScrollView { ScrollView() }
    func updateNSView(_ view: ScrollView, context: Context) {
        view.onScroll = onScroll
        view.onEnd = onEnd
    }
    static func dismantleNSView(_ view: ScrollView, coordinator: ()) { view.stop() }

    final class ScrollView: NSView {
        var onScroll: ((Double, Double) -> Void)?
        var onEnd: (() -> Void)?
        private var monitor: Any?
        private var saveWork: DispatchWorkItem?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      !self.isHiddenOrHasHiddenAncestor,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
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
            if !sheet.draft.goal.isEmpty {
                Label(sheet.draft.goal, systemImage: "flag").font(Font(Paper.body(13))).foregroundStyle(Color(Paper.muted)).lineLimit(2)
            }
            Text(sheet.excerpt.isEmpty ? "" : sheet.excerpt).font(Font(Paper.body(16))).lineSpacing(4).lineLimit(8).foregroundStyle(Color(Paper.ink).opacity(0.85))
            Spacer(minLength: 0)
            if active {
                Image(systemName: "pencil.tip").font(.system(size: 11)).foregroundStyle(Color(Paper.accent)).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }.padding(23).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
