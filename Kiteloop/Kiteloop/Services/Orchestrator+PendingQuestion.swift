import Foundation

/// Which agents hold an unanswered `ask_human` question, and the state each
/// would show without it.
///
/// While a question is open the agent reads `.waitingForHuman` — the badge,
/// the menu bar and `GET /v1/agents` all say it is waiting on you — except
/// while a turn is actually running, which still reads `.working`. When the
/// question goes (answered, cleared, the session stopped or switched) the
/// agent shows the state its session is really in: working if the turn goes
/// on, idle once it has ended.
///
/// Held by `Orchestrator` as one small property, like
/// `PendingAgentLaunchTracker` and for the same reason: that class's own file
/// sits at the complexity ratchet's baseline. Every state change `Orchestrator`
/// makes passes through `settle(_:for:)` or, when a session stops or starts
/// afresh, `sessionEnded(_:)`; the rule itself is pure, so it is checked
/// without a session.
final class PendingQuestionTracker {
    /// The state each asking agent's session is in, beneath the question.
    private var beneath: [String: Agent.AgentState] = [:]

    /// The agent has asked: it shows `.waitingForHuman`, and `current` is
    /// remembered as what it goes back to.
    func ask(_ agentID: String, current: Agent.AgentState) -> Agent.AgentState {
        if beneath[agentID] == nil {
            beneath[agentID] = current == .waitingForHuman ? .idle : current
        }
        return .waitingForHuman
    }

    /// The question is gone: the agent shows what its session is in.
    func answer(_ agentID: String, current: Agent.AgentState) -> Agent.AgentState {
        guard let under = beneath.removeValue(forKey: agentID) else { return current }
        return current == .waitingForHuman ? under : current
    }

    /// The agent's session stopped or was replaced: the call the question was
    /// asked from died with it, so nothing is waiting on an answer any more.
    func sessionEnded(_ agentID: String) -> Agent.AgentState {
        beneath.removeValue(forKey: agentID)
        return .idle
    }

    /// The state to show when the session moves to `state`. Without a
    /// question that is `state` itself; with one, a running turn still shows
    /// as working and anything else as waiting on the answer.
    func settle(_ state: Agent.AgentState, for agentID: String) -> Agent.AgentState {
        guard beneath[agentID] != nil else { return state }
        beneath[agentID] = state
        return state == .working ? .working : .waitingForHuman
    }
}

extension Orchestrator {
    /// Called by `ChatViewModel` as its `ask_human` question opens and closes;
    /// the agent's state follows (`PendingQuestionTracker`).
    func setAwaitingAnswer(_ awaiting: Bool, for agentID: String) {
        let questions = pendingQuestions
        updateAgent(id: agentID) { agent in
            agent.state = awaiting
                ? questions.ask(agentID, current: agent.state)
                : questions.answer(agentID, current: agent.state)
        }
    }
}
