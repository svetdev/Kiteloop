import Foundation

/// What the unattended chip and badge show for one agent that autopilot is
/// driving **unattended** — its tool calls decided by Claude Code's auto mode
/// with no human to ask (see `Orchestrator.unattendedAgentIDs`). `nil` from
/// `of(agentName:isUnattended:state:)` means the agent is human-attended and
/// gets no indicator at all. The view that draws it is `UnattendedIndicator`;
/// the decision is here so a view model can make it without a view.
struct UnattendedIndicatorModel: Equatable {
    let label: String
    let help: String
    /// The agent is mid-turn right now, as opposed to marked unattended for the
    /// run but standing by (autopilot marks worker *and* reviewer for the whole
    /// item, and only one of them acts at a time).
    let isActive: Bool

    var symbol: String { isActive ? "bolt.fill" : "bolt" }

    /// Derives the indicator for an agent, or `nil` when it isn't running unattended.
    nonisolated static func of(agentName: String, isUnattended: Bool, state: Agent.AgentState) -> UnattendedIndicatorModel? {
        guard isUnattended else { return nil }
        let isActive = state == .working
        return UnattendedIndicatorModel(
            label: isActive ? "Unattended" : "Unattended · standing by",
            help: isActive
                ? "\(agentName) is running unattended under autopilot — its tool calls are decided by Claude Code's auto mode. Stop the run from the Autopilot tab."
                : "\(agentName) is under autopilot control and waiting for its turn — its tool calls will be decided by Claude Code's auto mode.",
            isActive: isActive
        )
    }
}
