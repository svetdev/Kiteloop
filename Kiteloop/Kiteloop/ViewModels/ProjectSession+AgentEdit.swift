import Foundation

extension ProjectSession {
    /// Applies an edit to an agent on this project's team and writes the team
    /// file, as saving the agent's editor does: a rename is carried into the
    /// teammates' Cross-Agent Access, and an idle live session is restarted so
    /// its next turn runs with the new values.
    func editAgent(_ agentID: String, _ edit: AgentEdit) -> AgentEditEffect {
        guard let before = orchestrator.agents.first(where: { $0.id == agentID }) else { return .now }
        if let name = edit.name { orchestrator.renameInCrossAgentAccess(of: agentID, to: name) }
        orchestrator.updateAgent(id: agentID) { edit.apply(to: &$0) }
        persistTeamConfig()
        guard edit.changesSpawnValues(of: before) else { return .now }
        guard orchestrator.hasSession(for: agentID), before.state != .working else { return .nextStart }
        restartAgent(agentID)
        return .restarted
    }
}
