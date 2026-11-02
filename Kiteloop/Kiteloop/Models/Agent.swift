import Foundation
import KiteloopCore

struct Agent: Identifiable, Codable, Equatable {
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
    var avatar: String?
    var group: String?
    var effort: String?
    var maxBudgetUSD: Double?
    var thinkingEnabled: Bool
    var thinkingBudget: Int?
    var crossAgentAccess: [String]
    var canAcceptDelegation: Bool
    var runtimeKind: String?
    var workspacePath: String?
    var mcpConfigPath: String?
    /// Grants this agent the operator-scoped control-API token at spawn — its
    /// environment carries `KITELOOP_OPERATOR_TOKEN` and `KITELOOP_CONTROL_URL`,
    /// plus a bundled knowledge note on how to use them. Off by default: this is
    /// the same consent pattern as autonomous work, since the token authorizes
    /// everything the control API does except resolving the human gate.
    var operatorToolsEnabled: Bool
    /// Set when this agent is an ephemeral **aside** — a second agent forked
    /// from another's live session so the human can question it without
    /// spending the source's context. Holds the source agent's id.
    ///
    /// Non-nil is what makes an agent ephemeral: it is kept out of `team.json`,
    /// out of the autopilot pickers, and it dies with the app.
    var asideOfAgentID: String?
    /// The turn budget this agent's next session is spawned with — an autopilot
    /// worker's, derived from its project's runs, set for the length of a run.
    /// Nil leaves the runtime's own. Never persisted: not in `CodingKeys`.
    var maxTurns: Int?
    var state: AgentState

    /// True for an ephemeral aside — see `asideOfAgentID`.
    var isAside: Bool { asideOfAgentID != nil }

    enum AgentState: String, Codable {
        case idle
        case working
        case waitingForHuman
        case crashed
    }

    var resolvedRuntimeKind: RuntimeKind {
        if let explicit = RuntimeKind(rawValue: runtimeKind ?? "") { return explicit }
        let ollamaModels = ["llama3.1", "llama3.2", "qwen2.5-coder", "llama3.1:70b",
                            "mistral", "codellama", "deepseek-coder", "phi3"]
        if ollamaModels.contains(where: { model.hasPrefix($0) }) { return .ollama }
        if model == "copilot" || model.hasPrefix("copilot-") { return .copilot }
        return .claude
    }

    init(id: String, name: String, model: String, systemPrompt: String, tools: [String], denied: [String], permissionMode: String, subscriptions: [String] = [], mcpServers: [String] = [], skills: [String] = [], avatar: String? = nil, group: String? = nil, effort: String? = nil, maxBudgetUSD: Double? = nil, thinkingEnabled: Bool = false, thinkingBudget: Int? = nil, crossAgentAccess: [String] = [], canAcceptDelegation: Bool = false, runtimeKind: String? = nil, workspacePath: String? = nil, mcpConfigPath: String? = nil, operatorToolsEnabled: Bool = false, asideOfAgentID: String? = nil, state: AgentState) {
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
        self.avatar = avatar
        self.group = group
        self.effort = effort
        self.maxBudgetUSD = maxBudgetUSD
        self.thinkingEnabled = thinkingEnabled
        self.thinkingBudget = thinkingBudget
        self.crossAgentAccess = crossAgentAccess
        self.canAcceptDelegation = canAcceptDelegation
        self.runtimeKind = runtimeKind
        self.workspacePath = workspacePath
        self.mcpConfigPath = mcpConfigPath
        self.operatorToolsEnabled = operatorToolsEnabled
        self.asideOfAgentID = asideOfAgentID
        self.state = state
    }

    init(name: String, model: String, systemPrompt: String, tools: [String], denied: [String], permissionMode: String, subscriptions: [String] = [], mcpServers: [String] = [], skills: [String] = [], avatar: String? = nil, group: String? = nil, effort: String? = nil, maxBudgetUSD: Double? = nil, thinkingEnabled: Bool = false, thinkingBudget: Int? = nil, crossAgentAccess: [String] = [], canAcceptDelegation: Bool = false, runtimeKind: String? = nil, mcpConfigPath: String? = nil, operatorToolsEnabled: Bool = false) {
        self.id = UUID().uuidString
        self.name = name
        self.model = model
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.denied = denied
        self.permissionMode = permissionMode
        self.subscriptions = subscriptions
        self.mcpServers = mcpServers
        self.skills = skills
        self.avatar = avatar
        self.group = group
        self.effort = effort
        self.maxBudgetUSD = maxBudgetUSD
        self.thinkingEnabled = thinkingEnabled
        self.thinkingBudget = thinkingBudget
        self.crossAgentAccess = crossAgentAccess
        self.canAcceptDelegation = canAcceptDelegation
        self.runtimeKind = runtimeKind
        self.mcpConfigPath = mcpConfigPath
        self.operatorToolsEnabled = operatorToolsEnabled
        self.state = .idle
    }

    /// The mode an agent runs in when nothing names one: Claude Code's auto
    /// mode, whose classifier decides each tool call. Nothing in Kiteloop can
    /// answer a permission prompt, so a mode that would ask is never the default.
    static let defaultPermissionMode = "auto"

    /// The mode a new agent in a project starts in: the one Project Settings
    /// names, else `defaultPermissionMode`. Only a new agent reads it — an
    /// existing agent keeps the mode it was given.
    static func initialPermissionMode(projectConfig: ProjectConfig?) -> String {
        guard let mode = projectConfig?.permissionMode, !mode.isEmpty else { return defaultPermissionMode }
        return mode
    }

    /// `initialPermissionMode(projectConfig:)` for the project rooted at `url`,
    /// read off its `.kiteloop/config.json`; nil is no project, so the default.
    static func initialPermissionMode(forProjectAt url: URL?) -> String {
        initialPermissionMode(projectConfig: url.map { KiteloopProject(rootURL: $0).loadConfig() })
    }

    static let defaultCoder = Agent(
        id: "coder",
        name: "Coder",
        model: "sonnet",
        systemPrompt: "You are a senior developer. Write clean, testable code.",
        tools: ["Read", "Edit", "Write", "Bash", "Glob", "Grep"],
        denied: [],
        permissionMode: "acceptEdits",
        skills: [],
        state: .idle
    )

    enum CodingKeys: String, CodingKey {
        case id, name, model, systemPrompt, tools, denied
        case permissionMode, subscriptions, mcpServers, skills, avatar, group
        case effort, maxBudgetUSD, thinkingEnabled, thinkingBudget
        case crossAgentAccess, canAcceptDelegation, runtimeKind, workspacePath, mcpConfigPath
        case operatorToolsEnabled, asideOfAgentID, state
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decode(String.self, forKey: .name)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? "sonnet"
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        tools = try container.decodeIfPresent([String].self, forKey: .tools) ?? []
        denied = try container.decodeIfPresent([String].self, forKey: .denied) ?? []
        permissionMode = try container.decodeIfPresent(String.self, forKey: .permissionMode) ?? Self.defaultPermissionMode
        subscriptions = try container.decodeIfPresent([String].self, forKey: .subscriptions) ?? []
        mcpServers = try container.decodeIfPresent([String].self, forKey: .mcpServers) ?? []
        skills = try container.decodeIfPresent([String].self, forKey: .skills) ?? []
        avatar = try container.decodeIfPresent(String.self, forKey: .avatar)
        group = try container.decodeIfPresent(String.self, forKey: .group)
        effort = try container.decodeIfPresent(String.self, forKey: .effort)
        maxBudgetUSD = try container.decodeIfPresent(Double.self, forKey: .maxBudgetUSD)
        thinkingEnabled = try container.decodeIfPresent(Bool.self, forKey: .thinkingEnabled) ?? false
        thinkingBudget = try container.decodeIfPresent(Int.self, forKey: .thinkingBudget)
        crossAgentAccess = try container.decodeIfPresent([String].self, forKey: .crossAgentAccess) ?? []
        canAcceptDelegation = try container.decodeIfPresent(Bool.self, forKey: .canAcceptDelegation) ?? false
        runtimeKind = try container.decodeIfPresent(String.self, forKey: .runtimeKind)
        workspacePath = try container.decodeIfPresent(String.self, forKey: .workspacePath)
        mcpConfigPath = try container.decodeIfPresent(String.self, forKey: .mcpConfigPath)
        operatorToolsEnabled = try container.decodeIfPresent(Bool.self, forKey: .operatorToolsEnabled) ?? false
        asideOfAgentID = try container.decodeIfPresent(String.self, forKey: .asideOfAgentID)
        state = try container.decodeIfPresent(AgentState.self, forKey: .state) ?? .idle
    }
}
