import Foundation

struct AgentTemplate: Codable, Identifiable, Sendable {
    let id: String
    var name: String
    var model: String
    var systemPrompt: String
    var tools: [String]
    var denied: [String]
    var permissionMode: String
    var subscriptions: [String]
    var mcpServers: [String]
    var skills: [String]
    var description: String
    var avatar: String?
    var group: String?
    var runtimeKind: String?
    var crossAgentAccess: [String]
    var operatorToolsEnabled: Bool

    static let defaultAvatarEmoji: [String] = [
        "🧙‍♂️", "🧙‍♀️", "👺", "👹", "🤖", "🦉", "🐉", "🧛", "🧟", "🦹",
        "🦸", "🧝‍♂️", "🧝‍♀️", "🔮", "⚔️", "🛡️", "🏰", "👾", "🐺", "🦅",
        "🐍", "🕷️", "💀", "👁️", "🌑", "⚡", "🔥", "🌊", "🎨", "🧩",
        "🐛", "🦇", "🐙", "🦂", "🗡️", "🏹"
    ]

    static func customAvatars(projectURL: URL) -> [String] {
        let dir = projectURL.appendingPathComponent(".kiteloop/avatars")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return files.filter { name in
            let ext = (name as NSString).pathExtension.lowercased()
            return ["png", "jpg", "jpeg", "gif", "webp"].contains(ext)
        }.sorted()
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        model: String = "sonnet",
        systemPrompt: String = "",
        tools: [String] = [],
        denied: [String] = [],
        permissionMode: String = Agent.defaultPermissionMode,
        subscriptions: [String] = [],
        mcpServers: [String] = [],
        skills: [String] = [],
        description: String = "",
        avatar: String? = nil,
        group: String? = nil,
        runtimeKind: String? = nil,
        crossAgentAccess: [String] = [],
        operatorToolsEnabled: Bool = false
    ) {
        self.id = id
        self.name = name
        self.model = model
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.denied = denied
        self.permissionMode = permissionMode
        self.subscriptions = subscriptions
        self.mcpServers = mcpServers
        self.skills = skills
        self.description = description
        self.avatar = avatar
        self.group = group
        self.runtimeKind = runtimeKind
        self.crossAgentAccess = crossAgentAccess
        self.operatorToolsEnabled = operatorToolsEnabled
    }

    /// Forgiving decoder: team.json is hand-editable, so every field except
    /// `name` is optional and falls back to a sensible default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decode(String.self, forKey: .name)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? "sonnet"
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        tools = try container.decodeIfPresent([String].self, forKey: .tools) ?? []
        denied = try container.decodeIfPresent([String].self, forKey: .denied) ?? []
        permissionMode = try container.decodeIfPresent(String.self, forKey: .permissionMode) ?? Agent.defaultPermissionMode
        subscriptions = try container.decodeIfPresent([String].self, forKey: .subscriptions) ?? []
        mcpServers = try container.decodeIfPresent([String].self, forKey: .mcpServers) ?? []
        skills = try container.decodeIfPresent([String].self, forKey: .skills) ?? []
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        avatar = try container.decodeIfPresent(String.self, forKey: .avatar)
        group = try container.decodeIfPresent(String.self, forKey: .group)
        runtimeKind = try container.decodeIfPresent(String.self, forKey: .runtimeKind)
        crossAgentAccess = try container.decodeIfPresent([String].self, forKey: .crossAgentAccess) ?? []
        operatorToolsEnabled = try container.decodeIfPresent(Bool.self, forKey: .operatorToolsEnabled) ?? false
    }

    /// Snapshot of a live agent, for persisting the team back to team.json.
    init(from agent: Agent) {
        self.init(
            id: agent.id,
            name: agent.name,
            model: agent.model,
            systemPrompt: agent.systemPrompt,
            tools: agent.tools,
            denied: agent.denied,
            permissionMode: agent.permissionMode,
            subscriptions: agent.subscriptions,
            mcpServers: agent.mcpServers,
            skills: agent.skills,
            avatar: agent.avatar,
            group: agent.group,
            runtimeKind: agent.runtimeKind,
            crossAgentAccess: agent.crossAgentAccess,
            operatorToolsEnabled: agent.operatorToolsEnabled
        )
    }

    func instantiateAgent() -> Agent {
        instantiate(id: UUID().uuidString)
    }

    func instantiateAgentWithFixedID() -> Agent {
        instantiate(id: id)
    }

    private func instantiate(id: String) -> Agent {
        Agent(
            id: id,
            name: name,
            model: model,
            systemPrompt: systemPrompt,
            tools: tools,
            denied: denied,
            permissionMode: permissionMode,
            subscriptions: subscriptions,
            mcpServers: mcpServers,
            skills: skills,
            avatar: avatar,
            group: group,
            crossAgentAccess: crossAgentAccess,
            runtimeKind: runtimeKind,
            operatorToolsEnabled: operatorToolsEnabled,
            state: .idle
        )
    }
}
