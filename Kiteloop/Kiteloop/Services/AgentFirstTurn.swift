import Foundation
import KiteloopCore

/// Gathers what `FirstTurnCost` measures for one agent: the system prompt's
/// parts, the operator-tools note and the tool definitions a Claude session
/// is started with, and the MCP servers that session is handed.
///
/// The files are read off the main actor — the prompt's parts on the memory
/// manager's own executor, the agent's MCP config on a detached task.
@MainActor
enum AgentFirstTurn {

    /// `globalServers` are the app's configured MCP servers by name; `status`
    /// is what a session last reported of a server.
    static func cost(of agent: Agent, orchestrator: Orchestrator, globalServers: [String],
                     status: (String) -> ConnectorStatus?) async -> FirstTurnCost {
        let context = await orchestrator.memoryManager.systemContextSections(
            agent: agent, skillRegistry: orchestrator.skillRegistry)
        guard agent.resolvedRuntimeKind == .claude else {
            return FirstTurnCost(sections: context, startedByCLI: false)
        }
        let servers = await servers(for: agent, global: globalServers)
        return FirstTurnCost(sections: context + cliSections(for: agent), servers: servers, status: status)
    }

    /// What the Claude runtime adds at spawn that Kiteloop writes itself: the
    /// note that goes with the control API credential the agent holds, and
    /// the JSON its tool bridge answers `tools/list` with.
    static func cliSections(for agent: Agent) -> [(name: String, text: String)] {
        let note = agent.operatorToolsEnabled
            ? agent.controlAccess.note(operatorNote: OperatorToolsKnowledge.note,
                                       readOnlyNote: OperatorToolsKnowledge.readOnlyNote)
            : ""
        return [(name: "operatorTools", text: note),
                (name: "kiteloopTools", text: KiteloopToolSchemas.toolDefinitionsJSON(for: agent) ?? "")]
    }

    /// Every server a session of this agent starts with: the app's, then the
    /// ones in the agent's own MCP config that the app does not already name.
    /// The agent's `mcpServers` list is not applied — it decides which
    /// servers' tools are allowed, not which servers are started.
    private static func servers(for agent: Agent, global: [String]) async -> [String] {
        guard let path = agent.mcpConfigPath else { return global }
        let own = await Task.detached { ClaudeMCPConfig.load(from: path)?.mcpServers.keys.sorted() ?? [] }.value
        return global + own.filter { !global.contains($0) }
    }
}
