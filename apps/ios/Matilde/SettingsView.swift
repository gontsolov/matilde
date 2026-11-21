import SwiftUI
import UIKit
import MatildeKit

/// Settings: Sync (sign-in, the recovery key, status), Connections (the Langdock key and model
/// for Ask Matilde) and About.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                SyncSection()
                ConnectionsSection()
                Section("About") {
                    LabeledContent("Version", value: Self.version)
                    Link("matilde.page", destination: URL(string: "https://matilde.page")!)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", systemImage: "xmark", role: .close) { dismiss() }
                }
            }
        }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return short == build ? short : "\(short) (\(build))"
    }
}

/// IOS-03: the same steps as Settings → Sync on the Mac.
private struct SyncSection: View {
    @Environment(SyncController.self) private var sync
    @State private var email = ""
    @State private var code = ""
    @State private var recoveryCode = ""
    @State private var lastGroup = ""

    var body: some View {
        Section {
            phase
            if let message = sync.message {
                Text(message).foregroundStyle(.red).font(.callout)
            }
        } header: {
            Text("Sync")
        } footer: {
            Text(footer)
        }
        .disabled(sync.busy)
        .onChange(of: sync.phase) { _, _ in code = ""; recoveryCode = ""; lastGroup = "" }
        if SyncServerSelection.showsPicker {
            Section {
                Picker("Server", selection: Binding(get: { sync.server.isStaging }, set: { sync.setServer($0 ? .staging : .production) })) {
                    Text("Matilde").tag(false)
                    Text("Staging").tag(true)
                }
            } footer: {
                Text("Debug builds only.")
            }
        }
    }

    private var footer: String {
        switch sync.phase {
        case .signedOut: return "Use the email you sync with on your Mac. Your notes are end-to-end encrypted: the server can’t read them."
        case .awaitingCode(let email): return "We sent a code to \(email)."
        case .needsRecoveryKey: return "Your account key was made on another device. Enter the recovery key you saved then; you can also find it on your Mac in Settings → Sync."
        case .showRecoveryKey: return "Save this recovery key somewhere safe, such as a password manager. You need it to add another device, and it is shown only once."
        default: return ""
        }
    }

    @ViewBuilder private var phase: some View {
        switch sync.phase {
        case .signedOut:
            TextField("Email", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .onSubmit(sendCode)
            Button("Send Code", action: sendCode)
                .disabled(email.trimmingCharacters(in: .whitespaces).isEmpty)
        case .awaitingCode:
            TextField("Code", text: $code)
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .onSubmit(signIn)
            Button("Sign In", action: signIn)
                .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) { sync.cancelSignIn() }
        case .checkingKey:
            HStack {
                Text("Checking your account key")
                Spacer()
                ProgressView()
            }
        case .needsRecoveryKey:
            TextField("Recovery key", text: $recoveryCode, axis: .vertical)
                .font(.body.monospaced())
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Unlock", action: unlock)
                .disabled(recoveryCode.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Sign Out", role: .destructive) { sync.signOut() }
        case .showRecoveryKey(let key):
            Text(key)
                .font(.body.monospaced())
                .textSelection(.enabled)
            Button("Copy Recovery Key", systemImage: "doc.on.doc") { UIPasteboard.general.string = key }
            TextField("Type its last four characters", text: $lastGroup)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .onSubmit(confirm)
            Button("Done", action: confirm)
                .disabled(lastGroup.count < 4)
        case .ready:
            LabeledContent("Status", value: sync.statusText)
            LabeledContent("Server", value: sync.serverHost)
            Button("Sync Now") { sync.syncNow() }
                .disabled(sync.syncing)
            Button("Sign Out", role: .destructive) { sync.signOut() }
        case .updateRequired:
            Text("Update Matilde to keep syncing.")
        }
    }

    private func sendCode() { sync.requestCode(email: email) }
    private func signIn() { sync.verify(code: code) }
    private func unlock() { sync.recover(code: recoveryCode) }
    private func confirm() {
        if !sync.confirmRecoveryKey(lastGroup: lastGroup) { sync.message = "That doesn’t match the recovery key." }
    }
}

/// IOS-08: the Langdock key and model Ask Matilde uses, stored like on the Mac (the key in this
/// device's Keychain; address, region and model in UserDefaults).
private struct ConnectionsSection: View {
    @AppStorage("langdock.baseURL") private var langdockURL = "https://api.langdock.com"
    @AppStorage("langdock.region") private var langdockRegion = "eu"
    @AppStorage("langdock.model") private var langdockModel = ""
    @State private var key = ""
    @State private var hasKey = false
    @State private var models: [String] = []
    @State private var loadingModels = false
    @State private var message: String?
    @State private var keyError: String?
    @State private var removingKey = false
    private let keyStore = APIKeyStore()

    var body: some View {
        Section {
            LabeledContent("API key", value: hasKey ? "Saved" : "Not set")
            SecureField(hasKey ? "Replacement key" : "Langdock API key", text: $key)
                .textContentType(.password)
                .onSubmit(saveKey)
            if !key.isEmpty {
                Button(hasKey ? "Replace Key" : "Save Key", action: saveKey)
            }
            if hasKey {
                Button("Remove Key", role: .destructive) { removingKey = true }
            }
            Picker("Region", selection: $langdockRegion) {
                Text("Europe").tag("eu")
                Text("United States").tag("us")
            }
            Picker("Model", selection: $langdockModel) {
                Text(langdockModel.isEmpty ? "None" : langdockModel).tag(langdockModel)
                ForEach(models.filter { $0 != langdockModel }, id: \.self) { Text($0).tag($0) }
            }
            Button(loadingModels ? "Loading Models…" : "Load Models", action: loadModels)
                .disabled(!hasKey || loadingModels)
            DisclosureGroup("API Address") {
                TextField("https://api.langdock.com", text: $langdockURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            if let keyError { Text(keyError).font(.footnote).foregroundStyle(.red) }
        } header: {
            Text("Connections")
        } footer: {
            Text("Ask Matilde uses your Langdock API key. When you ask, the note’s title, goal and text go to Langdock; replies include the thread. Rewrites change your text only when you accept them. The key stays in this iPhone’s Keychain.")
        }
        .onAppear { perform { hasKey = try keyStore.containsKey() } }
        .onChange(of: langdockRegion) { _, _ in models = []; message = nil }
        .onChange(of: langdockURL) { _, _ in models = []; message = nil }
        .confirmationDialog("Remove the saved Langdock API key?", isPresented: $removingKey, titleVisibility: .visible) {
            Button("Remove Key", role: .destructive) { perform { try keyStore.remove(); hasKey = false; models = [] } }
        }
    }

    private func saveKey() {
        perform { try keyStore.save(key); key = ""; hasKey = true; loadModels() }
    }

    private func loadModels() {
        loadingModels = true; keyError = nil; message = nil
        let configuration = LangdockConfiguration.current
        Task {
            do {
                guard let credential = try keyStore.load() else { throw ReviewError.message("Save your API key first.") }
                let available = try await LangdockClient().models(configuration: configuration, key: credential)
                models = available
                message = available.isEmpty ? "Connected, but this key has no models." : "Connected. Choose a model for Ask Matilde."
            } catch {
                keyError = error.localizedDescription
            }
            loadingModels = false
        }
    }

    private func perform(_ operation: () throws -> Void) {
        keyError = nil
        do { try operation() } catch { keyError = error.localizedDescription }
    }
}
