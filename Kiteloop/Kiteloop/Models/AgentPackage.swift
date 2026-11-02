import Foundation

struct AgentPackage: Codable, Sendable {
    let handle: String
    let version: String
    let repos: [String]?
    let template: PackageTemplate
    let knowledge: KnowledgeConfig

    var handleNormalized: String {
        handle.hasPrefix("@") ? String(handle.dropFirst()) : handle
    }
}

struct PackageTemplate: Codable, Sendable {
    let name: String
    let model: String
    let systemPrompt: String
    let avatar: String?
    let group: String?
    let description: String?
    let tools: [String]?
    let mcpServers: [String]?
    let skills: [String]?
    let denied: [String]?
    let permissionMode: String?
    let effort: String?
    let thinkingEnabled: Bool?
    let runtimeKind: String?
}

struct KnowledgeConfig: Codable, Sendable {
    let critical: [String]
    let files: [String]
    let imports: [String]

    init(critical: [String] = [], files: [String] = [], imports: [String] = []) {
        self.critical = critical
        self.files = files
        self.imports = imports
    }
}

extension AgentPackage {
    func toAgentTemplate(id: String? = nil) -> AgentTemplate {
        AgentTemplate(
            id: id ?? handleNormalized,
            name: template.name,
            model: template.model,
            systemPrompt: "",
            tools: template.tools ?? ["Read", "Edit", "Write", "Bash", "Glob", "Grep", "message_agent", "broadcast_agents", "publish_event", "propose_memory", "ask_human", "recall_knowledge", "save_knowledge"],
            denied: template.denied ?? [],
            permissionMode: template.permissionMode ?? Agent.defaultPermissionMode,
            subscriptions: [],
            mcpServers: template.mcpServers ?? [],
            skills: template.skills ?? [],
            description: template.description ?? "",
            avatar: template.avatar,
            group: template.group,
            runtimeKind: template.runtimeKind
        )
    }
}
