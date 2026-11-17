import Foundation

/// The agents a person stopped — the sidebar's Stop Agent or
/// `POST /v1/agents/stop` — and who may start one again.
///
/// An agent with no session is one of three things: never started, ended by
/// the app's own machinery (a restart, a run moving it to a worktree, a
/// watchdog), or stopped by the person. Only the last is a decision, so only
/// it is recorded, and the record is dropped the moment the agent is started
/// again by anything allowed to.
///
/// The record is kept on disk, by agent id (a team's ids are fixed across
/// launches), so a relaunch does not undo the Stop: an agent that was stopped
/// when the app quit opens stopped.
package struct StoppedAgents: Equatable, Sendable {
    package private(set) var ids: Set<String>

    package init(ids: Set<String> = []) {
        self.ids = ids
    }

    package func contains(_ agentID: String) -> Bool {
        ids.contains(agentID)
    }

    /// Records the person's Stop. False when it was recorded already.
    @discardableResult
    package mutating func personStopped(_ agentID: String) -> Bool {
        ids.insert(agentID).inserted
    }

    /// Forgets the Stop: the agent has a session again. False when there was
    /// nothing to forget.
    @discardableResult
    package mutating func started(_ agentID: String) -> Bool {
        ids.remove(agentID) != nil
    }

    // MARK: - Who may start a stopped agent

    /// Why a message from `origin` does not start `agentName`, which the
    /// person stopped — the line the sender is answered with and the person
    /// is shown — or nil when it does start it.
    ///
    /// What the person did or set up starts the agent: their own message, a
    /// routine whatever fired it, a workflow or an event subscription. Another
    /// agent does not get to override the person's Stop.
    package static func refusal(of origin: ChatMessageOrigin, toStart agentName: String) -> String? {
        guard origin == .teammate else { return nil }
        return "\(agentName) was stopped by the person and is not running, so the message was not delivered. "
            + "Only the person, or a routine, workflow or autopilot run they set up, starts it again."
    }

    /// The same decision for an agent in a known state: nil when the agent has
    /// a session, or was not stopped by the person, or `origin` may start it.
    package func refusal(of origin: ChatMessageOrigin, sendingTo agentID: String, named agentName: String,
                         hasSession: Bool) -> String? {
        guard !hasSession, contains(agentID) else { return nil }
        return Self.refusal(of: origin, toStart: agentName)
    }

    // MARK: - On disk

    /// The record at `url`. A file that is missing reads as nobody stopped;
    /// one that cannot be read throws, so the caller can say so rather than
    /// start an agent the person stopped.
    package static func load(from url: URL) throws -> StoppedAgents {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return StoppedAgents() }
        let ids = try JSONDecoder().decode([String].self, from: Data(contentsOf: url))
        return StoppedAgents(ids: Set(ids))
    }

    /// Writes the record to `url`, sorted so the file is stable; an empty
    /// record removes the file.
    package func save(to url: URL) throws {
        let fileManager = FileManager.default
        guard !ids.isEmpty else {
            if fileManager.fileExists(atPath: url.path(percentEncoded: false)) { try fileManager.removeItem(at: url) }
            return
        }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(ids.sorted()).write(to: url, options: .atomic)
    }
}
