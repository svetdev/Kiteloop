import Foundation

package struct PackageTeamConfig: Codable, Sendable {
    package let agents: [PackageAgentRef]

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(agents: [PackageAgentRef]) {
        self.agents = agents
    }
}

package struct PackageAgentRef: Codable, Identifiable, Sendable {
    package let id: String
    package let ref: String
    package let version: String?
    package let overrides: AgentOverrides?

    package var refPrefix: String {
        guard let colonIndex = ref.firstIndex(of: ":") else { return "" }
        return String(ref[ref.startIndex..<colonIndex])
    }

    package var refName: String {
        guard let colonIndex = ref.firstIndex(of: ":") else { return ref }
        return String(ref[ref.index(after: colonIndex)...])
    }

    package var isShared: Bool { refPrefix == "shared" }
    package var isLocal: Bool { refPrefix == "local" }
    package var isUser: Bool { refPrefix == "user" }

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(id: String, ref: String, version: String?, overrides: AgentOverrides?) {
        self.id = id
        self.ref = ref
        self.version = version
        self.overrides = overrides
    }
}

package struct AgentOverrides: Codable, Sendable {
    package let model: String?
    package let tools: [String]?
    package let denied: [String]?
    package let permissionMode: String?
    package let effort: String?
    package let mcpServers: [String]?
    package let skills: [String]?
    package let thinkingEnabled: Bool?

    package init(
        model: String? = nil,
        tools: [String]? = nil,
        denied: [String]? = nil,
        permissionMode: String? = nil,
        effort: String? = nil,
        mcpServers: [String]? = nil,
        skills: [String]? = nil,
        thinkingEnabled: Bool? = nil
    ) {
        self.model = model
        self.tools = tools
        self.denied = denied
        self.permissionMode = permissionMode
        self.effort = effort
        self.mcpServers = mcpServers
        self.skills = skills
        self.thinkingEnabled = thinkingEnabled
    }
}

package struct TeamLock: Codable, Sendable {
    package let agents: [String: LockedAgent]

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(agents: [String: LockedAgent]) {
        self.agents = agents
    }
}

package struct LockedAgent: Codable, Sendable {
    package let ref: String
    package let version: String
    package let commit: String?
    package let digest: String?

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(ref: String, version: String, commit: String?, digest: String?) {
        self.ref = ref
        self.version = version
        self.commit = commit
        self.digest = digest
    }
}
