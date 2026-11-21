#if canImport(AppKit)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MatildeKit

/// The Sync tab in Settings (SYNC-07): an invitation to the guided setup (`SyncSetupSheet`) until
/// sync is on, then the status, the account, the signed-in devices, Sync Now and Sign Out.
struct SyncSettingsView: View {
    @ObservedObject var center = SyncCenter.shared
    @State private var settingUp = false

    var body: some View {
        Form {
            switch center.phase {
            case .ready:
                Section {
                    LabeledContent("Status", value: statusText)
                    if let email = center.signedInEmail { LabeledContent("Account", value: email) }
                    HStack {
                        Button("Sync Now") { center.syncNow() }.disabled(center.syncing)
                        Button("Sign Out") { center.signOut(); center.setEnabled(false) }
                    }
                } footer: {
                    Text("End-to-end encrypted. The server can’t read your notes.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !center.devices.isEmpty {
                    Section("Signed-in devices") {
                        ForEach(center.devices) { device in
                            Label {
                                Text(device.name)
                                if device.isCurrent { Text("This Mac").foregroundStyle(.secondary) }
                            } icon: {
                                Image(systemName: device.symbolName)
                            }
                        }
                    }
                }
            case .off, .signedOut:
                Section {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "laptopcomputer.and.iphone")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(SyncOnboardingCopy.callToActionTitle).font(.headline)
                            Text(SyncOnboardingCopy.callToActionText).foregroundStyle(.secondary)
                            Button("Set Up Sync…") { settingUp = true }
                                .controlSize(.large)
                                .keyboardShortcut(.defaultAction)
                                .padding(.top, 4)
                        }
                    }
                    .padding(.vertical, 4)
                }
            case .updateRequired:
                Section { Text(SyncOnboardingCopy.updateText) }
            case .awaitingCode, .checkingKey, .needsRecoveryKey, .showRecoveryKey:
                Section {
                    HStack {
                        Button("Finish Setting Up Sync…") { settingUp = true }
                        Button("Sign Out") { center.signOut(); center.setEnabled(false) }
                    }
                }
            }
            if SyncServerSelection.showsPicker {
                Section {
                    Picker("Server", selection: Binding(get: { center.server.isStaging }, set: { center.setServer($0 ? .staging : .production) })) {
                        Text("Matilde").tag(false)
                        Text("Staging").tag(true)
                    }
                } footer: {
                    Text("Debug builds only.").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { center.loadDevices() }
        .onChange(of: center.phase) { _, phase in if phase == .ready { center.loadDevices() } }
        .sheet(isPresented: $settingUp) {
            SyncSetupSheet(center: center)
        }
    }

    private var statusText: String {
        if center.syncing { return "Syncing…" }
        if !center.status.isEmpty { return center.status }
        guard let last = center.lastSynced else { return "Waiting" }
        return "Synced \(last.formatted(date: .omitted, time: .shortened))"
    }
}

/// The guided setup on the Mac: the same steps and words as on the iPhone
/// (`SyncOnboardingFlow`, `SyncOnboardingCopy`), in a sheet over Settings. Sized to its content;
/// steps slide (or fade, with Reduce Motion) into one another.
struct SyncSetupSheet: View {
    @ObservedObject var center: SyncCenter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flow: SyncOnboardingFlow
    @State private var email = ""
    @State private var key = ""
    @State private var saved = false
    @State private var shakes: CGFloat = 0

    init(center: SyncCenter) {
        self.center = center
        _flow = State(initialValue: SyncOnboardingFlow(phase: center.setupPhase))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProgressView(value: flow.progress)
                .progressViewStyle(.linear)
                .tint(Color(Paper.accent))
                .opacity(flow.step == .intro || flow.step == .done ? 0 : 1)
                .padding(.bottom, 22)
            content
                .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
                .id(stepID)
                .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                                  removal: .move(edge: .leading).combined(with: .opacity)))
            if let message = center.message, flow.step != .done {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
                    .transition(.opacity)
            }
            HStack(spacing: 12) {
                if flow.step != .done {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(MacQuietButtonStyle(tone: .muted))
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                actions
            }
            .frame(minHeight: 34)
            .padding(.top, 24)
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 22)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .clipped()
        .background(Color(Paper.background))
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.12), value: stepID)
        .animation(.easeInOut(duration: 0.2), value: center.message)
        .onAppear { if let known = center.signedInEmail { email = known }; feed() }
        .onChange(of: center.setupPhase) { _, _ in feed() }
        .onChange(of: center.syncing) { _, _ in feed() }
        .onChange(of: center.lastSynced) { _, _ in feed() }
        .onChange(of: center.message) { _, message in if message != nil { flow.failed() } }
        .onChange(of: flow.failures) { _, _ in
            withAnimation(reduceMotion ? nil : .linear(duration: 0.45)) { shakes += 1 }
        }
        .onDisappear {
            // Closed before signing in: leave sync off, as it was.
            if center.setupPhase == .signedOut { center.setEnabled(false) }
        }
    }

    private func feed() { flow.update(phase: center.setupPhase, syncing: center.syncing, lastSynced: center.lastSynced) }

    private var stepID: String {
        switch flow.step {
        case .intro: "intro"
        case .email: "email"
        case .code: "code"
        case .signingIn: "signingIn"
        case .saveKey: "saveKey"
        case .enterKey: "enterKey"
        case .syncing: "syncing"
        case .done: "done"
        case .updateRequired: "update"
        }
    }

    @ViewBuilder private var content: some View {
        switch flow.step {
        case .intro:
            VStack(alignment: .leading, spacing: 16) {
                MacStepHeader(title: SyncOnboardingCopy.introTitle, text: SyncOnboardingCopy.introText)
                ForEach(SyncOnboardingCopy.points) { point in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: point.symbol).font(.system(size: 17)).foregroundStyle(Color(Paper.accent)).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(point.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(Paper.ink))
                            Text(point.text).font(.system(size: 13)).foregroundStyle(Color(Paper.muted))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Text(SyncOnboardingCopy.introFootnote).font(.footnote).foregroundStyle(Color(Paper.muted))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .email:
            VStack(alignment: .leading, spacing: 20) {
                MacStepHeader(title: SyncOnboardingCopy.emailTitle, text: SyncOnboardingCopy.emailText)
                MacEmailField(email: $email, onSubmit: sendCode)
            }
        case .code(let address):
            MacCodeStep(center: center, email: address, failures: flow.failures, shakes: shakes)
        case .signingIn:
            MacStatusStep(symbol: "checkmark.circle.fill", title: SyncOnboardingCopy.signingInTitle,
                          text: SyncOnboardingCopy.signingInText, success: true, working: true)
        case .saveKey(let recovery):
            MacSaveKeyStep(center: center, recovery: recovery, saved: $saved)
        case .enterKey:
            VStack(alignment: .leading, spacing: 16) {
                MacStepHeader(title: SyncOnboardingCopy.enterKeyTitle, text: SyncOnboardingCopy.enterKeyText)
                MacInputField(placeholder: "MTLD-XXXX-XXXX-…", text: $key,
                              font: .system(size: 17, weight: .medium, design: .monospaced),
                              highlighted: RecoveryKeyInput.state(of: key) == .valid, onSubmit: unlock)
                    .modifier(MacShake(shakes: shakes))
                    .task {
                        // A copy another device kept in iCloud Keychain fills the field.
                        guard key.isEmpty, let stored = await center.storedRecoveryKey() else { return }
                        key = RecoveryKeyInput.formatted(stored)
                    }
                if let message = RecoveryKeyInput.message(for: RecoveryKeyInput.state(of: key)) {
                    Text(message).foregroundStyle(Color(nsColor: .systemRed)).font(.callout)
                } else if RecoveryKeyInput.state(of: key) == .valid {
                    Label("Looks right", systemImage: "checkmark.circle").foregroundStyle(Color(Paper.accent)).font(.callout)
                }
            }
        case .syncing:
            MacStatusStep(symbol: "arrow.triangle.2.circlepath", title: SyncOnboardingCopy.syncingTitle,
                          text: SyncOnboardingCopy.syncingText, working: true)
        case .done:
            MacStatusStep(symbol: "checkmark.circle.fill", title: SyncOnboardingCopy.doneTitle,
                          text: SyncOnboardingCopy.doneText, success: true)
        case .updateRequired:
            MacStatusStep(symbol: "arrow.down.app", title: SyncOnboardingCopy.updateTitle, text: SyncOnboardingCopy.updateText)
        }
    }

    @ViewBuilder private var actions: some View {
        switch flow.step {
        case .intro:
            Button("Continue") { center.setEnabled(true); flow.begin() }
                .buttonStyle(MacPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        case .email:
            Button(action: sendCode) {
                HStack(spacing: 6) {
                    if center.busy { ProgressView().controlSize(.mini).tint(Color(MacBrand.buttonInk)) }
                    Text("Send Code")
                }
            }
            .buttonStyle(MacPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(!EmailInput.isPlausible(email) || center.busy)
        case .code:
            EmptyView()
        case .saveKey:
            Button("Continue") { center.acknowledgeRecoveryKey() }
                .buttonStyle(MacPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!saved)
        case .enterKey:
            Button("Use a Different Email") { center.signOut() }
                .buttonStyle(MacQuietButtonStyle())
            Button(action: unlock) {
                HStack(spacing: 6) {
                    if center.busy { ProgressView().controlSize(.mini).tint(Color(MacBrand.buttonInk)) }
                    Text("Unlock")
                }
            }
            .buttonStyle(MacPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(RecoveryKeyInput.state(of: key) != .valid || center.busy)
        case .done, .updateRequired:
            Button("Done") { dismiss() }
                .buttonStyle(MacPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        case .signingIn, .syncing:
            EmptyView()
        }
    }

    private func sendCode() {
        guard EmailInput.isPlausible(email), !center.busy else { return }
        center.requestCode(email: EmailInput.normalized(email))
    }

    private func unlock() {
        guard RecoveryKeyInput.state(of: key) == .valid, !center.busy else { return }
        center.recover(code: RecoveryKeyInput.normalize(key))
    }
}

// MARK: Steps

private struct MacStepHeader: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Font(Paper.body(28, weight: 680)))
                .foregroundStyle(Color(Paper.ink))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Color(Paper.muted))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The email step's field: large, rounded, focused when the step opens; Return sends the code.
private struct MacEmailField: View {
    @Binding var email: String
    let onSubmit: () -> Void

    var body: some View {
        MacInputField(placeholder: "you@example.com", text: $email, font: .system(size: 18),
                      contentType: .emailAddress, onSubmit: onSubmit)
    }
}

/// A large rounded text field in the onboarding style (the iPhone's email and key fields): paper
/// fill, hairline border, the accent ring while focused. Plain style, so nothing clips the baseline.
private struct MacInputField: View {
    let placeholder: String
    @Binding var text: String
    var font: Font = .system(size: 18)
    var contentType: NSTextContentType? = nil
    var highlighted = false
    let onSubmit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(Color(Paper.ink))
            .textContentType(contentType)
            .autocorrectionDisabled()
            .focused($focused)
            .onSubmit(onSubmit)
            .padding(.vertical, 13)
            .padding(.horizontal, 16)
            .background(Color(Paper.sidebar), in: RoundedRectangle(cornerRadius: MacOnboarding.fieldRadius))
            .overlay(
                RoundedRectangle(cornerRadius: MacOnboarding.fieldRadius)
                    .strokeBorder(focused || highlighted ? Color(Paper.accent) : Color(Paper.muted).opacity(0.25),
                                  lineWidth: focused ? 2 : 1)
            )
            .animation(.easeOut(duration: 0.15), value: focused)
            .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

/// "Check your email": six digit boxes (`MacOneTimeCodeField`), then quiet "Send a New Code"
/// (after a 30 s countdown) and "Change Email". A complete code is sent at once.
private struct MacCodeStep: View {
    @ObservedObject var center: SyncCenter
    let email: String
    let failures: Int
    let shakes: CGFloat
    @State private var editor = OneTimeCodeEditor()
    @State private var cooldown = ResendCooldown()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MacStepHeader(title: SyncOnboardingCopy.codeTitle, text: SyncOnboardingCopy.codeText(email))
            MacOneTimeCodeField(editor: $editor, working: center.busy)
                .modifier(MacShake(shakes: shakes))
            HStack(spacing: 18) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = cooldown.remaining(at: context.date)
                    Button(remaining > 0 ? "Send a new code in \(remaining) s" : "Send a New Code") {
                        cooldown.restart()
                        editor.clear()
                        center.requestCode(email: email)
                    }
                    .buttonStyle(MacQuietButtonStyle())
                    .disabled(remaining > 0 || center.busy)
                    .monospacedDigit()
                }
                Button("Change Email") { center.cancelSignIn() }
                    .buttonStyle(MacQuietButtonStyle())
                    .disabled(center.busy)
            }
        }
        .onChange(of: editor) { _, new in
            if new.isComplete, !center.busy { center.verify(code: new.code) }
        }
        .onChange(of: failures) { _, _ in editor.clear() }
    }
}

/// Six separate digit boxes over one borderless `NSTextField` that takes the keys: typing
/// advances, Backspace steps back, ←/→ move, ⌘V pastes a whole code and macOS one-time-code
/// AutoFill fills it in (`contentType = .oneTimeCode`). The editing rules are MatildeKit's
/// `OneTimeCodeEditor`, the digit rules `OneTimeCodeInput`, as on the iPhone.
struct MacOneTimeCodeField: View {
    @Binding var editor: OneTimeCodeEditor
    var working = false
    @State private var focused = false
    @State private var focusRequest = 0

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                // The key-taking field sits under the boxes, full size, so AutoFill's suggestion
                // appears below the code rather than in a corner.
                OneTimeCodeKeyField(editor: $editor, focused: $focused, focusRequest: focusRequest)
                    .accessibilityLabel("Code")
                    .accessibilityValue(editor.code)
                HStack(spacing: 8) {
                    ForEach(0..<OneTimeCodeInput.length, id: \.self) { index in
                        box(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                editor.move(to: index)
                                focusRequest += 1
                            }
                    }
                }
                .accessibilityHidden(true)
            }
            .frame(width: 6 * MacOnboarding.boxWidth + 5 * 8, height: MacOnboarding.boxHeight)
            ZStack {
                if working, editor.isComplete { ProgressView().controlSize(.small) }
            }
            .frame(width: 20)
        }
        .onAppear { focusRequest += 1 }
    }

    private func box(_ index: Int) -> some View {
        let digit = editor.digits[index]
        let active = focused && index == editor.cursor
        return Text(digit.map(String.init) ?? "")
            .font(.system(size: 30, weight: .medium, design: .monospaced))
            .foregroundStyle(Color(Paper.ink))
            .frame(width: MacOnboarding.boxWidth, height: MacOnboarding.boxHeight)
            .background(Color(Paper.sidebar), in: RoundedRectangle(cornerRadius: MacOnboarding.boxRadius))
            .overlay(
                RoundedRectangle(cornerRadius: MacOnboarding.boxRadius)
                    .strokeBorder(active ? Color(Paper.accent) : Color(Paper.muted).opacity(0.25), lineWidth: active ? 2 : 1)
            )
            .animation(.easeOut(duration: 0.12), value: active)
            .animation(.easeOut(duration: 0.12), value: digit)
    }
}

/// The invisible field under the boxes. Its text is emptied after every change, so each edit
/// arrives as just the typed, pasted or filled-in text; commands (Backspace, arrows) come in
/// through the delegate and never touch the text.
private struct OneTimeCodeKeyField: NSViewRepresentable {
    @Binding var editor: OneTimeCodeEditor
    @Binding var focused: Bool
    let focusRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> KeyField {
        let field = KeyField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = .clear
        field.font = .monospacedSystemFont(ofSize: 1, weight: .regular)
        field.contentType = .oneTimeCode
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.onFocus = { [weak coordinator = context.coordinator] in coordinator?.setFocused(true) }
        return field
    }

    func updateNSView(_ field: KeyField, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.handledFocusRequest != focusRequest {
            context.coordinator.handledFocusRequest = focusRequest
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    final class KeyField: NSTextField {
        var onFocus: (@MainActor () -> Void)?
        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became {
                onFocus?()
                (currentEditor() as? NSTextView)?.insertionPointColor = .clear
            }
            return became
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: OneTimeCodeKeyField
        var handledFocusRequest = -1

        init(_ parent: OneTimeCodeKeyField) { self.parent = parent }

        func setFocused(_ value: Bool) {
            if parent.focused != value { parent.focused = value }
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            (obj.userInfo?["NSFieldEditor"] as? NSTextView)?.insertionPointColor = .clear
            setFocused(true)
        }

        func controlTextDidEndEditing(_ obj: Notification) { setFocused(false) }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            let typed = field.stringValue
            if let editor = obj.userInfo?["NSFieldEditor"] as? NSTextView { editor.string = "" } else { field.stringValue = "" }
            apply { $0.insert(typed) }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteWordBackward(_:)):
                apply { $0.deleteBackward() }
            case #selector(NSResponder.deleteForward(_:)):
                apply { $0.deleteForward() }
            case #selector(NSResponder.deleteToBeginningOfLine(_:)):
                apply { $0.clear() }
            case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveBackward(_:)):
                apply { $0.moveLeft() }
            case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveForward(_:)):
                apply { $0.moveRight() }
            case #selector(NSResponder.moveToBeginningOfLine(_:)), #selector(NSResponder.moveUp(_:)):
                apply { $0.move(to: 0) }
            case #selector(NSResponder.moveToEndOfLine(_:)), #selector(NSResponder.moveDown(_:)):
                apply { $0.move(to: OneTimeCodeInput.length - 1) }
            case #selector(NSResponder.insertNewline(_:)):
                // A complete code was already sent; Return does nothing else here.
                return true
            default:
                return false
            }
            return true
        }

        private func apply(_ change: (inout OneTimeCodeEditor) -> Void) {
            var editor = parent.editor
            change(&editor)
            if editor != parent.editor { parent.editor = editor }
        }
    }
}

/// Signing in, syncing, done: a centred symbol, title and line. `success` draws the tick in the
/// accent and lets it spring in (a plain fade with Reduce Motion).
private struct MacStatusStep: View {
    let symbol: String
    let title: String
    let text: String
    var success = false
    var working = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(success ? Color(Paper.accent) : Color(Paper.muted))
                .scaleEffect(appeared || reduceMotion ? 1 : 0.6)
                .opacity(appeared ? 1 : 0)
                .accessibilityHidden(true)
            Text(title)
                .font(Font(Paper.body(26, weight: 680)))
                .foregroundStyle(Color(Paper.ink))
                .multilineTextAlignment(.center)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Color(Paper.muted))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if working { ProgressView().controlSize(.small).padding(.top, 4) }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.5, bounce: 0.35)) { appeared = true }
        }
    }
}

/// The new account's recovery key: the groups on a paper card, Copy (with a tick), Save… and
/// Print…, the iCloud Keychain note and "I've saved it".
private struct MacSaveKeyStep: View {
    @ObservedObject var center: SyncCenter
    let recovery: String
    @Binding var saved: Bool
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            MacStepHeader(title: SyncOnboardingCopy.saveKeyTitle, text: SyncOnboardingCopy.saveKeyText)
            let groups = RecoveryKeyInput.groups(recovery)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 10) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    Text(group)
                        .font(.system(size: 17, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color(Paper.ink))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(Color(Paper.sidebar), in: RoundedRectangle(cornerRadius: MacOnboarding.fieldRadius))
            .overlay(RoundedRectangle(cornerRadius: MacOnboarding.fieldRadius).strokeBorder(Color(Paper.muted).opacity(0.25)))
            .textSelection(.enabled)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recovery key")
            .accessibilityValue(groups.joined(separator: ", "))
            HStack(spacing: 8) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(recovery, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Button { RecoveryKeyExport.save(code: recovery, email: center.signedInEmail) } label: {
                    Label("Save…", systemImage: "square.and.arrow.down")
                }
                Button { RecoveryKeyExport.print(code: recovery, email: center.signedInEmail) } label: {
                    Label("Print…", systemImage: "printer")
                }
            }
            .buttonStyle(MacOutlineButtonStyle())
            if center.recoveryKeyInICloud {
                Label(SyncOnboardingCopy.savedToICloud, systemImage: "key.icloud")
                    .font(.footnote)
                    .foregroundStyle(Color(Paper.muted))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle(SyncOnboardingCopy.savedConfirmation, isOn: $saved)
                .toggleStyle(.checkbox)
                .foregroundStyle(Color(Paper.ink))
                .padding(.top, 2)
        }
    }
}

// MARK: Style

enum MacOnboarding {
    /// The same radii as the iPhone's fields (14) and code boxes (12).
    static let fieldRadius: CGFloat = 14
    static let boxRadius: CGFloat = 12
    static let boxWidth: CGFloat = 52
    static let boxHeight: CGFloat = 62
}

/// The landing page's button colours (apps/web: #2b2724 on paper), swapped in dark mode.
enum MacBrand {
    private static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> NSColor {
        func color(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                    blue: Double(hex & 0xff) / 255, alpha: 1)
        }
        return NSColor(name: NSColor.Name("Matilde.brand." + name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? color(dark) : color(light)
        }
    }

    static let button = adaptive("button", light: 0x2b2724, dark: 0xebe5da)
    static let buttonPressed = adaptive("buttonPressed", light: 0x3a3531, dark: 0xf6f2ea)
    static let buttonInk = adaptive("buttonInk", light: 0xf6f2ea, dark: 0x2b2724)
}

/// The main action: a compact warm dark-gray capsule with light text, as on matilde.page.
struct MacPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color(MacBrand.buttonInk))
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(Color(configuration.isPressed ? MacBrand.buttonPressed : MacBrand.button), in: Capsule())
            .opacity(isEnabled ? 1 : 0.35)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// A quiet text button in the app's tone (accent brown, or muted for Cancel), no link blue.
struct MacQuietButtonStyle: ButtonStyle {
    enum Tone { case accent, muted }
    var tone: Tone = .accent
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(tone == .accent ? Color(Paper.accent) : Color(Paper.muted))
            .padding(.vertical, 6)
            .padding(.horizontal, 2)
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.55 : 1)
            .contentShape(Rectangle())
    }
}

/// Secondary actions beside content (Copy, Save…, Print…): a hairline capsule in ink.
struct MacOutlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color(Paper.ink))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(Paper.sidebar).opacity(configuration.isPressed ? 1 : 0), in: Capsule())
            .overlay(Capsule().strokeBorder(Color(Paper.muted).opacity(0.3)))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}

private struct MacShake: GeometryEffect {
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 8 * sin(shakes * .pi * 4), y: 0))
    }
}

/// Save or print a new recovery key (`RecoveryKeyDocument` in MatildeKit).
@MainActor
enum RecoveryKeyExport {
    static func save(code: String, email: String?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = RecoveryKeyDocument.fileName
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? RecoveryKeyDocument.text(code: code, email: email).write(to: url, atomically: true, encoding: .utf8)
    }

    static func print(code: String, email: String?) {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 468, height: 300))
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.string = RecoveryKeyDocument.text(code: code, email: email)
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = false
        operation.run()
    }
}
#endif
