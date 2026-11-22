import SwiftUI
import UIKit
import MatildeKit

/// Settings: Sync (status and devices; setup is the guided flow), Connections (the Langdock key and model
/// for Ask Matilde) and About.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(FirstRunTour.seenKey) private var tourSeen = false
    @Environment(SyncController.self) private var sync
    /// Owned here, on the stable NavigationStack, not by a row: a cover attached inside the Form
    /// went away with its row when the sync phase changed the rows (signed out → code → key),
    /// which closed the setup in the middle of the flow.
    @State private var settingUpSync = false
    @State private var sendingFeedback = false

    var body: some View {
        NavigationStack {
            Form {
                SyncSection(settingUp: $settingUpSync)
                ConnectionsSection()
                Section {
                    Button("Send Feedback", systemImage: "bubble.left") { sendingFeedback = true }
                } header: {
                    Text("Feedback")
                } footer: {
                    Text(FeedbackCopy.promise)
                }
                Section("About") {
                    LabeledContent("Version", value: Self.version)
                    NavigationLink("What's New") { WhatsNewView() }
                    Link("matilde.page", destination: URL(string: "https://matilde.page")!)
                    Button("Show Welcome Again") {
                        // RootView plays the tour once this sheet has closed.
                        tourSeen = false
                        dismiss()
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $settingUpSync) {
                SyncOnboardingView(phase: sync.setupPhase)
            }
            .sheet(isPresented: $sendingFeedback) {
                FeedbackView()
            }
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

/// Sync in Settings: an invitation to the guided setup (`SyncOnboardingView`) until sync is on,
/// then its status, the account, the signed-in devices, Sync Now and Sign Out. No forms here.
private struct SyncSection: View {
    @Environment(SyncController.self) private var sync
    @Binding var settingUp: Bool
    @State private var signingOut = false
    @State private var revoking: ConnectedAITool?

    var body: some View {
        Section {
            switch sync.phase {
            case .ready:
                LabeledContent("Status") {
                    Text(sync.statusText).contentTransition(.opacity)
                }
                if let email = sync.signedInEmail {
                    LabeledContent("Account", value: email)
                }
                Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") { sync.syncNow() }
                    .disabled(sync.syncing)
                Button("Sign Out", role: .destructive) { signingOut = true }
            case .updateRequired:
                Label(SyncOnboardingCopy.updateText, systemImage: "arrow.down.app")
            case .signedOut:
                SyncCallToAction { settingUp = true }
            case .awaitingCode, .checkingKey, .needsRecoveryKey, .showRecoveryKey:
                Button("Finish Setting Up Sync", systemImage: "arrow.forward.circle") { settingUp = true }
                Button("Sign Out", role: .destructive) { sync.signOut() }
            }
        } header: {
            Text("Sync")
        } footer: {
            if sync.phase == .ready {
                Text(sync.connections.contains(where: \.canReachNotes)
                     ? "End-to-end encrypted. While an AI tool below is connected, the Matilde server can decrypt your notes for it."
                     : "End-to-end encrypted. No one else can read your notes.")
            }
        }
        .onAppear { sync.loadDevices(); sync.loadConnections() }
        .onChange(of: sync.phase) { _, phase in if phase == .ready { sync.loadDevices(); sync.loadConnections() } }
        .confirmationDialog("Sign out of sync on this iPhone?", isPresented: $signingOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { sync.signOut() }
        } message: {
            Text("Your notes stay on this iPhone. To sync again you’ll need your email and, if another device made your account, your Matilde key.")
        }
        if sync.phase == .ready, !sync.devices.isEmpty {
            Section("Signed-in Devices") {
                ForEach(sync.devices) { device in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                            Text(device.isCurrent ? "This iPhone" : "Last seen \(Self.day(device.lastSeenDay))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: device.symbolName)
                    }
                }
            }
        }
        if sync.phase == .ready, !sync.connections.isEmpty {
            Section {
                ForEach(sync.connections) { tool in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.displayName)
                        if let domain = tool.clientDomain {
                            Text(domain).font(.footnote).foregroundStyle(.secondary)
                        }
                        Text(tool.permissionsSummary).font(.footnote).foregroundStyle(.secondary)
                        Text(Self.connectionDetails(tool)).font(.footnote).foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("Disconnect", role: .destructive) { revoking = tool }
                    }
                    .contextMenu {
                        Button("Disconnect…", systemImage: "xmark.circle", role: .destructive) { revoking = tool }
                    }
                }
            } header: {
                Text("Connected AI Tools")
            } footer: {
                Text("These tools can use your notes as shown until the connection ends. Swipe to disconnect; what a tool has already read stays with it.")
            }
            .confirmationDialog("Disconnect \(revoking?.displayName ?? "this tool")?", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
                                titleVisibility: .visible, presenting: revoking) { tool in
                Button("Disconnect", role: .destructive) { sync.revokeConnection(tool.id) }
            } message: { _ in
                Text("It can no longer read or change your notes. To use it again, connect it from the tool.")
            }
        }
        if SyncServerSelection.showsPicker {
            Section {
                Picker("Server", selection: Binding(get: { sync.server.isStaging }, set: { sync.setServer($0 ? .staging : .production) })) {
                    Text("Matilde").tag(false)
                    Text("Staging").tag(true)
                }
                LabeledContent("Address", value: sync.serverHost)
            } footer: {
                Text("Debug builds only.")
            }
        }
    }

    /// "Ends 21 Dec 2026 · last used today" for a connected AI tool.
    static func connectionDetails(_ tool: ConnectedAITool) -> String {
        let ends = "Ends \(tool.expires.formatted(date: .abbreviated, time: .omitted))"
        guard let day = tool.lastUsedDay else { return ends + " · not used yet" }
        return ends + " · last used \(Self.day(day))"
    }

    /// "2026-11-21" as "Today", "Yesterday" or a short date.
    static func day(_ value: String) -> String {
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: value) else { return value }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "today" }
        if calendar.isDateInYesterday(date) { return "yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
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
