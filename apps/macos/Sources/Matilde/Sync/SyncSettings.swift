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
/// (`SyncOnboardingFlow`, `SyncOnboardingCopy`), in a sheet over Settings.
struct SyncSetupSheet: View {
    @ObservedObject var center: SyncCenter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flow: SyncOnboardingFlow
    @State private var email = ""
    @State private var code = ""
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
                .opacity(flow.step == .intro || flow.step == .done ? 0 : 1)
                .padding(.bottom, 18)
            content
                .id(stepID)
                .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                                  removal: .move(edge: .leading).combined(with: .opacity)))
            Spacer(minLength: 16)
            if let message = center.message, flow.step != .done {
                Text(message).foregroundStyle(.red).font(.callout).padding(.bottom, 10)
            }
            HStack {
                if flow.step != .done {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                Spacer()
                actions
            }
        }
        .padding(28)
        .frame(width: 480, height: 440)
        .clipped()
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.12), value: stepID)
        .onAppear { if let known = center.signedInEmail { email = known }; feed() }
        .onChange(of: center.setupPhase) { _, _ in feed() }
        .onChange(of: center.syncing) { _, _ in feed() }
        .onChange(of: center.lastSynced) { _, _ in feed() }
        .onChange(of: center.message) { _, message in if message != nil { flow.failed() } }
        .onChange(of: flow.failures) { _, _ in
            withAnimation(.linear(duration: 0.45)) { shakes += 1 }
            code = ""
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

    private func header(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 24, weight: .bold, design: .serif))
            Text(text).font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var content: some View {
        switch flow.step {
        case .intro:
            VStack(alignment: .leading, spacing: 16) {
                header(SyncOnboardingCopy.introTitle, SyncOnboardingCopy.introText)
                ForEach(SyncOnboardingCopy.points) { point in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: point.symbol).font(.system(size: 17)).foregroundStyle(.secondary).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(point.title).font(.system(size: 13, weight: .semibold))
                            Text(point.text).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                }
                Text(SyncOnboardingCopy.introFootnote).font(.footnote).foregroundStyle(.secondary)
            }
        case .email:
            VStack(alignment: .leading, spacing: 18) {
                header(SyncOnboardingCopy.emailTitle, SyncOnboardingCopy.emailText)
                TextField("you@example.com", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 18))
                    .textContentType(.emailAddress)
                    .onSubmit(sendCode)
            }
        case .code(let address):
            VStack(alignment: .leading, spacing: 18) {
                header(SyncOnboardingCopy.codeTitle, SyncOnboardingCopy.codeText(address))
                TextField("123456", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 28, weight: .medium, design: .monospaced))
                    .textContentType(.oneTimeCode)
                    .frame(width: 200)
                    .modifier(MacShake(shakes: shakes))
                    .onChange(of: code) { _, new in
                        let clean = OneTimeCodeInput.sanitize(new)
                        if clean != new { code = clean; return }
                        if OneTimeCodeInput.isComplete(clean), !center.busy { center.verify(code: clean) }
                    }
                HStack(spacing: 14) {
                    Button("Send a New Code") { code = ""; center.requestCode(email: address) }.buttonStyle(.link)
                    Button("Change Email") { center.cancelSignIn() }.buttonStyle(.link)
                }
                .disabled(center.busy)
            }
        case .signingIn:
            status("checkmark.circle", SyncOnboardingCopy.signingInTitle, SyncOnboardingCopy.signingInText)
        case .saveKey(let recovery):
            VStack(alignment: .leading, spacing: 16) {
                header(SyncOnboardingCopy.saveKeyTitle, SyncOnboardingCopy.saveKeyText)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                    ForEach(Array(RecoveryKeyInput.groups(recovery).enumerated()), id: \.offset) { _, group in
                        Text(group).font(.system(size: 17, weight: .medium, design: .monospaced))
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25)))
                .textSelection(.enabled)
                HStack {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(recovery, forType: .string)
                    }
                    Button("Save…") { RecoveryKeyExport.save(code: recovery, email: center.signedInEmail) }
                    Button("Print…") { RecoveryKeyExport.print(code: recovery, email: center.signedInEmail) }
                }
                if center.recoveryKeyInICloud {
                    Text(SyncOnboardingCopy.savedToICloud).font(.footnote).foregroundStyle(.secondary)
                }
                Toggle(SyncOnboardingCopy.savedConfirmation, isOn: $saved)
            }
        case .enterKey:
            VStack(alignment: .leading, spacing: 16) {
                header(SyncOnboardingCopy.enterKeyTitle, SyncOnboardingCopy.enterKeyText)
                TextField("MTLD-XXXX-XXXX-…", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .modifier(MacShake(shakes: shakes))
                    .onSubmit(unlock)
                    .task {
                        // A copy another device kept in iCloud Keychain fills the field.
                        guard key.isEmpty, let stored = await center.storedRecoveryKey() else { return }
                        key = RecoveryKeyInput.formatted(stored)
                    }
                if let message = RecoveryKeyInput.message(for: RecoveryKeyInput.state(of: key)) {
                    Text(message).foregroundStyle(.red).font(.callout)
                } else if RecoveryKeyInput.state(of: key) == .valid {
                    Label("Looks right", systemImage: "checkmark.circle").foregroundStyle(.secondary).font(.callout)
                }
            }
        case .syncing:
            status("arrow.triangle.2.circlepath", SyncOnboardingCopy.syncingTitle, SyncOnboardingCopy.syncingText)
        case .done:
            status("checkmark.circle.fill", SyncOnboardingCopy.doneTitle, SyncOnboardingCopy.doneText, working: false)
        case .updateRequired:
            status("arrow.down.app", SyncOnboardingCopy.updateTitle, SyncOnboardingCopy.updateText, working: false)
        }
    }

    private func status(_ symbol: String, _ title: String, _ text: String, working: Bool = true) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 54, weight: .ultraLight))
                .foregroundStyle(.secondary)
                .symbolEffect(.bounce, value: stepID)
            Text(title).font(.system(size: 22, weight: .bold, design: .serif))
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if working { ProgressView().controlSize(.small) }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    @ViewBuilder private var actions: some View {
        switch flow.step {
        case .intro:
            Button("Continue") { center.setEnabled(true); flow.begin() }
                .keyboardShortcut(.defaultAction)
        case .email:
            Button("Send Code", action: sendCode)
                .keyboardShortcut(.defaultAction)
                .disabled(!EmailInput.isPlausible(email) || center.busy)
        case .code:
            if center.busy { ProgressView().controlSize(.small) }
        case .saveKey:
            Button("Continue") { center.acknowledgeRecoveryKey() }
                .keyboardShortcut(.defaultAction)
                .disabled(!saved)
        case .enterKey:
            Button("Use a Different Email") { center.signOut() }
            Button("Unlock", action: unlock)
                .keyboardShortcut(.defaultAction)
                .disabled(RecoveryKeyInput.state(of: key) != .valid || center.busy)
        case .done, .updateRequired:
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        case .signingIn, .syncing:
            EmptyView()
        }
    }

    private func sendCode() {
        guard EmailInput.isPlausible(email) else { return }
        center.requestCode(email: EmailInput.normalized(email))
    }

    private func unlock() {
        guard RecoveryKeyInput.state(of: key) == .valid else { return }
        center.recover(code: RecoveryKeyInput.normalize(key))
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
