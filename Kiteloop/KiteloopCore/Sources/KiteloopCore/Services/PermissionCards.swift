import Foundation

/// The cards a session's prompts open in its chat, and the answer each card
/// sends back (`PermissionPrompt`).
///
/// A prompt is one of three things, told apart by the tool it is about: a
/// call waiting on leave to run, the model's own questions with the choices
/// it offers (`AskUserQuestion`), or a plan offered for approval
/// (`ExitPlanMode`). Each becomes a message; answering one marks the message
/// and yields the decision the session is waiting on. A card is open until it
/// is answered or lapses, and only an open card yields a decision — so a
/// second answer, from the Mac or a phone, is nothing.
package enum PermissionCards {
    package static let questionTool = "AskUserQuestion"
    package static let planTool = "ExitPlanMode"

    // MARK: - Opening

    /// The card `request` opens. `subagent` is the task of the subagent whose
    /// call it is, in the words it was given; nil for the agent's own.
    package static func card(for request: PermissionPrompt.Request, subagent: String?, agentID: String) -> Message {
        Message(id: UUID(), timestamp: .now, sender: .agent(agentID),
                content: content(for: request, subagent: subagent))
    }

    private static func content(for request: PermissionPrompt.Request, subagent: String?) -> Message.Content {
        let input = PermissionPrompt.object(from: request.input)
        switch request.toolName {
        case questionTool:
            return .choices(Message.ChoiceQuestion(id: request.id, input: request.input,
                                                   questions: questions(in: input)))
        case planTool:
            return .plan(Message.PlanProposal(text: input["plan"] as? String ?? "", requestID: request.id,
                                              requestInput: request.input))
        default:
            return .permission(Message.PermissionRequest(
                id: request.id, toolName: request.toolName, input: request.input,
                summary: PermissionPrompt.summary(of: request), subagent: subagent,
                suggestions: request.suggestions))
        }
    }

    private static func questions(in input: [String: Any]) -> [Message.ChoiceQuestion.Question] {
        (input["questions"] as? [[String: Any]] ?? []).map { asked in
            let options = (asked["options"] as? [[String: Any]] ?? []).map {
                Message.ChoiceQuestion.Option(label: $0["label"] as? String ?? "",
                                              description: $0["description"] as? String ?? "")
            }
            return Message.ChoiceQuestion.Question(
                question: asked["question"] as? String ?? "", header: asked["header"] as? String ?? "",
                options: options, multiSelect: asked["multiSelect"] as? Bool ?? false)
        }
    }

    /// What the notice for a card says — a title naming the agent, and the
    /// question — or nil for a message that is no such card.
    package static func notice(for content: Message.Content, agentName: String) -> (title: String, body: String)? {
        switch content {
        case .permission(let request):
            return ("\(agentName) asks to use \(request.toolName)", request.question)
        case .choices(let asked):
            return ("\(agentName) needs input", asked.text)
        case .plan(let plan):
            let firstLine = plan.text.split(whereSeparator: \.isNewline)
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return ("\(agentName) has a plan ready for approval", firstLine.map(String.init) ?? plan.text)
        default:
            return nil
        }
    }

    // MARK: - What is open

    /// The request ids of every card still waiting, oldest first.
    package static func openRequestIDs(in messages: [Message]) -> [String] {
        messages.compactMap { openRequestID(of: $0.content) }
    }

    private static func openRequestID(of content: Message.Content) -> String? {
        switch content {
        case .permission(let request): return request.answer == nil ? request.id : nil
        case .choices(let asked): return asked.isOpen ? asked.id : nil
        case .plan(let plan): return plan.answer == nil ? plan.requestID : nil
        default: return nil
        }
    }

    private static func index(ofOpen requestID: String, in messages: [Message]) -> Int? {
        messages.lastIndex { openRequestID(of: $0.content) == requestID }
    }

    // MARK: - Answering a call

    /// Allows the call on the open card `requestID`, remembering the
    /// suggestion at `remembering` when one is named, and with `edits` put
    /// over the fields of its input they name — the person's own wording of
    /// a command or a message, which is then what runs. Nil — and nothing
    /// changed — when no such card is open, it offers no such suggestion, or
    /// an edit names something that is not one of the call's text fields.
    package static func allow(_ requestID: String, remembering: Int? = nil, edits: [String: String] = [:],
                              in messages: inout [Message]) -> PermissionPrompt.Decision? {
        guard let at = index(ofOpen: requestID, in: messages),
              case .permission(var request) = messages[at].content,
              let input = edited(request.input, with: edits) else { return nil }
        var remembered: [String] = []
        if let remembering {
            guard request.suggestions.indices.contains(remembering) else { return nil }
            remembered = [request.suggestions[remembering].json]
        }
        request.answer = remembered.isEmpty ? .allowed : .allowedAlways
        request.sent = input == request.input ? nil : input
        messages[at].content = .permission(request)
        return .allow(input: input, remembering: remembered)
    }

    /// What the agent is told after a call of its was allowed reworded: the
    /// change. The call's own result says nothing of the change, and
    /// an agent left to assume would report what it asked for. Nil for a card
    /// that was not answered that way.
    package static func rewordingNote(for requestID: String, in messages: [Message]) -> String? {
        for message in messages.reversed() {
            guard case .permission(let request) = message.content, request.id == requestID else { continue }
            guard let sent = request.sent else { return nil }
            // Only what was changed: the rest of the call ran as asked.
            let asked = editableFields(ofInput: request.input)
            let changed = editableFields(ofInput: sent).filter { !asked.contains($0) }
            return "I changed your \(request.toolName) call before allowing it. It ran with:\n\n"
                + changed.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
        }
        return nil
    }

    /// One text field of a call's input, as a person may reword it.
    package struct EditableField: Equatable, Sendable {
        package let name: String
        package let value: String
    }

    /// The fields of a call a person may reword before allowing it: the text
    /// values at the top of its input, the one that says what the call does
    /// first. Numbers, flags and nested values are the call's own.
    package static func editableFields(ofInput input: String) -> [EditableField] {
        let fields = PermissionPrompt.object(from: input).compactMapValues { $0 as? String }
        let subject = PermissionPrompt.subject(ofInput: input)?.field
        let names = fields.keys.sorted { ($0 != subject ? 1 : 0, $0) < ($1 != subject ? 1 : 0, $1) }
        return names.map { EditableField(name: $0, value: fields[$0] ?? "") }
    }

    /// `input` with `edits` over its text fields; nil when an edit names a
    /// field the input does not hold as text.
    private static func edited(_ input: String, with edits: [String: String]) -> String? {
        guard !edits.isEmpty else { return input }
        var fields = PermissionPrompt.object(from: input)
        for (name, value) in edits {
            guard fields[name] is String else { return nil }
            fields[name] = value
        }
        return PermissionPrompt.text(of: fields)
    }

    /// Refuses the call on the open card `requestID`. Nil when none is open.
    package static func deny(_ requestID: String, in messages: inout [Message]) -> PermissionPrompt.Decision? {
        guard let at = index(ofOpen: requestID, in: messages),
              case .permission(var request) = messages[at].content else { return nil }
        request.answer = .denied
        messages[at].content = .permission(request)
        return .deny(message: PermissionPrompt.declined)
    }

    // MARK: - Answering the model's questions

    /// Answers the open questions card `requestID` — one answer per question,
    /// in order, each a choice's label, several joined with ", ", or words of
    /// the person's own. Nil when no such card is open, or the answers do not
    /// number the questions, or one is blank.
    package static func answer(_ requestID: String, with answers: [String],
                               in messages: inout [Message]) -> PermissionPrompt.Decision? {
        guard let at = index(ofOpen: requestID, in: messages),
              case .choices(var asked) = messages[at].content,
              answers.count == asked.questions.count,
              !answers.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
        asked.answers = answers
        messages[at].content = .choices(asked)
        var input = PermissionPrompt.object(from: asked.input)
        input["answers"] = Dictionary(zip(asked.questions.map(\.question), answers), uniquingKeysWith: { first, _ in first })
        return .allow(input: PermissionPrompt.text(of: input))
    }

    // MARK: - Answering a plan

    /// Answers the open plan card `messageID` when the plan came with a
    /// request: approving allows it and moves the session to the answer's
    /// mode; Keep planning refuses it with `feedback`, or with the plain
    /// refusal when there is none. Nil — and nothing changed — for a plan
    /// that came with no request, which is answered the older way.
    package static func answerPlan(_ messageID: UUID, with answer: Message.PlanProposal.Answer, feedback: String,
                                   in messages: inout [Message]) -> (requestID: String, decision: PermissionPrompt.Decision)? {
        guard let at = messages.firstIndex(where: { $0.id == messageID }),
              case .plan(var plan) = messages[at].content, plan.answer == nil,
              let requestID = plan.requestID else { return nil }
        plan.answer = answer
        messages[at].content = .plan(plan)
        guard let mode = answer.permissionMode else {
            return (requestID, .deny(message: feedback.isEmpty ? PermissionPrompt.declined : feedback))
        }
        let setMode = PermissionPrompt.text(of: ["type": "setMode", "mode": mode, "destination": "session"])
        let input = plan.requestInput ?? PermissionPrompt.text(of: ["plan": plan.text])
        return (requestID, .allow(input: input, remembering: [setMode]))
    }

    // MARK: - Refusals the person made

    /// Whether a call the session reports as refused — `toolName`, pointed at
    /// `detail` — is one a card in `messages` refused: denied on it, or
    /// taken back from it. Such a refusal was the person's own and needs no
    /// second line saying permission was denied.
    package static func wasRefusedOnACard(toolName: String, detail: String, in messages: some Sequence<Message>) -> Bool {
        messages.contains { message in
            guard case .permission(let request) = message.content, request.toolName == toolName,
                  request.answer == .denied || request.answer == .lapsed else { return false }
            return detail.isEmpty || request.summary == detail
        }
    }

    // MARK: - Lapsing

    /// Closes the open card `requestID` unanswered — the session took the
    /// question back — or, given nil, every open card: the session they were
    /// asked from is gone. A plan lapses as Keep planning. True when anything
    /// changed.
    @discardableResult
    package static func lapse(_ requestID: String? = nil, in messages: inout [Message]) -> Bool {
        var changed = false
        for at in messages.indices {
            guard let open = openRequestID(of: messages[at].content), requestID == nil || requestID == open else { continue }
            messages[at].content = lapsed(messages[at].content)
            changed = true
        }
        return changed
    }

    private static func lapsed(_ content: Message.Content) -> Message.Content {
        switch content {
        case .permission(var request):
            request.answer = .lapsed
            return .permission(request)
        case .choices(var asked):
            asked.lapsed = true
            return .choices(asked)
        case .plan(var plan):
            plan.answer = .keepPlanning
            return .plan(plan)
        default:
            return content
        }
    }
}
