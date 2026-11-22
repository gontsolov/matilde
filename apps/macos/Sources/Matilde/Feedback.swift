import SwiftUI
import AppKit
import MatildeKit

// FEEDBACK (UI-29): the sidebar's Feedback button, Help → Send Feedback… and Settings → General
// all open the same small window (`FeedbackWindow`, centred on screen), never a sheet: a sheet
// on the small Settings window used to hang out of it. It sends only what the user types plus the
// basic diagnostics (app, version, build, system, device model) to the sync server the app is set
// to (`SyncCenter.server`). Never note content.

/// The feedback window's scene: one window, sized to the form, centred, not in the Window menu.
struct FeedbackWindow: Scene {
    static let id = "feedback"

    var body: some Scene {
        Window(FeedbackCopy.title, id: Self.id) {
            FeedbackSheet()
                .modifier(AppAppearanceModifier())
                .scrollIndicators(.hidden)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commandsRemoved()
    }
}

/// Opens the feedback window. Menu item, sidebar and Settings all use it; `openWindow` only exists
/// inside views, hence a view rather than a function.
struct FeedbackButton<Label: View>: View {
    @Environment(\.openWindow) private var openWindow
    let label: () -> Label

    init(@ViewBuilder label: @escaping () -> Label) { self.label = label }

    var body: some View {
        Button(action: {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: FeedbackWindow.id)
        }, label: label)
    }
}

/// The sidebar footer's "Feedback", opposite the Settings gear: muted 12-point text, no
/// background, ink on hover.
struct SidebarFeedbackButton: View {
    @State private var hovering = false

    var body: some View {
        FeedbackButton { Text("Feedback") }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Color(hovering ? Paper.ink : Paper.muted))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .help(FeedbackCopy.menuTitle)
    }
}

/// A compact form in the sync setup's style: header, kind, message, optional reply email, then
/// Send. Success and failure replace the form in place; a failure offers "Email Instead".
struct FeedbackSheet: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = FeedbackDraft()
    @State private var stage: Stage = .editing
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
                        .frame(maxWidth: .infinity, minHeight: 160)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
                } else {
                    form.transition(.opacity)
                }
            }
            HStack(spacing: 12) {
                actions
            }
            .frame(minHeight: 30)
            .padding(.top, 18)
        }
        // Laid out from the window's top edge (hidden title bar); the top inset clears the traffic lights.
        .padding(.horizontal, 24)
        .padding(.top, 38)
        .padding(.bottom, 18)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(Paper.background))
        .ignoresSafeArea(.container, edges: .top)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.12), value: stage)
        .onAppear { DispatchQueue.main.async { focus = .message } }
        .onDisappear { draft = FeedbackDraft(); stage = .editing }
    }

    private func dismiss() { dismissWindow(id: FeedbackWindow.id) }

    // MARK: Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                // The app's ordinary sheet-title size, not the onboarding's large serif.
                Text(FeedbackCopy.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color(Paper.ink))
                    .accessibilityAddTraits(.isHeader)
                Text(FeedbackCopy.promise)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(Paper.muted))
                    .fixedSize(horizontal: false, vertical: true)
            }

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
                            .font(.system(size: 13))
                            .foregroundStyle(Color(Paper.muted).opacity(0.8))
                            .padding(.top, 9)
                            .padding(.leading, 13)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    TextEditor(text: $draft.message)
                        .font(.system(size: 13))
                        .foregroundStyle(Color(Paper.ink))
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.hidden)
                        .focused($focus, equals: .message)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 8)
                        .accessibilityLabel("Feedback message")
                }
                .frame(height: 120)
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
                    .font(.system(size: 13))
                    .foregroundStyle(Color(Paper.ink))
                    .textContentType(.emailAddress)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .email)
                    .onSubmit(send)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 12)
                    .fieldBackground(focused: focus == .email)
                    .accessibilityLabel(FeedbackCopy.emailLabel)
                if !draft.replyEmailIsValid && focus != .email {
                    Text(FeedbackCopy.emailInvalid)
                        .font(.caption).foregroundStyle(Color(nsColor: .systemRed))
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
