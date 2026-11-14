import Foundation

/// The CLI's permission prompts, as a session spawned with
/// `--permission-prompts host --permission-prompt-tool stdio` carries them on
/// its own stdout and stdin.
///
/// Where a terminal would stop and ask — before a command that changes
/// files, for a subagent's call, for the model's own question or its plan —
/// such a session writes a `control_request` of subtype `can_use_tool` and
/// waits, with no limit, for the `control_response` naming that request. An
/// interrupt takes the question back with a `control_cancel_request`.
/// Kiteloop is the host: this reads the two lines and writes the answers, and
/// the two requests Kiteloop itself makes of a session over the same channel.
package enum PermissionPrompt {

    /// What a session says about a prompt.
    package enum Line: Equatable, Sendable {
        /// The session is waiting on an answer to this.
        case request(Request)
        /// The session no longer wants the answer to the request with this id.
        case cancelled(requestID: String)
    }

    /// One question the session is waiting on.
    package struct Request: Equatable, Sendable {
        /// The id the answer must carry.
        package let id: String
        package let toolName: String
        /// The call's input, a JSON object as text — what an answer that
        /// allows the call hands back, changed or not.
        package let input: String
        /// The CLI's own line about the call; empty when it sent none.
        package let description: String
        /// The path the call was stopped over, when it was stopped over one.
        package let blockedPath: String?
        package let toolUseID: String?
        /// The task id of the subagent whose call this is; nil for the
        /// session's own agent.
        package let subagentTaskID: String?
        /// True for a call that is itself a question to the person — the
        /// model's `AskUserQuestion`, a plan offered with `ExitPlanMode` —
        /// rather than a call waiting on leave to run.
        package let needsAnswer: Bool
        /// What the CLI offers to remember so it need not ask again.
        package let suggestions: [Suggestion]

        package init(id: String, toolName: String, input: String, description: String = "",
                     blockedPath: String? = nil, toolUseID: String? = nil, subagentTaskID: String? = nil,
                     needsAnswer: Bool = false, suggestions: [Suggestion] = []) {
            self.id = id
            self.toolName = toolName
            self.input = input
            self.description = description
            self.blockedPath = blockedPath
            self.toolUseID = toolUseID
            self.subagentTaskID = subagentTaskID
            self.needsAnswer = needsAnswer
            self.suggestions = suggestions
        }
    }

    /// What a session is told when its call is refused — the CLI's own words
    /// for it, which stop the model and have it wait to be told how to go on,
    /// as a refusal in a terminal does.
    package static let declined = "The user doesn't want to proceed with this tool use. The tool use was rejected "
        + "(eg. if it was a file edit, the new_string was NOT written to the file). "
        + "STOP what you are doing and wait for the user to tell you how to proceed."

    /// What a session is told when its question lapsed unanswered because
    /// the session itself is going away.
    package static let lapsed = "The question was not answered."

    /// One thing the CLI offers to remember with an answer; kept with the
    /// card it was offered on, so the type lives with the message model.
    package typealias Suggestion = PermissionSuggestion

    /// The answer to a request.
    package enum Decision: Equatable, Sendable {
        /// Run the call with `input` — a JSON object as text — and remember
        /// each of `remembering`, the `json` of suggestions taken.
        case allow(input: String, remembering: [String] = [])
        /// Do not run it; `message` is what the model is told.
        case deny(message: String)
    }

    /// Whether a session a person attends, in permission mode `mode`, asks
    /// before the tools its agent lists. The three modes that promise to ask
    /// — Ask, Accept Edits, Plan — do, so such a session is spawned with none
    /// of the agent's built-in tools approved ahead of time and the CLI asks
    /// as its mode says. Auto, Don't Ask and Bypass keep the list approved:
    /// in them nothing is promised a question.
    package static func asksBeforeListedTools(mode: String) -> Bool {
        ["default", "acceptEdits", "plan"].contains(mode)
    }

    /// The settings, as the JSON `--settings` takes, under which a session
    /// asks before every call matching one of `rules`.
    package static func askRulesSettings(_ rules: [String]) -> String {
        text(of: ["permissions": ["ask": rules]])
    }

    // MARK: - Reading

    /// What the call would do, as the thing a person decides on: the command
    /// itself rather than the model's description of it, the file, the
    /// address — else the CLI's line about it, else the tool's name.
    package static func summary(of request: Request) -> String {
        if let subject = subject(ofInput: request.input) { return subject.value }
        return request.description.isEmpty ? request.toolName : request.description
    }

    /// The field of a call's input that says what it would do, and its value;
    /// nil for an input with none of the fields that do.
    package static func subject(ofInput input: String) -> (field: String, value: String)? {
        let fields = object(from: input)
        for key in ["command", "file_path", "notebook_path", "url", "query", "pattern"] {
            if let value = fields[key] as? String, !value.isEmpty { return (key, value) }
        }
        return nil
    }

    /// The prompt line `jsonLine` is, or nil for every other line a session
    /// writes — which is nearly all of them, so the text is checked before it
    /// is parsed.
    package static func line(_ jsonLine: String) -> Line? {
        guard jsonLine.contains("\"control_"),
              let data = jsonLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let requestID = json["request_id"] as? String else { return nil }
        switch json["type"] as? String {
        case "control_cancel_request":
            return .cancelled(requestID: requestID)
        case "control_request":
            return request(id: requestID, body: json["request"] as? [String: Any] ?? [:]).map(Line.request)
        default:
            return nil
        }
    }

    private static func request(id: String, body: [String: Any]) -> Request? {
        guard body["subtype"] as? String == "can_use_tool", let toolName = body["tool_name"] as? String else { return nil }
        let offers = body["permission_suggestions"] as? [[String: Any]] ?? []
        return Request(
            id: id, toolName: toolName,
            input: text(of: body["input"] as? [String: Any] ?? [:]),
            description: body["description"] as? String ?? "",
            blockedPath: body["blocked_path"] as? String,
            toolUseID: body["tool_use_id"] as? String,
            subagentTaskID: body["agent_id"] as? String,
            needsAnswer: body["requires_user_interaction"] as? Bool ?? false,
            suggestions: offers.compactMap(suggestion)
        )
    }

    /// An offer with the words for it; nil for a kind of offer this cannot
    /// put into words, which is then not made.
    private static func suggestion(_ offer: [String: Any]) -> Suggestion? {
        guard let label = label(for: offer) else { return nil }
        return Suggestion(label: label, json: text(of: offer))
    }

    private static func label(for offer: [String: Any]) -> String? {
        let scope = scopeWords(offer["destination"] as? String)
        switch offer["type"] as? String {
        case "addRules":
            guard offer["behavior"] as? String == "allow" else { return nil }
            let rules = (offer["rules"] as? [[String: Any]] ?? []).compactMap(ruleWords)
            return rules.isEmpty ? nil : "Always allow \(rules.joined(separator: ", ")) \(scope)"
        case "addDirectories":
            let directories = offer["directories"] as? [String] ?? []
            return directories.isEmpty ? nil : "Allow work in \(directories.joined(separator: ", ")) \(scope)"
        case "setMode":
            return (offer["mode"] as? String).map { "Switch to \(SettingNames.permissionMode($0)) \(scope)" }
        default:
            return nil
        }
    }

    /// A rule the way the CLI's own settings spell one: `Bash(git status)`,
    /// or the tool's name alone for a rule about every call of it.
    private static func ruleWords(_ rule: [String: Any]) -> String? {
        guard let tool = rule["toolName"] as? String else { return nil }
        guard let content = rule["ruleContent"] as? String, !content.isEmpty else { return tool }
        return "\(tool)(\(content))"
    }

    /// Where the CLI would keep what is remembered.
    private static func scopeWords(_ destination: String?) -> String {
        switch destination {
        case "localSettings", "projectSettings": return "in this project"
        case "userSettings": return "in every project"
        default: return "for this session"
        }
    }

    // MARK: - Writing

    /// The line that answers request `requestID`, newline included.
    package static func response(requestID: String, decision: Decision) -> String {
        let answer: [String: Any]
        switch decision {
        case .allow(let input, let remembering):
            var allowed: [String: Any] = ["behavior": "allow", "updatedInput": object(from: input)]
            if !remembering.isEmpty { allowed["updatedPermissions"] = remembering.map(object) }
            answer = allowed
        case .deny(let message):
            answer = ["behavior": "deny", "message": message]
        }
        return text(of: ["type": "control_response",
                         "response": ["subtype": "success", "request_id": requestID, "response": answer]]) + "\n"
    }

    /// The line that moves a running session to permission mode `mode`.
    package static func setMode(_ mode: String, requestID: String) -> String {
        hostRequest(["subtype": "set_permission_mode", "mode": mode], requestID: requestID)
    }

    /// The line that stops one task of a session — a subagent or a background
    /// shell — and leaves the rest of it running.
    package static func stopTask(_ taskID: String, requestID: String) -> String {
        hostRequest(["subtype": "stop_task", "task_id": taskID], requestID: requestID)
    }

    private static func hostRequest(_ request: [String: Any], requestID: String) -> String {
        text(of: ["type": "control_request", "request_id": requestID, "request": request]) + "\n"
    }

    // MARK: - JSON

    static func text(of object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func object(from text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
    }
}
