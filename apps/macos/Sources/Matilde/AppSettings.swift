import SwiftUI
import Security
import MatildeKit

enum SettingKeys {
    static let appearance = "appearance.mode"
    static let appIcon = "appearance.appIcon"
    static let textSize = "writing.textSize"
    static let lineSpacing = "writing.lineSpacing"
    static let spellChecking = "writing.spellChecking"
}

struct AppSettingsView: View {
    @AppStorage(SettingKeys.appearance) private var appearance = AppAppearance.system.rawValue
    @AppStorage(SettingKeys.appIcon) private var appIcon = AppIconChoice.standard.rawValue
    @AppStorage(SettingKeys.textSize) private var textSize = 19.0
    @AppStorage(SettingKeys.lineSpacing) private var lineSpacing = 9.0
    @AppStorage(SettingKeys.spellChecking) private var spellChecking = false
    @AppStorage("langdock.baseURL") private var langdockURL = "https://api.langdock.com"
    @AppStorage("langdock.region") private var langdockRegion = "eu"
    @AppStorage("langdock.model") private var langdockModel = ""
    @AppStorage(WritingAssistPrompt.guidanceKey) private var guidance = WritingAssistPrompt.defaultGuidance
    @State private var models: [String] = []
    @State private var loadingModels = false
    @State private var modelTask: Task<Void, Never>?
    @State private var connectionMessage: String?
    @State private var key = ""
    @State private var hasKey = false
    @State private var keyError: String?
    @State private var removingKey = false
    private let keyStore = APIKeyStore()

    var body: some View {
        TabView {
            Form {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { mode in Text(mode.title).tag(mode.rawValue) }
                }.pickerStyle(.segmented)
                Section("App Icon") { AppIconPicker(selection: $appIcon) }
            }.formStyle(.grouped)
                .tabItem { Label { Text("General") } icon: { MatildeIcon.settings.image(size: MatildeIcon.tabSize) } }

            Form {
                Section {
                    LabeledContent("Text size") {
                        Slider(value: $textSize, in: 16...26, step: 1).frame(width: 180)
                            .accessibilityLabel("Writing text size")
                        Text("\(Int(textSize)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                    LabeledContent("Line spacing") {
                        Slider(value: $lineSpacing, in: 2...12, step: 1).frame(width: 180)
                            .accessibilityLabel("Writing line spacing")
                        Text("\(Int(lineSpacing)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                    Toggle("Check spelling while typing", isOn: $spellChecking)
                }
                Section {
                    Text("A little room to think clearly, follow an idea, and make it yours.")
                        .font(Font(Paper.body(CGFloat(textSize)))).lineSpacing(lineSpacing)
                        .foregroundStyle(Color(Paper.ink)).padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading).background(Color(Paper.background))
                    Button("Restore Writing Defaults") { textSize = 19; lineSpacing = 9; spellChecking = false }
                }
            }.formStyle(.grouped)
                .tabItem { Label { Text("Writing") } icon: { MatildeIcon.typography.image(size: MatildeIcon.tabSize) } }
            Form {
                Section("Guidance") {
                    TextEditor(text: $guidance)
                        .font(.body).frame(minHeight: 200)
                        .accessibilityLabel("Ask Matilde guidance")
                    Button("Reset to Default") {
                        guidance = WritingAssistPrompt.defaultGuidance
                        UserDefaults.standard.removeObject(forKey: WritingAssistPrompt.guidanceKey)
                    }.disabled(guidance == WritingAssistPrompt.defaultGuidance)
                }
            }.formStyle(.grouped)
                .tabItem { Label { Text("Ask Matilde") } icon: { MatildeIcon.askMatilde.image(size: MatildeIcon.tabSize) } }
            Form {
                Section("Langdock") {
                    LabeledContent("API key", value: hasKey ? "Saved in Keychain" : "Not configured")
                    SecureField(hasKey ? "Enter a replacement key" : "Enter your API key", text: $key)
                        .textContentType(.password).accessibilityLabel("Langdock API key")
                    HStack {
                        Button(hasKey ? "Replace Key" : "Save Key") {
                            perform { try keyStore.save(key); key = ""; hasKey = true; resetModels() }
                        }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if hasKey {
                            Button("Remove Key", role: .destructive) { removingKey = true }
                        }
                    }
                    TextField("API address", text: $langdockURL).accessibilityLabel("Langdock API address")
                    Picker("Region", selection: $langdockRegion) {
                        Text("Europe").tag("eu")
                        Text("United States").tag("us")
                    }
                    HStack {
                        TextField("Model ID", text: $langdockModel).accessibilityLabel("Langdock model")
                        if !models.isEmpty {
                            Menu("Choose") { ForEach(models, id: \.self) { name in Button(name) { langdockModel = name } } }
                        }
                        Button(loadingModels ? "Loading…" : "Load models") { loadModels() }.disabled(!hasKey || loadingModels)
                    }
                    if let connectionMessage { Text(connectionMessage).font(.caption).foregroundStyle(.secondary) }
                    Text("Reviews send the active draft’s title, goal and text to Langdock, manually or after 30 seconds without typing. Pause automatic reviews from Ask Matilde. Replies include the relevant comment thread. Stash, other drafts and image files are excluded. Reviews stay in your workspace; rewrites change your text only when you accept them. Your API key stays in Keychain.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let keyError { Text(keyError).foregroundStyle(.red).font(.callout) }
                }
            }.formStyle(.grouped)
                .tabItem { Label { Text("Connections") } icon: { MatildeIcon.key.image(size: MatildeIcon.tabSize) } }
            SyncSettingsView()
                .tabItem { Label { Text("Sync") } icon: { MatildeIcon.sync.image(size: MatildeIcon.tabSize) } }
        }
        .padding(12).frame(width: 540, height: 380)
        .tint(Color(Paper.accent)).modifier(AppAppearanceModifier())
        .onAppear { perform { hasKey = try keyStore.containsKey() } }
        .onDisappear { key = ""; modelTask?.cancel(); loadingModels = false }
        .onChange(of: appIcon) { _, value in AppIconChoice.resolved(value).apply() }
        .onChange(of: langdockURL) { _, _ in resetModels() }
        .onChange(of: langdockRegion) { _, _ in resetModels() }
        .confirmationDialog("Remove the saved Langdock API key?", isPresented: $removingKey) {
            Button("Remove Key", role: .destructive) { perform { try keyStore.remove(); hasKey = false; key = ""; resetModels() } }
        }
    }
    private func resetModels() {
        modelTask?.cancel(); loadingModels = false; models = []; connectionMessage = nil
    }
    private func loadModels() {
        modelTask?.cancel()
        loadingModels = true; keyError = nil; connectionMessage = nil
        let configuration = LangdockConfiguration.current
        modelTask = Task { @MainActor in
            do {
                guard let credential = try keyStore.load() else { throw ReviewError.message("Save your API key first.") }
                let available = try await LangdockClient().models(configuration: configuration, key: credential)
                try Task.checkCancellation()
                models = available
                connectionMessage = available.isEmpty ? "Connected, but this key has no available models." : "Connected. Choose a chat model for writing reviews."
                loadingModels = false
            } catch is CancellationError { }
            catch { keyError = error.localizedDescription; loadingModels = false }
        }
    }
    private func perform(_ operation: () throws -> Void) {
        keyError = nil
        do { try operation() } catch { keyError = error.localizedDescription }
    }
}
