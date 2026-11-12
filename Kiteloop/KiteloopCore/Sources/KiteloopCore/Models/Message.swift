import Foundation

package struct Message: Identifiable, Codable {
    package let id: UUID
    package let timestamp: Date
    package let sender: Sender
    package var content: Content
    /// How many tokens the model thought for, as the CLI estimated before a
    /// `.thinking` block whose text current models leave empty. Nil on every
    /// other message, and on a chat saved before the estimate was kept.
    package var thinkingTokenEstimate: Int?
    /// On a `.text` or `.thinking` message: the `Agent`/`Task` call whose
    /// subagent said it, which is where the chat draws it. Nil for the
    /// agent's own words, on every other message — a tool call carries its
    /// parent on `ToolCall` — and on a chat saved before this was kept.
    package var parentToolUseID: String?

    package enum Sender: Codable, Equatable {
        case human
        case agent(String)
        case system
    }

    package enum Content: Codable {
        case text(String)
        case thinking(String)
        case toolCall(ToolCall)
        case toolResult(ToolResult)
        case approval(ApprovalRequest)
        case mcpAuthRequest(MCPAuthRequest)
        case image(Data)
        case error(String)
        case systemEvent(SystemEvent)
        case plan(PlanProposal)
        case permission(PermissionRequest)
        case choices(ChoiceQuestion)
    }

    /// A call the session stopped to ask leave for, as a terminal would, and
    /// what was answered — nil while it waits, which has no limit. A card the
    /// session no longer wants answered — the turn was interrupted, the
    /// session ended — is `lapsed`.
    package struct PermissionRequest: Identifiable, Codable, Equatable {
        /// The id the CLI gave the request; the answer carries it back.
        package let id: String
        package let toolName: String
        /// The call's input, a JSON object as text.
        package let input: String
        /// One line of what the call would do.
        package let summary: String
        /// The subagent whose call it is, in the words its task was given;
        /// nil for the agent's own call.
        package let subagent: String?
        /// What the CLI offers to remember so it need not ask again.
        package let suggestions: [PermissionSuggestion]
        package var answer: Answer?

        /// The request as one line: whose call it is, and what it would do.
        package var question: String { subagent.map { "\($0) — \(summary)" } ?? summary }

        package enum Answer: String, Codable {
            case allowed
            case allowedAlways
            case denied
            case lapsed
        }

        package init(id: String, toolName: String, input: String, summary: String, subagent: String? = nil,
                     suggestions: [PermissionSuggestion] = [], answer: Answer? = nil) {
            self.id = id
            self.toolName = toolName
            self.input = input
            self.summary = summary
            self.subagent = subagent
            self.suggestions = suggestions
            self.answer = answer
        }
    }

    /// The questions the model put with the CLI's own `AskUserQuestion`, each
    /// with the choices it offered, and what was answered — one answer per
    /// question, in order; nil while it waits.
    package struct ChoiceQuestion: Identifiable, Codable, Equatable {
        /// The id the CLI gave the request; the answer carries it back.
        package let id: String
        /// The call's input, a JSON object as text: the answer is this with
        /// the answers added.
        package let input: String
        package let questions: [Question]
        package var answers: [String]?
        /// True for a card the session no longer wants answered.
        package var lapsed = false

        package var isOpen: Bool { answers == nil && !lapsed }

        /// Every question asked, one to a line.
        package var text: String { questions.map(\.question).joined(separator: "\n") }

        package struct Question: Codable, Equatable {
            package let question: String
            package let header: String
            package let options: [Option]
            package let multiSelect: Bool

            package init(question: String, header: String = "", options: [Option] = [], multiSelect: Bool = false) {
                self.question = question
                self.header = header
                self.options = options
                self.multiSelect = multiSelect
            }
        }

        package struct Option: Codable, Equatable {
            package let label: String
            package let description: String

            package init(label: String, description: String = "") {
                self.label = label
                self.description = description
            }
        }

        package init(id: String, input: String, questions: [Question], answers: [String]? = nil, lapsed: Bool = false) {
            self.id = id
            self.input = input
            self.questions = questions
            self.answers = answers
            self.lapsed = lapsed
        }
    }

    /// The plan a `plan`-mode agent wrote under `~/.claude/plans/` during a
    /// turn, offered for approval, and what was chosen — nil until answered,
    /// and on a card saved before one was.
    package struct PlanProposal: Codable {
        package let text: String
        package var answer: Answer?
        /// The CLI's request this plan was offered with (`ExitPlanMode`),
        /// which the answer goes back to; nil for a plan read off the
        /// transcript, and on a card saved before the request was kept.
        package var requestID: String?
        /// That request's input, a JSON object as text, handed back with an
        /// approval; nil wherever `requestID` is.
        package var requestInput: String?

        package enum Answer: String, Codable {
            case approveAuto
            case approveAcceptEdits
            case keepPlanning

            /// The permission mode approving switches the agent to, or nil
            /// for Keep planning, which leaves it as it is.
            package var permissionMode: String? {
                switch self {
                case .approveAuto: "auto"
                case .approveAcceptEdits: "acceptEdits"
                case .keepPlanning: nil
                }
            }
        }

        package init(text: String, answer: Answer? = nil, requestID: String? = nil, requestInput: String? = nil) {
            self.text = text
            self.answer = answer
            self.requestID = requestID
            self.requestInput = requestInput
        }
    }

    package struct SystemEvent: Codable {
        package let kind: Kind
        package let detail: String

        package enum Kind: String, Codable {
            case compaction
            case apiRetry
            case sessionResumed
            case reconnecting
        }
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(kind: Kind, detail: String) {
            self.kind = kind
            self.detail = detail
        }
    }

    package struct ToolCall: Identifiable, Codable {
        package let id: String
        package let name: String
        package let input: String
        package var output: String?
        package var isCollapsed: Bool = true
        /// The `Agent`/`Task` call whose subagent made this call, or nil for
        /// the agent's own. A chat saved before this was kept decodes as nil.
        package var parentToolUseID: String?
        /// How the task this call started ended — a subagent's outcome and
        /// counters, a background shell's exit — saved with the chat so a
        /// reopened chat's row still says it. Nil while it runs, for a call
        /// that started no task, and in a chat saved before this was kept.
        package var finishedTask: AgentActivity.SavedTask?
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(id: String, name: String, input: String, output: String? = nil, isCollapsed: Bool = true,
                     parentToolUseID: String? = nil) {
            self.id = id
            self.name = name
            self.input = input
            self.output = output
            self.isCollapsed = isCollapsed
            self.parentToolUseID = parentToolUseID
        }
    }

    package struct ToolResult: Identifiable, Codable {
        package let id: String
        package let toolCallID: String
        package let output: String
        /// As on `ToolCall`: the subagent call this result belongs under.
        package var parentToolUseID: String?
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(id: String, toolCallID: String, output: String, parentToolUseID: String? = nil) {
            self.id = id
            self.toolCallID = toolCallID
            self.output = output
            self.parentToolUseID = parentToolUseID
        }
    }

    package struct ApprovalRequest: Identifiable, Codable {
        package let id: String
        package let action: String
        package let tool: String
        package var status: ApprovalStatus = .pending

        package enum ApprovalStatus: String, Codable {
            case pending
            case approved
            case denied
        }
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(id: String, action: String, tool: String, status: ApprovalStatus = .pending) {
            self.id = id
            self.action = action
            self.tool = tool
            self.status = status
        }
    }

    package struct MCPAuthRequest: Identifiable, Codable {
        package let id: String
        package let toolCallID: String
        package let serverName: String
        package let reason: String
        package let description: String
        package let authKeys: [String]
        package var status: AuthStatus = .pending
        package var envValues: [String: String] = [:]

        package enum AuthStatus: String, Codable {
            case pending
            case authorized
            case denied
        }
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(id: String, toolCallID: String, serverName: String, reason: String, description: String, authKeys: [String], status: AuthStatus = .pending, envValues: [String: String] = [:]) {
            self.id = id
            self.toolCallID = toolCallID
            self.serverName = serverName
            self.reason = reason
            self.description = description
            self.authKeys = authKeys
            self.status = status
            self.envValues = envValues
        }
    }

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(id: UUID, timestamp: Date, sender: Sender, content: Content, thinkingTokenEstimate: Int? = nil,
                 parentToolUseID: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.sender = sender
        self.content = content
        self.thinkingTokenEstimate = thinkingTokenEstimate
        self.parentToolUseID = parentToolUseID
    }
}

extension Message.Sender {
    private enum CodingKeys: String, CodingKey { case type, agentID }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .human:            try c.encode("human", forKey: .type)
        case .agent(let id): try c.encode("agent", forKey: .type); try c.encode(id, forKey: .agentID)
        case .system:        try c.encode("system", forKey: .type)
        }
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "human":  self = .human
        case "agent":  self = .agent(try c.decode(String.self, forKey: .agentID))
        default:       self = .system
        }
    }
}

extension Message.Content {
    private enum CodingKeys: String, CodingKey {
        case type, value, toolCall, toolResult, approval, mcpAuthRequest, systemEvent, plan, permission, choices
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let t):            try c.encode("text", forKey: .type);            try c.encode(t, forKey: .value)
        case .thinking(let t):        try c.encode("thinking", forKey: .type);        try c.encode(t, forKey: .value)
        case .toolCall(let v):        try c.encode("toolCall", forKey: .type);        try c.encode(v, forKey: .toolCall)
        case .toolResult(let v):      try c.encode("toolResult", forKey: .type);      try c.encode(v, forKey: .toolResult)
        case .approval(let v):        try c.encode("approval", forKey: .type);        try c.encode(v, forKey: .approval)
        case .mcpAuthRequest(let v):  try c.encode("mcpAuthRequest", forKey: .type);  try c.encode(v, forKey: .mcpAuthRequest)
        case .image(let data):        try c.encode("image", forKey: .type);           try c.encode(data.base64EncodedString(), forKey: .value)
        case .error(let t):           try c.encode("error", forKey: .type);           try c.encode(t, forKey: .value)
        default:                      try encodeChatNotice(into: &c)
        }
    }

    /// The kinds Kiteloop itself posts into the chat, split off `encode(to:)`.
    private func encodeChatNotice(into c: inout KeyedEncodingContainer<CodingKeys>) throws {
        switch self {
        case .systemEvent(let e):     try c.encode("systemEvent", forKey: .type);     try c.encode(e, forKey: .systemEvent)
        case .plan(let p):            try c.encode("plan", forKey: .type);            try c.encode(p, forKey: .plan)
        case .permission(let r):      try c.encode("permission", forKey: .type);      try c.encode(r, forKey: .permission)
        case .choices(let q):         try c.encode("choices", forKey: .type);         try c.encode(q, forKey: .choices)
        default:                      break
        }
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "text":            self = .text(try c.decode(String.self, forKey: .value))
        case "thinking":        self = .thinking(try c.decode(String.self, forKey: .value))
        case "toolCall":        self = .toolCall(try c.decode(Message.ToolCall.self, forKey: .toolCall))
        case "toolResult":      self = .toolResult(try c.decode(Message.ToolResult.self, forKey: .toolResult))
        case "approval":        self = .approval(try c.decode(Message.ApprovalRequest.self, forKey: .approval))
        case "mcpAuthRequest":  self = .mcpAuthRequest(try c.decode(Message.MCPAuthRequest.self, forKey: .mcpAuthRequest))
        case "image":           self = .image(Data(base64Encoded: (try c.decode(String.self, forKey: .value))) ?? Data())
        case "error":           self = .error(try c.decode(String.self, forKey: .value))
        case let type:          self = try Self.decodeChatNotice(type, from: c)
        }
    }

    /// The kinds Kiteloop itself posts into the chat, split off `init(from:)`;
    /// a type nothing knows reads as unknown text.
    private static func decodeChatNotice(_ type: String, from c: KeyedDecodingContainer<CodingKeys>) throws -> Self {
        switch type {
        case "systemEvent":     .systemEvent(try c.decode(Message.SystemEvent.self, forKey: .systemEvent))
        case "plan":            .plan(try c.decode(Message.PlanProposal.self, forKey: .plan))
        case "permission":      .permission(try c.decode(Message.PermissionRequest.self, forKey: .permission))
        case "choices":         .choices(try c.decode(Message.ChoiceQuestion.self, forKey: .choices))
        default:                .text("[unknown]")
        }
    }
}

extension Message {
    package static func human(_ text: String) -> Message {
        Message(id: UUID(), timestamp: .now, sender: .human, content: .text(text))
    }

    package static func agentText(_ text: String, agent: String, parent: String? = nil) -> Message {
        Message(id: UUID(), timestamp: .now, sender: .agent(agent), content: .text(text), parentToolUseID: parent)
    }

    package static func agentThinking(_ text: String, agent: String, estimatedTokens: Int? = nil,
                                      parent: String? = nil) -> Message {
        Message(id: UUID(), timestamp: .now, sender: .agent(agent), content: .thinking(text),
                thinkingTokenEstimate: estimatedTokens, parentToolUseID: parent)
    }

    package static func toolCall(_ call: ToolCall, agent: String) -> Message {
        Message(id: UUID(), timestamp: .now, sender: .agent(agent), content: .toolCall(call))
    }

    package static func toolResult(_ result: ToolResult, agent: String) -> Message {
        Message(id: UUID(), timestamp: .now, sender: .agent(agent), content: .toolResult(result))
    }

    package static func agentImage(_ data: Data, agent: String) -> Message {
        Message(id: UUID(), timestamp: .now, sender: .agent(agent), content: .image(data))
    }

    package static func permissionDenied(tool: String, detail: String) -> Message {
        let msg = detail.isEmpty
            ? "Permission denied for \(tool). Adjust allowed tools in Settings (\u{2318},) and retry."
            : "Permission denied for \(tool): \(detail). Adjust allowed tools in Settings (\u{2318},) and retry."
        return Message(id: UUID(), timestamp: .now, sender: .system, content: .error(msg))
    }

    package static func systemEvent(_ kind: SystemEvent.Kind, detail: String) -> Message {
        Message(id: UUID(), timestamp: .now, sender: .system, content: .systemEvent(SystemEvent(kind: kind, detail: detail)))
    }
}
