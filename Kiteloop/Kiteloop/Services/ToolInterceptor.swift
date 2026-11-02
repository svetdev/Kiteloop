import Foundation
import KiteloopCore

enum InterceptedTool: String, CaseIterable {
    case publishEvent = "publish_event"
    case proposeMemory = "propose_memory"
    case askHuman = "ask_human"
    case recallKnowledge = "recall_knowledge"
    case saveKnowledge = "save_knowledge"
    case discoverAgents = "discover_agents"
}

struct ToolInterceptor {
    static func isIntercepted(_ toolName: String) -> Bool {
        InterceptedTool(rawValue: toolName) != nil
    }

    @MainActor
    static func handle(
        tool: InterceptedTool,
        input: String,
        agentID: String,
        orchestrator: Orchestrator
    ) async -> String {
        guard let data = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Error: invalid input JSON"
        }

        switch tool {
        case .publishEvent:
            return handlePublishEvent(json: json, agentID: agentID, orchestrator: orchestrator)
        case .proposeMemory:
            return await handleProposeMemory(json: json, agentID: agentID, orchestrator: orchestrator)
        case .askHuman:
            let question = json["question"] as? String ?? "Agent needs your input"
            return "__WAITING_FOR_HUMAN__:\(question)"
        case .recallKnowledge:
            guard let query = recallQuery(from: json) else { return "Error: query is required" }
            // The agent's own memory is the second tier of the same mechanism —
            // only the index rides in the system prompt, so this is the only way
            // back to what a fact actually said.
            let memory = await orchestrator.memoryManager.recallMemory(agentID: agentID, query: query)
            guard let recallService = orchestrator.knowledgeRecallService else {
                return memory.isEmpty ? "Error: knowledge recall service not available" : memorySection(memory)
            }
            let knowledge = await recallService.recall(query: query, agentID: agentID)
            return memory.isEmpty ? knowledge : knowledge + "\n\n" + memorySection(memory)
        case .saveKnowledge:
            return "Error: save_knowledge must be handled via ChatViewModel"
        case .discoverAgents:
            let query = json["query"] as? String ?? ""
            guard !query.isEmpty else { return "Error: query is required" }
            let projectID = json["projectID"] as? String
            let limit = json["limit"] as? Int ?? 10
            guard let cardService = orchestrator.agentCardService else {
                return "Error: agent card service not available"
            }
            let callerRef = AgentRef(id: agentID, scope: orchestrator.agentScope(for: agentID) ?? (projectID.map { .project(id: $0) } ?? .global))
            let results = await cardService.discover(query: query, caller: callerRef, projectID: projectID, limit: limit)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            guard let data = try? encoder.encode(results),
                  let jsonString = String(data: data, encoding: .utf8) else {
                return "Error: failed to encode results"
            }
            return jsonString
        }
    }

    /// Labels recalled memory so it is not mistaken for package knowledge — one
    /// is what the agent was taught, the other what it was told and a human
    /// approved.
    static func memorySection(_ body: String) -> String {
        "# From your memory\n\n\(body)"
    }

    /// Why an update to an existing knowledge entry was refused before anything
    /// was written.
    enum KnowledgeUpdateError: LocalizedError {
        case wouldExceedMaxFileSize

        var errorDescription: String? {
            switch self {
            case .wouldExceedMaxFileSize:
                return "updating existing entry would exceed max file size (8KB). Use conflict_policy: 'always_new' instead."
            }
        }
    }

    /// Appends one `save_knowledge` update to the entry it matched: composes the
    /// `_Updated … by …:_` block after `existing`, refuses when the result would
    /// pass the 8KB ceiling, and writes the whole file back.
    ///
    /// It throws rather than swallowing the write, because the caller's answer
    /// goes to the agent. A `try?` here used to report "Updated existing entry"
    /// for a write that never landed, leaving the agent believing knowledge it
    /// will never recall was saved — which the sibling new-entry path has always
    /// returned an error for.
    static func appendKnowledgeUpdate(
        _ content: String,
        to url: URL,
        existing: String,
        agentID: String,
        timestamp: String
    ) throws {
        let updated = existing + "\n\n---\n_Updated \(timestamp) by \(agentID):_\n\n\(content)"
        let maxFileSize = 8192
        guard updated.utf8.count <= maxFileSize else {
            throw KnowledgeUpdateError.wouldExceedMaxFileSize
        }
        try updated.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The search text of a `recall_knowledge` call, trimmed, or nil when the
    /// call carried none.
    ///
    /// Both dispatch paths read the arguments through here, because the agent is
    /// told two different spellings by two different places: the schema
    /// documents `query`, while ``AgentMemoryIndex/preamble`` — which rides in
    /// every system prompt — says to call the tool "with a topic name", and the
    /// slug in square brackets on each index line is that name. An agent that
    /// does as its preamble says used to be answered on one path and refused on
    /// the other.
    ///
    /// `query` is preferred when both keys are present: it is the documented
    /// spelling. A key holding nothing but whitespace is no argument at all, so
    /// it falls through to the other rather than refusing with a key in hand.
    static func recallQuery(from json: [String: Any]) -> String? {
        for key in ["query", "topic"] {
            guard let raw = json[key] as? String else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// What a `recall_knowledge` scope argument resolved to: the knowledge to
    /// search, or the refusal the agent is answered with instead of a search.
    enum RecallScopeResolution {
        case scope(KnowledgeIndex.SearchScope)
        case refusal(String)
    }

    /// Whether a `crossAgentAccess` list grants every agent: any entry that is
    /// `*` or `all`, case-insensitive after trimming. `message_agent` and
    /// `recall_knowledge` both read the wildcard through this.
    static func grantsEveryAgent(_ crossAgentAccess: [String]) -> Bool {
        crossAgentAccess.contains {
            let entry = $0.trimmingCharacters(in: .whitespaces).lowercased()
            return entry == "*" || entry == "all"
        }
    }

    /// The scope a `recall_knowledge` call searches.
    ///
    /// `own` and `shared` are open to every agent; any other spelling names
    /// another agent's knowledge, which only `crossAgentAccess` opens — either
    /// by listing that agent or by holding the wildcard, `*` or `all`.
    static func recallScope(
        requested: String,
        agentID: String,
        crossAgentAccess: [String]
    ) -> RecallScopeResolution {
        switch requested {
        case "own":
            return .scope(.ownAndShared(agentID: agentID))
        case "shared":
            return .scope(.shared)
        case "all":
            guard grantsEveryAgent(crossAgentAccess) else {
                return .refusal("Error: agent '\(agentID)' does not have cross-agent access. Requires crossAgentAccess: [\"*\"] or [\"all\"] in profile.")
            }
            return .scope(.all)
        default:
            guard crossAgentAccess.contains(requested) || grantsEveryAgent(crossAgentAccess) else {
                return .refusal("Error: agent '\(agentID)' does not have access to scope '\(requested)'. Authorized scopes: own, shared, \(crossAgentAccess.joined(separator: ", "))")
            }
            return .scope(.specific(agentID: requested))
        }
    }

    /// A `recall_knowledge` answer: the entries the search found, then the
    /// agent's own memory, labelled. Either half may be empty, and when both
    /// are the agent is told plainly that nothing matched the query.
    static func recallAnswer(
        results: [KnowledgeIndex.SearchResult],
        query: String,
        memory: String
    ) -> String {
        guard !results.isEmpty else {
            return memory.isEmpty
                ? "No relevant knowledge found for query: \"\(query)\""
                : memorySection(memory)
        }

        var output = "Found \(results.count) relevant entries:\n\n"
        for (i, result) in results.enumerated() {
            output += "[\(i + 1)] score=\(String(format: "%.3f", result.score)) source=\(result.source.rawValue)\n"
            output += "    file: \(result.filePath)\n"
            output += "    content: \(String(result.chunkText.prefix(500)))\n\n"
        }
        if !memory.isEmpty {
            output += memorySection(memory) + "\n"
        }
        return output
    }

    /// The arguments of a `save_knowledge` call the handler can act on.
    struct SaveKnowledgeArguments: Equatable {
        let content: String
        /// One of ``saveKnowledgeKinds`` — the only thing that ever becomes the
        /// entry's directory name.
        let kind: String
    }

    /// The kinds a knowledge entry may be filed under, in the order the schema
    /// lists them. The union of what the schema and the handler each documented.
    static let saveKnowledgeKinds = ["observation", "pattern", "decision", "reference", "context"]

    /// The arguments of a `save_knowledge` call; it throws the refusal to answer
    /// the agent with.
    ///
    /// The schema documents `category` while the handler used to demand `type`,
    /// so an agent following the schema was refused on every call. Both are read
    /// here; `type` wins when both are present. The kind becomes a directory
    /// name, so it must be one of ``saveKnowledgeKinds`` exactly — anything else,
    /// a path separator or `..` included, is refused before anything is written.
    static func saveKnowledgeArguments(from json: [String: Any]) throws -> SaveKnowledgeArguments {
        guard let content = json["content"] as? String else {
            throw SaveKnowledgeArgumentError("save_knowledge requires JSON with 'content' field")
        }
        let raw = (json["type"] as? String) ?? (json["category"] as? String) ?? ""
        let kind = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard saveKnowledgeKinds.contains(kind) else {
            let accepted = saveKnowledgeKinds.joined(separator: ", ")
            throw SaveKnowledgeArgumentError("save_knowledge requires 'category' to be one of: \(accepted)")
        }
        return SaveKnowledgeArguments(content: content, kind: kind)
    }

    /// The file a new `save_knowledge` entry is written as: the YAML front
    /// matter the index reads, then the content the agent sent.
    ///
    /// Composing it is the one thing here that depends on nothing outside its
    /// arguments, so it is separated from the handler that picks a file name and
    /// writes it.
    static func knowledgeEntry(
        _ arguments: SaveKnowledgeArguments,
        agentID: String,
        tags: [String],
        timestamp: String,
        sessionID: String
    ) -> String {
        let tagsYAML = tags.isEmpty ? "[]" : "[\(tags.joined(separator: ", "))]"
        return """
        ---
        type: \(arguments.kind)
        authorAgent: \(agentID)
        createdAt: \(timestamp)
        sourceRunID: session-\(sessionID)
        confidence: medium
        tags: \(tagsYAML)
        ---

        \(arguments.content)
        """
    }

    /// Why a `save_knowledge` call's arguments were refused.
    struct SaveKnowledgeArgumentError: LocalizedError, Equatable {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    @MainActor
    private static func handlePublishEvent(json: [String: Any], agentID: String, orchestrator: Orchestrator) -> String {
        let eventType = json["event"] as? String ?? "custom"
        let payload = json["payload"] as? [String: String] ?? [:]
        let type = KiteloopEvent.EventType(rawValue: eventType) ?? .custom
        let event = KiteloopEvent(source: agentID, type: type, payload: payload)
        orchestrator.publishEvent(event)
        return "Event published: \(eventType)"
    }

    @MainActor
    private static func handleProposeMemory(json: [String: Any], agentID: String, orchestrator: Orchestrator) async -> String {
        let content = json["content"] as? String ?? ""
        guard !content.isEmpty else { return "Error: content is required" }
        do {
            let proposal = try await orchestrator.memoryManager.proposeUpdate(agentID: agentID, content: content)
            return "Memory update proposed (id: \(proposal.id)). Awaiting human approval."
        } catch {
            // Nothing is awaiting approval: the proposal reached no queue a human
            // will ever see, so saying it did would leave the agent believing the
            // fact is on its way into memory.
            return "Error: the memory proposal was not recorded — \(error.localizedDescription)"
        }
    }
}

// MARK: - Tool Scope Backstop

extension ToolInterceptor {
    static func checkScope(tool: String, scope: ResolvedToolScope) -> ScopeDecision {
        if scope.denied.contains(tool) { return .denied(reason: .explicitDeny) }
        if !scope.effective.contains(tool) { return .denied(reason: .notInAllowed) }
        return .permitted
    }

    static func checkScope(tool: String, scope: ResolvedToolScope, agentID: String) -> (ScopeDecision, SpanEvent) {
        let decision = checkScope(tool: tool, scope: scope)
        let emitter = GuardrailSpanEmitter()
        let event = emitter.makeSpanEvent(tool: tool, decision: decision, agentID: agentID, scope: scope)
        return (decision, event)
    }
}
