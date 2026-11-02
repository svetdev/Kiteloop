import KiteloopCore
import SwiftUI

struct AgentEditorSheet: View {
    let agentID: String
    let orchestrator: Orchestrator
    let project: KiteloopProject
    /// The app's defaults, for the notes under the pickers that say what the
    /// project's own value is and where it came from. Optional so a caller
    /// without the store still gets the editor, with the notes resolving no
    /// further up than the project.
    var appConfig: GlobalConfig? = nil
    var onSave: () -> Void
    /// Stops the agent's live session and starts it again with the saved
    /// values; the caller reports a start that fails.
    var onRestart: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var model: String = ModelCatalog.defaultModelID
    /// What Ollama has pulled, fetched once when the sheet opens; nil when it
    /// could not be reached.
    @State private var pulledModels: [String]?
    @State private var permissionMode: String = Agent.defaultPermissionMode
    @State private var operatorToolsEnabled: Bool = false
    @State private var avatar: String?
    @State private var toolsText: String = ""
    @State private var deniedText: String = ""
    @State private var crossAgentAccessText: String = ""
    @State private var systemPrompt: String = ""
    /// The project's config as loaded once with the agent, so the notes below
    /// do not read the file on every render.
    @State private var projectConfig: ProjectConfig?
    /// Set when the save landed on an agent that was mid-turn, so the sheet
    /// stays open and says when the change takes.
    @State private var appliesAtNextStart: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit Agent")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("agent-editor-cancel-button")
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(nameRefusal != nil)
                    .accessibilityIdentifier("agent-editor-save-button")
            }
            .padding()

            if appliesAtNextStart {
                Text("Saved. \(name) is mid-turn, so this takes effect at its next start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("agent-editor-next-start-note")
            }

            Divider()

            Form {
                Section("Identity") {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("agent-editor-name-field")
                    if let nameRefusal {
                        Text(nameRefusal)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("agent-editor-name-refusal")
                    }
                    Picker("Model", selection: $model) {
                        ForEach(ModelCatalog.pickerOptions(including: model, pulled: pulledModels)) { option in
                            Text(option.pickerLabel).tag(option.id)
                        }
                    }
                    .accessibilityIdentifier("agent-editor-model-picker")
                    Text(projectModelNote)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityIdentifier("agent-editor-model-note")
                    Picker("Permission Mode", selection: $permissionMode) {
                        Text("Auto (Claude Code decides)").tag("auto")
                        Text("Accept Edits").tag("acceptEdits")
                        Text("Plan (read-only)").tag("plan")
                        Text("Default").tag("default")
                        Text("Bypass All").tag("bypassPermissions")
                    }
                    .accessibilityIdentifier("agent-editor-permission-mode-picker")
                    Text(projectPermissionNote)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityIdentifier("agent-editor-permission-mode-note")
                    AvatarPickerField(selection: $avatar, projectURL: project.rootURL)
                }

                Section("Operator Tools") {
                    Toggle("Operator Tools", isOn: $operatorToolsEnabled)
                        .help("Grants this agent the operator-scoped control-API token at spawn (KITELOOP_OPERATOR_TOKEN, KITELOOP_CONTROL_URL) plus a knowledge note on using it. Authorized for the whole control API except the two approve endpoints, which stay a human's call. Off by default.")
                        .accessibilityIdentifier("agent-editor-operator-tools-toggle")
                }

                Section("Tools") {
                    TextField("Tools (comma-separated)", text: $toolsText)
                        .accessibilityIdentifier("agent-editor-tools-field")
                    TextField("Denied", text: $deniedText)
                        .accessibilityIdentifier("agent-editor-denied-field")
                }

                Section("Cross-Agent Access") {
                    TextField("Allowed agents (comma-separated, or * or all for every agent)", text: $crossAgentAccessText)
                        .help("Agents this agent can message (message_agent) and whose knowledge it can recall (recall_knowledge). * or all grants every agent. Empty = message anyone, recall only its own and shared knowledge.")
                        .accessibilityIdentifier("agent-editor-cross-agent-access-field")
                }

                Section("System Prompt") {
                    TextEditor(text: $systemPrompt)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100)
                        .accessibilityIdentifier("agent-editor-system-prompt-editor")
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 520, height: 480)
        .onAppear { loadAgent() }
        .task { pulledModels = await OllamaRuntime.availableModels() }
    }

    /// An agent carries a concrete model, set when it was hired, so there is
    /// no Default entry to label; the note says what the project's own default
    /// is, so an agent set to it reads as the norm and one set away from it
    /// reads as the override it is.
    private var projectModelNote: String {
        let resolved = SettingInheritance.resolve(
            builtIn: ModelCatalog.defaultModelID,
            app: SettingInheritance.present(appConfig?.defaultModel),
            project: SettingInheritance.present(projectConfig?.model))
        return SettingInheritance.inheritedNote(
            resolved, prefix: "Project default", describe: ModelCatalog.displayName(for:))
    }

    private var projectPermissionNote: String {
        Self.projectPermissionNote(Agent.initialPermissionMode(projectConfig: projectConfig))
    }

    /// What the editor says under this agent's own mode about the project's:
    /// the mode new agents there start in — which this agent does not follow
    /// once created — and that any of it governs chat only.
    static func projectPermissionNote(_ projectMode: String) -> String {
        "New agents in this project start in \(SettingNames.permissionMode(projectMode)). "
            + "Chat only — an unattended run always uses auto mode."
    }

    private func loadAgent() {
        projectConfig = project.loadConfig()
        guard let agent = orchestrator.agents.first(where: { $0.id == agentID }) else { return }
        name = agent.name
        model = ModelCatalog.normalize(agent.model)
        permissionMode = agent.permissionMode
        operatorToolsEnabled = agent.operatorToolsEnabled
        avatar = agent.avatar
        toolsText = agent.tools.joined(separator: ", ")
        deniedText = agent.denied.joined(separator: ", ")
        crossAgentAccessText = agent.crossAgentAccess.joined(separator: ", ")
        systemPrompt = agent.systemPrompt
    }

    private var nameRefusal: String? {
        Self.nameRefusal(name, agentID: agentID, agents: orchestrator.agents)
    }

    private func save() {
        guard nameRefusal == nil else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        orchestrator.renameInCrossAgentAccess(of: agentID, to: trimmedName)
        orchestrator.updateAgent(id: agentID) { agent in
            agent.name = trimmedName
            agent.model = model
            agent.permissionMode = permissionMode
            agent.operatorToolsEnabled = operatorToolsEnabled
            agent.avatar = avatar
            agent.tools = toolsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            agent.denied = deniedText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            agent.crossAgentAccess = crossAgentAccessText.isEmpty ? [] : crossAgentAccessText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            agent.systemPrompt = systemPrompt
        }
        onSave()
        switch Self.saveEffect(
            hasSession: orchestrator.hasSession(for: agentID),
            state: orchestrator.agents.first(where: { $0.id == agentID })?.state
        ) {
        case .dismiss:
            dismiss()
        case .restartSession:
            onRestart()
            dismiss()
        case .applyAtNextStart:
            appliesAtNextStart = true
        }
    }

    /// What a save does to the agent's live session. Everything the sheet
    /// writes but the name is read when the CLI process is spawned, so a
    /// running session keeps the values it started with until it is restarted.
    enum SaveEffect: Equatable {
        /// Nothing is running: the written values are picked up at the next
        /// start anyway, so just close.
        case dismiss
        /// A session that is not mid-turn: stop and start it, so the next turn
        /// spawns with the edited model, tools and prompt.
        case restartSession
        /// A turn is in flight: stop nothing underneath it and say in the sheet
        /// when the change takes.
        case applyAtNextStart
    }

    /// Why the typed name cannot be saved, or nil when it can. Agents are
    /// found by name with a case-insensitive first match, so a blank name
    /// leaves an empty row and a teammate's name makes one of the two
    /// unreachable. The edited agent's own name is always allowed.
    static func nameRefusal(_ name: String, agentID: String, agents: [Agent]) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "A name is required." }
        let taken = agents.contains {
            $0.id != agentID
                && $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(trimmed) == .orderedSame
        }
        return taken ? "Another agent is already named \u{201C}\(trimmed)\u{201D}." : nil
    }

    static func saveEffect(hasSession: Bool, state: Agent.AgentState?) -> SaveEffect {
        guard hasSession else { return .dismiss }
        return state == .working ? .applyAtNextStart : .restartSession
    }
}
