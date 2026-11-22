import SwiftUI
import AppKit
import MatildeKit

// FEEDBACK (UI-29): Help → Send Feedback… and Settings → General open `FeedbackSheet`. It sends
// only what the user types and, if the toggle stays on, the diagnostics listed in the sheet,
// to the sync server the app is set to (`SyncCenter.server`). Never note content.

/// Opens the feedback sheet over the main window (from the Help menu).
@MainActor
final class FeedbackPresenter: ObservableObject {
    static let shared = FeedbackPresenter()
    @Published var showing = false

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showing = true
    }
}

/// A calm sheet in the sync setup's style: header, kind, message, optional reply email, the
/// diagnostics toggle with exactly what gets sent, then Send. Success and failure replace the
/// form in place; a failure offers "Email Instead".
struct FeedbackSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = FeedbackDraft()
    @State private var stage: Stage = .editing
    @State private var showsDiagnostics = false
    @FocusState private var focus: Field?
    private let diagnostics = FeedbackDiagnostics.current()

    enum Stage: Equatable {
        case editing
        case sending
        case sent(FeedbackOutcome)
        case failed(String)
    }

    enum Field { case message, email }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if case .sent(let outcome) = stage {
                    MacStatusStep(icon: .done, title: FeedbackCopy.sentTitle,
                                  text: outcome == .sent ? FeedbackCopy.sentText : FeedbackCopy.savedText, success: true)
                        .frame(maxWidth: .infinity, minHeight: 190)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
                } else {
                    form.transition(.opacity)
                }
            }
            HStack(spacing: 12) {
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
        .background(Color(Paper.background))
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.12), value: stage)
        .onAppear { DispatchQueue.main.async { focus = .message } }
    }

    // MARK: Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 18) {
            MacStepHeader(title: FeedbackCopy.title, text: FeedbackCopy.promise)

            Picker(FeedbackCopy.kindLabel, selection: $draft.kind) {
                ForEach(FeedbackKind.allCases) { kind in Text(kind.title).tag(kind) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(FeedbackCopy.kindLabel)

            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topLeading) {
                    if draft.message.isEmpty {
                        Text(FeedbackCopy.messagePlaceholder)
                            .font(.system(size: 14))
                            .foregroundStyle(Color(Paper.muted).opacity(0.8))
                            .padding(.top, 13)
                            .padding(.leading, 17)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    TextEditor(text: $draft.message)
                        .font(.system(size: 14))
                        .foregroundStyle(Color(Paper.ink))
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.hidden)
                        .focused($focus, equals: .message)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 12)
                        .accessibilityLabel("Feedback message")
                }
                .frame(height: 150)
                .fieldBackground(focused: focus == .message)
                if draft.isTooLong {
                    Text(FeedbackCopy.tooLong(draft.messageLength))
                        .font(.caption).foregroundStyle(Color(nsColor: .systemRed))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(FeedbackCopy.emailLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(Paper.muted))
                TextField(FeedbackCopy.emailPlaceholder, text: $draft.replyEmail)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(Paper.ink))
                    .textContentType(.emailAddress)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .email)
                    .onSubmit(send)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
                    .fieldBackground(focused: focus == .email)
                    .accessibilityLabel(FeedbackCopy.emailLabel)
                if !draft.replyEmailIsValid && focus != .email {
                    Text(FeedbackCopy.emailInvalid)
                        .font(.caption).foregroundStyle(Color(nsColor: .systemRed))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle(FeedbackCopy.diagnosticsToggle, isOn: $draft.includeDiagnostics)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 13))
                    .tint(Color(Paper.accent))
                DisclosureGroup(isExpanded: $showsDiagnostics) {
                    diagnosticsList.padding(.top, 6)
                } label: {
                    Text(FeedbackCopy.diagnosticsDisclosure)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(Paper.muted))
                }
            }

            if case .failed(let reason) = stage {
                Label { Text(reason) } icon: { MatildeIcon.alert.image(size: 16).iconBaseline() }
                    .font(.callout)
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .disabled(stage == .sending)
    }

    @ViewBuilder private var diagnosticsList: some View {
        if draft.includeDiagnostics {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                ForEach(diagnostics.lines) { line in
                    GridRow {
                        Text(line.label).foregroundStyle(Color(Paper.muted))
                        Text(line.value).foregroundStyle(Color(Paper.ink)).textSelection(.enabled)
                    }
                }
            }
            .font(.system(size: 12))
        } else {
            Text(FeedbackCopy.diagnosticsOff)
                .font(.system(size: 12))
                .foregroundStyle(Color(Paper.muted))
        }
    }

    // MARK: Actions

    @ViewBuilder private var actions: some View {
        switch stage {
        case .sent:
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(MacPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        case .editing, .sending, .failed:
            Button("Cancel") { dismiss() }
                .buttonStyle(MacQuietButtonStyle(tone: .muted))
                .keyboardShortcut(.cancelAction)
            Spacer()
            if case .failed = stage {
                Button(FeedbackCopy.emailInstead) { emailInstead() }
                    .buttonStyle(MacQuietButtonStyle())
            }
            Button(action: send) {
                HStack(spacing: 6) {
                    if stage == .sending { ProgressView().controlSize(.mini).tint(Color(MacBrand.buttonInk)) }
                    Text(stage == .sending ? FeedbackCopy.sending : sendTitle)
                }
            }
            .buttonStyle(MacPrimaryButtonStyle())
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!draft.canSend || stage == .sending)
        }
    }

    private var sendTitle: String {
        if case .failed = stage { return FeedbackCopy.tryAgain }
        return FeedbackCopy.send
    }

    private func send() {
        guard draft.canSend, stage != .sending else { return }
        stage = .sending
        let request = draft.request(diagnostics: diagnostics)
        let center = SyncCenter.shared
        let client = FeedbackClient(server: center.server)
        Task { @MainActor in
            let token = await center.feedbackAccessToken()
            do {
                stage = .sent(try await client.send(request, accessToken: token))
            } catch {
                stage = .failed(FeedbackCopy.failure(error))
            }
        }
    }

    private func emailInstead() {
        NSWorkspace.shared.open(draft.mailtoURL(diagnostics: diagnostics))
    }
}

private extension View {
    /// The onboarding fields' look (`MacInputField`): paper fill, hairline border, accent ring while focused.
    func fieldBackground(focused: Bool) -> some View {
        background(Color(Paper.sidebar), in: RoundedRectangle(cornerRadius: MacOnboarding.fieldRadius))
            .overlay(
                RoundedRectangle(cornerRadius: MacOnboarding.fieldRadius)
                    .strokeBorder(focused ? Color(Paper.accent) : Color(Paper.muted).opacity(0.25), lineWidth: focused ? 2 : 1)
            )
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}
