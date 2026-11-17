import KiteloopCore
import SwiftUI

/// What the agent's saved configuration puts in its context before anyone
/// speaks — read-only, in the agent editor. Sizes are the measured bytes; a
/// part Kiteloop cannot size says so instead of showing a number.
struct AgentFirstTurnView: View {
    let agentID: String
    let orchestrator: Orchestrator
    /// The app's configured MCP servers, by name.
    let appServers: [String]

    @State private var cost: FirstTurnCost?

    var body: some View {
        DisclosureGroup {
            if let cost {
                ForEach(cost.sections, id: \.name) { section in
                    LabeledContent(section.name, value: Self.bytes(section.bytes))
                }
                ForEach(cost.reported, id: \.name) { server in
                    LabeledContent(server.name, value: Self.summary(of: server))
                }
                ForEach(cost.unmeasured, id: \.name) { part in
                    LabeledContent(part.name, value: "not measured")
                        .help(part.reason)
                }
            }
        } label: {
            LabeledContent("Before the first turn", value: cost.map { Self.bytes($0.total) + " measured" } ?? "…")
                .help("What this agent's saved configuration puts in its context before anyone speaks. Bytes of text, not tokens.")
        }
        .font(.caption)
        .accessibilityIdentifier("agent-editor-first-turn")
        .task { await measure() }
    }

    private func measure() async {
        guard let agent = orchestrator.agents.first(where: { $0.id == agentID }) else { return }
        cost = await AgentFirstTurn.cost(of: agent, orchestrator: orchestrator, globalServers: appServers,
                                         status: orchestrator.connectorStatus(named:))
    }

    static func bytes(_ count: Int) -> String {
        "\(count.formatted()) bytes"
    }

    /// A server a session has started: how it was seen and how many tools it
    /// offered — the CLI reports no size for them.
    static func summary(of server: FirstTurnCost.Reported) -> String {
        "\(server.state), \(server.tools.count) tools, size not reported"
    }
}
