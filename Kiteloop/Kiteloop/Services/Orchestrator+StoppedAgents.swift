import Foundation
import KiteloopCore
import os.log

private let stopLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "stopped-agents")

/// What the orchestrator keeps about the agents the person stopped: the
/// record, where it is written, and how a stopped agent's chat is reopened.
struct PersonStops {
    var record = StoppedAgents()
    var file: URL?
    /// Makes sure the agent has a chat to be sent to. Stopping an agent from
    /// the sidebar closes its chat, and an event or a workflow node reaches an
    /// agent through its chat, so one aimed at a stopped agent needs it back.
    var openChat: ((String) -> Void)?
}

extension Orchestrator {
    /// Reads the project's record of stopped agents and keeps it written at
    /// `file` from here on. Returns what went wrong when the file is there and
    /// cannot be read — the team then opens with nobody stopped.
    @discardableResult
    func loadStoppedAgents(from file: URL) -> String? {
        personStops.file = file
        do {
            personStops.record = try StoppedAgents.load(from: file)
            return nil
        } catch {
            return "Couldn't read which agents were stopped (\(file.path(percentEncoded: false))): "
                + "\(error.localizedDescription). Every agent starts as usual."
        }
    }

    /// Whether the person stopped this agent and nothing has started it since.
    func isStoppedByPerson(_ agentID: String) -> Bool {
        personStops.record.contains(agentID)
    }

    /// The person's Stop — the sidebar's Stop Agent or `POST /v1/agents/stop`.
    /// Everything else that ends a session (a restart, a run moving the agent,
    /// a watchdog) goes through `stopAgent` and leaves no record.
    func stopAgentForPerson(_ agentID: String) {
        stopAgent(agentID)
        if personStops.record.personStopped(agentID) { saveStoppedAgents() }
    }

    /// Called for every session installed: the agent is running again, so the
    /// Stop is over.
    func forgetPersonStop(of agentID: String) {
        if personStops.record.started(agentID) { saveStoppedAgents() }
    }

    /// Why another agent's message to `agentID` is not delivered — the person
    /// stopped it — or nil when it can be sent.
    func teammateRefusal(sendingTo agentID: String) -> String? {
        let name = agents.first { $0.id == agentID }?.name ?? agentID
        return personStops.record.refusal(of: .teammate, sendingTo: agentID, named: name,
                                          hasSession: hasSession(for: agentID))
    }

    /// Reopens the chat of an agent the person stopped, so a message from
    /// something they set up — a workflow node, an event the agent subscribes
    /// to — has somewhere to go and starts it. False when the agent was not
    /// stopped by the person, or there is no way to open its chat.
    func reopenChatOfStoppedAgent(_ agentID: String) -> Bool {
        guard isStoppedByPerson(agentID), let openChat = personStops.openChat else { return false }
        openChat(agentID)
        return true
    }

    /// Starts a session for each of `agentIDs` that has none — what a run the
    /// person started or armed does instead of refusing. Returns why one of
    /// them still has no session, or nil when all do.
    func startSessionsIfMissing(for agentIDs: [String], cwd: URL?) async -> String? {
        for agentID in agentIDs where !hasSession(for: agentID) {
            let name = agents.first { $0.id == agentID }?.name ?? agentID
            guard let cwd else { return "\(name) has no session and there is no project directory to start it in" }
            do {
                try await startAgent(agentID, cwd: cwd)
            } catch {
                return "\(name) has no session and could not be started: \(error.localizedDescription)"
            }
            guard hasSession(for: agentID) else {
                return "\(name) has no session and is not an agent on this team"
            }
        }
        return nil
    }

    private func saveStoppedAgents() {
        guard let file = personStops.file else { return }
        do {
            try personStops.record.save(to: file)
        } catch {
            stopLog.error("could not write \(file.path(percentEncoded: false), privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
