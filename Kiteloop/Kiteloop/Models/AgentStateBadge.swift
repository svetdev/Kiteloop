import Foundation

/// What the sidebar avatar shows for an agent whose `ask_human` question is
/// still unanswered (`.waitingForHuman`). `nil` from `waiting(agentName:
/// isUnattended:state:)` means no badge: any other state has nothing to show
/// here, and an unattended agent already wears the unattended indicator in the
/// same corner — its question still reaches you through the notice and the
/// menu bar's waiting-on-you list. The view that draws it is `AgentAvatarView`;
/// the decision is here so it can be tested without a view.
struct AgentStateBadge: Equatable {
    let symbol: String
    let help: String

    /// Derives the waiting badge for an agent, or `nil` when it doesn't apply.
    nonisolated static func waiting(agentName: String, isUnattended: Bool, state: Agent.AgentState) -> AgentStateBadge? {
        guard !isUnattended, state == .waitingForHuman else { return nil }
        return AgentStateBadge(
            symbol: "hand.raised.fill",
            help: "\(agentName) is waiting on you — answer its question in the chat to continue."
        )
    }
}
