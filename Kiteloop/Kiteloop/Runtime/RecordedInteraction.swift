import Foundation

/// A complete recorded session — all interactions with one agent, serializable to disk.
struct RecordedSession: Codable {
    let agentID: String
    let sessionID: String
    let recordedAt: Date
    let interactions: [RecordedInteraction]
}

/// One request/response pair: a send() or sendToolResult() call and the resulting stream.
struct RecordedInteraction: Codable {
    enum RequestType: String, Codable {
        case send
        case sendToolResult
    }

    let requestType: RequestType
    let timestamp: Date
    let message: String
    let attachments: [RecordedAttachment]
    let toolCallID: String?
    let events: [TimestampedEvent]
}

struct RecordedAttachment: Codable {
    let filename: String
    let mimeType: String
    let dataBase64: String
}

/// A StreamEvent captured with its relative offset from the start of the interaction.
struct TimestampedEvent: Codable {
    let offsetMs: Int
    let event: CodableStreamEvent
}

/// Codable mirror of StreamEvent — preserves exact event data for faithful replay.
enum CodableStreamEvent: Codable {
    case system(subtype: String, payloadJSON: String)
    /// A recording made before subagent text was forwarded decodes with no
    /// parent, as the agent's own.
    case thinking(String, parentToolUseID: String? = nil)
    case assistantText(String, parentToolUseID: String? = nil)
    /// A recording made before subagent calls were told apart decodes with
    /// no parent, which is what every call in it was drawn as.
    case toolUse(id: String, name: String, input: String, parentToolUseID: String? = nil)
    case toolResult(id: String, output: String, parentToolUseID: String? = nil)
    case image(base64Data: String, mimeType: String)
    case hook(hookType: String, hookName: String, toolName: String, output: String, exitCode: Int)
    case mcpToolCall(requestID: String, toolName: String, input: String)
    case result(ResultData)
    case unknown(String)

    struct ResultData: Codable {
        let text: String
        let costUSD: Double
        let durationMs: Int
        let inputTokens: Int
        let outputTokens: Int
        let cacheCreationInputTokens: Int
        let cacheReadInputTokens: Int
        let sessionID: String
        let permissionDenials: [DenialData]
    }

    struct DenialData: Codable {
        let toolName: String
        let detail: String
    }

    /// Convert from live StreamEvent to Codable representation.
    static func from(_ event: StreamEvent) -> CodableStreamEvent {
        switch event {
        case .system(let subtype, let payload):
            let json = (try? JSONSerialization.data(withJSONObject: payload))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return .system(subtype: subtype, payloadJSON: json)
        case .thinking(let text, let parent):
            return .thinking(text, parentToolUseID: parent)
        case .assistantText(let text, let parent):
            return .assistantText(text, parentToolUseID: parent)
        case .toolUse(let id, let name, let input, let parent):
            return .toolUse(id: id, name: name, input: input, parentToolUseID: parent)
        case .toolResult(let id, let output, let parent):
            return .toolResult(id: id, output: output, parentToolUseID: parent)
        case .image(let data, let mime):
            return .image(base64Data: data, mimeType: mime)
        case .hook(let payload):
            return .hook(
                hookType: payload.hookType, hookName: payload.hookName,
                toolName: payload.toolName, output: payload.output, exitCode: payload.exitCode
            )
        case .mcpToolCall(let payload):
            return .mcpToolCall(requestID: payload.requestID, toolName: payload.toolName, input: payload.input)
        case .result(let payload):
            return .result(ResultData(
                text: payload.text, costUSD: payload.costUSD, durationMs: payload.durationMs,
                inputTokens: payload.inputTokens, outputTokens: payload.outputTokens,
                cacheCreationInputTokens: payload.cacheCreationInputTokens,
                cacheReadInputTokens: payload.cacheReadInputTokens,
                sessionID: payload.sessionID,
                permissionDenials: payload.permissionDenials.map {
                    DenialData(toolName: $0.toolName, detail: $0.detail)
                }
            ))
        case .unknown(let raw):
            return .unknown(raw)
        }
    }

    /// Convert back to live StreamEvent for replay.
    func toStreamEvent() -> StreamEvent {
        switch self {
        case .system(let subtype, let payloadJSON):
            let payload = (try? JSONSerialization.jsonObject(
                with: Data(payloadJSON.utf8)
            ) as? [String: Any]) ?? ["type": "system", "subtype": subtype]
            return .system(subtype: subtype, payload: payload)
        case .thinking(let text, let parent):
            return .thinking(text, parentToolUseID: parent)
        case .assistantText(let text, let parent):
            return .assistantText(text, parentToolUseID: parent)
        case let .toolUse(id, name, input, parentToolUseID):
            return .toolUse(id: id, name: name, input: input, parentToolUseID: parentToolUseID)
        case let .toolResult(id, output, parentToolUseID):
            return .toolResult(id: id, output: output, parentToolUseID: parentToolUseID)
        case .image(let data, let mime):
            return .image(base64Data: data, mimeType: mime)
        case .hook(let hookType, let hookName, let toolName, let output, let exitCode):
            return .hook(StreamEvent.HookPayload(
                hookType: hookType, hookName: hookName,
                toolName: toolName, output: output, exitCode: exitCode
            ))
        case .mcpToolCall(let requestID, let toolName, let input):
            return .mcpToolCall(StreamEvent.MCPToolCallPayload(
                requestID: requestID, toolName: toolName, input: input
            ))
        case .result(let data):
            return .result(StreamEvent.ResultPayload(
                text: data.text, costUSD: data.costUSD, durationMs: data.durationMs,
                inputTokens: data.inputTokens, outputTokens: data.outputTokens,
                cacheCreationInputTokens: data.cacheCreationInputTokens,
                cacheReadInputTokens: data.cacheReadInputTokens,
                sessionID: data.sessionID,
                permissionDenials: data.permissionDenials.map {
                    StreamEvent.PermissionDenial(toolName: $0.toolName, detail: $0.detail)
                }
            ))
        case .unknown(let raw):
            return .unknown(raw)
        }
    }
}
