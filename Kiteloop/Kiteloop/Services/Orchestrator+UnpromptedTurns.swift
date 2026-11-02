import Foundation
import KiteloopCore

/// A turn an agent's session started on its own — see
/// `AgentRuntime.unpromptedTurns(of:)` — as handed to the chat, tagged with
/// the session it came from so a turn from a session since replaced can be
/// told apart from one the chat should show.
struct UnpromptedTurn {
    let events: AsyncStream<StreamEvent>
    /// The token `Orchestrator.installSession` gave the session this turn
    /// came from.
    let sessionToken: UUID
}

/// Who takes each agent's unprompted turns, and which session is the one
/// they may come from. Held by `Orchestrator` as a single property; see
/// `PendingAgentLaunchTracker` for why it is a type of its own.
@MainActor
final class UnpromptedTurnRouter {
    fileprivate var handlers: [String: (UnpromptedTurn) -> Void] = [:]
    /// A fresh token per session installed, per agent: a turn carrying any
    /// other is from a session this agent no longer has.
    fileprivate var sessionTokens: [String: UUID] = [:]
}

extension Orchestrator {
    /// Makes `session` the agent's live session and starts listening for the
    /// turns it starts on its own. Every session the orchestrator starts goes
    /// through here.
    func installSession(_ session: AgentSession, runtime: any AgentRuntime,
                        options: SessionOptions, for agentID: String) {
        sessions[agentID] = ManagedSession(session: session, runtime: runtime, options: options)
        let token = UUID()
        unpromptedTurns.sessionTokens[agentID] = token
        let turns = runtime.unpromptedTurns(of: session)
        Task { [weak self] in
            for await events in turns {
                self?.deliverUnpromptedTurn(UnpromptedTurn(events: events, sessionToken: token), for: agentID)
            }
        }
    }

    /// Where `agentID`'s unprompted turns go — its chat, which shows them as
    /// turns of their own. The last handler set wins; an agent with none has
    /// its unprompted turns run unheard (see `UnpromptedTurnTracker`).
    func setUnpromptedTurnHandler(for agentID: String, _ handler: @escaping (UnpromptedTurn) -> Void) {
        unpromptedTurns.handlers[agentID] = handler
    }

    /// Whether `turn` came from the session `agentID` has now. False once the
    /// agent is stopped, cleared, restarted or switched to another chat: what
    /// that session says afterwards belongs to no chat that is open.
    func isCurrentSession(_ turn: UnpromptedTurn, for agentID: String) -> Bool {
        sessions[agentID] != nil && unpromptedTurns.sessionTokens[agentID] == turn.sessionToken
    }

    /// The agent is working on a turn nobody prompted: the same state, and the
    /// same app-wide streaming flag, `send` sets for one that was.
    func beginUnpromptedTurn(agentID: String) {
        let state = pendingQuestions.settle(.working, for: agentID)
        updateAgent(id: agentID) { $0.state = state }
        isStreaming = true
    }

    /// A turn from a session the agent no longer has, or for an agent with no
    /// chat to show it, is let go: the runtime then runs it unheard.
    private func deliverUnpromptedTurn(_ turn: UnpromptedTurn, for agentID: String) {
        guard isCurrentSession(turn, for: agentID), let handler = unpromptedTurns.handlers[agentID] else { return }
        handler(turn)
    }
}
