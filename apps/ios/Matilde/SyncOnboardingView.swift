import SwiftUI
import UIKit
import MatildeKit

/// The guided "Sync your notes" flow (a full-screen sheet, one step per screen): intro → email →
/// code → save or enter the recovery key → first sync → done. The steps come from
/// `SyncOnboardingFlow` in MatildeKit, the words from `SyncOnboardingCopy`; the work stays in
/// `SyncController`.
struct SyncOnboardingView: View {
    @Environment(SyncController.self) private var sync
    @Environment(NoteLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flow: SyncOnboardingFlow

    init(phase: SyncSetupPhase) {
        _flow = State(initialValue: SyncOnboardingFlow(phase: phase))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Paper.background.ignoresSafeArea()
                step
                    .id(stepID)
                    .transition(transition)
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.15), value: stepID)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if flow.step != .done {
                        Button("Close", systemImage: "xmark", role: .close) { dismiss() }
                    }
                }
                ToolbarItem(placement: .principal) {
                    if flow.step != .intro && flow.step != .done {
                        ProgressView(value: flow.progress)
                            .progressViewStyle(.linear)
                            .tint(Paper.accent)
                            .frame(width: 120)
                            .animation(.easeInOut, value: flow.progress)
                            .accessibilityLabel("Setup progress")
                    }
                }
            }
        }
        .interactiveDismissDisabled(flow.isWorking)
        .onChange(of: sync.setupPhase, initial: true) { _, _ in feed() }
        .onChange(of: sync.syncing) { _, _ in feed() }
        .onChange(of: sync.lastSynced) { _, _ in feed() }
        .onChange(of: sync.message) { _, message in if message != nil { flow.failed() } }
        .sensoryFeedback(.success, trigger: flow.step == .done) { _, done in done }
        .sensoryFeedback(.error, trigger: flow.failures)
    }

    private func feed() {
        flow.update(phase: sync.setupPhase, syncing: sync.syncing, lastSynced: sync.lastSynced)
    }

    private var transition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                               removal: .move(edge: .leading).combined(with: .opacity))
    }

    /// Changes only when the screen does (not on every keystroke inside it).
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

    @ViewBuilder private var step: some View {
        switch flow.step {
        case .intro:
            IntroStep { flow.begin() }
        case .email:
            EmailStep()
        case .code(let email):
            CodeStep(email: email, failures: flow.failures)
        case .signingIn:
            StatusStep(symbol: "checkmark.circle", title: SyncOnboardingCopy.signingInTitle,
                       text: SyncOnboardingCopy.signingInText, working: true)
        case .saveKey(let code):
            SaveKeyStep(code: code)
        case .enterKey:
            EnterKeyStep(failures: flow.failures)
        case .syncing:
            StatusStep(symbol: "arrow.triangle.2.circlepath", title: SyncOnboardingCopy.syncingTitle,
                       text: library.drafts.isEmpty ? SyncOnboardingCopy.syncingText
                           : "\(library.drafts.count) \(library.drafts.count == 1 ? "note" : "notes") so far…",
                       working: true)
        case .done:
            DoneStep { dismiss() }
        case .updateRequired:
            StatusStep(symbol: "arrow.down.app", title: SyncOnboardingCopy.updateTitle,
                       text: SyncOnboardingCopy.updateText, working: false)
        }
    }
}

// MARK: Layout

/// A step's frame: a symbol, title and text at the top, content in the middle, actions at the
/// bottom above the keyboard.
private struct StepLayout<Content: View, Actions: View>: View {
    var symbol: String? = nil
    let title: String
    let text: String
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(Paper.accent)
                            .padding(.bottom, 6)
                            .accessibilityHidden(true)
                    }
                    Text(title)
                        .font(Font(MarkdownStyle.bodyFont(30, bold: true)))
                        .foregroundStyle(Paper.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(text)
                        .font(.system(size: 17))
                        .foregroundStyle(Paper.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    content
                        .padding(.top, 14)
                }
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            VStack(spacing: 6) { actions }
                .padding(.horizontal, 28)
                .padding(.bottom, 12)
        }
    }
}

/// The error the controller reported for the last step, if any.
private struct StepMessage: View {
    @Environment(SyncController.self) private var sync

    var body: some View {
        if let message = sync.message {
            Label(message, systemImage: "exclamationmark.circle")
                .font(.callout)
                .foregroundStyle(.red)
                .transition(.opacity)
        }
    }
}

// MARK: Steps

private struct IntroStep: View {
    let begin: () -> Void
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        StepLayout(title: SyncOnboardingCopy.introTitle, text: SyncOnboardingCopy.introText) {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 54, weight: .ultraLight))
                    .foregroundStyle(Paper.accent)
                    .symbolEffect(.bounce, options: .nonRepeating, value: appeared)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .accessibilityHidden(true)
                ForEach(Array(SyncOnboardingCopy.points.enumerated()), id: \.element.id) { index, point in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: point.symbol)
                            .font(.system(size: 20, weight: .regular))
                            .foregroundStyle(Paper.accent)
                            .frame(width: 28)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(point.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Paper.ink)
                            Text(point.text).font(.system(size: 15)).foregroundStyle(Paper.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared || reduceMotion ? 0 : 12)
                    .animation(.easeOut(duration: 0.4).delay(0.1 + Double(index) * 0.08), value: appeared)
                }
            }
        } actions: {
            Button("Continue", action: begin).buttonStyle(.matildePrimary)
            Text(SyncOnboardingCopy.introFootnote)
                .font(.footnote)
                .foregroundStyle(Paper.muted)
                .padding(.top, 4)
        }
        .onAppear { appeared = true }
    }
}

private struct EmailStep: View {
    @Environment(SyncController.self) private var sync
    @State private var email = ""
    @FocusState private var focused: Bool

    var body: some View {
        StepLayout(title: SyncOnboardingCopy.emailTitle, text: SyncOnboardingCopy.emailText) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("you@example.com", text: $email)
                    .font(.system(size: 22))
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.continue)
                    .focused($focused)
                    .onSubmit(send)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 16)
                    .background(Paper.sidebar, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Paper.muted.opacity(0.25)))
                StepMessage()
            }
        } actions: {
            Button(action: send) {
                if sync.busy { ProgressView().tint(Brand.buttonInk) } else { Text("Send Code") }
            }
            .buttonStyle(.matildePrimary)
            .disabled(!EmailInput.isPlausible(email) || sync.busy)
        }
        .onAppear {
            if email.isEmpty, let known = sync.signedInEmail { email = known }
            focused = true
        }
    }

    private func send() {
        guard EmailInput.isPlausible(email) else { return }
        sync.requestCode(email: EmailInput.normalized(email))
    }
}

private struct CodeStep: View {
    @Environment(SyncController.self) private var sync
    let email: String
    let failures: Int
    @State private var code = ""
    @State private var cooldown = ResendCooldown()
    @State private var shakes: CGFloat = 0
    @FocusState private var focused: Bool

    var body: some View {
        StepLayout(title: SyncOnboardingCopy.codeTitle, text: SyncOnboardingCopy.codeText(email)) {
            VStack(alignment: .leading, spacing: 14) {
                ZStack {
                    // The real field: invisible, takes typing, paste and the code from Mail.
                    TextField("", text: $code)
                        .textContentType(.oneTimeCode)
                        .keyboardType(.numberPad)
                        .focused($focused)
                        .foregroundStyle(.clear)
                        .tint(.clear)
                        .frame(width: 1, height: 1)
                        .opacity(0.02)
                        .accessibilityLabel("Code")
                    boxes
                        .onTapGesture { focused = true }
                }
                .modifier(Shake(shakes: shakes))
                StepMessage()
            }
        } actions: {
            if sync.busy {
                ProgressView().padding(.vertical, 14)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = cooldown.remaining(at: context.date)
                Button(remaining > 0 ? "Send a new code in \(remaining) s" : "Send a New Code") {
                    cooldown.restart()
                    code = ""
                    sync.requestCode(email: email)
                }
                .buttonStyle(.matildeSecondary)
                .disabled(remaining > 0 || sync.busy)
            }
            Button("Change Email") { sync.cancelSignIn() }
                .buttonStyle(.matildeSecondary)
        }
        .onAppear { focused = true }
        .onChange(of: code) { _, new in
            let clean = OneTimeCodeInput.sanitize(new)
            if clean != new { code = clean; return }
            if OneTimeCodeInput.isComplete(clean), !sync.busy { sync.verify(code: clean) }
        }
        .onChange(of: failures) { _, _ in
            withAnimation(.linear(duration: 0.45)) { shakes += 1 }
            code = ""
        }
    }

    private var boxes: some View {
        let digits = OneTimeCodeInput.boxes(code)
        let active = OneTimeCodeInput.activeBox(code)
        return HStack(spacing: 8) {
            ForEach(0..<OneTimeCodeInput.length, id: \.self) { index in
                Text(digits[index].map(String.init) ?? "")
                    .font(.system(size: 28, weight: .medium, design: .monospaced))
                    .foregroundStyle(Paper.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background(Paper.sidebar, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(focused && index == active ? Paper.accent : Paper.muted.opacity(0.25),
                                          lineWidth: focused && index == active ? 2 : 1)
                    )
                    .animation(.easeOut(duration: 0.15), value: active)
                    .sensoryFeedback(.selection, trigger: digits[index] != nil) { _, filled in filled }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct StatusStep: View {
    let symbol: String
    let title: String
    let text: String
    let working: Bool
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 64, weight: .ultraLight))
                .foregroundStyle(Paper.accent)
                .symbolEffect(.bounce, options: .nonRepeating, value: appeared)
                .symbolEffect(.rotate, options: .repeat(.continuous), isActive: working && symbol.contains("circlepath"))
                .accessibilityHidden(true)
            Text(title)
                .font(Font(MarkdownStyle.bodyFont(28, bold: true)))
                .foregroundStyle(Paper.ink)
                .multilineTextAlignment(.center)
            Text(text)
                .font(.system(size: 17))
                .foregroundStyle(Paper.muted)
                .multilineTextAlignment(.center)
                .contentTransition(.numericText())
            if working { ProgressView().padding(.top, 6) }
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
        .onAppear { appeared = true }
        .accessibilityElement(children: .combine)
    }
}

private struct SaveKeyStep: View {
    @Environment(SyncController.self) private var sync
    let code: String
    @State private var saved = false
    @State private var copied = 0
    @State private var file: URL?

    var body: some View {
        StepLayout(symbol: "key", title: SyncOnboardingCopy.saveKeyTitle, text: SyncOnboardingCopy.saveKeyText) {
            VStack(alignment: .leading, spacing: 16) {
                keyGrid
                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = code
                        copied += 1
                    } label: {
                        Label(copied > 0 ? "Copied" : "Copy", systemImage: copied > 0 ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .sensoryFeedback(.success, trigger: copied)
                    if let file {
                        ShareLink(item: file) {
                            Label("Save to Files", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .controlSize(.large)
                .tint(Paper.accent)
                if sync.recoveryKeyInICloud {
                    Label(SyncOnboardingCopy.savedToICloud, systemImage: "key.icloud")
                        .font(.footnote)
                        .foregroundStyle(Paper.muted)
                }
                Toggle(SyncOnboardingCopy.savedConfirmation, isOn: $saved)
                    .font(.system(size: 16))
                    .foregroundStyle(Paper.ink)
                    .tint(Paper.accent)
                    .padding(.top, 6)
            }
        } actions: {
            Button("Continue") { sync.acknowledgeRecoveryKey() }
                .buttonStyle(.matildePrimary)
                .disabled(!saved)
        }
        .onAppear(perform: writeFile)
        .onDisappear(perform: removeFile)
    }

    private var keyGrid: some View {
        let groups = RecoveryKeyInput.groups(code)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 10) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                Text(group)
                    .font(.system(size: 19, weight: .medium, design: .monospaced))
                    .foregroundStyle(Paper.ink)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Paper.sidebar, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Paper.muted.opacity(0.25)))
        .textSelection(.enabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recovery key")
        .accessibilityValue(groups.joined(separator: ", "))
    }

    /// The key as a text file for "Save to Files", in a private temporary folder; removed again
    /// when the step closes.
    private func writeFile() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = folder.appendingPathComponent(RecoveryKeyDocument.fileName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try RecoveryKeyDocument.text(code: code, email: sync.signedInEmail)
                .write(to: url, atomically: true, encoding: .utf8)
            file = url
        } catch {
            file = nil
        }
    }

    private func removeFile() {
        if let file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        file = nil
    }
}

private struct EnterKeyStep: View {
    @Environment(SyncController.self) private var sync
    let failures: Int
    @State private var key = ""
    @State private var shakes: CGFloat = 0
    @State private var filledFromICloud = false
    @FocusState private var focused: Bool

    var body: some View {
        let state = RecoveryKeyInput.state(of: key)
        StepLayout(symbol: "key", title: SyncOnboardingCopy.enterKeyTitle, text: SyncOnboardingCopy.enterKeyText) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("MTLD-XXXX-XXXX-…", text: $key, axis: .vertical)
                    .font(.system(size: 19, weight: .medium, design: .monospaced))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .lineLimit(2...4)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 16)
                    .background(Paper.sidebar, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(state == .valid ? Paper.accent : Paper.muted.opacity(0.25)))
                    .modifier(Shake(shakes: shakes))
                Group {
                    if let message = RecoveryKeyInput.message(for: state) {
                        Text(message).foregroundStyle(.red)
                    } else if case .incomplete(let remaining) = state {
                        Text("\(remaining) characters to go").foregroundStyle(Paper.muted)
                    } else if state == .valid {
                        Label(filledFromICloud ? SyncOnboardingCopy.filledFromICloud : "Looks right",
                              systemImage: filledFromICloud ? "key.icloud" : "checkmark.circle")
                            .foregroundStyle(Paper.accent)
                    }
                }
                .font(.callout)
                .contentTransition(.numericText())
                StepMessage()
            }
        } actions: {
            Button(action: { sync.recover(code: RecoveryKeyInput.normalize(key)) }) {
                if sync.busy { ProgressView().tint(Brand.buttonInk) } else { Text("Unlock") }
            }
            .buttonStyle(.matildePrimary)
            .disabled(state != .valid || sync.busy)
            Button("Use a Different Email", role: .destructive) { sync.signOut() }
                .buttonStyle(.matildeSecondary)
        }
        .onAppear { focused = true }
        .task {
            // A copy another device kept in iCloud Keychain fills the field; the user still taps Unlock.
            guard key.isEmpty, let stored = await sync.storedRecoveryKey() else { return }
            key = RecoveryKeyInput.formatted(stored)
            filledFromICloud = true
        }
        .onChange(of: key) { _, new in
            // Format into groups as the user types, unless that would fight a deletion.
            let formatted = RecoveryKeyInput.formatted(new)
            if formatted != new, formatted.count >= new.count, RecoveryKeyInput.normalize(new).count <= RecoveryKeyInput.characterCount {
                key = formatted
            }
        }
        .onChange(of: failures) { _, _ in withAnimation(.linear(duration: 0.45)) { shakes += 1 } }
    }
}

private struct DoneStep: View {
    let finish: () -> Void
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(Paper.accent)
                .symbolEffect(.bounce, options: .nonRepeating, value: appeared)
                .scaleEffect(appeared ? 1 : 0.6)
                .opacity(appeared ? 1 : 0)
                .animation(.spring(duration: 0.5, bounce: 0.35), value: appeared)
                .accessibilityHidden(true)
            Text(SyncOnboardingCopy.doneTitle)
                .font(Font(MarkdownStyle.bodyFont(30, bold: true)))
                .foregroundStyle(Paper.ink)
            Text(SyncOnboardingCopy.doneText)
                .font(.system(size: 17))
                .foregroundStyle(Paper.muted)
                .multilineTextAlignment(.center)
            Spacer()
            Button("Start Writing", action: finish)
                .buttonStyle(.matildePrimary)
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 28)
        .onAppear { appeared = true }
    }
}

/// The invitation shown where sync isn't set up (Settings, the empty notes list).
struct SyncCallToAction: View {
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Paper.accent)
                .accessibilityHidden(true)
            Text(SyncOnboardingCopy.callToActionTitle)
                .font(Font(MarkdownStyle.bodyFont(22, bold: true)))
                .foregroundStyle(Paper.ink)
            Text(SyncOnboardingCopy.callToActionText)
                .font(.system(size: 15))
                .foregroundStyle(Paper.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Set Up Sync", action: open)
                .buttonStyle(MatildePrimaryButtonStyle(fullWidth: false))
                .padding(.top, 4)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
