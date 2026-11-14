import Foundation
import Observation

/// The project's agents, and a conversation with any of them: send goes through
/// `POST /v1/agents/message` (delivered exactly as if typed on the Mac, and
/// answered at once), history through the transcript endpoint, then the chat
/// as it happens through `GET /v1/agents/events` — each reply growing in place
/// as it streams. A stream that fails falls back to reloading the transcript
/// every few seconds, and reopens from the last message it saw.
@Observable @MainActor
final class AgentsViewModel {
    var project = "kiteloop"
    var projects: [String] = []
    var agents: [AgentInfo] = []
    var error: String?

    // The open conversation.
    var chatAgent: AgentInfo?
    var transcript: [TranscriptMessage] = []
    var draft = ""
    /// A photo to go with the next message.
    var photo: PhotoAttachment?
    var sending = false
    /// Why the last send failed — kept apart from `error`, which every
    /// transcript poll resets, and cleared only by the next send.
    var sendFailure: String?
    /// Whether the chat is following the Mac live; false while the stream is
    /// down and the chat is reloading on a timer instead.
    var live = false
    /// The agent's working state as the stream last said it; nil before the
    /// first state event, when the agent list's state is all there is.
    var streamedWorking: Bool?
    /// The one-tap replies the Mac keeps; empty until a chat opens, or when
    /// they were cleared there.
    var quickReplies: [String] = []
    /// The subagents and background shells the open agent's session has
    /// running, as last read.
    var tasks: [AgentTaskInfo] = []
    private var pollTask: Task<Void, Never>?

    /// How many of the newest messages the chat holds and the stream watches.
    static let window = 80
    /// How long the chat waits between reloads while the stream is down.
    static let fallbackInterval: Duration = .seconds(3)

    func refresh(_ client: ControlClient) async {
        do {
            (projects, project) = try await client.projectsAndSelection(holding: project)
            agents = (try await client.get(client.query("/v1/agents", [("project", project)]), as: AgentsReply.self).agents) ?? []
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func open(_ client: ControlClient, agent: AgentInfo) {
        chatAgent = agent
        transcript = []
        streamedWorking = nil
        pollTask?.cancel()
        pollTask = Task {
            if let replies = try? await client.quickReplies() { quickReplies = replies }
            await loadTranscript(client)
            while !Task.isCancelled {
                await follow(client, agent: agent)
                // The stream ended or was refused: reload instead, then try it again.
                live = false
                guard !Task.isCancelled else { return }
                await loadTranscript(client)
                let transcriptFailure = error
                await refresh(client)
                // The agents poll's success must not wipe the transcript's failure.
                error = error ?? transcriptFailure
                try? await Task.sleep(for: Self.fallbackInterval)
            }
        }
    }

    func close() {
        pollTask?.cancel()
        pollTask = nil
        chatAgent = nil
        live = false
    }

    /// Reads the agent's event stream until it ends, applying each event.
    private func follow(_ client: ControlClient, agent: AgentInfo) async {
        let path = Self.streamPath(client, project: project, agent: agent.id, after: transcript.last?.id)
        do {
            for try await line in client.events(path) {
                guard let event = AgentEvent.decode(line) else { continue }
                live = true
                error = nil
                if let working = event.working { streamedWorking = working }
                transcript = Self.applying(event, to: transcript)
                LiveActivityController.shared.apply(event, agentID: agent.id)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The stream, reopened from the last message the chat holds so a
    /// reconnect replays only what it missed.
    static func streamPath(_ client: ControlClient, project: String, agent: String, after: String?) -> String {
        var params = [("project", project), ("agent", agent), ("limit", String(window))]
        if let after { params.append(("after", after)) }
        return client.query("/v1/agents/events", params)
    }

    /// A message event replaces the message with its id — a reply still
    /// streaming arrives again and again under one id — or appends a new one,
    /// keeping the newest `window`. A state event changes nothing here.
    static func applying(_ event: AgentEvent, to transcript: [TranscriptMessage]) -> [TranscriptMessage] {
        guard let message = event.message else { return transcript }
        var updated = transcript
        if let id = message.id, let index = updated.firstIndex(where: { $0.id == id }) {
            updated[index] = message
        } else {
            updated.append(message)
        }
        return Array(updated.suffix(window))
    }

    /// Hires an agent into the project, as summoning one on the Mac does. The
    /// model is the project's (else the Mac's default) when left empty.
    /// True when the hire went through; the list shows it at once.
    func hire(_ client: ControlClient, name: String, model: String) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        var body: [String: Any] = ["project": project, "name": name]
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty { body["model"] = model }
        do {
            let reply = try await client.post("/v1/agents", body)
            if let hired = Self.hiredAgent(reply), !agents.contains(where: { $0.id == hired.id }) {
                agents.append(hired)
            }
            error = nil
            return true
        } catch {
            self.error = NowViewModel.refusalText(error)
            return false
        }
    }

    /// The agent `POST /v1/agents` answers with, as the list shows one.
    static func hiredAgent(_ reply: [String: Any]) -> AgentInfo? {
        guard let id = reply["agentId"] as? String else { return nil }
        return AgentInfo(id: id, name: reply["name"] as? String, model: reply["model"] as? String, state: "idle")
    }

    /// What a tapped quick reply does: sent as it stands, or added to the
    /// draft — while the agent works, so sending queues it as a typed message
    /// would, and over text already typed, which it must not throw away.
    enum QuickReplyAction: Equatable {
        case send
        case draft(String)
    }

    nonisolated static func quickReplyAction(_ reply: String, draft: String, working: Bool) -> QuickReplyAction {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard working || !typed.isEmpty else { return .send }
        return .draft(typed.isEmpty ? reply : typed + " " + reply)
    }

    func useQuickReply(_ client: ControlClient, _ reply: String, working: Bool) async {
        switch Self.quickReplyAction(reply, draft: draft, working: working) {
        case .send:
            draft = reply
            await send(client)
        case .draft(let text):
            draft = text
        }
    }

    /// A fresh conversation: `/clear`, which the Mac's chat handles as if typed.
    func startNewConversation(_ client: ControlClient) async {
        draft = "/clear"
        await send(client)
        transcript = []
    }

    /// Stops the agent's turn. What the Mac had queued from you comes back
    /// into the draft, ahead of anything typed since.
    func interrupt(_ client: ControlClient) async {
        guard let agent = chatAgent else { return }
        do {
            let reply = try await client.post("/v1/agents/interrupt", ["project": project, "agent": agent.id])
            if let returned = reply["returned"] as? String, !returned.isEmpty {
                draft = [returned, draft].filter { !$0.isEmpty }.joined(separator: "\n\n")
            }
            sendFailure = nil
        } catch {
            sendFailure = error.localizedDescription
        }
    }

    /// Answers the plan card `messageID` as the Mac's card would: build in a
    /// mode, or keep planning with what should change.
    func answerPlan(_ client: ControlClient, messageID: String, answer: String, feedback: String = "") async {
        guard let agent = chatAgent else { return }
        var body: [String: Any] = ["project": project, "agent": agent.id, "message": messageID, "answer": answer]
        if !feedback.isEmpty { body["feedback"] = feedback }
        await post("/v1/agents/plan", body, client)
    }

    /// Answers the question the agent is waiting on.
    func answerQuestion(_ client: ControlClient, requestID: String, answer: String) async {
        guard let agent = chatAgent else { return }
        await post("/v1/agents/answer",
                   ["project": project, "agent": agent.id, "request": requestID, "answer": answer], client)
    }

    /// Answers a permission card as the Mac's would: `allow` this once,
    /// `deny`, or `always` — allow, and remember the card's offer at `always`.
    /// `edits` rewords the call's text fields by name; the call then runs as
    /// reworded.
    func answerPermission(_ client: ControlClient, requestID: String, answer: String, always: Int? = nil,
                          edits: [String: String] = [:]) async {
        guard let agent = chatAgent else { return }
        var body: [String: Any] = ["project": project, "agent": agent.id, "request": requestID, "answer": answer]
        if let always { body["always"] = always }
        if !edits.isEmpty { body["input"] = edits }
        await post("/v1/agents/permission", body, client)
    }

    /// Answers the model's own questions, one answer each.
    func answerChoices(_ client: ControlClient, requestID: String, answers: [String]) async {
        guard let agent = chatAgent else { return }
        await post("/v1/agents/choices",
                   ["project": project, "agent": agent.id, "request": requestID, "answers": answers], client)
    }

    /// Moves the open agent to a permission mode, as `/mode` does on the Mac;
    /// the list shows the new mode once the Mac has taken it.
    func setMode(_ client: ControlClient, mode: String) async {
        guard let agent = chatAgent else { return }
        do {
            let reply = try await client.post("/v1/agents/mode", ["project": project, "agent": agent.id, "mode": mode])
            let stored = reply["mode"] as? String ?? mode
            if let index = agents.firstIndex(where: { $0.id == agent.id }) { agents[index].mode = stored }
            chatAgent?.mode = stored
            sendFailure = nil
        } catch {
            sendFailure = NowViewModel.refusalText(error)
        }
    }

    /// Stops one running task of the open agent's session and leaves the
    /// rest of it going; the list is read again either way.
    func stopTask(_ client: ControlClient, taskID: String) async {
        guard let agent = chatAgent else { return }
        do {
            _ = try await client.post("/v1/agents/tasks/stop", ["project": project, "agent": agent.id, "task": taskID])
            sendFailure = nil
        } catch {
            sendFailure = NowViewModel.refusalText(error)
        }
        await loadTasks(client)
    }

    private func post(_ path: String, _ body: [String: Any], _ client: ControlClient) async {
        do {
            _ = try await client.post(path, body)
            sendFailure = nil
            if !live { await loadTranscript(client) }
        } catch {
            sendFailure = NowViewModel.refusalText(error)
        }
    }

    func send(_ client: ControlClient) async {
        guard let agent = chatAgent else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || photo != nil else { return }
        let photo = self.photo
        draft = ""
        self.photo = nil
        sendFailure = nil
        sending = true
        defer { sending = false }
        var body: [String: Any] = ["project": project, "agent": agent.id, "message": text]
        if let photo { body["attachments"] = [photo.body] }
        do {
            _ = try await client.post("/v1/agents/message", body)
            LiveActivityController.shared.start(agentID: agent.id, agentName: agent.name ?? agent.id,
                                                project: project, client: client)
            // Live, the message and the reply come over the stream; otherwise
            // reload now rather than at the next tick.
            if !live { await loadTranscript(client) }
        } catch {
            sendFailure = NowViewModel.refusalText(error)
            draft = text
            self.photo = photo
        }
    }


    // Last in the class, with `loadTranscript`: lizard reads `client.get(` as
    // a `get` accessor and counts every function after one into it.
    /// Reads what the open agent's session has running. A Mac that predates
    /// the endpoint answers an error; the list is then empty, not stale.
    func loadTasks(_ client: ControlClient) async {
        guard let agent = chatAgent else { return }
        let path = client.query("/v1/agents/tasks", [("project", project), ("agent", agent.id)])
        tasks = (try? await client.get(path, as: AgentTasksReply.self).tasks) ?? []
    }

    private func loadTranscript(_ client: ControlClient) async {
        guard let agent = chatAgent else { return }
        do {
            let reply = try await client.get(
                client.query("/v1/agents/transcript", [("project", project), ("agent", agent.id), ("limit", String(Self.window))]),
                as: TranscriptReply.self)
            transcript = reply.messages ?? []
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
