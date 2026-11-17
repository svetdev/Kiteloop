import Foundation
import KiteloopCore

struct Agent: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var model: String
    var systemPrompt: String
    var tools: [String]
    var denied: [String]
    /// Calls this agent always stops to ask a person about, in every
    /// permission mode — rules in the CLI's own spelling, `Bash(gh pr comment:*)`
    /// or an MCP tool's name. This is how an agent drafts a message and a
    /// person sends it: the call opens a card, and nothing remembers a yes.
    /// A session nobody attends has the call refused instead.
    var askFirst: [String] = []
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
    /// The share of the context window, 50–95, at which this agent compacts
    /// itself after a turn (`ContextFillPolicy`). Nil — the default — is off.
    var contextCompactPercent: Int?
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
        case id, name, model, systemPrompt, tools, denied, askFirst
        case permissionMode, subscriptions, mcpServers, skills, avatar, group
        case effort, maxBudgetUSD, thinkingEnabled, thinkingBudget
        case crossAgentAccess, canAcceptDelegation, runtimeKind, workspacePath, mcpConfigPath
        case operatorToolsEnabled, contextCompactPercent, asideOfAgentID, state
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decode(String.self, forKey: .name)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? "sonnet"
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        tools = try container.decodeIfPresent([String].self, forKey: .tools) ?? []
        denied = try container.decodeIfPresent([String].self, forKey: .denied) ?? []
        askFirst = try container.decodeIfPresent([String].self, forKey: .askFirst) ?? []
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
        contextCompactPercent = try container.decodeIfPresent(Int.self, forKey: .contextCompactPercent)
        asideOfAgentID = try container.decodeIfPresent(String.self, forKey: .asideOfAgentID)
        state = try container.decodeIfPresent(AgentState.self, forKey: .state) ?? .idle
    }
}

extension Agent {
    /// The permission modes an agent can be in, as they are stored.
    static let permissionModes = ["auto", "acceptEdits", "plan", "default", "dontAsk", "bypassPermissions"]

    /// Why a name cannot be given to an agent, or nil when it can. Agents are
    /// found by name with a case-insensitive first match, so a blank name
    /// leaves an empty row and a teammate's name makes one of the two
    /// unreachable. The agent's own current name is always allowed.
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
}

/// A change to an agent already on a project's team: the fields named are
/// replaced, the ones left nil stay as they are.
struct AgentEdit: Equatable {
    var name: String?
    var model: String?
    var systemPrompt: String?
    var avatar: String?
    var tools: [String]?
    var denied: [String]?
    var askFirst: [String]?
    var mcpServers: [String]?
    var crossAgentAccess: [String]?
    var skills: [String]?
    var effort: String?
    var thinking: Bool?
    var thinkingBudget: Int?
    /// `.some(nil)` lifts the ceiling.
    var maxBudgetUSD: Double??

    static let textFields = ["name", "model", "systemPrompt", "avatar", "effort"]
    static let listFields = ["tools", "denied", "askFirst", "mcpServers", "crossAgentAccess", "skills"]
    static let tuningFields = ["thinking", "thinkingBudget", "maxBudgetUSD"]
    static let effortLevels = ["low", "medium", "high", "xhigh", "max"]

    /// Why a body could not be read as an edit.
    struct Refusal: Error, Equatable {
        let reason: String
    }

    /// Reads the edit out of a request body. A field of the wrong type is
    /// refused by name rather than dropped, and so is a body that changes
    /// nothing: either would answer 200 for an edit that did not happen.
    static func parse(_ json: [String: Any]) -> Result<AgentEdit, Refusal> {
        if let wrong = textFields.first(where: { json[$0] != nil && !(json[$0] is String) }) {
            return .failure(Refusal(reason: "\"\(wrong)\" must be a string"))
        }
        if let wrong = listFields.first(where: { json[$0] != nil && !(json[$0] is [String]) }) {
            return .failure(Refusal(reason: "\"\(wrong)\" must be an array of strings"))
        }
        if let refusal = tuningRefusal(json) { return .failure(refusal) }
        var edit = AgentEdit(
            name: (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            model: json["model"] as? String,
            systemPrompt: json["systemPrompt"] as? String,
            avatar: json["avatar"] as? String,
            tools: json["tools"] as? [String],
            denied: json["denied"] as? [String],
            askFirst: json["askFirst"] as? [String],
            mcpServers: json["mcpServers"] as? [String],
            crossAgentAccess: json["crossAgentAccess"] as? [String],
            skills: json["skills"] as? [String],
            effort: json["effort"] as? String
        )
        edit.readTuning(json)
        guard edit != AgentEdit() else {
            let fields = (textFields + listFields + tuningFields).joined(separator: ", ")
            return .failure(Refusal(reason: "Body must include at least one of: \(fields)"))
        }
        return .success(edit)
    }

    /// Why the effort, thinking or budget a body names cannot be taken.
    private static func tuningRefusal(_ json: [String: Any]) -> Refusal? {
        if let effort = json["effort"] as? String, !effortLevels.contains(effort) {
            return Refusal(reason: "\"effort\" must be one of: \(effortLevels.joined(separator: ", "))")
        }
        if json["thinking"] != nil, !isBool(json["thinking"]) {
            return Refusal(reason: "\"thinking\" must be true or false")
        }
        if json["thinkingBudget"] != nil, (wholeNumber(json["thinkingBudget"]) ?? 0) <= 0 {
            return Refusal(reason: "\"thinkingBudget\" must be a whole number of tokens above zero")
        }
        if let budget = json["maxBudgetUSD"], !(budget is NSNull), (amount(budget) ?? 0) <= 0 {
            return Refusal(reason: "\"maxBudgetUSD\" must be a number above zero, or null for no ceiling")
        }
        return nil
    }

    /// JSON's true and false, and not the 1 and 0 they bridge to.
    private static func isBool(_ value: Any?) -> Bool {
        (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
    }

    private static func amount(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, !isBool(number) else { return nil }
        return number.doubleValue
    }

    private static func wholeNumber(_ value: Any?) -> Int? {
        guard let double = amount(value), double == double.rounded() else { return nil }
        return Int(double)
    }

    /// Takes the fields `tuningRefusal` has already passed.
    private mutating func readTuning(_ json: [String: Any]) {
        thinking = json["thinking"] as? Bool
        thinkingBudget = Self.wholeNumber(json["thinkingBudget"])
        if let budget = json["maxBudgetUSD"] {
            maxBudgetUSD = .some(Self.amount(budget))
        }
    }

    /// Whether the edit changes something the agent's CLI process reads when
    /// it is spawned — everything but its name and avatar — so a live session
    /// would keep the old value until it is started again.
    func changesSpawnValues(of agent: Agent) -> Bool {
        [
            model.map { $0 != agent.model },
            systemPrompt.map { $0 != agent.systemPrompt },
            tools.map { $0 != agent.tools },
            denied.map { $0 != agent.denied },
            askFirst.map { $0 != agent.askFirst },
            mcpServers.map { $0 != agent.mcpServers },
            crossAgentAccess.map { $0 != agent.crossAgentAccess },
            skills.map { $0 != agent.skills },
            effort.map { $0 != agent.effort },
            thinking.map { $0 != agent.thinkingEnabled },
            thinkingBudget.map { $0 != agent.thinkingBudget },
            maxBudgetUSD.map { $0 != agent.maxBudgetUSD }
        ].contains(true)
    }

    func apply(to agent: inout Agent) {
        if let name { agent.name = name }
        if let model { agent.model = model }
        if let systemPrompt { agent.systemPrompt = systemPrompt }
        if let avatar { agent.avatar = avatar.isEmpty ? nil : avatar }
        applyLists(to: &agent)
    }

    private func applyLists(to agent: inout Agent) {
        if let tools { agent.tools = tools }
        if let denied { agent.denied = denied }
        if let askFirst { agent.askFirst = askFirst }
        if let mcpServers { agent.mcpServers = mcpServers }
        if let crossAgentAccess { agent.crossAgentAccess = crossAgentAccess }
        if let skills { agent.skills = skills }
        applyTuning(to: &agent)
    }

    private func applyTuning(to agent: inout Agent) {
        if let effort { agent.effort = effort }
        if let thinking {
            agent.thinkingEnabled = thinking
            if !thinking { agent.thinkingBudget = nil }
        }
        if let thinkingBudget {
            agent.thinkingEnabled = true
            agent.thinkingBudget = thinkingBudget
        }
        if let maxBudgetUSD { agent.maxBudgetUSD = maxBudgetUSD }
    }
}

/// When an edit reaches the agent's session.
enum AgentEditEffect: String {
    /// Nothing the session reads at spawn changed: it is in effect already.
    case now
    /// An idle session was stopped and started on the same conversation.
    case restarted
    /// No session is running, or one is mid-turn and was left alone: the edit
    /// takes when the agent next starts.
    case nextStart
}
