import SwiftUI
import AppKit

struct BranchMoment: Identifiable {
    let id = UUID()
    let sourceTitle: String
    let image: NSImage?
}

/// Captures only the writing pane, in memory, before the active draft changes.
struct PageCapture: NSViewRepresentable {
    var onReady: (@escaping () -> NSImage?) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        onReady { [weak view] in
            guard let view, let root = view.window?.contentView else { return nil }
            let rect = root.convert(view.bounds, from: view)
            guard rect.width > 0, rect.height > 0,
                  let bitmap = root.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
            root.cacheDisplay(in: rect, to: bitmap)
            let image = NSImage(size: rect.size)
            image.addRepresentation(bitmap)
            return image
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct TearAwayPage: View {
    let moment: BranchMoment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            if let image = moment.image, !reduceMotion {
                PageCurlView(image: image)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct DraftPreview: Identifiable {
    let draft: Draft
    let excerpt: String
    var id: String { draft.id }
}

struct DraftTray: View {
    @ObservedObject var model: AppModel
    let close: () -> Void
    @State private var previews: [DraftPreview] = []
    @State private var highlighted = ""
    @FocusState private var keyboardFocus: Bool
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(previews) { preview in
                        Button { open(preview.draft) } label: {
                            VStack(alignment: .leading, spacing: 9) {
                                HStack(spacing: 6) {
                                    Text(preview.draft.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Spacer(minLength: 0)
                                    if preview.id == model.active?.id {
                                        Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                                    }
                                }
                                Text(preview.excerpt.isEmpty ? "Empty draft" : preview.excerpt)
                                    .font(Font(Paper.body(16))).lineSpacing(3).lineLimit(3)
                                    .foregroundStyle(Color(Paper.muted)).frame(maxWidth: .infinity, alignment: .leading)
                                Spacer(minLength: 0)
                            }.padding(14).frame(width: 224, height: 126, alignment: .topLeading)
                                .background(Color(Paper.background), in: RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(Paper.accent).opacity(highlighted == preview.id ? 0.55 : 0.1), lineWidth: 1))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).id(preview.id)
                            .onHover { if $0 { highlighted = preview.id } }
                            .accessibilityLabel("\(preview.draft.title), \(preview.excerpt)")
                            .accessibilityAddTraits(preview.id == model.active?.id ? .isSelected : [])
                    }
                }.padding(.horizontal, 28).padding(.vertical, 12)
            }.scrollIndicators(.hidden)
                .focusable().focused($keyboardFocus).focusEffectDisabled()
                .onKeyPress(.leftArrow) { move(-1); return .handled }
                .onKeyPress(.rightArrow) { move(1); return .handled }
                .onKeyPress(.return) {
                    if let draft = previews.first(where: { $0.id == highlighted })?.draft { open(draft) }
                    return .handled
                }
                .onKeyPress(.escape) { close(); return .handled }
                .onChange(of: highlighted) { _, id in proxy.scrollTo(id, anchor: .center) }
                .onAppear {
                    model.attempt {
                        try model.flush()
                        previews = try model.related.map { draft in
                            let text = draft.id == model.active?.id ? model.text : try model.workspace?.read(draft) ?? ""
                            return DraftPreview(draft: draft, excerpt: Self.excerpt(text))
                        }
                    }
                    highlighted = model.active?.id ?? ""
                    keyboardFocus = true
                }
        }.frame(height: 150)
            .background(Color(Paper.ink).opacity(0.025))
    }
    private func move(_ offset: Int) {
        guard !previews.isEmpty else { return }
        let index = previews.firstIndex { $0.id == highlighted } ?? 0
        highlighted = previews[min(max(index + offset, 0), previews.count - 1)].id
    }
    private func open(_ draft: Draft) {
        model.select(draft)
        if model.active?.id == draft.id { close() }
    }
    static func excerpt(_ source: String) -> String {
        let trimmed = source.replacingOccurrences(of: "(?m)^\\s*(#{1,6} |[-*+] (?:\\[[ xX]\\] )?|> ?|```.*$)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\[([^]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "[*_`]", with: "", options: .regularExpression)
        return String(trimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(240))
    }
}
