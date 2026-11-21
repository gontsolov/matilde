import SwiftUI
import AppKit
import MatildeKit

@MainActor
final class StashModel: ObservableObject {
    @Published var text = ""
    @Published var isOpen = false
    private(set) var family: String?
    private var workspace: Workspace?
    private var saved = ""
    var cursor = 0
    var scroll = 0.0
    weak var editor: WritingTextView?
    weak var returnResponder: NSResponder?
    private var saveTask: Task<Void, Never>?
    var reportError: (String) -> Void = { _ in }

    func load(workspace: Workspace?, family: String?) throws {
        guard self.workspace !== workspace || self.family != family else { return }
        try flush()
        let text = try family.flatMap { try workspace?.readStash($0) } ?? ""
        let key = "stash:\(family ?? "")"
        let cursor = Int(try workspace?.state(key + ":cursor") ?? "") ?? 0
        let scroll = Double(try workspace?.state(key + ":scroll") ?? "") ?? 0
        isOpen = false; returnResponder = nil
        self.workspace = workspace; self.family = family
        self.text = text; saved = text; self.cursor = cursor; self.scroll = scroll
    }
    func edited(_ value: String) {
        text = value
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            guard let self else { return }
            do { try self.flush() } catch { self.reportError(error.localizedDescription) }
        }
    }
    func flush() throws {
        saveTask?.cancel()
        guard let workspace, let family else { return }
        if text != saved {
            try workspace.saveStash(family, text: text, expected: saved)
            saved = text
        }
        try workspace.setState("stash:\(family):cursor", String(cursor))
        try workspace.setState("stash:\(family):scroll", String(scroll))
    }
    func poll() throws {
        guard let workspace, let family else { return }
        let disk = try workspace.readStash(family)
        guard disk != saved else { return }
        if text != saved { try flush() }
        else { text = disk; saved = disk }
    }
    func toggle() {
        do {
            if isOpen { try close() }
            else {
                try poll()
                returnResponder = NSApp.keyWindow?.firstResponder
                isOpen = true
                editor?.window?.makeFirstResponder(editor)
            }
        } catch { reportError(error.localizedDescription) }
    }
    func close(restoreFocus: Bool = true) throws {
        try flush()
        guard isOpen else { return }
        isOpen = false
        if restoreFocus, let returnResponder { NSApp.keyWindow?.makeFirstResponder(returnResponder) }
        returnResponder = nil
    }
    func reloadPreservingChanges() {
        do {
            guard let workspace, let family else { return }
            let disk = try workspace.readStash(family)
            if text != saved {
                let directory = try workspace.stashDirectory()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let recovery = directory.appendingPathComponent("\(family)-recovery-\(UUID().uuidString).md")
                try text.write(to: recovery, atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([recovery])
            }
            saveTask?.cancel()
            text = disk; saved = disk
        } catch { reportError(error.localizedDescription) }
    }
    func reveal(all: Bool = false) {
        do {
            guard let workspace else { return }
            let directory = try workspace.stashDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = try family.map { try workspace.stashURL($0) }
            NSWorkspace.shared.activateFileViewerSelecting([!all && url.map { FileManager.default.fileExists(atPath: $0.path) } == true ? url! : directory])
        } catch { reportError(error.localizedDescription) }
    }
}

enum StashLayout {
    static func height(content: CGFloat, header: CGFloat, available: CGFloat) -> CGFloat {
        max(1, min(max(420, content + header), available - 16))
    }
}

private struct StashHeaderHeight: PreferenceKey {
    static var defaultValue: CGFloat = 32
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct StashPocket: View {
    @ObservedObject var stash: StashModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(SettingKeys.lineSpacing) private var lineSpacing = 9.0
    @State private var contentHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 32
    var size: CGSize
    var body: some View {
        let width = max(1, min(420, size.width - 32))
        let height = StashLayout.height(content: contentHeight, header: headerHeight, available: size.height)
        let family = stash.family
        let panelShape = UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12)
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                HStack {
                    Text("Stash").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button { stash.toggle() } label: { MatildeIcon.close.image(size: 14) }
                        .buttonStyle(.plain).accessibilityLabel("Close Stash")
                }.padding(.horizontal, 16).padding(.top, 16)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: StashHeaderHeight.self, value: geometry.size.height)
                    })
                MarkdownEditor(draftID: "stash:" + (stash.family ?? ""), text: stash.text,
                               initialCursor: stash.cursor, initialScroll: stash.scroll,
                               onChange: stash.edited, onPosition: { stash.cursor = $0; stash.scroll = $1 },
                               focusOnLoad: false, textSize: 17, lineSpacing: lineSpacing,
                               accessibilityName: "Stash editor", onMount: { stash.editor = $0 },
                               onEscape: { stash.toggle() },
                               textInsets: NSSize(width: 16, height: 16), fragmentPadding: 0,
                               onContentHeight: { measured in
                                   DispatchQueue.main.async {
                                       guard stash.family == family, abs(contentHeight - measured) > 0.5 else { return }
                                       contentHeight = measured
                                   }
                               })
                    .overlay(alignment: .topLeading) {
                        if stash.text.isEmpty {
                            Text("Loose thoughts, cut passages…").font(.custom("Newsreader", size: 17))
                                .foregroundStyle(.tertiary).padding(.leading, 16).padding(.top, 16).allowsHitTesting(false)
                        }
                    }
            }
            .frame(width: width, height: height)
            .background(StashEventBoundary(enabled: stash.isOpen))
            .background(Color(Paper.background))
            .clipShape(panelShape)
            .overlay(panelShape.stroke(Color(Paper.ink).opacity(0.12)))
            .shadow(color: .black.opacity(stash.isOpen ? 0.14 : 0), radius: 18, x: 0, y: 5)
            .offset(y: reduceMotion ? 0 : stash.isOpen ? 0 : height + 12)
            .opacity(stash.isOpen ? 1 : 0)
            .allowsHitTesting(stash.isOpen).accessibilityHidden(!stash.isOpen)
        }
        .onPreferenceChange(StashHeaderHeight.self) { headerHeight = $0 }
        .foregroundStyle(Color(Paper.ink))
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82), value: stash.isOpen)
        .padding(.trailing, 16)
    }
}

// Native event monitors must leave the overlay's scroll and pinch events alone.
struct StashEventBoundary: NSViewRepresentable {
    var enabled: Bool
    func makeNSView(context: Context) -> Boundary { Boundary() }
    func updateNSView(_ view: Boundary, context: Context) { view.enabled = enabled }
    final class Boundary: NSView {
        static let views = NSHashTable<Boundary>.weakObjects()
        var enabled = false
        override init(frame: NSRect) { super.init(frame: frame); Self.views.add(self) }
        required init?(coder: NSCoder) { fatalError() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        static func contains(_ event: NSEvent) -> Bool {
            views.allObjects.contains { $0.enabled && $0.window === event.window && !$0.isHiddenOrHasHiddenAncestor && $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) }
        }
    }
}
