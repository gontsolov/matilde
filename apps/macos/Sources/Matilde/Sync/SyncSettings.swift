#if canImport(AppKit)
import SwiftUI

/// The Sync tab in Settings (SYNC-07): on/off, server, sign-in, the recovery key and a status line.
struct SyncSettingsView: View {
    @ObservedObject var center = SyncCenter.shared
    @State private var email = ""
    @State private var code = ""
    @State private var recoveryCode = ""
    @State private var lastGroup = ""

    var body: some View {
        Form {
            Section {
                Toggle("Sync", isOn: Binding(get: { center.enabled }, set: { center.setEnabled($0) }))
                if center.enabled && SyncServerSelection.showsPicker {
                    Picker("Server", selection: Binding(get: { center.server.isStaging }, set: { center.setServer($0 ? .staging : .production) })) {
                        Text("Matilde").tag(false)
                        Text("Staging").tag(true)
                    }
                }
            }
            if center.enabled { Section { phase } }
            if let message = center.message { Text(message).foregroundStyle(.red).font(.callout) }
        }
        .formStyle(.grouped)
        .disabled(center.busy)
        .onChange(of: center.phase) { _, _ in code = ""; recoveryCode = ""; lastGroup = "" }
    }

    @ViewBuilder private var phase: some View {
        switch center.phase {
        case .off, .signedOut:
            TextField("Email", text: $email).textContentType(.emailAddress).onSubmit(sendCode)
            Button("Send Code", action: sendCode).disabled(email.trimmingCharacters(in: .whitespaces).isEmpty)
        case .awaitingCode:
            TextField("Code", text: $code).textContentType(.oneTimeCode).onSubmit(signIn)
            HStack {
                Button("Sign In", action: signIn).disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { center.cancelSignIn() }
            }
        case .checkingKey:
            ProgressView().controlSize(.small)
        case .needsRecoveryKey:
            TextField("Recovery key", text: $recoveryCode).font(.body.monospaced()).onSubmit(unlock)
            HStack {
                Button("Unlock", action: unlock).disabled(recoveryCode.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Sign Out") { center.signOut() }
            }
        case .showRecoveryKey(let key):
            LabeledContent("Recovery key") {
                Text(key).font(.body.monospaced()).textSelection(.enabled)
            }
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key, forType: .string)
                }
                TextField("Last four characters", text: $lastGroup).onSubmit(confirm)
                Button("Done", action: confirm).disabled(lastGroup.count < 4)
            }
        case .ready:
            LabeledContent("Status", value: statusText)
            HStack {
                Button("Sync Now") { center.syncNow() }.disabled(center.syncing)
                Button("Sign Out") { center.signOut() }
            }
        case .updateRequired:
            Text("Update Matilde to keep syncing.")
        }
    }

    private var statusText: String {
        if center.syncing { return "Syncing…" }
        if !center.status.isEmpty { return center.status }
        guard let last = center.lastSynced else { return "Waiting" }
        return "Synced \(last.formatted(date: .omitted, time: .shortened))"
    }

    private func sendCode() { center.requestCode(email: email) }
    private func signIn() { center.verify(code: code) }
    private func unlock() { center.recover(code: recoveryCode) }
    private func confirm() {
        if !center.confirmRecoveryKey(lastGroup: lastGroup) { center.message = "That doesn’t match the recovery key." }
    }
}
#endif
