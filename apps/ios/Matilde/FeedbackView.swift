import SwiftUI
import UIKit
import MatildeKit

// FEEDBACK (UI-29): Settings → Send Feedback. The same fields and words as the Mac's sheet
// (`FeedbackCopy`): kind, message, optional reply email. Sends them with the basic diagnostics
// (app, version, build, system, device model) to the sync server the app is set to. Never note content.

struct FeedbackView: View {
    @Environment(SyncController.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = FeedbackDraft()
    @State private var stage: Stage = .editing
    @State private var failures = 0
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
        NavigationStack {
            ZStack {
                Paper.background.ignoresSafeArea()
                if case .sent(let outcome) = stage {
                    sent(outcome).transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
                } else {
                    form.transition(.opacity)
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.15), value: stage)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !isSent {
                        Button("Close", systemImage: "xmark", role: .close) { dismiss() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(stage == .sending)
        .sensoryFeedback(.success, trigger: isSent) { _, sent in sent }
        .sensoryFeedback(.error, trigger: failures)
    }

    private var isSent: Bool { if case .sent = stage { true } else { false } }

    // MARK: Form

    private var form: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(FeedbackCopy.title)
                            .font(Font(MarkdownStyle.bodyFont(30, bold: true)))
                            .foregroundStyle(Paper.ink)
                            .accessibilityAddTraits(.isHeader)
                        Text(FeedbackCopy.promise)
                            .font(.system(size: 17))
                            .foregroundStyle(Paper.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Picker(FeedbackCopy.kindLabel, selection: $draft.kind) {
                        ForEach(FeedbackKind.allCases) { kind in Text(kind.title).tag(kind) }
                    }
                    .pickerStyle(.segmented)
                    .sensoryFeedback(.selection, trigger: draft.kind)

                    VStack(alignment: .leading, spacing: 6) {
                        TextField(FeedbackCopy.messagePlaceholder, text: $draft.message, axis: .vertical)
                            .font(.system(size: 17))
                            .lineLimit(6...14)
                            .focused($focus, equals: .message)
                            .padding(.vertical, 14)
                            .padding(.horizontal, 16)
                            .field(focused: focus == .message)
                            .accessibilityLabel("Feedback message")
                        if draft.isTooLong {
                            Text(FeedbackCopy.tooLong(draft.messageLength)).font(.footnote).foregroundStyle(.red)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(FeedbackCopy.emailLabel)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Paper.muted)
                        TextField(FeedbackCopy.emailPlaceholder, text: $draft.replyEmail)
                            .font(.system(size: 17))
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.send)
                            .focused($focus, equals: .email)
                            .onSubmit(send)
                            .padding(.vertical, 14)
                            .padding(.horizontal, 16)
                            .field(focused: focus == .email)
                            .accessibilityLabel(FeedbackCopy.emailLabel)
                        if !draft.replyEmailIsValid && focus != .email {
                            Text(FeedbackCopy.emailInvalid).font(.footnote).foregroundStyle(.red)
                        }
                    }

                    if case .failed(let reason) = stage {
                        Label(reason, systemImage: "exclamationmark.circle")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
            .disabled(stage == .sending)

            VStack(spacing: 4) {
                Button(action: send) {
                    if stage == .sending { ProgressView().tint(Brand.buttonInk) } else { Text(sendTitle) }
                }
                .buttonStyle(.matildePrimary)
                .disabled(!draft.canSend || stage == .sending)
                if case .failed = stage {
                    Button(FeedbackCopy.emailInstead) { openURL(draft.mailtoURL(diagnostics: diagnostics)) }
                        .buttonStyle(.matildeSecondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
    }

    private func sent(_ outcome: FeedbackOutcome) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 64, weight: .ultraLight))
                .foregroundStyle(Paper.accent)
                .symbolEffect(.bounce, options: .nonRepeating, value: isSent)
                .accessibilityHidden(true)
            Text(FeedbackCopy.sentTitle)
                .font(Font(MarkdownStyle.bodyFont(28, bold: true)))
                .foregroundStyle(Paper.ink)
            Text(outcome == .sent ? FeedbackCopy.sentText : FeedbackCopy.savedText)
                .font(.system(size: 17))
                .foregroundStyle(Paper.muted)
                .multilineTextAlignment(.center)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.matildePrimary)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    // MARK: Actions

    private var sendTitle: String {
        if case .failed = stage { return FeedbackCopy.tryAgain }
        return FeedbackCopy.send
    }

    private func send() {
        guard draft.canSend, stage != .sending else { return }
        focus = nil
        stage = .sending
        let request = draft.request(diagnostics: diagnostics)
        let controller = sync
        let client = FeedbackClient(server: controller.server)
        Task {
            let token = await controller.feedbackAccessToken()
            do {
                stage = .sent(try await client.send(request, accessToken: token))
            } catch {
                stage = .failed(FeedbackCopy.failure(error))
                failures += 1
            }
        }
    }
}

private extension View {
    /// The onboarding fields' look: paper fill, hairline border, the accent while focused.
    func field(focused: Bool) -> some View {
        background(Paper.sidebar, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(focused ? Paper.accent : Paper.muted.opacity(0.25), lineWidth: focused ? 1.5 : 1))
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}
