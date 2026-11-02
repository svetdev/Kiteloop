import SwiftUI

/// Visual marker for an agent that autopilot is driving **unattended** — its tool
/// calls are decided by Claude Code's auto mode with no human to ask (see
/// `Orchestrator.unattendedAgentIDs`). Rendered as a chip in the chat header and as
/// a badge on the agent's sidebar avatar, so it's obvious at a glance that nobody is
/// gating what that agent does.
struct UnattendedIndicator: View {
    /// The decision of what to show is `UnattendedIndicatorModel`, a model; this
    /// view only draws it. The names here keep the view's callers reading as before.
    typealias Model = UnattendedIndicatorModel

    let model: Model

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: model.symbol)
                .font(.system(size: 9))
            Text(model.label)
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(1)
        }
        .foregroundStyle(model.isActive ? Color.orange : Color.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(model.isActive ? Color.orange.opacity(0.12) : Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .help(model.help)
        .accessibilityIdentifier("unattended-indicator")
    }

    /// Derives the indicator for an agent, or `nil` when it isn't running unattended.
    nonisolated static func model(agentName: String, isUnattended: Bool, state: Agent.AgentState) -> Model? {
        UnattendedIndicatorModel.of(agentName: agentName, isUnattended: isUnattended, state: state)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        if let active = UnattendedIndicator.model(agentName: "Builder", isUnattended: true, state: .working) {
            UnattendedIndicator(model: active)
        }
        if let idle = UnattendedIndicator.model(agentName: "Reviewer", isUnattended: true, state: .idle) {
            UnattendedIndicator(model: idle)
        }
    }
    .padding()
}
