import Foundation
import KiteloopCore

enum StreamEvent: @unchecked Sendable {
    /// A line the session writes about itself. Besides the CLI's own `system`
    /// lines this carries its top-level `rate_limit_event`, under that name as
    /// the subtype: both are notices about the session rather than content,
    /// and `AgentActivityEvent` reads the ones about subagents, background
    /// tasks, thinking and the rate limit.
    case system(subtype: String, payload: [String: Any])
    /// A thought and a run of prose. `parentToolUseID` is, as on `toolUse`,
    /// the `Agent`/`Task` call whose subagent said it — nil for the agent's
    /// own. The CLI forwards a subagent's text and thinking only when spawned
    /// with `--forward-subagent-text`, and every consumer that sums
    /// `.assistantText` into an answer takes only the ones with no parent.
    case thinking(String, parentToolUseID: String? = nil)
    case assistantText(String, parentToolUseID: String? = nil)
    /// `parentToolUseID` is the `Agent`/`Task` call whose subagent made this
    /// call — nil for the agent's own. The CLI streams a subagent's tool
    /// traffic on the same stdout, told apart only by that id.
    case toolUse(id: String, name: String, input: String, parentToolUseID: String? = nil)
    case toolResult(id: String, output: String, parentToolUseID: String? = nil)
    case image(base64Data: String, mimeType: String)
    case hook(HookPayload)
    case mcpToolCall(MCPToolCallPayload)
    case result(ResultPayload)
    case unknown(String)

    struct HookPayload {
        let hookType: String
        let hookName: String
        let toolName: String
        let output: String
        let exitCode: Int
    }

    struct MCPToolCallPayload {
        let requestID: String
        let toolName: String
        let input: String
    }

    struct ResultPayload {
        let text: String
        let costUSD: Double
        let durationMs: Int
        let inputTokens: Int
        let outputTokens: Int
        let cacheCreationInputTokens: Int
        let cacheReadInputTokens: Int
        let sessionID: String
        let permissionDenials: [PermissionDenial]
        /// What the **first model call** of this leg was sent — the opening
        /// context, before the agent had read a file or called a tool.
        ///
        /// The counters above are the whole leg's: one `result` covers up to
        /// fifty model calls with every tool result folded in, so they cannot
        /// say what the run's opening prompt cost. This one can, and it is the
        /// only place the distinction exists — the CLI reports per-call usage on
        /// its `assistant` lines and nowhere else.
        ///
        /// Nil when no `assistant` line carried a `usage` block, which is what a
        /// non-Claude runtime and a leg that died before its first reply both
        /// look like. Never zero: a leg nobody measured is not a leg that was
        /// sent nothing.
        var openingUsage: TokenUsage?
        /// How the CLI says the leg ended — `success`, or an `error_…` subtype
        /// such as `error_max_turns`. Nil for a runtime that reports none.
        var subtype: String?
        /// The turns the leg took, as the CLI counted them (`num_turns`). Nil
        /// when the line carried no count — not zero turns.
        var numTurns: Int?
        /// Each model's context window as the CLI measured the leg against it
        /// (`modelUsage.<model>.contextWindow`), keyed by model id. Empty when
        /// the line carried none — a runtime that reports no window.
        var contextWindows: [String: Int] = [:]

        /// The window of `model`, the session's own: its entry, matched with
        /// a bracketed variant such as `[1m]` dropped, or the only entry when
        /// there is just one. Nil when the leg named several and none is
        /// `model` — a subagent's window is not the session's.
        func contextWindow(for model: String) -> Int? {
            let bare = model.split(separator: "[", maxSplits: 1).first.map(String.init) ?? model
            if let window = contextWindows[model] ?? contextWindows[bare] { return window }
            return contextWindows.count == 1 ? contextWindows.values.first : nil
        }

        /// Whether the session's own `--max-turns` is what ended the leg: the
        /// agent stopped because it ran out of turns, not because it finished.
        var endedOnTurnCap: Bool { subtype == Self.turnCapSubtype }

        static let turnCapSubtype = "error_max_turns"
        /// Where a workflow node's completion carries `numTurns`, beside
        /// `RunClosingMessage.outputKey` and underscore-prefixed like it.
        static let turnsOutputKey = "_sessionTurns"
        /// Where it carries `endedOnTurnCap`, present only when true.
        static let turnCapOutputKey = "_sessionEndedOnTurnCap"
    }

    struct PermissionDenial {
        let toolName: String
        let detail: String
    }

    /// The `usage` block the CLI puts on an `assistant` line — one model call's
    /// own counters, which is the granularity `result` throws away.
    ///
    /// Read beside `parse` rather than through it: one line yields exactly one
    /// `StreamEvent`, and an assistant line already yields the content block it
    /// carries. The cheap `contains` guard is there because this runs over every
    /// line of every agent's stream and most of them have no usage to find.
    ///
    /// Nil for any line that is not an assistant message with a usage block, and
    /// for one whose counters are all zero — a usage nobody filled in says
    /// nothing, and reporting it as an opening context of 0 would.
    static func assistantUsage(inLine jsonLine: String) -> TokenUsage? {
        guard jsonLine.contains("\"usage\""),
              let data = jsonLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "assistant",
              let message = json["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return nil }
        let counters = TokenUsage(
            inputTokens: usage["input_tokens"] as? Int ?? 0,
            outputTokens: usage["output_tokens"] as? Int ?? 0,
            cacheCreationTokens: usage["cache_creation_input_tokens"] as? Int ?? 0,
            cacheReadTokens: usage["cache_read_input_tokens"] as? Int ?? 0
        )
        return counters.isEmpty ? nil : counters
    }

    /// `payload` with the result line's own account of how the leg ended —
    /// its subtype and turn count — and the context windows it measured. Read beside `parse`'s `result` arm rather
    /// than in it, which is already at its complexity baseline.
    static func withEnding(_ payload: ResultPayload, from json: [String: Any]) -> ResultPayload {
        var payload = payload
        payload.subtype = json["subtype"] as? String
        payload.numTurns = json["num_turns"] as? Int
        let usageByModel = json["modelUsage"] as? [String: [String: Any]] ?? [:]
        payload.contextWindows = usageByModel.compactMapValues { $0["contextWindow"] as? Int }.filter { $0.value > 0 }
        return payload
    }

    static func parse(_ jsonLine: String) throws -> StreamEvent {
        guard let data = jsonLine.data(using: .utf8) else {
            throw StreamEventError.invalidEncoding
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StreamEventError.invalidJSON
        }

        guard let type = json["type"] as? String else {
            throw StreamEventError.missingType
        }

        switch type {
        case "system":
            let subtype = json["subtype"] as? String ?? ""
            return .system(subtype: subtype, payload: json)

        case "assistant":
            return try assistantEvent(json)

        case "user":
            return userEvent(json)

        case AgentActivityEvent.rateLimitType:
            return .system(subtype: type, payload: json)

        case "hook":
            let hookType = json["hook_type"] as? String ?? ""
            let hookName = json["hook_name"] as? String ?? ""
            let toolName = json["tool_name"] as? String ?? ""
            let output = json["output"] as? String ?? ""
            let exitCode = json["exit_code"] as? Int ?? 0
            return .hook(HookPayload(
                hookType: hookType,
                hookName: hookName,
                toolName: toolName,
                output: output,
                exitCode: exitCode
            ))

        case "result":
            let text = json["result"] as? String ?? ""
            let cost = json["total_cost_usd"] as? Double ?? 0
            let duration = (json["duration_ms"] as? Int) ?? Int(json["duration_ms"] as? Double ?? 0)
            let usage = json["usage"] as? [String: Any] ?? [:]
            let inputTokens = usage["input_tokens"] as? Int ?? 0
            let outputTokens = usage["output_tokens"] as? Int ?? 0
            let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
            let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
            let sessionID = json["session_id"] as? String ?? ""
            let denials = (json["permission_denials"] as? [[String: Any]] ?? []).map { denial in
                let toolName = denial["tool_name"] as? String ?? ""
                let input = denial["tool_input"] as? [String: Any] ?? [:]
                let detail = (input["command"] as? String)
                    ?? (input["file_path"] as? String)
                    ?? ""
                return PermissionDenial(toolName: toolName, detail: detail)
            }
            return .result(withEnding(ResultPayload(
                text: text,
                costUSD: cost,
                durationMs: duration,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheCreationInputTokens: cacheCreation,
                cacheReadInputTokens: cacheRead,
                sessionID: sessionID,
                permissionDenials: denials
            ), from: json))

        default:
            return .unknown(type)
        }
    }
}

// MARK: - Content lines

extension StreamEvent {
    /// An `assistant` line's first block the chat shows, tagged with the
    /// subagent call it came from. `.unknown` when it carries none.
    static func assistantEvent(_ json: [String: Any]) throws -> StreamEvent {
        let parent = StreamLineage.parentToolUseID(in: json)
        for block in contentBlocks(of: json) {
            if let event = try assistantBlock(block, parent: parent) { return event }
        }
        return .unknown("assistant")
    }

    /// A `user` line's tool result — the only thing on one the chat reads.
    static func userEvent(_ json: [String: Any]) -> StreamEvent {
        let parent = StreamLineage.parentToolUseID(in: json)
        guard let block = contentBlocks(of: json).first(where: { $0["type"] as? String == "tool_result" }) else {
            return .unknown("user")
        }
        return .toolResult(id: block["tool_use_id"] as? String ?? "",
                           output: toolResultOutput(block["content"]),
                           parentToolUseID: parent)
    }

    private static func contentBlocks(of json: [String: Any]) -> [[String: Any]] {
        (json["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
    }

    private static func assistantBlock(_ block: [String: Any], parent: String?) throws -> StreamEvent? {
        switch block["type"] as? String ?? "" {
        case "image":
            guard let source = block["source"] as? [String: Any],
                  let mediaType = source["media_type"] as? String,
                  let base64String = source["data"] as? String else { return nil }
            return .image(base64Data: base64String, mimeType: mediaType)
        case "thinking":
            return (block["thinking"] as? String).map { .thinking($0, parentToolUseID: parent) }
        case "text":
            return (block["text"] as? String).map { .assistantText($0, parentToolUseID: parent) }
        case "tool_use":
            return .toolUse(id: block["id"] as? String ?? "", name: block["name"] as? String ?? "",
                            input: try toolInputJSON(block["input"]), parentToolUseID: parent)
        default:
            return nil
        }
    }

    private static func toolInputJSON(_ input: Any?) throws -> String {
        guard let input else { return "{}" }
        let data = try JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func toolResultOutput(_ content: Any?) -> String {
        if let text = content as? String { return text }
        let blocks = content as? [[String: Any]] ?? []
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
}

enum StreamEventError: LocalizedError {
    case invalidEncoding
    case invalidJSON
    case missingType

    var errorDescription: String? {
        switch self {
        case .invalidEncoding: return "Line is not valid UTF-8"
        case .invalidJSON: return "Line is not valid JSON"
        case .missingType: return "JSON missing 'type' field"
        }
    }
}
