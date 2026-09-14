import SwiftUI
import Security

enum SettingKeys {
    static let appearance = "appearance.mode"
    static let textSize = "writing.textSize"
    static let lineSpacing = "writing.lineSpacing"
    static let spellChecking = "writing.spellChecking"
}

struct APIKeyStore {
    let service: String
    let account: String
    init(service: String = "app.matilde.credentials", account: String = "langdock") {
        self.service = service; self.account = account
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    func containsKey() throws -> Bool {
        var request = query
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return false }
        try check(status)
        return true
    }
    func save(_ key: String) throws {
        let cleaned = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw KeyError.empty }
        let changes = [kSecValueData as String: Data(cleaned.utf8)]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(changes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            item[kSecAttrLabel as String] = "Matilde — Langdock API key"
            try check(SecItemAdd(item as CFDictionary, nil))
        } else { try check(status) }
    }
    /// Only callers making an authorized provider request should retrieve the key.
    /// Settings uses an attributes-only query and never loads it into the UI.
    func load() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else { throw KeyError.access(errSecDecode) }
        return key
    }
    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw KeyError.access(status) }
    }
    enum KeyError: LocalizedError {
        case empty, access(OSStatus)
        var errorDescription: String? {
            switch self {
            case .empty: return "Enter an API key before saving."
            case .access(let status): return "Keychain could not complete the operation (\(status)). Your saved key has not been cleared."
            }
        }
    }
}

struct AppSettingsView: View {
    @AppStorage(SettingKeys.appearance) private var appearance = AppAppearance.system.rawValue
    @AppStorage(SettingKeys.textSize) private var textSize = 19.0
    @AppStorage(SettingKeys.lineSpacing) private var lineSpacing = 9.0
    @AppStorage(SettingKeys.spellChecking) private var spellChecking = false
    @AppStorage("langdock.baseURL") private var langdockURL = "https://api.langdock.com"
    @AppStorage("langdock.region") private var langdockRegion = "eu"
    @AppStorage("langdock.model") private var langdockModel = ""
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
            }.formStyle(.grouped)
                .tabItem { Label("General", systemImage: "gearshape") }

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
                .tabItem { Label("Writing", systemImage: "textformat") }
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
                    Text("Review now sends the active draft’s title, goal and text to Langdock. Stash, other drafts and image files are excluded. Reviews stay in your workspace; rewrites change your text only when you accept them. Your API key stays in Keychain.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let keyError { Text(keyError).foregroundStyle(.red).font(.callout) }
                }
            }.formStyle(.grouped)
                .tabItem { Label("Connections", systemImage: "key") }
        }
        .padding(12).frame(width: 540, height: 380)
        .tint(Color(Paper.accent)).modifier(AppAppearanceModifier())
        .onAppear { perform { hasKey = try keyStore.containsKey() } }
        .onDisappear { key = ""; modelTask?.cancel(); loadingModels = false }
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
