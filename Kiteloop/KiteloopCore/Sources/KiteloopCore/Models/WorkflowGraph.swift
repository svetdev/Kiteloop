import Foundation

package struct WorkflowGraph: Codable, Identifiable, Sendable {
    package let id: String
    package let name: String
    package let version: Int
    package var nodes: [NodeID: WorkflowNode]
    package var edges: [WorkflowEdge]
    package let entryNode: NodeID
    package let terminalNodes: Set<NodeID>
    package var metadata: GraphMetadata
    package var globalTimeout: Int?
    package var maxIterations: Int?

    package typealias NodeID = String

    package struct GraphMetadata: Codable, Sendable {
        package var description: String
        package var author: String?
        package var createdAt: Date?
        package var tags: [String]

        package static let empty = GraphMetadata(description: "", author: nil, createdAt: nil, tags: [])

        package init(description: String, author: String? = nil, createdAt: Date? = nil, tags: [String] = []) {
            self.description = description
            self.author = author
            self.createdAt = createdAt
            self.tags = tags
        }

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
            author = try c.decodeIfPresent(String.self, forKey: .author)
            createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
            tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        }

        private enum CodingKeys: String, CodingKey {
            case description, author, createdAt, tags
        }
    }

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(id: String, name: String, version: Int, nodes: [NodeID: WorkflowNode], edges: [WorkflowEdge], entryNode: NodeID, terminalNodes: Set<NodeID>, metadata: GraphMetadata, globalTimeout: Int? = nil, maxIterations: Int? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.nodes = nodes
        self.edges = edges
        self.entryNode = entryNode
        self.terminalNodes = terminalNodes
        self.metadata = metadata
        self.globalTimeout = globalTimeout
        self.maxIterations = maxIterations
    }
}

package struct WorkflowNode: Codable, Sendable {
    package let id: WorkflowGraph.NodeID
    package let agentID: String?
    package let subGraphID: String?
    package let prompt: String
    package var toolScopeOverride: ToolScopeHint?
    package var maxTurns: Int?
    package var timeoutSeconds: Int?
    package var outputSchema: OutputSchema?
    package var preloadKnowledge: [String]?
    package var allowFreeform: Bool
    package var fileScope: FileScope?
    package var shellCommand: String?
    package var timeoutFallback: TimeoutFallback?

    /// What a node's own `timeoutSeconds` means when it fires, for a node
    /// whose question is a restatement of a decision made elsewhere rather
    /// than a decision of its own — the reviewer's follow-up ask, asked only
    /// because its first answer didn't parse. A clock the ask runs out on
    /// says nothing about that decision, so its overrun is not a failure:
    /// the engine completes the node with `state[key]` read back as `trueValue`
    /// when it already reads that way, `falseValue` otherwise (which is every
    /// other case, including nothing at all — the safe default), and routes
    /// on that exactly as a normal completion would. `note` lands in
    /// `state["_timeoutFallbackNote"]` for the caller to surface, and — only
    /// on the `falseValue` branch, since an approval needs no explanation —
    /// in `state[feedbackKey]` too, when a key is given, so the round this
    /// routes to isn't handed a stale or empty one left by an earlier round.
    package struct TimeoutFallback: Codable, Sendable, Equatable {
        package let key: String
        package let trueValue: String
        package let falseValue: String
        package let note: String
        package let feedbackKey: String?

        package init(key: String, trueValue: String, falseValue: String, note: String, feedbackKey: String? = nil) {
            self.key = key
            self.trueValue = trueValue
            self.falseValue = falseValue
            self.note = note
            self.feedbackKey = feedbackKey
        }
    }

    package init(
        id: WorkflowGraph.NodeID,
        agentID: String? = nil,
        subGraphID: String? = nil,
        prompt: String,
        toolScopeOverride: ToolScopeHint? = nil,
        maxTurns: Int? = nil,
        timeoutSeconds: Int? = nil,
        outputSchema: OutputSchema? = nil,
        preloadKnowledge: [String]? = nil,
        allowFreeform: Bool = false,
        fileScope: FileScope? = nil,
        shellCommand: String? = nil,
        timeoutFallback: TimeoutFallback? = nil
    ) {
        self.id = id
        self.agentID = agentID
        self.subGraphID = subGraphID
        self.prompt = prompt
        self.toolScopeOverride = toolScopeOverride
        self.maxTurns = maxTurns
        self.timeoutSeconds = timeoutSeconds
        self.outputSchema = outputSchema
        self.preloadKnowledge = preloadKnowledge
        self.allowFreeform = allowFreeform
        self.fileScope = fileScope
        self.shellCommand = shellCommand
        self.timeoutFallback = timeoutFallback
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        agentID = try c.decodeIfPresent(String.self, forKey: .agentID)
        subGraphID = try c.decodeIfPresent(String.self, forKey: .subGraphID)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        toolScopeOverride = try c.decodeIfPresent(ToolScopeHint.self, forKey: .toolScopeOverride)
        maxTurns = try c.decodeIfPresent(Int.self, forKey: .maxTurns)
        timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds)
        outputSchema = try c.decodeIfPresent(OutputSchema.self, forKey: .outputSchema)
        preloadKnowledge = try c.decodeIfPresent([String].self, forKey: .preloadKnowledge)
        allowFreeform = try c.decodeIfPresent(Bool.self, forKey: .allowFreeform) ?? false
        fileScope = try c.decodeIfPresent(FileScope.self, forKey: .fileScope)
        shellCommand = try c.decodeIfPresent(String.self, forKey: .shellCommand)
        timeoutFallback = try c.decodeIfPresent(TimeoutFallback.self, forKey: .timeoutFallback)
    }

    private enum CodingKeys: String, CodingKey {
        case id, agentID, subGraphID, prompt, toolScopeOverride
        case maxTurns, timeoutSeconds, outputSchema, preloadKnowledge, allowFreeform
        case fileScope, shellCommand, timeoutFallback
    }
}

package struct FileScope: Codable, Sendable, Equatable {
    package let allowedPaths: [String]
    package let frozenPaths: [String]

    package init(allowedPaths: [String], frozenPaths: [String] = []) {
        self.allowedPaths = allowedPaths
        self.frozenPaths = frozenPaths
    }

    package func isPathAllowed(_ path: String) -> Bool {
        if frozenPaths.contains(where: { matchesGlob($0, path: path) }) {
            return false
        }
        return allowedPaths.contains(where: { matchesGlob($0, path: path) })
    }

    private func matchesGlob(_ pattern: String, path: String) -> Bool {
        if pattern.hasSuffix("/**/*") {
            let prefix = String(pattern.dropLast(5))
            return path.hasPrefix(prefix)
        }
        if pattern.hasSuffix("/**/*.swift") {
            let prefix = String(pattern.dropLast(11))
            return path.hasPrefix(prefix) && path.hasSuffix(".swift")
        }
        if pattern.hasSuffix("/**") {
            let prefix = String(pattern.dropLast(3))
            return path.hasPrefix(prefix)
        }
        if pattern.hasSuffix("/*") {
            let prefix = String(pattern.dropLast(2))
            let remainder = path.dropFirst(prefix.count + 1)
            return path.hasPrefix(prefix) && !remainder.contains("/")
        }
        return path == pattern || path.hasSuffix("/\(pattern)")
    }
}

package struct ToolScopeHint: Codable, Sendable, Equatable {
    package let allowed: Set<String>?
    package let denied: Set<String>

    package init(allowed: Set<String>? = nil, denied: Set<String> = []) {
        self.allowed = allowed
        self.denied = denied
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allowed = try c.decodeIfPresent(Set<String>.self, forKey: .allowed)
        denied = try c.decodeIfPresent(Set<String>.self, forKey: .denied) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case allowed, denied
    }
}

package struct OutputSchema: Codable, Sendable, Equatable {
    package let fields: [String: SchemaField]

    package struct SchemaField: Codable, Sendable, Equatable {
        package let type: String
        package let required: Bool
        package let description: String?
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(type: String, required: Bool, description: String?) {
            self.type = type
            self.required = required
            self.description = description
        }
    }

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(fields: [String: SchemaField]) {
        self.fields = fields
    }
}
