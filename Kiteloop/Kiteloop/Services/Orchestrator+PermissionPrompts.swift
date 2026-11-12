import Foundation
import KiteloopCore

/// Who answers each agent's permission prompts — see
/// `AgentRuntime.permissionPrompts(of:)`. Held by `Orchestrator` as a single
/// property; see `PendingAgentLaunchTracker` for why it is a type of its own.
@MainActor
final class PermissionPromptRouter {
    fileprivate var handlers: [String: (PermissionPrompt.Line) -> Void] = [:]
    /// Per agent: the requests its live session is still waiting on. What is
    /// left when a session ends was asked by a process that is gone, and each
    /// is taken back on its behalf so no card stays open that nothing reads
    /// the answer to.
    fileprivate var waiting: [String: Set<String>] = [:]

    /// Keeps `waiting` current: a request is waited on until it is taken back.
    fileprivate func note(_ prompt: PermissionPrompt.Line, for agentID: String) {
        switch prompt {
        case .request(let request): waiting[agentID, default: []].insert(request.id)
        case .cancelled(let requestID): waiting[agentID]?.remove(requestID)
        }
    }

    /// What a session with nobody to answer is told, so it is refused rather
    /// than left waiting on an answer nothing will give.
    static let nobodyToAnswer = "Nobody is at this session to answer, so the call was not allowed."
}

extension Orchestrator {
    /// Starts listening for what `session` stops to ask. Called for every
    /// session as it is installed.
    func listenForPermissionPrompts(of session: AgentSession, runtime: any AgentRuntime, agentID: String) {
        let prompts = runtime.permissionPrompts(of: session)
        Task { [weak self] in
            for await prompt in prompts {
                self?.deliverPermissionPrompt(prompt, from: session, for: agentID)
            }
            self?.permissionPromptsEnded(for: agentID, asked: session)
        }
    }

    /// The session's prompts are over — it stopped, or its process died.
    /// When it is still the agent's session, or the agent has none, what it
    /// was waiting on is taken back; a session already replaced had its
    /// requests taken back as it was.
    private func permissionPromptsEnded(for agentID: String, asked session: AgentSession) {
        guard sessions[agentID] == nil || sessions[agentID]?.session.id == session.id else { return }
        takeBackPermissionPrompts(for: agentID)
    }

    /// Tells the agent's chat that every request its session was waiting on
    /// is void. Called as a session is stopped or replaced.
    func takeBackPermissionPrompts(for agentID: String) {
        let stranded = permissionPrompts.waiting.removeValue(forKey: agentID) ?? []
        guard let handler = permissionPrompts.handlers[agentID] else { return }
        for requestID in stranded.sorted() { handler(.cancelled(requestID: requestID)) }
    }

    /// Where `agentID`'s prompts go — its chat, which shows each as a card.
    /// The last handler set wins.
    func setPermissionPromptHandler(for agentID: String, _ handler: @escaping (PermissionPrompt.Line) -> Void) {
        permissionPrompts.handlers[agentID] = handler
    }

    /// A prompt from the session the agent has now goes to its chat. One from
    /// an agent with no chat is refused at once: the session waits on every
    /// prompt without limit, and nothing else would ever answer it.
    private func deliverPermissionPrompt(_ prompt: PermissionPrompt.Line, from session: AgentSession, for agentID: String) {
        guard sessions[agentID]?.session.id == session.id else { return }
        permissionPrompts.note(prompt, for: agentID)
        if let handler = permissionPrompts.handlers[agentID] {
            handler(prompt)
        } else if case .request(let request) = prompt {
            answerPermissionPrompt(request.id, .deny(message: PermissionPromptRouter.nobodyToAnswer), agentID: agentID)
        }
    }

    /// Answers the prompt `requestID` of the agent's live session.
    func answerPermissionPrompt(_ requestID: String, _ decision: PermissionPrompt.Decision, agentID: String) {
        permissionPrompts.waiting[agentID]?.remove(requestID)
        sendControl(PermissionPrompt.response(requestID: requestID, decision: decision), agentID: agentID)
    }

    /// Writes one control line to the agent's live session; nothing when it
    /// has none.
    func sendControl(_ line: String, agentID: String) {
        guard let managed = sessions[agentID] else { return }
        managed.runtime.sendControl(line, to: managed.session)
    }
}

extension Orchestrator {
    /// The options a session of this agent is spawned with: it asks before
    /// the agent's tools when a person attends it and its mode promises to.
    func options(unattended: Bool, for agentID: String) -> SessionOptions {
        let mode = agents.first { $0.id == agentID }?.permissionMode ?? ""
        return SessionOptions(unattended: unattended,
                              asksBeforeListedTools: !unattended && PermissionPrompt.asksBeforeListedTools(mode: mode))
    }

    /// Whether this agent's live session can be moved to `mode` as it runs:
    /// one a person attends, spawned on the same terms a fresh session in
    /// `mode` would be. A session spawned with the agent's tools approved
    /// cannot start asking for them, nor the reverse, so that move takes a
    /// new process. False with no session.
    func liveSessionTakes(mode: String, for agentID: String) -> Bool {
        guard let options = sessions[agentID]?.options, !options.unattended else { return false }
        return options.asksBeforeListedTools == PermissionPrompt.asksBeforeListedTools(mode: mode)
    }
}
