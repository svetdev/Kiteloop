import Foundation

/// A chat flattened to what a phone renders, and what changed in it since a
/// client last looked. `GET /v1/agents/transcript` answers the newest messages
/// of it; `GET /v1/agents/events` sends a message again each time it changes —
/// a reply growing as it streams, a tool call landing.
package enum AgentTranscript {

    /// A chat message flattened to what a phone renders: sender, kind, text.
    /// Tool traffic collapses to the tool's name and one line of what it was
    /// pointed at (`ToolCallSummary`) — the phone reads the conversation, not
    /// the machinery, but "Bash" ten times over says nothing.
    package static func message(_ msg: Message) -> [String: Any]? {
        guard let (kind, text) = kindAndText(msg.content), !text.isEmpty else { return nil }
        var flat: [String: Any] = ["id": msg.id.uuidString, "sender": senderName(msg.sender), "kind": kind,
                                   "text": text, "at": ISO8601DateFormatter().string(from: msg.timestamp)]
        if let (key, state) = answerState(msg.content) { flat[key] = state }
        if case .toolCall(let call) = msg.content, let path = ToolCallSummary.filePath(name: call.name, input: call.input) {
            flat["path"] = path
        }
        return flat
    }

    /// What a card the phone can answer carries beside its text: a plan's
    /// answer once chosen, a question's request id and whether it still waits.
    /// A question the session has moved past reads as open until answered on
    /// the Mac; the answer endpoint refuses it, so the phone learns then.
    private static func answerState(_ content: Message.Content) -> (String, [String: Any])? {
        switch content {
        case .plan(let plan):
            var state: [String: Any] = ["open": plan.answer == nil]
            if let answer = plan.answer { state["answer"] = answer.rawValue }
            return ("plan", state)
        case .approval(let request) where request.tool == "ask_human":
            return ("question", ["request": request.id, "open": request.status == .pending])
        default:
            return nil
        }
    }

    private static func senderName(_ sender: Message.Sender) -> String {
        switch sender {
        case .human: return "you"
        case .agent(let name): return name
        case .system: return "system"
        }
    }

    /// The kind a phone renders and its one line of text, or nil for what the
    /// transcript leaves out.
    private static func kindAndText(_ content: Message.Content) -> (String, String)? {
        switch content {
        case .text(let t): return ("text", t)
        case .thinking(let t): return ("thinking", t)
        case .toolCall(let call): return ("tool", ToolCallSummary.line(name: call.name, input: call.input))
        default: return noteText(content)
        }
    }

    /// What is not the conversation itself but still reads on a phone: an
    /// error, a system note, or a card it can answer.
    private static func noteText(_ content: Message.Content) -> (String, String)? {
        switch content {
        case .error(let e): return ("error", e)
        case .systemEvent(let event): return ("system", event.detail)
        case .plan, .approval: return cardText(content)
        case .toolResult, .mcpAuthRequest, .image, .text, .thinking, .toolCall: return nil
        }
    }

    /// A card the phone can answer: a plan, or a question an agent asked.
    /// An approval for any other tool is left out.
    private static func cardText(_ content: Message.Content) -> (String, String)? {
        switch content {
        case .plan(let plan): return ("plan", plan.text)
        case .approval(let request) where request.tool == "ask_human": return ("question", request.action)
        default: return nil
        }
    }

    /// The flattened tail a transcript read answers: the newest `limit`
    /// messages that flatten to anything, oldest first.
    package static func tail(of messages: [Message], limit: Int) -> [[String: Any]] {
        Array(messages.compactMap(message).suffix(max(0, limit)))
    }

    /// What one event stream has already sent, so each change goes out once.
    ///
    /// A message is sent again whenever what it flattens to changes — the text
    /// of a reply still streaming, most often. Messages are compared by what
    /// they flatten to rather than by their stored content, so a change the
    /// phone cannot see (a tool's result filling in) sends nothing.
    package struct Tracker {
        private var sent: [UUID: String] = [:]

        /// `after` is the last message the client already holds. Nil means the
        /// client starts from now: everything present counts as sent. An id
        /// the chat does not hold — a message the window has scrolled past, or
        /// one from another chat — sends the whole window again, so a client
        /// that reconnects late replaces rather than misses.
        package init(messages: [Message], after: UUID?) {
            let alreadySent: ArraySlice<Message>
            if let after {
                guard let index = messages.firstIndex(where: { $0.id == after }) else { return }
                alreadySent = messages[...index]
            } else {
                alreadySent = messages[...]
            }
            for msg in alreadySent { sent[msg.id] = Self.signature(msg) }
        }

        /// The messages in `messages` that are new or changed since the last
        /// call, flattened, oldest first.
        package mutating func changes(in messages: [Message]) -> [[String: Any]] {
            var changed: [[String: Any]] = []
            for msg in messages {
                let signature = Self.signature(msg)
                guard sent[msg.id] != signature else { continue }
                sent[msg.id] = signature
                if let flat = AgentTranscript.message(msg) { changed.append(flat) }
            }
            return changed
        }

        private static func signature(_ msg: Message) -> String {
            guard let flat = AgentTranscript.message(msg),
                  let data = try? JSONSerialization.data(withJSONObject: flat, options: [.sortedKeys]) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
