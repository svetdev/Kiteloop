import KiteloopCore
import SwiftUI

struct NewAgentSheet: View {
    /// What Create hands over: the picked template's fields with the sheet's
    /// edits applied. A nil field takes `ProjectSession.addAgent`'s default.
    struct Creation: Equatable {
        var name: String
        var model: String
        var permissionMode: String
        var avatar: String?
        var systemPrompt: String?
        var tools: [String]?
        var denied: [String]?
        var runtimeKind: String?
        var mcpServers: [String]?
        var skills: [String]?
    }

    /// The agent to create from `template` (nil for Custom Agent) as edited in
    /// the sheet. The name, model, permission mode and avatar are the sheet's;
    /// the rest is the template's, with the prompt taken from the package
    /// because `toAgentTemplate` leaves it empty. An empty prompt stays nil.
    static func creation(
        from template: AgentTemplate?,
        packagePrompt: String?,
        name: String,
        model: String,
        permissionMode: String,
        avatar: String?
    ) -> Creation {
        var creation = Creation(name: name, model: model, permissionMode: permissionMode, avatar: avatar)
        guard let template else { return creation }
        creation.systemPrompt = (packagePrompt ?? "").isEmpty ? nil : packagePrompt
        creation.tools = template.tools
        creation.denied = template.denied
        creation.runtimeKind = template.runtimeKind
        creation.mcpServers = template.mcpServers
        creation.skills = template.skills
        return creation
    }

    /// The mode the picker starts at for `template` (nil for Custom Agent):
    /// the project's configured mode, unless the template names a mode of its
    /// own — the same rule a team template follows when the project opens
    /// (`ProjectSession.takesWelcomeMode`).
    static func startingPermissionMode(for template: AgentTemplate?, projectMode: String) -> String {
        guard let template, !ProjectSession.takesWelcomeMode(template) else { return projectMode }
        return template.permissionMode
    }

    /// The model the picker starts at for `template` (nil for Custom Agent):
    /// a package's own model, else the project's model if set, else the app's
    /// Default Model, else the built-in — the default Edit Agent's model note
    /// names. An empty string at either scope is unset.
    static func startingModel(for template: AgentTemplate?, appModel: String?, projectModel: String?) -> String {
        if let template { return ModelCatalog.normalize(template.model) }
        return SettingInheritance.resolve(
            builtIn: ModelCatalog.defaultModelID,
            app: SettingInheritance.present(appModel),
            project: SettingInheritance.present(projectModel)).value
    }

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTemplate: String = ""
    @State private var pickedTemplate: AgentTemplate?
    @State private var name = ""
    @State private var model = ModelCatalog.defaultModelID
    @State private var permissionMode = Agent.defaultPermissionMode
    /// The project's configured mode for new agents, read when the sheet opens.
    @State private var projectPermissionMode = Agent.defaultPermissionMode
    /// The project's configured model for new agents, read when the sheet opens.
    @State private var projectModel: String?
    @State private var avatar: String?
    @State private var filterText = ""
    /// What Ollama has pulled, fetched once when the sheet opens; nil when it
    /// could not be reached.
    @State private var pulledModels: [String]?
    let packageResolver: PackageResolver?
    let existingAgentIDs: Set<String>
    let agents: [Agent]
    /// The open project's root, so the avatar picker has somewhere to install
    /// an uploaded image into. Nil when the sheet is opened with no project.
    var projectURL: URL?
    /// Settings → Default Model, which a Custom Agent starts on when the
    /// project names no model of its own.
    var appDefaultModel: String?
    let onCreate: (Creation) -> Void

    private var availableTemplates: [AgentTemplate] {
        let packages = packageResolver?.availablePackages ?? []
        let all = packages.map { $0.package.toAgentTemplate() }
        let notAlreadyAdded = all.filter { !existingAgentIDs.contains($0.id) }
        if filterText.isEmpty { return notAlreadyAdded }
        let lower = filterText.lowercased()
        return notAlreadyAdded.filter {
            $0.name.lowercased().contains(lower)
            || $0.description.lowercased().contains(lower)
            || ($0.group?.lowercased().contains(lower) ?? false)
        }
    }

    /// Edit Agent…'s rule, with an id no agent carries: a new agent has none yet.
    private var nameRefusal: String? {
        AgentEditorSheet.nameRefusal(name, agentID: "", agents: agents)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("New Agent")
                .font(.headline)

            TextField("Search agents…", text: $filterText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .accessibilityIdentifier("catalog-search-field")

            if selectedTemplate.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        agentRow(label: "Custom Agent", description: "Start from scratch", id: "__custom__", avatar: nil, group: nil)
                        ForEach(availableTemplates) { template in
                            agentRow(
                                label: template.name,
                                description: template.description,
                                id: template.id,
                                avatar: template.avatar,
                                group: template.group
                            )
                        }
                    }
                    .padding(.horizontal)
                }
                .frame(maxHeight: 260)
            } else {
                Form {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("agent-name-field")
                    if let nameRefusal {
                        Text(nameRefusal)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("agent-name-refusal")
                    }
                    Picker("Model", selection: $model) {
                        ForEach(ModelCatalog.pickerOptions(including: model, pulled: pulledModels)) { option in
                            Text(option.pickerLabel).tag(option.id)
                        }
                    }
                    Picker("Permission Mode", selection: $permissionMode) {
                        Text("Auto (Claude Code decides)").tag("auto")
                        Text("Accept Edits").tag("acceptEdits")
                        Text("Plan").tag("plan")
                        Text("Ask").tag("default")
                        Text("Don't Ask").tag("dontAsk")
                        Text("Bypass All").tag("bypassPermissions")
                    }
                    AvatarPickerField(selection: $avatar, projectURL: projectURL)

                    Button("← Back to list") {
                        selectedTemplate = ""
                    }
                    .font(.caption)
                }
                .formStyle(.grouped)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("cancel-agent-button")
                Spacer()
                if !selectedTemplate.isEmpty {
                    Button("Create") {
                        let prompt = pickedTemplate.flatMap { template in
                            packageResolver?.availablePackages
                                .first { $0.package.handleNormalized == template.id }?
                                .package.template.systemPrompt
                        }
                        onCreate(Self.creation(
                            from: pickedTemplate, packagePrompt: prompt,
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines), model: model,
                            permissionMode: permissionMode, avatar: avatar
                        ))
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(nameRefusal != nil)
                    .accessibilityIdentifier("create-agent-button")
                }
            }
        }
        .padding()
        .frame(width: 420)
        .frame(minHeight: 380)
        .onAppear {
            projectPermissionMode = Agent.initialPermissionMode(forProjectAt: projectURL)
            permissionMode = projectPermissionMode
            projectModel = projectURL.flatMap { KiteloopProject(rootURL: $0).loadConfig().model }
            model = Self.startingModel(for: nil, appModel: appDefaultModel, projectModel: projectModel)
        }
        .task { pulledModels = await OllamaRuntime.availableModels() }
    }

    private func agentRow(label: String, description: String, id: String, avatar: String?, group: String?) -> some View {
        Button {
            if id == "__custom__" {
                selectedTemplate = "__custom__"
                pickedTemplate = nil
                name = ""
                model = Self.startingModel(for: nil, appModel: appDefaultModel, projectModel: projectModel)
                permissionMode = Self.startingPermissionMode(for: nil, projectMode: projectPermissionMode)
                self.avatar = nil
            } else if let template = availableTemplates.first(where: { $0.id == id }) {
                selectedTemplate = template.id
                pickedTemplate = template
                name = template.name
                model = ModelCatalog.normalize(template.model)
                permissionMode = Self.startingPermissionMode(for: template, projectMode: projectPermissionMode)
                self.avatar = template.avatar
            }
        } label: {
            HStack(spacing: 10) {
                Text(avatar ?? "🤖")
                    .font(.title3)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(label).font(.body.weight(.medium))
                        if let group {
                            Text(group)
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(.quaternary))
                        }
                    }
                    if !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
