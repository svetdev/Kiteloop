import Foundation
import KiteloopCore

/// Why a management request was not carried out: what to say and the status
/// to say it with. Thrown, so a handler reads as the steps it takes.
struct ControlRefusal: Error, Equatable {
    let message: String
    let status: Int

    init(_ message: String, status: Int) {
        self.message = message
        self.status = status
    }

    static func missing(_ fields: String) -> ControlRefusal {
        ControlRefusal("Must include \(fields)", status: 400)
    }
}

/// The endpoints that set a team and its project up — `ManagementRoute`.
extension KiteloopControlServer {
    func manage(_ route: ManagementRoute, _ req: HTTPServer.Request) async -> HTTPServer.Response {
        do {
            return try await answer(route, req)
        } catch let refusal as ControlRefusal {
            return .error(refusal.message, status: refusal.status)
        } catch {
            return .error(error.localizedDescription, status: 500)
        }
    }

    private func answer(_ route: ManagementRoute, _ req: HTTPServer.Request) async throws -> HTTPServer.Response {
        switch route {
        case .startAgent, .stopAgent, .restartAgent,
             .listAgentChats, .newAgentChat, .openAgentChat, .deleteAgentChat:
            return try await agentSessionRoute(route, req)
        case .closeProject, .getProjectSettings, .setProjectSettings, .exportProjectSetup,
             .updateBacklogItem, .deleteBacklogItem:
            return try await ProjectSetupEndpoints(server: self).answer(route, req)
        case .getAgentMemory, .addMemoryFact, .rewriteMemoryFact, .archiveMemoryFact,
             .getSharedMemory, .setSharedMemory:
            return try await MemoryEndpoints(server: self).agentMemoryRoute(route, req)
        case .listClaudeMemory, .putClaudeMemoryNote, .deleteClaudeMemoryNote,
             .listKnowledge, .getKnowledgeFile, .putKnowledgeFile:
            return try await MemoryEndpoints(server: self).notesRoute(route, req)
        case .listMCPServers, .putMCPServer, .deleteMCPServer, .getSettings, .setSettings:
            return try AppSettingsEndpoints(server: self).answer(route, req)
        }
    }

    // MARK: - Finding what a request names

    /// The open project a request names, or the refusal.
    func openProject(_ name: Any?) throws -> ControlSessionRegistry.Entry {
        guard let project = name as? String, !project.isEmpty else { throw ControlRefusal.missing("\"project\"") }
        guard let entry = registry.entry(forProject: project) else {
            throw ControlRefusal("Project not open in Kiteloop: \(project)", status: 409)
        }
        return entry
    }

    /// The agent a request names, in the open project it names.
    func agent(_ fields: [String: Any]) throws -> (entry: ControlSessionRegistry.Entry, agent: Agent) {
        guard let name = fields["agent"] as? String, fields["project"] is String else {
            throw ControlRefusal.missing("\"project\" and \"agent\"")
        }
        let entry = try openProject(fields["project"])
        guard let agent = Self.agent(in: entry, idOrName: name) else {
            throw ControlRefusal("No agent '\(name)' in this project", status: 404)
        }
        return (entry, agent)
    }

    /// A field that must be there as text.
    func text(_ fields: [String: Any], _ key: String) throws -> String {
        guard let value = fields[key] as? String else { throw ControlRefusal.missing("\"\(key)\"") }
        return value
    }

    /// Refuses when an autopilot run in flight has the agent as its worker or
    /// reviewer: the run would lose it.
    func refuseIfARunUses(_ agent: Agent, in entry: ControlSessionRegistry.Entry) throws {
        let staffed = [entry.autopilot.workerAgentID, entry.autopilot.reviewerAgentID].contains(agent.id)
        guard !staffed || entry.autopilot.status == .idle else {
            throw ControlRefusal("An autopilot run is using \(agent.name) as its worker or reviewer", status: 409)
        }
    }

    func refuseMidTurn(_ agent: Agent) throws {
        guard agent.state != .working else {
            throw ControlRefusal("\(agent.name) is mid-turn; stop it first with POST /v1/agents/interrupt", status: 409)
        }
    }

    // MARK: - An agent's session

    private func agentSessionRoute(_ route: ManagementRoute, _ req: HTTPServer.Request) async throws -> HTTPServer.Response {
        switch route {
        case .startAgent: return try await startAgentSession(Self.jsonBody(req.body))
        case .stopAgent: return try stopAgentSession(Self.jsonBody(req.body))
        case .restartAgent: return try await restartAgentSession(Self.jsonBody(req.body))
        case .listAgentChats: return try listAgentChats(req.query)
        case .newAgentChat: return try await newAgentChat(Self.jsonBody(req.body))
        case .openAgentChat: return try await openAgentChat(Self.jsonBody(req.body))
        default: return try await deleteAgentChat(req.query)
        }
    }

    private func startAgentSession(_ fields: [String: Any]) async throws -> HTTPServer.Response {
        let (entry, agent) = try agent(fields)
        let orchestrator = entry.session.orchestrator
        guard !orchestrator.hasSession(for: agent.id) else {
            return .json(["agent": agent.id, "running": true, "started": false])
        }
        try await orchestrator.startAgent(agent.id, cwd: entry.session.project.rootURL)
        return .json(["agent": agent.id, "running": true, "started": true])
    }

    private func stopAgentSession(_ fields: [String: Any]) throws -> HTTPServer.Response {
        let (entry, agent) = try agent(fields)
        try refuseIfARunUses(agent, in: entry)
        let wasRunning = entry.session.orchestrator.hasSession(for: agent.id)
        entry.session.orchestrator.stopAgentForPerson(agent.id)
        return .json(["agent": agent.id, "running": false, "stopped": wasRunning])
    }

    private func restartAgentSession(_ fields: [String: Any]) async throws -> HTTPServer.Response {
        let (entry, agent) = try agent(fields)
        try refuseMidTurn(agent)
        try refuseIfARunUses(agent, in: entry)
        entry.session.orchestrator.stopAgent(agent.id)
        try await entry.session.orchestrator.startAgent(agent.id, cwd: entry.session.project.rootURL)
        return .json(["agent": agent.id, "running": true])
    }

    // MARK: - An agent's chats

    private func chatJSON(_ chat: ChatSession, current: UUID?) -> [String: Any] {
        ["id": chat.id.uuidString, "title": chat.isUntitled ? "New Chat" : chat.title,
         "messages": chat.messageCount,
         "lastMessageAt": ISO8601DateFormatter().string(from: chat.lastMessageAt),
         "current": chat.id == current]
    }

    /// The agent's chat a request names by id.
    private func chat(_ id: Any?, of agent: Agent, in entry: ControlSessionRegistry.Entry) throws -> ChatSession {
        guard let id = id as? String else { throw ControlRefusal.missing("\"chat\"") }
        guard let chat = entry.session.sessionStore.sessions(for: agent.id).first(where: { $0.id.uuidString == id.uppercased() }) else {
            throw ControlRefusal("No chat '\(id)' of \(agent.name)'s", status: 404)
        }
        return chat
    }

    private func listAgentChats(_ query: [String: String]) throws -> HTTPServer.Response {
        let (entry, agent) = try agent(query)
        let current = entry.session.chatViewModel(for: agent.id).currentSession?.id
        let chats = entry.session.sessionStore.sessions(for: agent.id).sorted { $0.lastMessageAt > $1.lastMessageAt }
        return .json(["agent": agent.id, "chats": chats.map { chatJSON($0, current: current) }])
    }

    private func newAgentChat(_ fields: [String: Any]) async throws -> HTTPServer.Response {
        let (entry, agent) = try agent(fields)
        try refuseMidTurn(agent)
        let chatView = entry.session.chatViewModel(for: agent.id)
        await chatView.startNewChat()
        guard let chat = chatView.currentSession else {
            throw ControlRefusal("This project keeps no chats", status: 503)
        }
        return .json(["agent": agent.id, "chat": chatJSON(chat, current: chat.id)], status: 201)
    }

    private func openAgentChat(_ fields: [String: Any]) async throws -> HTTPServer.Response {
        let (entry, agent) = try agent(fields)
        let chat = try chat(fields["chat"], of: agent, in: entry)
        try refuseMidTurn(agent)
        await entry.session.chatViewModel(for: agent.id).switchToSession(chat)
        return .json(["agent": agent.id, "chat": chatJSON(chat, current: chat.id)])
    }

    private func deleteAgentChat(_ query: [String: String]) async throws -> HTTPServer.Response {
        let (entry, agent) = try agent(query)
        let chat = try chat(query["chat"], of: agent, in: entry)
        let chatView = entry.session.chatViewModel(for: agent.id)
        if chatView.currentSession?.id == chat.id { try refuseMidTurn(agent) }
        await chatView.deleteSession(chat)
        return .json(["agent": agent.id, "deleted": chat.id.uuidString])
    }
}
