import CoreImage
import KiteloopCore
import SwiftUI

struct AppPreferencesView: View {
    @Bindable var globalConfigStore: GlobalConfigStore
    @Bindable var agentCatalogStore: AgentCatalogStore
    @Bindable var controlServer: KiteloopControlServer
    @Bindable var softwareUpdater: SoftwareUpdater
    /// The resolver `chooseKnowledgeRepo` rescans through: writing the chosen path
    /// to the config is not enough, because the resolver keeps the scan paths it
    /// resolved at launch and would go on offering the packages found then until
    /// the next launch. Optional because the `Settings` scene holds it as one too —
    /// it bootstraps in the background at launch.
    var packageResolver: PackageResolver?

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }

            backendTab
                .tabItem { Label("Backend", systemImage: "cpu") }

            controlAPITab
                .tabItem { Label("Control API", systemImage: "network") }

            AgentCatalogView(catalogStore: agentCatalogStore)
                .tabItem { Label("Team", systemImage: "person.2") }

            globalMCPTab
                .tabItem { Label("MCP Servers", systemImage: "puzzlepiece.extension") }

            PluginManagerView(globalConfig: globalConfigStore.config)
                .tabItem { Label("Plugins", systemImage: "shippingbox") }
        }
        .frame(width: 640, height: 540)
    }

    // MARK: - General

    @State private var defaultModel: String = ModelCatalog.defaultModelID
    @State private var defaultEffort: String = ""
    @State private var loaded = false
    /// One `/api/tags` request per refresh: nil is unreachable, [] is nothing pulled.
    @State private var ollamaModels = RuntimeProbe { await OllamaRuntime.availableModels() }
    @State private var authMethod: ClaudeAuthMethod = .subscription
    @State private var apiKeyInput = ""
    @State private var apiKeySaved = false
    @State private var apiKeyWriteFailed = false
    @State private var confirmingAPIKeyRemoval = false
    @State private var apiKeyRemoveFailed = false
    @State private var bedrockRegion = BedrockConfig.default.region
    @State private var bedrockProfile = BedrockConfig.default.profile
    @State private var controlServerEnabled = false
    @State private var controlServerPort = String(KiteloopControlServer.defaultPort)
    @AppStorage("playfulStatusVerbs") private var playfulStatusVerbs = true

    @State private var confirmingTokenRotation = false
    @State private var pairingPhone = false
    /// The one-time code the open pairing sheet shows; the control token
    /// stands in, as `pairingToken`, only on a server that keeps no phones.
    @State private var pairingCode: String?
    @State private var pairingToken: String?
    @State private var tokenRotation: TokenRotationOutcome?
    @State private var tokenCopy: TokenCopyOutcome?

    /// What the last Regenerate press did, so the pane says whether the token in
    /// the file changed rather than leaving the user to `cat` it and guess.
    private enum TokenRotationOutcome {
        case rotated, failed
    }

    /// What the last Copy Token press did: the row confirms the copy, or says
    /// the file could not be read rather than leaving the clipboard silently stale.
    private enum TokenCopyOutcome {
        case copied, unreadable
    }

    /// What Copy Token does with the token file as read: the text to copy, or
    /// a failure when there is nothing to copy.
    enum ControlTokenCopy: Equatable {
        case copy(String)
        case unreadable
    }

    /// A nil read (missing or not UTF-8) and a blank one are both failures —
    /// copying an empty string would wipe the clipboard and look like success.
    static func controlTokenCopy(read: String?) -> ControlTokenCopy {
        let token = read?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return token.isEmpty ? .unreadable : .copy(token)
    }

    private var controlTokenPath: String {
        KiteloopControlServer.defaultTokenURL.path(percentEncoded: false)
    }

    /// What the QR should point the phone at: the live port when the server is
    /// up, else what the field says, else the default.
    private var pairingPort: UInt16 {
        controlServer.activePort ?? parsedControlServerPort.map(UInt16.init) ?? KiteloopControlServer.defaultPort
    }

    private var pairPhoneButton: some View {
        Button {
            // The QR carries a one-time code; the phone trades it for a token
            // of its own, revocable alone. Closing the sheet withdraws it.
            pairingCode = controlServer.offerPairingCode()
            pairingToken = pairingCode == nil
                ? KiteloopControlServer.readExactToken(at: KiteloopControlServer.defaultTokenURL) : nil
            pairingPhone = true
        } label: {
            Label("Pair a phone...", systemImage: "qrcode")
        }
        .accessibilityIdentifier("settings-pair-phone-button")
        .sheet(isPresented: $pairingPhone, onDismiss: {
            if let pairingCode { controlServer.withdrawPairingCode(pairingCode) }
            pairingCode = nil
        }) {
            PairPhoneSheet(port: pairingPort, serverRunning: controlServer.isRunning,
                           code: pairingCode, token: pairingToken,
                           pairedName: pairingCode.flatMap { controlServer.pairingClaims[$0] })
        }
    }

    private var generalTab: some View {
        Form {
            Section("Appearance") {
                Toggle("Playful status verbs", isOn: $playfulStatusVerbs)
                Text("Shows action-sports verbs (\"Carving…\", \"Catching air…\") in the activity ticker while agents work. Turn off for a neutral \"Working…\".")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("Knowledge Repository") {
                HStack {
                    Text(globalConfigStore.config.knowledgeRepoPath ?? "Not configured")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose...") { chooseKnowledgeRepo() }
                        .accessibilityIdentifier("settings-choose-knowledge-repo-button")
                }
            }

            Section("Vault Path (optional)") {
                HStack {
                    Text(Self.vaultPathStatus(path: globalConfigStore.config.vaultPath, folderExists: globalConfigStore.vaultURL != nil))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let vaultPath = globalConfigStore.config.vaultPath, !vaultPath.isEmpty {
                        Button("Clear") { globalConfigStore.setVaultPath(nil) }
                            .accessibilityIdentifier("settings-clear-vault-path-button")
                    }
                    Button("Choose...") { chooseVaultPath() }
                        .accessibilityIdentifier("settings-choose-vault-path-button")
                }
                Text("Backlogs are read from BACKLOG.md in each project root by default. A vault (Projects/<name>/Backlog.md) adds a shared cross-project layer; project-local files take precedence.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("Setup & Health") {
                UpdatePreferenceRows(updater: softwareUpdater)
                // The same resolve the app spawns through, so these rows report
                // the binary that will actually run rather than one the
                // configured `claudePath`/`nodePath` may have replaced.
                let cli = CLIResolver.resolve(globalConfig: globalConfigStore.config)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Claude CLI")
                            .font(.body)
                        Text(cli.claude ?? "Not found")
                            .font(.caption)
                            .foregroundColor(cli.claude != nil ? .secondary : .orange)
                    }
                    Spacer()
                    Image(systemName: cli.claude != nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(cli.claude != nil ? .green : .orange)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Node.js")
                            .font(.body)
                        Text(cli.node ?? "Not found")
                            .font(.caption)
                            .foregroundColor(cli.node != nil ? .secondary : .orange)
                    }
                    Spacer()
                    Image(systemName: cli.node != nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(cli.node != nil ? .green : .orange)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ollama")
                            .font(.body)
                        Text(ollamaStatus())
                            .font(.caption)
                            .foregroundColor(isOllamaAvailable() ? .secondary : .gray)
                    }
                    Spacer()
                    Image(systemName: isOllamaAvailable() ? "checkmark.circle.fill" : "minus.circle")
                        .foregroundColor(isOllamaAvailable() ? .green : .gray)
                }
                Button("Run Setup Wizard...") {
                    NotificationCenter.default.post(name: .showSetupWizard, object: nil)
                }
                .accessibilityIdentifier("settings-run-setup-wizard-button")
            }
        }
        .formStyle(.grouped)
        .onAppear { loadGlobalDefaults() }
        // Re-read each time the tab is opened, so an Ollama started since the
        // last look is reported without a relaunch.
        .task { await ollamaModels.refresh() }
    }

    /// Backend: which Claude the agents talk to and what they ask of it by
    /// default. Split out of General with Control API, because one form holding
    /// appearance, a server, credentials, model defaults and health checks
    /// scrolled, and nothing on it was findable by where it sat.
    private var backendTab: some View {
        Form {
            Section("Claude Backend") {
                Picker("Authentication", selection: $authMethod) {
                    ForEach(ClaudeAuthMethod.allCases, id: \.self) { method in
                        Text(method.displayName).tag(method)
                    }
                }
                .accessibilityIdentifier("settings-auth-method-picker")

                switch authMethod {
                case .subscription:
                    Text("Uses the Claude CLI's own login. Run `claude` in a terminal and sign in once if agents fail to authenticate.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                case .apiKey:
                    apiKeyRows
                case .bedrock:
                    TextField("AWS region", text: $bedrockRegion)
                    TextField("AWS profile", text: $bedrockProfile)
                    Text("Uses AWS SSO credentials. Model aliases map to inference-profile IDs; edit `bedrock.modelMappings` in ~/.kiteloop/global-config.json to override.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Section("Default Model") {
                Picker("Model", selection: $defaultModel) {
                    ForEach(ModelCatalog.pickerOptions(including: defaultModel)) { option in
                        Text(option.pickerLabel).tag(option.id)
                    }
                }
                .accessibilityIdentifier("settings-model-picker")
            }

            Section("Default Reasoning Effort") {
                Picker("Effort Level", selection: $defaultEffort) {
                    Text("None (agent default)").tag("")
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                    Text("Extra High").tag("xhigh")
                    Text("Max").tag("max")
                }
                .accessibilityIdentifier("settings-effort-picker")
            }

        }
        .formStyle(.grouped)
        .onAppear { loadGlobalDefaults() }
        .onChange(of: defaultModel) { _, val in globalConfigStore.setDefaultModel(val) }
        .onChange(of: defaultEffort) { _, val in globalConfigStore.setDefaultEffort(val.isEmpty ? nil : val) }
        .onChange(of: authMethod) { _, val in globalConfigStore.setClaudeAuth(val) }
        .onChange(of: bedrockRegion) { _, _ in saveBedrockConfig() }
        .onChange(of: bedrockProfile) { _, _ in saveBedrockConfig() }
    }

    /// The API key field, Save, and — once a key is saved — Remove…, which
    /// deletes it from the tokens file after a confirmation.
    @ViewBuilder private var apiKeyRows: some View {
        HStack {
            SecureField("ANTHROPIC_API_KEY", text: $apiKeyInput)
            Button("Save") {
                apiKeyWriteFailed = !TokenStore.set(
                    ClaudeAuthConfig.anthropicTokenKey, value: apiKeyInput
                )
                // The typed key stays in the field when it did not
                // reach disk: it is the only copy left.
                guard !apiKeyWriteFailed else { return }
                apiKeyInput = ""
                apiKeySaved = true
                apiKeyRemoveFailed = false
            }
            .disabled(apiKeyInput.isEmpty)
            if apiKeySaved {
                Button("Remove…", role: .destructive) { confirmingAPIKeyRemoval = true }
                    .accessibilityIdentifier("settings-api-key-remove-button")
                    .confirmationDialog(
                        "Remove the saved API key?",
                        isPresented: $confirmingAPIKeyRemoval
                    ) {
                        Button("Remove", role: .destructive) { removeAPIKey() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("The key is deleted from this Mac. While Authentication is set to API key, agents started after this will have no key to sign in with.")
                    }
            }
        }
        Text(Self.apiKeyStatus(saved: apiKeySaved, writeFailed: apiKeyWriteFailed, removeFailed: apiKeyRemoveFailed))
            .font(.caption)
            .foregroundStyle(
                apiKeySaved && !apiKeyWriteFailed && !apiKeyRemoveFailed ? .secondary : Color.orange
            )
    }

    /// A removal that did not reach disk leaves the key saved, and says so.
    private func removeAPIKey() {
        apiKeyRemoveFailed = !TokenStore.remove(ClaudeAuthConfig.anthropicTokenKey)
        guard !apiKeyRemoveFailed else { return }
        apiKeySaved = false
    }

    /// A refused write or removal is worth saying out loud: the agents the next
    /// launch spawns would otherwise fail to authenticate with nothing to point at.
    static func apiKeyStatus(saved: Bool, writeFailed: Bool, removeFailed: Bool) -> String {
        if removeFailed {
            return "API key could not be removed from ~/.kiteloop/tokens.json."
        }
        if writeFailed {
            return "API key could not be written to ~/.kiteloop/tokens.json."
        }
        return saved ? "API key saved." : "No API key saved yet."
    }

    /// A vault whose folder is gone is no vault to `GlobalConfigStore.vaultURL`,
    /// so the row says so instead of showing the path like a working one.
    static func vaultPathStatus(path: String?, folderExists: Bool) -> String {
        guard let path, !path.isEmpty else { return "Not configured" }
        return folderExists ? path : "\(path) (folder not found)"
    }

    /// Why the server is not listening, and who has the port — so a refused
    /// bind names the process to stop instead of only saying it failed.
    private var controlServerFailureDetail: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(controlServer.lastListenerFailure)
            if let holder = controlServer.portHolder {
                Text("Port held by \(holder)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .accessibilityIdentifier("settings-control-server-failure-detail")
    }

    /// The local control API: the server, its token, and pairing a phone —
    /// the section that made General scroll, on a tab of its own.
    private var controlAPITab: some View {
        Form {
            Section("Local Control API") {
                Toggle("Enable control server", isOn: $controlServerEnabled)
                    .accessibilityIdentifier("settings-control-server-toggle")
                HStack {
                    Text("Port")
                    TextField(String(KiteloopControlServer.defaultPort), text: $controlServerPort)
                        .frame(width: 90)
                        .disabled(!controlServerEnabled)
                        .accessibilityIdentifier("settings-control-server-port-field")
                    Spacer()
                    if controlServer.isRunning, let port = controlServer.activePort {
                        Label("Running on \(String(port))", systemImage: "circle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else if controlServerEnabled {
                        // The toggle is on but the listener isn't bound — a
                        // failed bind still retrying, or one that exhausted its
                        // retries — so the pane must not claim a port it does
                        // not hold.
                        Label("Not currently listening", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("settings-control-server-down-warning")
                        Button("Retry") { controlServer.retryListening() }
                            .controlSize(.small)
                            .accessibilityIdentifier("settings-control-server-retry")
                    } else {
                        Label("Stopped", systemImage: "circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if controlServerEnabled, !controlServer.isRunning, !controlServer.lastListenerFailure.isEmpty {
                    controlServerFailureDetail
                }
                if controlServerEnabled, parsedControlServerPort == nil {
                    Label(
                        "Enter a port between \(KiteloopControlServer.validPortRange.lowerBound) and \(KiteloopControlServer.validPortRange.upperBound). Keeping the last saved port until then.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("settings-control-server-port-warning")
                }
                Text("Exposes a token-guarded HTTP API on 127.0.0.1 so external tools — e.g. a Claude Code session — can start backlog items, monitor them, and read results. Off by default. Starts and stops immediately.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if controlServerEnabled {
                    LabeledContent("Bearer token") {
                        HStack(spacing: 8) {
                            Text(controlTokenPath)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Button("Copy Token") { copyControlToken() }
                                .accessibilityIdentifier("settings-control-token-copy-button")
                            Button("Regenerate...") { confirmingTokenRotation = true }
                                .accessibilityIdentifier("settings-control-token-regenerate-button")
                                .confirmationDialog(
                                    "Regenerate the control API token?",
                                    isPresented: $confirmingTokenRotation
                                ) {
                                    Button("Regenerate", role: .destructive) { regenerateControlToken() }
                                    Button("Cancel", role: .cancel) {}
                                } message: {
                                    Text("Every client holding the current token stops working immediately — including a queue driver in the middle of a run. The new token takes effect at once, with no restart; re-read it from \(controlTokenPath).")
                                }
                        }
                    }
                    switch tokenRotation {
                    case .rotated:
                        Label("New token written. Existing clients must re-read the file.", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("settings-control-token-rotated-note")
                    case .failed:
                        Label("Could not write the token file — the previous token still works.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("settings-control-token-rotation-error")
                    case nil:
                        EmptyView()
                    }
                    tokenCopyNote
                    pairPhoneButton
                }
            }
            PairedPhonesSection(controlServer: controlServer)
            PushKeySection(globalConfigStore: globalConfigStore)
            QuickRepliesSection(globalConfigStore: globalConfigStore)

        }
        .formStyle(.grouped)
        .onAppear { loadGlobalDefaults() }
        .onChange(of: controlServerEnabled) { _, _ in saveControlServer() }
        .onChange(of: controlServerPort) { _, _ in saveControlServer() }
    }

    /// The port as typed, if it is one we can actually bind. `nil` while the field
    /// holds a half-typed or out-of-range value.
    private var parsedControlServerPort: Int? {
        guard let parsed = Int(controlServerPort.trimmingCharacters(in: .whitespaces)),
              KiteloopControlServer.isValidPort(parsed) else { return nil }
        return parsed
    }

    private func saveControlServer() {
        guard loaded else { return }
        // Persist only a bindable port. Writing a half-typed or out-of-range value
        // would leave the config disagreeing with the running server and hand the
        // next launch a port it cannot bind, so the last good value stands until
        // the field holds another one.
        if let port = parsedControlServerPort {
            globalConfigStore.setControlServer(enabled: controlServerEnabled, port: port)
        } else {
            globalConfigStore.setControlServer(
                enabled: controlServerEnabled,
                port: Int(KiteloopControlServer.resolvedPort(globalConfigStore.config.controlServerPort))
            )
        }
        guard controlServerEnabled else {
            controlServer.stop()
            return
        }
        if let port = parsedControlServerPort {
            controlServer.start(port: UInt16(port))
        }
    }

    /// Confirmed rotation: the server swaps its live token and rewrites the file,
    /// so this is the whole action — nothing to restart afterwards.
    private func regenerateControlToken() {
        tokenRotation = controlServer.regenerateToken() == nil ? .failed : .rotated
    }

    /// Reads the file at click time, so after a Regenerate it copies the new token.
    private func copyControlToken() {
        let read = KiteloopControlServer.readExactToken(at: KiteloopControlServer.defaultTokenURL)
        guard case .copy(let token) = Self.controlTokenCopy(read: read) else {
            tokenCopy = .unreadable
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
        tokenCopy = .copied
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if tokenCopy == .copied { tokenCopy = nil }
        }
    }

    @ViewBuilder
    private var tokenCopyNote: some View {
        switch tokenCopy {
        case .copied:
            Label("Copied", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings-control-token-copied-note")
        case .unreadable:
            Label("Could not read the token from \(controlTokenPath).", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("settings-control-token-copy-error")
        case nil:
            EmptyView()
        }
    }

    private func loadGlobalDefaults() {
        guard !loaded else { return }
        loaded = true
        defaultModel = ModelCatalog.normalize(globalConfigStore.config.defaultModel ?? ModelCatalog.defaultModelID)
        defaultEffort = globalConfigStore.config.defaultEffort ?? ""
        controlServerEnabled = globalConfigStore.config.controlServerEnabled ?? false
        controlServerPort = String(KiteloopControlServer.resolvedPort(globalConfigStore.config.controlServerPort))
        authMethod = globalConfigStore.claudeAuthConfig.method
        apiKeySaved = !(TokenStore.get(ClaudeAuthConfig.anthropicTokenKey) ?? "").isEmpty
        let bedrock = globalConfigStore.config.bedrock ?? .default
        bedrockRegion = bedrock.region
        bedrockProfile = bedrock.profile
    }

    private func saveBedrockConfig() {
        guard loaded else { return }
        var bedrock = globalConfigStore.config.bedrock ?? .default
        bedrock.region = bedrockRegion
        bedrock.profile = bedrockProfile
        globalConfigStore.setBedrockConfig(bedrock)
    }

    private func chooseKnowledgeRepo() {
        PermissionAuditLogger.shared.log(.filePanel, purpose: "choose knowledge repo")
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the kiteloop-knowledge repository"
        guard panel.runModal() == .OK, let path = panel.url?.path(percentEncoded: false) else { return }
        globalConfigStore.setKnowledgeRepoPath(path)
        Task { await packageResolver?.rescanPaths(configuredRepoPath: path) }
    }

    private func chooseVaultPath() {
        PermissionAuditLogger.shared.log(.filePanel, purpose: "choose vault path")
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the vault directory"
        if panel.runModal() == .OK, let url = panel.url {
            globalConfigStore.setVaultPath(url.path(percentEncoded: false))
        }
    }

    private func isOllamaAvailable() -> Bool { (ollamaModels.value ?? nil) != nil }

    private func ollamaStatus() -> String {
        guard let probed = ollamaModels.value else { return "Checking..." }
        guard let models = probed else { return "Not running (optional — for local models)" }
        return models.isEmpty ? "Running (no models pulled)" : "\(models.count) model\(models.count == 1 ? "" : "s") available"
    }

    // MARK: - Global MCP Servers

    @State private var mcpRows: [GlobalMCPServerRow] = []
    @State private var mcpLoaded = false
    @State private var newServerName = ""
    @State private var mcpSaveError: String?
}

extension AppPreferencesView {
    private var globalMCPTab: some View {
        Form {
            Section("Global MCP Servers") {
                if mcpRows.isEmpty {
                    Text("No global MCP servers configured.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach($mcpRows) { $row in
                        globalMCPRow($row)
                    }
                }
            }

            Section("Add Server") {
                TextField("Server name", text: $newServerName)
                    .accessibilityIdentifier("settings-mcp-new-server-field")
                Button("Add") { addMCPServer() }
                    .disabled(newServerName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("settings-mcp-add-button")
            }

            globalMCPSaveSection
        }
        .formStyle(.grouped)
        .onAppear {
            guard !mcpLoaded else { return }
            mcpLoaded = true
            mcpRows = Self.globalMCPRows(from: globalConfigStore.config.mcpServers ?? [:])
        }
    }

    private var globalMCPSaveSection: some View {
        HStack {
            if let mcpSaveError {
                FooterErrorLabel(mcpSaveError)
            }
            Spacer()
            Button("Save") { saveMCPServers() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("settings-mcp-save-button")
        }
    }

    /// A command server is edited in place; a server with no command (a
    /// remote one that only carries `extras`) is shown as it is and written
    /// back unchanged.
    private func globalMCPRow(_ row: Binding<GlobalMCPServerRow>) -> some View {
        HStack(alignment: .top) {
            if row.wrappedValue.isRemote {
                VStack(alignment: .leading) {
                    Text(row.wrappedValue.fields.name).font(.headline)
                    Text(row.wrappedValue.original?.displaySummary ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Server name", text: row.fields.name)
                    TextField("Command", text: row.fields.command)
                        .help("e.g. npx, node, python")
                    TextField("Arguments (quote one that contains a space)", text: row.fields.args)
                        .help("e.g. -y @modelcontextprotocol/server-github --root \"/Users/me/My Project\"")
                    TextField("Environment (KEY=VALUE per line)", text: row.fields.env, axis: .vertical)
                        .lineLimit(2...4)
                        .font(.system(.body, design: .monospaced))
                }
            }
            Spacer()
            Button(role: .destructive) {
                mcpRows.removeAll { $0.id == row.wrappedValue.id }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings-mcp-delete-\(row.wrappedValue.fields.name)")
        }
    }

    /// Appends an unsaved row; nothing reaches the config until Save.
    private func addMCPServer() {
        let name = newServerName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        mcpRows.append(GlobalMCPServerRow(fields: MCPServerRow(name: name, command: "", args: "", env: "")))
        newServerName = ""
    }

    private func saveMCPServers() {
        switch Self.globalMCPServersToWrite(from: mcpRows) {
        case .refused(let message):
            mcpSaveError = message
        case .servers(let entries):
            globalConfigStore.setMCPServers(entries.isEmpty ? nil : entries)
            mcpSaveError = nil
        }
    }

    /// The saved servers as rows, sorted by name: arguments quoted the way
    /// the project pane shows them, the environment as `KEY=VALUE` lines.
    static func globalMCPRows(from servers: [String: ClaudeMCPServerEntry]) -> [GlobalMCPServerRow] {
        servers.keys.sorted().compactMap { name in
            guard let entry = servers[name] else { return nil }
            let env = (entry.env ?? [:]).keys.sorted()
                .map { "\($0)=\(entry.env?[$0] ?? "")" }
                .joined(separator: "\n")
            let fields = MCPServerRow(
                name: name,
                command: entry.command ?? "",
                args: ShellArguments.line(from: entry.args ?? []),
                env: env
            )
            return GlobalMCPServerRow(fields: fields, original: entry)
        }
    }

    /// The servers the rows say to write, or why the list is not writable.
    /// The refusals are the project pane's, from `MCPServerConfigView
    /// .serversToWrite(from:)`; a remote row is checked with its summary in
    /// place of the command it does not have, so it is never refused as
    /// commandless. Each row keeps the `extras` it was loaded with.
    static func globalMCPServersToWrite(from rows: [GlobalMCPServerRow]) -> GlobalMCPServerSave {
        let checked = rows.map { row -> MCPServerRow in
            guard row.isRemote else { return row.fields }
            var fields = row.fields
            fields.command = row.original?.displaySummary ?? row.fields.name
            return fields
        }
        if case .refused(let message) = MCPServerConfigView.serversToWrite(from: checked) {
            return .refused(message)
        }
        var entries: [String: ClaudeMCPServerEntry] = [:]
        for row in rows {
            if row.isRemote, let original = row.original {
                entries[row.fields.name] = original
                continue
            }
            let env = MCPServerConfigView.environment(from: row.fields.env)
            entries[row.fields.name] = ClaudeMCPServerEntry(
                command: row.fields.command,
                args: ShellArguments.tokenize(row.fields.args),
                env: env.isEmpty ? nil : env,
                extras: row.original?.extras ?? [:]
            )
        }
        return .servers(entries)
    }
}

/// One row of the app-wide MCP Servers tab: the fields it edits, and the
/// entry it was loaded from — nil for a row added since the last save.
/// App Preferences' two update switches. Both are off and disabled in a copy
/// that does not update itself; downloading in the background follows
/// checking, so it is disabled while checking is off.
struct UpdatePreferenceRows: View {
    @Bindable var updater: SoftwareUpdater

    var body: some View {
        Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
            .help("Looks for a newer version about once a day while Kiteloop runs. Check for Updates… in the Kiteloop menu still checks whenever you choose it.")
            .disabled(!updater.isAvailable)
        Toggle("Automatically download updates", isOn: $updater.automaticallyDownloadsUpdates)
            .help("Downloads a newer version when one is found and installs it the next time Kiteloop quits, instead of asking first.")
            .disabled(!updater.isAvailable || !updater.automaticallyChecksForUpdates)
    }
}

struct GlobalMCPServerRow: Identifiable {
    var fields: MCPServerRow
    var original: ClaudeMCPServerEntry?

    var id: UUID { fields.id }

    /// A saved server with no command — a remote one that only carries
    /// `extras` — which the tab shows but does not edit.
    var isRemote: Bool { original != nil && original?.command == nil }
}

/// What the global MCP tab's Save does with the rows: the servers to write,
/// or the message shown instead of a write.
enum GlobalMCPServerSave {
    case servers([String: ClaudeMCPServerEntry])
    case refused(String)
}

/// The pairing QR: `kiteloop://connect?base=…&token=…&name=…`, everything the phone
/// needs in one scan. Prefers the tailnet address (CGNAT 100.64/10) because
/// that is the network the phone reaches the Mac on; falls back to the LAN.
private struct PairPhoneSheet: View {
    let port: UInt16
    let serverRunning: Bool
    /// The one-time code the QR carries, which the phone trades for a token
    /// of its own.
    let code: String?
    /// The control token, carried instead only when this Mac keeps no paired phones.
    let token: String?
    /// The phone that claimed `code`, once one has.
    let pairedName: String?
    @Environment(\.dismiss) private var dismiss
    @State private var chosenAddress: String?
    @State private var reachability: PairingReachability = .checking
    private let reachabilityProbe = PairingReachabilityProbe()

    private var candidates: [String] { PairPhoneSheet.candidateAddresses() }
    private var address: String? { chosenAddress ?? candidates.first }

    private var payload: String? {
        guard let address, let credential = Self.credential(code: code, token: token) else { return nil }
        var components = URLComponents()
        components.scheme = "kiteloop"
        components.host = "connect"
        // The name is what the phone lists this Mac as once it has paired more than one.
        components.queryItems = [URLQueryItem(name: "base", value: "http://\(address):\(port)"),
                                 credential,
                                 URLQueryItem(name: "name", value: Host.current().localizedName ?? ProcessInfo.processInfo.hostName)]
        return components.string
    }

    /// The code when there is one, else the control token; nil with neither.
    private static func credential(code: String?, token: String?) -> URLQueryItem? {
        if let code, !code.isEmpty { return URLQueryItem(name: "code", value: code) }
        guard let token, !token.isEmpty else { return nil }
        return URLQueryItem(name: "token", value: token)
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Pair a phone").font(.headline)
            if let pairedName {
                Label("Paired \(pairedName)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("This code is used up. Revoke the phone under Paired phones if it was not yours.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if let payload, let image = Self.qrImage(for: payload) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
                Text("Kiteloop on the iPhone → Connect → Scan pairing code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(code == nil
                     ? "http://\(address ?? "?"):\(String(port)) — carries the control token; show it only to your own phone."
                     : "http://\(address ?? "?"):\(String(port)) — pairs one phone, once; closing this withdraws it.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                if let address {
                    PairingReachabilityBanner(reachability: reachability, address: address, port: port, serverRunning: serverRunning)
                }
            } else {
                Text(address == nil
                     ? "No network address found — is the Mac on the tailnet?"
                     : "No control token yet — enable the control server first.")
                    .foregroundStyle(.orange)
            }
            if candidates.count > 1 {
                Picker("Network", selection: Binding(get: { address ?? "" },
                                                     set: { chosenAddress = $0 })) {
                    ForEach(candidates, id: \.self) { candidate in
                        Text("\(PairingAddresses.label(for: candidate)) — \(candidate)")
                            .tag(candidate)
                    }
                }
                .pickerStyle(.radioGroup)
                .font(.caption)
            }
            Button("Done") { dismiss() }
        }
        .padding(24)
        .frame(width: 320)
        .task(id: address) { await probeReachability() }
    }

    /// Re-runs whenever `.task(id: address)` sees a new address — first
    /// appearance and every Picker change alike — so the verdict on screen
    /// always matches the address the QR is currently offering.
    private func probeReachability() async {
        guard let address else {
            reachability = .unreachable
            return
        }
        reachability = .checking
        reachability = await reachabilityProbe.probe(address: address, port: port)
    }

    /// Tailnet first (encrypted transport, reachable anywhere), then the LAN
    /// addresses — same Wi-Fi works too, with the token as the only guard.
    static func candidateAddresses() -> [String] {
        PairingAddresses.reachable(from: ipv4Addresses())
    }

    private static func ipv4Addresses() -> [String] {
        var addresses: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var cursor = list
        while let interface = cursor?.pointee {
            defer { cursor = interface.ifa_next }
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  (Int32(interface.ifa_flags) & IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            addresses.append(String(cString: host))
        }
        return addresses
    }

    private static func qrImage(for payload: String) -> NSImage? {
        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter?.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter?.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// The verdict beneath the QR: silent-ish while checking, a quiet
/// confirmation once something answers, and — the reason this exists — a
/// warning when nothing does, naming whichever of the two causes
/// `serverRunning` distinguishes: the toggle is off, or it's on and nothing
/// answers at the offered address. `PairingRemedy` holds the strings.
private struct PairingReachabilityBanner: View {
    let reachability: PairingReachability
    let address: String
    let port: UInt16
    let serverRunning: Bool

    private var remedy: PairingRemedy {
        PairingRemedy.banner(for: reachability, address: address, port: port, serverRunning: serverRunning)
    }

    var body: some View {
        switch reachability {
        case .checking:
            Label(remedy.headline, systemImage: "ellipsis.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .reachable:
            Label(remedy.headline, systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .unreachable:
            VStack(spacing: 2) {
                Label(remedy.headline, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                if let text = remedy.remedy {
                    Text(text)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .multilineTextAlignment(.center)
        }
    }
}
