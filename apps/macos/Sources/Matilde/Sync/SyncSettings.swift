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
    @State private var revoking: ConnectedAITool?

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
                    Text(center.connections.contains(where: \.canReachNotes)
                         ? "End-to-end encrypted. While an AI tool below is connected, the Matilde server can decrypt your notes for it."
                         : "End-to-end encrypted. No one else can read your notes.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !center.devices.isEmpty {
                    Section("Signed-in devices") {
                        ForEach(center.devices) { device in
                            Label {
                                Text(device.name)
                                if device.isCurrent { Text("This Mac").foregroundStyle(.secondary) }
                            } icon: {
                                MatildeIcon.forSharedSymbol(device.symbolName).image(size: 18)
                            }
                        }
                    }
                }
                if !center.connections.isEmpty {
                    Section {
                        ForEach(center.connections) { tool in
                            ConnectedAIToolRow(tool: tool) { revoking = tool }
                        }
                    } header: {
                        Text("Connected AI tools")
                    } footer: {
                        Text("These tools can use your notes as shown until the connection ends. Disconnecting stops them at once; what a tool has already read stays with it.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            case .off, .signedOut:
                Section {
                    HStack(alignment: .top, spacing: 14) {
                        MatildeIcon.devices.image(size: 32)
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
        .onAppear { center.loadDevices(); center.loadConnections() }
        .onChange(of: center.phase) { _, phase in if phase == .ready { center.loadDevices(); center.loadConnections() } }
        .confirmationDialog("Disconnect \(revoking?.displayName ?? "this tool")?", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
                            titleVisibility: .visible, presenting: revoking) { tool in
            Button("Disconnect", role: .destructive) { center.revokeConnection(tool.id) }
        } message: { _ in
            Text("It can no longer read or change your notes. To use it again, connect it from the tool.")
        }
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

/// One connected AI tool: its name (and verified domain), what it may do, when it ends and was
/// last used, and Disconnect.
private struct ConnectedAIToolRow: View {
    let tool: ConnectedAITool
    let onRevoke: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.displayName)
                if let domain = tool.clientDomain {
                    Text(domain).font(.caption).foregroundStyle(.secondary)
                }
                Text(tool.permissionsSummary).font(.caption).foregroundStyle(.secondary)
                Text(details).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Disconnect…", action: onRevoke)
        }
    }

    private var details: String {
        var parts = ["Ends \(tool.expires.formatted(date: .abbreviated, time: .omitted))"]
        if let day = tool.lastUsedDay { parts.append("last used \(day)") } else { parts.append("not used yet") }
        return parts.joined(separator: " · ")
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
    /// Entering the old long key (accounts made before Matilde keys) instead of 12 words.
    @State private var legacyKey = false
    @State private var words = MatildeKeyWordsEditor()
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
                Label { Text(message) } icon: { MatildeIcon.alert.image(size: 16).iconBaseline() }
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
                        MatildeIcon.forSharedSymbol(point.symbol).image(size: 20).foregroundStyle(Color(Paper.accent)).frame(width: 24)
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
            MacStatusStep(icon: .done, title: SyncOnboardingCopy.signingInTitle,
                          text: SyncOnboardingCopy.signingInText, success: true, working: true)
        case .saveKey(let recovery):
            MacSaveKeyStep(center: center, recovery: recovery, saved: $saved)
        case .enterKey:
            MacEnterKeyStep(center: center, legacy: $legacyKey, key: $key, words: $words, shakes: shakes, onSubmit: unlock)
        case .syncing:
            MacStatusStep(icon: .refresh, title: SyncOnboardingCopy.syncingTitle,
                          text: SyncOnboardingCopy.syncingText, working: true)
        case .done:
            MacStatusStep(icon: .done, title: SyncOnboardingCopy.doneTitle,
                          text: SyncOnboardingCopy.doneText, success: true)
        case .updateRequired:
            MacStatusStep(icon: .download, title: SyncOnboardingCopy.updateTitle, text: SyncOnboardingCopy.updateText)
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
            .disabled(keyState != .valid || center.busy)
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

    private var keyState: RecoveryKeyInput.State { legacyKey ? RecoveryKeyInput.state(of: key) : words.state }

    private func unlock() {
        guard keyState == .valid, !center.busy else { return }
        center.recover(code: legacyKey ? RecoveryKeyInput.normalize(key) : words.phrase)
    }
}

// MARK: Steps

struct MacStepHeader: View {
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
struct MacStatusStep: View {
    let icon: MatildeIcon
    let title: String
    let text: String
    var success = false
    var working = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 12) {
            icon.image(size: 56)
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

/// The new account's Matilde key: its 12 words on a paper card, Copy (with a tick), Save… and
/// Print…, the iCloud Keychain note and "I've saved my Matilde key" (Continue waits for it).
private struct MacSaveKeyStep: View {
    @ObservedObject var center: SyncCenter
    let recovery: String
    @Binding var saved: Bool
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            MacStepHeader(title: SyncOnboardingCopy.saveKeyTitle, text: SyncOnboardingCopy.saveKeyText)
            MatildeKeyCard(code: recovery)
            HStack(spacing: 8) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(recovery, forType: .string)
                    copied = true
                } label: {
                    Label { Text(copied ? "Copied" : "Copy") } icon: { (copied ? MatildeIcon.check : .copy).image(size: 14) }
                }
                Button { RecoveryKeyExport.save(code: recovery, email: center.signedInEmail) } label: {
                    Label { Text("Save…") } icon: { MatildeIcon.download.image(size: 14) }
                }
                Button { RecoveryKeyExport.print(code: recovery, email: center.signedInEmail) } label: {
                    Label { Text("Print…") } icon: { MatildeIcon.printer.image(size: 14) }
                }
            }
            .buttonStyle(MacOutlineButtonStyle())
            if center.recoveryKeyInICloud {
                Label { Text(SyncOnboardingCopy.savedToICloud) } icon: { MatildeIcon.cloudLock.image(size: 14) }
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

/// "Your Matilde key" over its 12 numbered words in two columns (1–6, 7–12) on a warm card; a
/// legacy key shows as its groups of four.
private struct MatildeKeyCard: View {
    let code: String

    var body: some View {
        let words = SyncRecoveryKey.format(of: code) == .words ? MatildeKeyPhrase.letterRuns(code) : []
        let half = (words.count + 1) / 2
        VStack(alignment: .leading, spacing: 12) {
            Label { Text(SyncOnboardingCopy.keyCardTitle) } icon: { MatildeIcon.key.image(size: 15).iconBaseline() }
                .font(.custom("Newsreader", size: 16).weight(.semibold))
                .foregroundStyle(Color(Paper.accent))
            if words.isEmpty {
                Text(RecoveryKeyInput.groups(code).joined(separator: "-"))
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(Paper.ink))
            } else {
                HStack(alignment: .top, spacing: 24) {
                    column(words, 0..<half)
                    column(words, half..<words.count)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(Paper.underside), in: RoundedRectangle(cornerRadius: MacOnboarding.fieldRadius))
        .overlay(RoundedRectangle(cornerRadius: MacOnboarding.fieldRadius).strokeBorder(Color(Paper.accent).opacity(0.3)))
        .textSelection(.enabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SyncOnboardingCopy.keyCardTitle)
        .accessibilityValue(words.isEmpty ? RecoveryKeyInput.groups(code).joined(separator: ", ") : words.joined(separator: ", "))
    }

    private func column(_ words: [String], _ range: Range<Int>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(range), id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color(Paper.muted))
                        .frame(width: 18, alignment: .trailing)
                    Text(words[index])
                        .font(.custom("Newsreader", size: 18))
                        .foregroundStyle(Color(Paper.ink))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Entering the Matilde key: 12 numbered word fields with suggestions from the word list and a
/// flag for a word that isn't in it (pasting the whole key into any field fills them all), or,
/// behind "I have a key that starts with MTLD", the old long key in one field. Starts in the
/// account's format when the server says which; an iCloud Keychain copy fills either in.
private struct MacEnterKeyStep: View {
    @ObservedObject var center: SyncCenter
    @Binding var legacy: Bool
    @Binding var key: String
    @Binding var words: MatildeKeyWordsEditor
    let shakes: CGFloat
    let onSubmit: () -> Void
    @FocusState private var slot: Int?
    @State private var filledFromICloud = false
    @State private var started = false

    private var state: RecoveryKeyInput.State { legacy ? RecoveryKeyInput.state(of: key) : words.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MacStepHeader(title: SyncOnboardingCopy.enterKeyTitle,
                          text: legacy ? SyncOnboardingCopy.enterLegacyKeyText : SyncOnboardingCopy.enterKeyText)
            Group {
                if legacy {
                    MacInputField(placeholder: "MTLD-XXXX-XXXX-…", text: $key,
                                  font: .system(size: 17, weight: .medium, design: .monospaced),
                                  highlighted: state == .valid, onSubmit: onSubmit)
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(spacing: 7) { ForEach(0..<6, id: \.self) { wordField($0) } }
                        VStack(spacing: 7) { ForEach(6..<12, id: \.self) { wordField($0) } }
                    }
                }
            }
            .modifier(MacShake(shakes: shakes))
            if !legacy, let slot, !words.suggestions(slot).isEmpty {
                HStack(spacing: 6) {
                    ForEach(words.suggestions(slot), id: \.self) { word in
                        Button(word) { self.slot = words.complete(slot, with: word) }
                    }
                }
                .buttonStyle(MacOutlineButtonStyle())
                .accessibilityLabel("Suggestions")
            }
            status.font(.callout)
            Button(legacy ? SyncOnboardingCopy.useWords : SyncOnboardingCopy.useLegacyKey) {
                legacy.toggle()
                if !legacy { slot = words.words.firstIndex(where: \.isEmpty) ?? 0 }
            }
            .buttonStyle(MacQuietButtonStyle())
        }
        .onChange(of: key) { _, new in
            // Format into groups as the user types, unless that would fight a deletion.
            let formatted = RecoveryKeyInput.formatted(new)
            if formatted != new, formatted.count >= new.count, RecoveryKeyInput.normalize(new).count <= RecoveryKeyInput.characterCount {
                key = formatted
            }
        }
        .onAppear {
            guard !started else { return }
            started = true
            legacy = center.recoveryKeyFormat == .legacy
            if !legacy { DispatchQueue.main.async { slot = 0 } }
        }
        .task {
            // A copy another device kept in iCloud Keychain fills the key in; the user still clicks Unlock.
            guard key.isEmpty, words.state == .empty, let stored = await center.storedRecoveryKey() else { return }
            if RecoveryKeyInput.format(of: stored) == .words {
                words = MatildeKeyWordsEditor(stored)
                legacy = false
            } else {
                key = RecoveryKeyInput.formatted(stored)
                legacy = true
            }
            filledFromICloud = true
        }
    }

    private func wordField(_ index: Int) -> some View {
        let unknown = words.isUnknown(index)
        let binding = Binding<String>(
            get: { words.words[index] },
            set: { text in
                let next = words.set(text, at: index)
                filledFromICloud = false
                if next != index { slot = next }
            })
        return HStack(spacing: 6) {
            Text("\(index + 1)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(Paper.muted))
                .frame(width: 18, alignment: .trailing)
            TextField("", text: binding)
                .textFieldStyle(.plain)
                .font(.custom("Newsreader", size: 16))
                .foregroundStyle(unknown ? Color(nsColor: .systemRed) : Color(Paper.ink))
                .autocorrectionDisabled()
                .focused($slot, equals: index)
                .onSubmit {
                    let options = words.suggestions(index, limit: 2)
                    if options.count == 1 {
                        slot = words.complete(index, with: options[0])
                    } else if state == .valid {
                        onSubmit()
                    } else if index < 11 {
                        slot = index + 1
                    }
                }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(Color(Paper.sidebar), in: RoundedRectangle(cornerRadius: MacOnboarding.boxRadius - 2))
        .overlay(RoundedRectangle(cornerRadius: MacOnboarding.boxRadius - 2)
            .strokeBorder(unknown ? Color(nsColor: .systemRed).opacity(0.7)
                          : slot == index ? Color(Paper.accent) : Color(Paper.muted).opacity(0.25)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Word \(index + 1)")
    }

    @ViewBuilder private var status: some View {
        let state = self.state
        // The last word is the start of a list word: not wrong yet.
        let stillTyping: Bool = {
            if case .unknownWord = state, !legacy { return !(0..<12).contains(where: words.isUnknown) }
            return false
        }()
        if stillTyping {
            Text("Finish the last word").foregroundStyle(Color(Paper.muted))
        } else if let message = RecoveryKeyInput.message(for: state) {
            Text(message).foregroundStyle(Color(nsColor: .systemRed)).fixedSize(horizontal: false, vertical: true)
        } else if case .incompleteWords(let remaining) = state {
            Text(remaining == 1 ? "1 word to go" : "\(remaining) words to go").foregroundStyle(Color(Paper.muted))
        } else if state == .valid {
            Label { Text(filledFromICloud ? SyncOnboardingCopy.filledFromICloud : "Looks right") } icon: {
                (filledFromICloud ? MatildeIcon.cloudLock : .circleCheck).image(size: 16).iconBaseline()
            }
            .foregroundStyle(Color(Paper.accent))
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

/// Save or print a new Matilde key (`RecoveryKeyDocument` in MatildeKit).
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
