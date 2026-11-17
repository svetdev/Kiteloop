import Foundation
import KiteloopCore

/// What an agent's rows and replies say of its context: the size its
/// configuration puts there before the first turn, and the tokens a turn has
/// measured since.
@MainActor
struct AgentContextFields {
    let registry: ControlSessionRegistry

    /// `firstTurn`, and beside it `contextTokens` and `contextWindow` when a
    /// turn has measured them — bytes before, tokens after, neither derived
    /// from the other.
    func fields(of agent: Agent, in entry: ControlSessionRegistry.Entry) async -> [String: Any] {
        let cost = await AgentFirstTurn.cost(
            of: agent, orchestrator: entry.session.orchestrator,
            globalServers: entry.session.appMCPServers,
            status: newestStatus(of:))
        return Self.measured(of: agent.id, in: entry).merging(["firstTurn": cost.json]) { _, new in new }
    }

    /// The agent's context as its last turn left it; empty until its chat is
    /// open, and on a runtime whose window Kiteloop does not know.
    static func measured(of agentID: String, in entry: ControlSessionRegistry.Entry) -> [String: Any] {
        // `chatViewModels[…]`, not `chatViewModel(for:)`: reading never creates one.
        guard let occupancy = entry.session.chatViewModels[agentID]?.contextOccupancy else { return [:] }
        var fields: [String: Any] = ["contextTokens": occupancy.tokens]
        if let window = occupancy.windowSize { fields["contextWindow"] = window }
        return fields
    }

    /// The newest report of a server across every open project's sessions.
    func newestStatus(of name: String) -> ConnectorStatus? {
        registry.entries.values
            .compactMap { $0.session.orchestrator.connectorStatus(named: name) }
            .max { $0.reportedAt < $1.reportedAt }
    }
}
