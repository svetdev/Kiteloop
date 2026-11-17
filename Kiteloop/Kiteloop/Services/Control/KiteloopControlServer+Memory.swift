import Foundation
import KiteloopCore

/// What agents remember and are told: Kiteloop's per-agent memory, the
/// project's shared context, the notes the Claude CLI keeps, and the
/// knowledge packages.
@MainActor
struct MemoryEndpoints {
    let server: KiteloopControlServer

    func agentMemoryRoute(_ route: ManagementRoute, _ req: HTTPServer.Request) async throws -> HTTPServer.Response {
        switch route {
        case .getAgentMemory: return try await agentMemory(req.query)
        case .addMemoryFact: return try await addMemoryFact(KiteloopControlServer.jsonBody(req.body))
        case .rewriteMemoryFact: return try await rewriteMemoryFact(KiteloopControlServer.jsonBody(req.body))
        case .archiveMemoryFact: return try await archiveMemoryFact(req.query)
        case .getSharedMemory: return try await sharedMemory(req.query["project"])
        default: return try await setSharedMemory(KiteloopControlServer.jsonBody(req.body))
        }
    }

    // MARK: - Kiteloop's per-agent memory

    private static func facts(_ topics: [MemoryTopic]) -> [[String: Any]] {
        topics.map { ["topic": $0.id, "body": $0.body] }
    }

    private func agentMemory(_ query: [String: String]) async throws -> HTTPServer.Response {
        let (entry, agent) = try server.agent(query)
        let memory = entry.session.orchestrator.memoryManager
        return .json([
            "agent": agent.id,
            "index": await memory.currentMemory(agentID: agent.id),
            "facts": Self.facts(await memory.memoryTopics(agentID: agent.id)),
            "archived": Self.facts(await memory.archivedTopics(agentID: agent.id))
        ])
    }

    /// Text a memory write is given, refused when blank.
    private func content(_ fields: [String: Any]) throws -> String {
        let content = try server.text(fields, "content")
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ControlRefusal("\"content\" can't be blank", status: 400)
        }
        return content
    }

    private func addMemoryFact(_ fields: [String: Any]) async throws -> HTTPServer.Response {
        let (entry, agent) = try server.agent(fields)
        let memory = entry.session.orchestrator.memoryManager
        try await memory.addFact(agentID: agent.id, content: try content(fields))
        return .json(["agent": agent.id, "facts": Self.facts(await memory.memoryTopics(agentID: agent.id))], status: 201)
    }

    /// The fact a request names, refused when the agent's memory holds none by
    /// that topic — the manager's own refusal for it reads as a failed write.
    private func topic(_ fields: [String: Any], of agent: Agent, in entry: ControlSessionRegistry.Entry) async throws -> String {
        let topic = try server.text(fields, "topic")
        let held = await entry.session.orchestrator.memoryManager.memoryTopics(agentID: agent.id)
        guard held.contains(where: { $0.id == topic }) else {
            throw ControlRefusal("No fact '\(topic)' in \(agent.name)'s memory", status: 404)
        }
        return topic
    }

    private func rewriteMemoryFact(_ fields: [String: Any]) async throws -> HTTPServer.Response {
        let (entry, agent) = try server.agent(fields)
        let topic = try await topic(fields, of: agent, in: entry)
        try await entry.session.orchestrator.memoryManager.rewriteFact(agentID: agent.id, topic: topic, content: try content(fields))
        return .json(["agent": agent.id, "topic": topic])
    }

    private func archiveMemoryFact(_ query: [String: String]) async throws -> HTTPServer.Response {
        let (entry, agent) = try server.agent(query)
        let topic = try await topic(query, of: agent, in: entry)
        try await entry.session.orchestrator.memoryManager.archiveFact(agentID: agent.id, topic: topic)
        return .json(["agent": agent.id, "archived": topic])
    }

    // MARK: - The project's shared context

    private func sharedMemory(_ project: String?) async throws -> HTTPServer.Response {
        let entry = try server.openProject(project)
        return .json(["content": await entry.session.orchestrator.memoryManager.sharedContext()])
    }

    private func setSharedMemory(_ fields: [String: Any]) async throws -> HTTPServer.Response {
        let entry = try server.openProject(fields["project"])
        let content = try server.text(fields, "content")
        try await entry.session.orchestrator.memoryManager.saveSharedContext(content)
        return .json(["content": content])
    }

    // MARK: - The Claude CLI's notes

    func notesRoute(_ route: ManagementRoute, _ req: HTTPServer.Request) async throws -> HTTPServer.Response {
        switch route {
        case .listClaudeMemory: return try listClaudeMemory(req.query["project"])
        case .putClaudeMemoryNote: return try putClaudeMemoryNote(KiteloopControlServer.jsonBody(req.body))
        case .deleteClaudeMemoryNote: return try deleteClaudeMemoryNote(req.query)
        case .listKnowledge: return try listKnowledge(req.query["project"])
        case .getKnowledgeFile: return try knowledgeFile(req.query)
        default: return try putKnowledgeFile(KiteloopControlServer.jsonBody(req.body))
        }
    }

    private func claudeNotes(_ project: Any?) throws -> ClaudeMemoryStore {
        try server.openProject(project).session.claudeMemoryViewModel.store
    }

    /// A note's id is its file's name: nothing that could name another folder.
    private func noteID(_ value: Any?) throws -> String {
        guard let id = value as? String else { throw ControlRefusal.missing("\"note\"") }
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !id.isEmpty, id.unicodeScalars.allSatisfy(plain.contains) else {
            throw ControlRefusal("\"note\" is a file name: letters, digits, - and _", status: 400)
        }
        return id
    }

    private func listClaudeMemory(_ project: String?) throws -> HTTPServer.Response {
        let store = try claudeNotes(project)
        let notes = store.notes().map { note -> [String: Any] in
            var row: [String: Any] = ["id": note.id, "name": note.name, "text": note.text]
            if let summary = note.summary { row["summary"] = summary }
            if let kind = note.kind { row["kind"] = kind }
            return row
        }
        return .json(["directory": store.directory.path(percentEncoded: false), "notes": notes])
    }

    private func putClaudeMemoryNote(_ fields: [String: Any]) throws -> HTTPServer.Response {
        let store = try claudeNotes(fields["project"])
        let id = try noteID(fields["note"])
        let text = try server.text(fields, "text")
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try store.save(id: id, text: text)
        return .json(["note": id])
    }

    private func deleteClaudeMemoryNote(_ query: [String: String]) throws -> HTTPServer.Response {
        let store = try claudeNotes(query["project"])
        let id = try noteID(query["note"])
        guard id != ClaudeMemoryStore.indexName else {
            throw ControlRefusal("The index is not a note; write it with PUT /v1/memory/claude", status: 400)
        }
        guard store.text(of: id) != nil else { throw ControlRefusal("No note '\(id)'", status: 404) }
        try store.delete(id: id)
        return .json(["deleted": id])
    }

    // MARK: - Knowledge packages

    private static func paths(_ files: [TrainedAgent.KnowledgeFile]) -> [String] {
        files.flatMap { $0.isDirectory ? paths($0.children) : [String($0.relativePath.drop { $0 == "/" })] }
    }

    private func listKnowledge(_ project: String?) throws -> HTTPServer.Response {
        let store = try server.openProject(project).session.knowledgeStore
        store.reload()
        let packages = store.agents.map { package -> [String: Any] in
            ["id": package.id, "name": package.name, "description": package.description,
             "files": ["profile.md"] + Self.paths(package.knowledgeFiles).map { "knowledge/\($0)" }]
        }
        return .json(["packages": packages])
    }

    /// A file inside a package the request names. The path is held to the
    /// package's own folder, as a workspace read is held to the project.
    private func knowledgeFileURL(_ fields: [String: Any]) throws -> (store: AgentKnowledgeStore, package: TrainedAgent, path: String, url: URL) {
        let store = try server.openProject(fields["project"]).session.knowledgeStore
        let id = try server.text(fields, "package")
        let path = try server.text(fields, "path")
        store.reload()
        guard let package = store.agents.first(where: { $0.id == id }) else {
            throw ControlRefusal("No knowledge package '\(id)'", status: 404)
        }
        let base = package.basePath.standardizedFileURL
        let url = base.appending(path: path).standardizedFileURL
        let inside = url.path(percentEncoded: false).hasPrefix(base.path(percentEncoded: false).appending(base.path(percentEncoded: false).hasSuffix("/") ? "" : "/"))
        guard !path.isEmpty, !path.hasPrefix("/"), inside else {
            throw ControlRefusal("\"path\" must stay inside the package", status: 400)
        }
        return (store, package, path, url)
    }

    private func knowledgeFile(_ query: [String: String]) throws -> HTTPServer.Response {
        let (_, package, path, url) = try knowledgeFileURL(query)
        guard let data = try? Data(contentsOf: url) else {
            throw ControlRefusal("No file '\(path)' in \(package.id)", status: 404)
        }
        return .json(["package": package.id, "path": path, "content": String(decoding: data, as: UTF8.self)])
    }

    private func putKnowledgeFile(_ fields: [String: Any]) throws -> HTTPServer.Response {
        let (store, package, path, url) = try knowledgeFileURL(fields)
        let content = try server.text(fields, "content")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try store.saveFile(at: url, content: content)
        return .json(["package": package.id, "path": path])
    }
}
