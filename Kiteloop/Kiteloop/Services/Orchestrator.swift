import Foundation
import KiteloopCore
import Combine
import os.log

private let msgLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "message-agent")
private let resumeLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "workflow-resume")
private let workflowEventLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "workflow-event")

extension Notification {
    /// Where an `.agentSummoned` post carries the files the summoning message
    /// was sent with; absent from an aside, which opens with none.
    static let summonedAttachmentsKey = "attachments"
}

extension Notification.Name {
    static let agentTriggered = Notification.Name("agentTriggered")
    static let agentHired = Notification.Name("agentHired")
    static let agentFired = Notification.Name("agentFired")
    static let agentSummoned = Notification.Name("agentSummoned")
    static let crossAgentMessageCompleted = Notification.Name("crossAgentMessageCompleted")
    static let teamConfigFileChanged = Notification.Name("teamConfigFileChanged")
    static let showSetupWizard = Notification.Name("showSetupWizard")
    /// A gate's banner was clicked; the object is its `BannerDestination`.
    static let openBannerDestination = Notification.Name("openBannerDestination")
}

@Observable
@MainActor
class Orchestrator {
    private let runtimeRegistry: RuntimeRegistry
    let eventBus: EventBus
    private let subscriptionEngine: SubscriptionEngine
    let memoryManager: MemoryManager
    let skillRegistry: SkillRegistry
    private let contextEngine: ContextEngine
    /// Internal rather than private so `Orchestrator+UnpromptedTurns.swift`
    /// can install a session and watch it: this file's line count is held by
    /// the complexity ratchet.
    var sessions: [String: ManagedSession] = [:]
    private(set) var agents: [Agent] = []
    /// Settable beyond this file only for `beginUnpromptedTurn`.
    var isStreaming = false
    private(set) var workflowEventBridge: WorkflowEventBridge?
    let workflowEngine: WorkflowEngine
    let a2aRegistry = A2ARegistry()
    private(set) var knowledgeRecallService: KnowledgeRecallService?
    private(set) var agentCardService: AgentCardService?
    private(set) var workflowResumeService: WorkflowResumeService?
    var incompleteExecutions: [IncompleteExecution] = []
    var lastResumeReport: ResumeReport?
    private(set) var workflowApprovalBridge: WorkflowApprovalBridge?
    private(set) var pendingWorkflowApprovals: [PendingApproval] = []
    private var approvalCancellable: AnyCancellable?
    private(set) var traceStore: TraceStore?
    private(set) var runTranscriptStore: RunTranscriptStore?
    /// Agents currently driven by unattended autopilot — their sessions run in
    /// Claude Code's auto mode, whose classifier decides each tool call (within
    /// their declared tools; workflow file-scope still enforced), since no one is
    /// there to answer a prompt.
    private(set) var unattendedAgentIDs: Set<String> = []
    /// Agents with no live session — stopped from the sidebar, or never
    /// started. Read off `sessions`, so it cannot drift from `hasSession`.
    var stoppedAgentIDs: Set<String> {
        Set(agents.map(\.id).filter { sessions[$0] == nil })
    }
    private(set) var notificationStore: NotificationStore?
    /// See `PendingAgentLaunchTracker`; accessors in `Orchestrator+PendingAgentLaunch.swift`.
    let pendingAgentLaunches = PendingAgentLaunchTracker()
    /// Who is waiting on an `ask_human` answer; every agent state set here goes
    /// through it. See `Orchestrator+PendingQuestion.swift`.
    let pendingQuestions = PendingQuestionTracker()
    /// Who takes the turns each agent's session starts on its own. See
    /// `Orchestrator+UnpromptedTurns.swift`.
    let unpromptedTurns = UnpromptedTurnRouter()
    /// Asked before a workflow node is activated; `false` leaves it unactivated.
    ///
    /// Nil by default — a workflow with no gate runs every node it transitions
    /// to. `BacklogAutopilot` installs one for the item it has in flight, so a
    /// run whose worker left nothing behind never spends a reviewer pass on an
    /// empty diff.
    ///
    /// A gate that refuses owns what happens next: the engine has already
    /// transitioned, so nothing else will move the run off the node it is now
    /// parked on (autopilot cancels the execution from inside its gate).
    var nodeActivationGate: ((_ executionID: String, _ nodeID: String) async -> Bool)?

    struct ManagedSession {
        let session: AgentSession
        let runtime: any AgentRuntime
        /// What the session was started with. Kept because the terms a process
        /// was spawned on cannot be changed afterwards — only replaced.
        var options: SessionOptions = SessionOptions()
    }

    init(runtimeRegistry: RuntimeRegistry, eventBus: EventBus, subscriptionEngine: SubscriptionEngine, memoryManager: MemoryManager, skillRegistry: SkillRegistry = SkillRegistry(scanPaths: []), contextEngine: ContextEngine? = nil) {
        self.runtimeRegistry = runtimeRegistry
        self.eventBus = eventBus
        self.subscriptionEngine = subscriptionEngine
        self.memoryManager = memoryManager
        self.skillRegistry = skillRegistry
        self.contextEngine = contextEngine ?? DefaultContextEngine(memoryManager: memoryManager)

        let bridge = WorkflowEventBridge(eventBus: eventBus)
        self.workflowEventBridge = bridge
        self.workflowEngine = WorkflowEngine(queueTimeout: 30.0, eventBridge: bridge)

        let approvalBridge = WorkflowApprovalBridge(engine: workflowEngine)
        self.workflowApprovalBridge = approvalBridge
        self.approvalCancellable = approvalBridge.approvalsPublisher
            .sink { [weak self] approvals in
                Task { @MainActor in self?.pendingWorkflowApprovals = approvals }
            }
    }

    convenience init(runtime: any AgentRuntime, eventBus: EventBus, subscriptionEngine: SubscriptionEngine, memoryManager: MemoryManager, skillRegistry: SkillRegistry = SkillRegistry(scanPaths: []), contextEngine: ContextEngine? = nil) {
        let registry = RuntimeRegistry()
        registry.register(.claude, runtime: runtime)
        registry.register(.copilot, runtime: CopilotBridgeRuntime())
        registry.register(.ollama, runtime: OllamaRuntime())
        self.init(
            runtimeRegistry: registry,
            eventBus: eventBus,
            subscriptionEngine: subscriptionEngine,
            memoryManager: memoryManager,
            skillRegistry: skillRegistry,
            contextEngine: contextEngine
        )
    }

    convenience init(runtime: any AgentRuntime) {
        let tmpURL = FileManager.default.temporaryDirectory.appending(path: "kiteloop-orphan-\(UUID().uuidString)")
        let project = KiteloopProject(rootURL: tmpURL)
        let eventBus = EventBus(eventsURL: project.eventsURL)
        let skillRegistry = SkillRegistry(scanPaths: [])
        self.init(
            runtime: runtime,
            eventBus: eventBus,
            subscriptionEngine: SubscriptionEngine(eventBus: eventBus),
            memoryManager: MemoryManager(project: project),
            skillRegistry: skillRegistry
        )
    }

    func setupSubscriptions() {
        Task {
            await subscriptionEngine.setTriggerHandler { [weak self] agentID, event in
                guard let self else { return }
                let message = self.formatEventAsMessage(event)
                await MainActor.run {
                    self.triggerAgent(agentID: agentID, message: message)
                }
            }
        }
        startWorkflowBridge()
    }

    func startSubscriptions() {
        Task { await subscriptionEngine.start(agents: agents) }
    }

    /// The counterpart to `startSubscriptions()`, called when the project closes:
    /// drops every agent's subscription and the task watching it. Stopping an
    /// agent's session doesn't do this — an agent whose session is stopped is
    /// still on the team — so without it a closed project leaves one live
    /// subscription and one watch task per agent behind, each holding its
    /// `EventBus` alive for the life of the process.
    func stopSubscriptions() {
        Task { await subscriptionEngine.stop() }
    }

    func startWorkflowBridge() {
        guard let bridge = workflowEventBridge else { return }
        Task { await bridge.startInboundBridge(engine: workflowEngine) }
    }

    func publishEvent(_ event: KiteloopEvent) {
        Task { await eventBus.publish(event) }
    }

    func triggerAgent(agentID: String, message: String, chainDepth: Int = 0) {
        guard sessions[agentID] != nil else { return }
        NotificationCenter.default.post(
            name: .agentTriggered,
            object: self,
            userInfo: ["agentID": agentID, "message": message]
        )
    }

    private nonisolated func formatEventAsMessage(_ event: KiteloopEvent) -> String {
        var parts = ["[Event: \(event.type.rawValue)] from \(event.source)"]
        for (key, value) in event.payload {
            parts.append("\(key): \(value)")
        }
        return parts.joined(separator: "\n")
    }

    /// Every join lands here — a hire from chat, `POST /v1/agents`, the team read
    /// back from `team.json` — so this is where the new agent starts being
    /// watched. `startSubscriptions()` runs once, as the project opens, and an
    /// agent that arrives after it would otherwise be subscribed to nothing
    /// until the next launch.
    func addAgent(_ agent: Agent) {
        agents.append(agent)
        Task { await subscriptionEngine.startWatching(agent) }
    }

    /// The persistent team — every agent except the ephemeral asides.
    ///
    /// This is what `team.json` is written from and what the autopilot pickers
    /// offer: an aside exists only for the app's lifetime, so persisting it or
    /// letting it be assigned a run role would outlive the thing itself.
    var teamAgents: [Agent] { agents.filter { !$0.isAside } }

    /// The live aside forked from `agentID`, if one is open. At most one exists
    /// per source agent — `forkAside` refuses a second.
    func aside(of agentID: String) -> Agent? {
        agents.first { $0.asideOfAgentID == agentID }
    }

    enum AsideError: LocalizedError {
        case sourceNotFound
        case noSession
        case sourceIsAside
        case alreadyOpen(name: String)

        var errorDescription: String? {
            switch self {
            case .sourceNotFound:
                return "That agent is no longer on the team."
            case .noSession:
                return "No session to fork — send at least one message first."
            case .sourceIsAside:
                return "This is already an aside. Fork one from the agent it came from instead."
            case .alreadyOpen(let name):
                return "**\(name)** is already open. Dismiss it before forking another aside."
            }
        }
    }

    /// Forks `sourceAgentID`'s session **sideways**: a second, ephemeral agent
    /// that starts from the same checkpoint, leaving the source running and its
    /// context untouched.
    ///
    /// This is the counterpart to `/fork`, which restarts the source agent
    /// forked — there the live conversation *becomes* the fork. Here the point
    /// is to ask questions about the work without the questions and answers
    /// landing in the session doing the work.
    ///
    /// The source is deliberately never stopped or restarted: its CLI process
    /// keeps its session id, and `--fork-session` gives the aside a copy of the
    /// transcript rather than a claim on it.
    @discardableResult
    func forkAside(of sourceAgentID: String, cwd: URL, sourceSessionID: String) async throws -> Agent {
        guard let source = agents.first(where: { $0.id == sourceAgentID }) else {
            throw AsideError.sourceNotFound
        }
        guard !source.isAside else { throw AsideError.sourceIsAside }
        guard !sourceSessionID.isEmpty else { throw AsideError.noSession }
        if let existing = aside(of: sourceAgentID) {
            throw AsideError.alreadyOpen(name: existing.name)
        }

        let asideAgent = Agent(
            id: UUID().uuidString,
            name: "\(source.name) (aside)",
            model: source.model,
            systemPrompt: source.systemPrompt,
            tools: source.tools,
            denied: source.denied,
            permissionMode: source.permissionMode,
            // No subscriptions: an aside is a side conversation, not a second
            // pair of hands reacting to the event bus.
            subscriptions: [],
            mcpServers: source.mcpServers,
            skills: source.skills,
            avatar: source.avatar,
            group: source.group,
            effort: source.effort,
            maxBudgetUSD: source.maxBudgetUSD,
            thinkingEnabled: source.thinkingEnabled,
            thinkingBudget: source.thinkingBudget,
            crossAgentAccess: source.crossAgentAccess,
            canAcceptDelegation: false,
            runtimeKind: source.runtimeKind,
            workspacePath: source.workspacePath,
            mcpConfigPath: source.mcpConfigPath,
            asideOfAgentID: sourceAgentID,
            state: .idle
        )

        addAgent(asideAgent)
        do {
            try await startAgent(asideAgent.id, cwd: cwd, resumeSessionID: sourceSessionID, forkSession: true)
        } catch {
            // A half-created aside would sit in the sidebar with no process
            // behind it, and would block the next `/fork aside` as the
            // one-per-agent aside that already exists.
            removeAgent(asideAgent.id)
            throw error
        }
        return asideAgent
    }

    func updateAgent(id: String, mutate: (inout Agent) -> Void) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        mutate(&agents[index])
    }

    /// Carries a rename into every teammate's Cross-Agent Access, which names
    /// agents by name: an entry equal to the agent's current name (trimmed,
    /// ignoring case, as the messaging gate compares) becomes `newName`, so the
    /// teammate keeps the access it had. Call it before the name is changed.
    /// The wildcards, other names and the renamed agent's own list are left alone.
    func renameInCrossAgentAccess(of renamedAgentID: String, to newName: String) {
        guard let oldName = agents.first(where: { $0.id == renamedAgentID })?.name else { return }
        let old = oldName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let new = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard old != new.lowercased(), !ToolInterceptor.grantsEveryAgent([old]) else { return }
        for index in agents.indices where agents[index].id != renamedAgentID {
            agents[index].crossAgentAccess = agents[index].crossAgentAccess.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == old ? new : $0
            }
        }
    }

    func hasSession(for agentID: String) -> Bool {
        sessions[agentID] != nil
    }

    // MARK: - Pinned working directories

    /// Agents whose session must start in a particular directory, whatever the
    /// caller passes — see `pinWorkingDirectory`.
    private var pinnedWorkingDirectories: [String: URL] = [:]

    /// Confines an agent's sessions to `url` until it is unpinned.
    ///
    /// A Claude Code process has its working directory fixed at spawn, so an
    /// isolated run moves its agents by stopping and restarting them in the
    /// worktree (`WorktreeSession.begin`). That holds only until something else
    /// restarts the same agent — and a dozen paths do, every one of them
    /// passing the *project root*: `/model`, `/compact` and the rest of the
    /// slash commands, the team-config watcher re-adding an agent, the no-work
    /// restart. Any of them silently re-roots a worker mid-item, and from then
    /// on its edits land in the shared checkout while its worktree and branch
    /// stay empty. Two items were built into the main tree that way on
    /// 2026-08-11, and both reached the approval gate looking like ordinary
    /// finished work.
    ///
    /// So the directory is decided here rather than at each call site: one
    /// place to honour, and nothing to keep in step.
    func pinWorkingDirectory(_ url: URL, for agentID: String) {
        pinnedWorkingDirectories[agentID] = url
    }

    /// Releases the pin, so the agent goes back to starting wherever the caller
    /// asks. Called by `WorktreeSession.end` before it restores the agents to
    /// the project root.
    func unpinWorkingDirectory(for agentID: String) {
        pinnedWorkingDirectories.removeValue(forKey: agentID)
    }

    /// Where this agent is confined, if anywhere. Read by `WorktreeSession` to
    /// refuse an agent another run still holds.
    func pinnedWorkingDirectory(for agentID: String) -> URL? {
        pinnedWorkingDirectories[agentID]
    }

    /// Where a session actually starts: the pin when there is one, else what
    /// the caller asked for.
    ///
    /// A pin whose directory is no longer on disk is dropped rather than
    /// honoured — a run that crashed between creating a worktree and tearing it
    /// down must not strand its agents pointing at a path that isn't there.
    /// Pure, so the rule can be read without an orchestrator.
    nonisolated static func resolveWorkingDirectory(
        requested: URL,
        pinned: URL?,
        pinExists: Bool
    ) -> URL {
        guard let pinned, pinExists else { return requested }
        return pinned
    }

    func startAgent(_ agentID: String, cwd: URL, resumeSessionID: String? = nil, forkSession: Bool = false) async throws {
        guard let index = agents.firstIndex(where: { $0.id == agentID }) else { return }
        let pinned = pinnedWorkingDirectories[agentID]
        let cwd = Self.resolveWorkingDirectory(
            requested: cwd,
            pinned: pinned,
            pinExists: pinned.map {
                FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
            } ?? false
        )
        if let pinned, pinned != cwd {
            // The pin was dropped because its directory has gone. Say so: an
            // agent quietly returning to the project root is the failure this
            // whole mechanism exists to make visible.
            pinnedWorkingDirectories.removeValue(forKey: agentID)
            msgLog.error("[orchestrator.startAgent] pinned directory for \(agentID, privacy: .public) is gone (\(pinned.path(), privacy: .public)) — starting in \(cwd.path(), privacy: .public)")
        }
        var agent = agents[index]
        let composedPrompt = await contextEngine.composeSystemPrompt(for: agent, skillRegistry: skillRegistry)
        agent.systemPrompt = composedPrompt
        let strategy: ResumeStrategy
        if let id = resumeSessionID, !id.isEmpty {
            strategy = forkSession ? .fork(sessionID: id) : .resume(sessionID: id)
        } else {
            strategy = contextEngine.resumeStrategy(for: agent, currentSessionID: nil)
        }
        let agentRuntime = runtimeRegistry.runtime(for: agent)
        let options = sessionOptions(for: agentID)
        let session = try await agentRuntime.startSession(
            agent: agent, cwd: cwd, strategy: strategy, options: options
        )
        installSession(session, runtime: agentRuntime, options: options, for: agentID)
        agents[index].state = pendingQuestions.sessionEnded(agentID)
    }

    /// How the session about to be started will be driven: unattended exactly
    /// when a run has already taken the agent over.
    ///
    /// Holding an autopilot role is deliberately *not* enough. The same agents
    /// are chatted with between runs, through this same call, and a session a
    /// human is typing into is one this decision leaves alone.
    func sessionOptions(for agentID: String) -> SessionOptions {
        SessionOptions(unattended: unattendedAgentIDs.contains(agentID))
    }

    /// Whether this agent's live session was started for an unattended run.
    /// Nil when it has no session. `BacklogAutopilot` asks before it hands an
    /// item over: a session started for a human is one the run must replace, or
    /// the process it drives is not the one this decision was made about.
    func liveSessionIsUnattended(for agentID: String) -> Bool? {
        sessions[agentID]?.options.unattended
    }

    func send(_ message: String, attachments: [ChatAttachment] = [], to agentID: String) -> AsyncStream<StreamEvent> {
        guard let managed = sessions[agentID] else {
            let agentName = agents.first { $0.id == agentID }?.name ?? agentID
            msgLog.error("[orchestrator.send] NO SESSION for \(agentName, privacy: .public) (id=\(agentID, privacy: .public)) — returning empty stream")
            return AsyncStream { $0.finish() }
        }

        if let index = agents.firstIndex(where: { $0.id == agentID }) {
            agents[index].state = pendingQuestions.settle(.working, for: agentID)
        }
        isStreaming = true

        let agentName = agents.first { $0.id == agentID }?.name ?? agentID
        msgLog.info("[orchestrator.send] \(agentName, privacy: .public): forwarding to runtime (session=\(managed.session.id.prefix(8), privacy: .public)…)")
        return managed.runtime.send(message, attachments: attachments, to: managed.session)
    }

    func sendToolResult(toolCallID: String, content: String, to agentID: String) -> AsyncStream<StreamEvent> {
        guard let managed = sessions[agentID] else {
            return AsyncStream { $0.finish() }
        }

        if let index = agents.firstIndex(where: { $0.id == agentID }) {
            agents[index].state = pendingQuestions.settle(.working, for: agentID)
        }
        isStreaming = true

        return managed.runtime.sendToolResult(toolCallID: toolCallID, content: content, to: managed.session)
    }

    func setUnattended(_ agentID: String, _ unattended: Bool) {
        if unattended { unattendedAgentIDs.insert(agentID) }
        else { unattendedAgentIDs.remove(agentID) }
    }

    func respondToMCPToolCall(requestID: String, result: String, agentID: String) {
        guard let managed = sessions[agentID] else { return }
        managed.runtime.sendMCPToolResult(requestID: requestID, result: result, to: managed.session)
    }

    func markTurnDone(agentID: String) {
        if let index = agents.firstIndex(where: { $0.id == agentID }) {
            agents[index].state = pendingQuestions.settle(.idle, for: agentID)
        }
        isStreaming = false
    }

    func interrupt(agentID: String) {
        guard let managed = sessions[agentID] else { return }
        managed.runtime.interrupt(session: managed.session)
    }

    func stopAgent(_ agentID: String) {
        guard let managed = sessions.removeValue(forKey: agentID) else { return }
        managed.runtime.stop(session: managed.session)
        if let index = agents.firstIndex(where: { $0.id == agentID }) {
            agents[index].state = pendingQuestions.sessionEnded(agentID)
        }
    }

    func restartAgent(_ agentID: String, cwd: URL, resumeSessionID: String?) async throws {
        stopAgent(agentID)
        try await Task.sleep(for: .milliseconds(200))
        try await startAgent(agentID, cwd: cwd, resumeSessionID: resumeSessionID)
    }

    func restartAgentSession(agentID: String, cwd: URL? = nil) async throws {
        let sessionID = sessions[agentID]?.session.id
        let agent = agents.first { $0.id == agentID }
        let effectiveCWD: URL
        if let cwd {
            effectiveCWD = cwd
        } else if let wp = agent?.workspacePath, !wp.isEmpty {
            effectiveCWD = URL(fileURLWithPath: wp)
        } else {
            effectiveCWD = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
        try await restartAgent(agentID, cwd: effectiveCWD, resumeSessionID: sessionID)
    }

    func delegateSession(from sourceAgentID: String, to targetAgentID: String, message: String, cwd: URL) async throws -> AsyncStream<StreamEvent> {
        guard sessions[sourceAgentID] != nil else {
            throw RuntimeError.sessionNotFound
        }
        guard let targetIndex = agents.firstIndex(where: { $0.id == targetAgentID }),
              agents[targetIndex].canAcceptDelegation else {
            throw RuntimeError.sessionNotFound
        }

        stopAgent(targetAgentID)
        var targetAgent = agents[targetIndex]
        let composedPrompt = await contextEngine.composeSystemPrompt(for: targetAgent, skillRegistry: skillRegistry)
        targetAgent.systemPrompt = composedPrompt

        let sourceSessionID = sessions[sourceAgentID]?.session.id ?? ""
        let agentRuntime = runtimeRegistry.runtime(for: targetAgent)
        let options = sessionOptions(for: targetAgentID)
        let session = try await agentRuntime.startSession(
            agent: targetAgent,
            cwd: cwd,
            strategy: .fork(sessionID: sourceSessionID),
            options: options
        )
        installSession(session, runtime: agentRuntime, options: options, for: targetAgentID)
        agents[targetIndex].state = pendingQuestions.settle(.working, for: targetAgentID)
        isStreaming = true

        return agentRuntime.send(message, attachments: [], to: session)
    }

    func removeAgent(_ agentID: String) {
        if let managed = sessions.removeValue(forKey: agentID) {
            managed.runtime.stop(session: managed.session)
        }
        agents.removeAll { $0.id == agentID }
        Task { await subscriptionEngine.stopWatching(agentID: agentID) }
    }

    func sessionID(for agentID: String) -> String? {
        sessions[agentID]?.session.id
    }

    func agentScope(for agentID: String) -> AgentScope? {
        guard agents.contains(where: { $0.id == agentID }) else { return nil }
        return .global
    }

    // MARK: - Workflow Orchestration

    func startWorkflow(graph: WorkflowGraph, initialState: [String: AnyCodable]) async throws -> String {
        await workflowEngine.register(graph: graph)
        let execID = try await workflowEngine.start(graphID: graph.id, initialState: initialState)
        await activateWorkflowNode(executionID: execID, nodeID: graph.entryNode)
        return execID
    }

    func cancelWorkflow(executionID: String) async {
        await workflowEngine.cancel(executionID: executionID)
    }

    func workflowRoutingMode(for agentID: String) async -> RoutingMode {
        await workflowEngine.routingMode(for: agentID)
    }

    func activeWorkflowNode(for agentID: String) async -> (executionID: String, nodeID: String, schema: OutputSchema)? {
        guard let info = await workflowEngine.currentNodeForAgent(agentID),
              let schema = info.node.outputSchema else { return nil }
        return (info.executionID, info.nodeID, schema)
    }

    func activeWorkflowExecution(for agentID: String) async -> (executionID: String, nodeID: String)? {
        guard let info = await workflowEngine.currentNodeForAgent(agentID) else { return nil }
        return (info.executionID, info.nodeID)
    }

    /// Consulted the moment a workflow node's agent finishes a turn, *before*
    /// the node completes and the graph moves on. Returning text gives that
    /// agent one more turn with it, in the same session; returning nil — the
    /// default, and the state whenever nobody has installed a check — completes
    /// the node exactly as before.
    ///
    /// The seam exists because some things are only worth saying to an agent
    /// while it can still act on them. `BacklogAutopilot` installs one for the
    /// length of an item's run to tell a worker that its diff is empty (see
    /// `EmptyDiffHandoff`); the check itself decides whether it has anything to
    /// say, and how often.
    var workflowHandoffCheck: ((_ executionID: String, _ nodeID: String) async -> String?)?

    /// What the hand-off check wants said to `agentID` before its node
    /// completes, or nil. Nil for an agent that isn't on a workflow node at all,
    /// which is every agent in an ordinary chat.
    func workflowHandoffMessage(for agentID: String) async -> String? {
        guard let check = workflowHandoffCheck,
              let info = await workflowEngine.currentNodeForAgent(agentID) else { return nil }
        return await check(info.executionID, info.nodeID)
    }

    /// Notes an operator has handed to a workflow node's agent, waiting for that
    /// agent's next turn boundary — see `RunSteerNote` for why the boundary and
    /// not mid-turn.
    ///
    /// Keyed by agent, not by execution: what receives the note is the agent's
    /// session, and that is what `ChatViewModel` has in hand when a turn ends.
    /// The queue is drained on delivery and cleared by whoever filled it when
    /// its run ends (`BacklogAutopilot`), so a note nobody got to deliver can't
    /// surface in an unrelated chat an hour later.
    private var pendingSteerNotes: [String: [String]] = [:]

    func queueSteerNote(_ note: String, for agentID: String) {
        pendingSteerNotes[agentID, default: []].append(note)
    }

    /// Everything waiting for `agentID`, removed as it is read. Empty for an
    /// agent nobody has steered, which is every agent in an ordinary chat.
    func takeSteerNotes(for agentID: String) -> [String] {
        pendingSteerNotes.removeValue(forKey: agentID) ?? []
    }

    func clearSteerNotes(for agentID: String) {
        pendingSteerNotes.removeValue(forKey: agentID)
    }

    /// Paths an agent's own `Write`/`Edit`/`MultiEdit`/`NotebookEdit` tool calls
    /// have named, keyed by agent — recorded by `ChatViewModel` off each tool
    /// call it streams, via `RunWorkEvidence.writtenPath(toolName:input:relativeTo:)`.
    ///
    /// This is what lets `RunWorkEvidence.strayWork` tell a path git found
    /// newly dirty in the project's checkout apart from a path this session
    /// actually wrote: presence in the checkout at the wrong moment is not
    /// attribution, and blaming a run for another actor's edit is what sent
    /// three clean runs to `blocked` on 2026-08-28. This set is attribution.
    private var writtenPaths: [String: Set<String>] = [:]

    func recordWrittenPath(_ path: String, for agentID: String) {
        writtenPaths[agentID, default: []].insert(path)
    }

    /// Everything recorded for `agentID` so far — empty for an agent that has
    /// written nothing, which is every agent outside an autopilot run.
    func writtenPaths(for agentID: String) -> Set<String> {
        writtenPaths[agentID] ?? []
    }

    func clearWrittenPaths(for agentID: String) {
        writtenPaths.removeValue(forKey: agentID)
    }

    /// Consulted with a completed node's structured output, *before* the engine
    /// merges it into state and evaluates the outgoing edges — so what it
    /// returns is what the graph routes on.
    ///
    /// Nil by default: a workflow with no refinement routes on exactly what its
    /// agent said, which is every workflow but an autopilot run.
    /// `BacklogAutopilot` installs one for the length of an item's run so a
    /// reviewer's findings can decide the verdict alongside its boolean (see
    /// `ReviewFindings`), rather than having their severity read after the fact
    /// by whoever happens to look at the finished state.
    var workflowOutputRefinement: ((_ nodeID: String, _ output: [String: AnyCodable]) async -> [String: AnyCodable])?

    func handleWorkflowEvent(_ event: WorkflowEvent) {
        Task {
            let event = await refining(event)
            let result: TransitionResult?
            do {
                result = try await workflowEngine.handleEvent(event)
            } catch {
                // Refused events used to vanish here, and a run whose node's
                // result was refused sat on that node until the stall watchdog
                // ended it, with nothing anywhere saying why.
                workflowEventLog.error("""
                    workflow \(event.executionID, privacy: .public) refused \(event.nodeID, privacy: .public)'s \
                    \(String(describing: event.type), privacy: .public): \(String(describing: error), privacy: .public)
                    """)
                result = nil
            }
            switch result {
            case .transitioned(let toNode):
                await activateWorkflowNode(executionID: event.executionID, nodeID: toNode)
            case .awaitingApproval(let question, let edgeID):
                if let bridge = workflowApprovalBridge {
                    await bridge.registerPendingApproval(
                        executionID: event.executionID,
                        question: question,
                        edgeIndex: edgeID
                    )
                }
            default:
                break
            }
        }
    }

    /// The event as the engine should see it. Only a completed node carrying
    /// output is ever rewritten — a failure or a timeout has no verdict to
    /// reconcile, and with no refinement installed this is the identity.
    private func refining(_ event: WorkflowEvent) async -> WorkflowEvent {
        guard let refine = workflowOutputRefinement,
              event.type == .nodeCompleted,
              let output = event.output else { return event }
        return WorkflowEvent(
            executionID: event.executionID,
            nodeID: event.nodeID,
            agentID: event.agentID,
            type: event.type,
            output: await refine(event.nodeID, output)
        )
    }

    /// Resolves a pending human-approval gate. On approval the workflow
    /// transitions and the next node's agent is activated.
    func resolveWorkflowApproval(executionID: String, approved: Bool, reason: String?) {
        guard let bridge = workflowApprovalBridge else { return }
        Task {
            guard let result = try? await bridge.resolve(executionID: executionID, approved: approved, reason: reason) else { return }
            if case .transitioned(let toNode) = result {
                await activateWorkflowNode(executionID: executionID, nodeID: toNode)
            }
        }
    }

    func activateWorkflowNode(executionID: String, nodeID: String) async {
        guard let execution = await workflowEngine.execution(id: executionID),
              let graph = await workflowEngine.registeredGraph(id: execution.graphID),
              let node = graph.nodes[nodeID] else { return }

        // Asked before anything runs, so a node that shouldn't run costs nothing.
        if let gate = nodeActivationGate, await gate(executionID, nodeID) == false { return }

        // Re-read: the gate above may have written facts into state for this
        // node's own prompt (`WorkflowEngine.mergeState`) — `execution` was
        // fetched before it ran, so its `state` predates any such write.
        let state = await workflowEngine.execution(id: executionID)?.state ?? execution.state

        // Shell nodes execute directly without an agent
        if let shellCmd = node.shellCommand {
            executeShellNode(command: shellCmd, executionID: executionID, nodeID: nodeID, state: state)
            return
        }

        guard let agentID = node.agentID else { return }

        let runner = WorkflowNodeRunner()
        let activation = runner.prepareActivation(node: node, state: state, executionID: executionID)

        await MainActor.run {
            self.triggerAgent(agentID: agentID, message: activation.resolvedPrompt)
        }
    }

    /// Runs a shell node's command in `directory` and reports its exit status
    /// and its stdout and stderr interleaved.
    ///
    /// A child that could not be spawned at all reports `-1` and the spawn
    /// error as its output, and — the point of the arm — reads nothing. The
    /// pipe's write end is held by this process until the child inherits it, so
    /// after a throw nobody ever closes it and `readDataToEndOfFile()` blocks
    /// for ever: the node then publishes no event and the workflow sits on it
    /// for the life of the process. The commonest way in is a `_cwd` naming a
    /// directory that has since gone — a worktree cleaned up under a run.
    ///
    /// Not `SubprocessOutput.run`: that drops stderr to the null device and
    /// takes no working directory, and a shell node needs both.
    ///
    /// Synchronous — it blocks until the child exits, so call it off the main
    /// actor. `executable` exists so the failed-spawn arm can be driven from a
    /// test; nothing in the app passes it.
    nonisolated static func runShellNodeCommand(
        _ command: String,
        directory: String,
        executable: String = "/bin/bash"
    ) -> (status: Int32, output: String) {
        do {
            // stderr folded into stdout: the node's record carries both, as it
            // always has. The drain-before-wait this used to do by hand is the
            // runner's (098848e).
            let result = try SubprocessOutput.run(
                executable: executable,
                arguments: ["-c", command],
                directory: URL(fileURLWithPath: directory),
                mergeStandardError: true
            )
            return (result.status, String(decoding: result.standardOutput, as: UTF8.self))
        } catch {
            return (-1, "could not start command: \(error.localizedDescription)")
        }
    }

    private func executeShellNode(command: String, executionID: String, nodeID: String, state: [String: AnyCodable]) {
        let cwd = state["_cwd"]?.stringValue ?? FileManager.default.currentDirectoryPath
        Task.detached { [weak self] in
            let (status, output) = Orchestrator.runShellNodeCommand(command, directory: cwd)
            let passed = status == 0
            let event = WorkflowEvent(
                executionID: executionID,
                nodeID: nodeID,
                agentID: "",
                type: .nodeCompleted,
                output: [
                    "result": .string(passed ? "pass" : "fail"),
                    "test_output": .string(passed ? "" : String(output.suffix(4096))),
                    "exit_code": .string(String(status))
                ]
            )
            await MainActor.run { [weak self] in
                self?.handleWorkflowEvent(event)
            }
        }
    }

    // MARK: - Workflow Resume

    /// Enables per-turn trace recording, storing spans under the given directory.
    func configureTracing(tracesURL: URL) {
        traceStore = TraceStore(tracesURL: tracesURL)
    }

    /// Enables per-run transcript recording, storing one directory per run under
    /// the given directory. Until this is called, runs record nothing.
    ///
    /// Sweeps expired runs on the way in as well as during writing, so a project
    /// that has been idle past the retention window prunes when it is next
    /// opened rather than waiting for its next run to write something.
    func configureRunTranscripts(baseURL: URL) {
        let store = RunTranscriptStore(baseURL: baseURL)
        runTranscriptStore = store
        Task.detached(priority: .utility) { await store.prune() }
    }

    /// Enables agent notifications (questions, completions),
    /// persisted to the given log file.
    func configureNotifications(notificationsURL: URL) {
        notificationStore = NotificationStore(notificationsURL: notificationsURL)
    }

    /// Records a notification for the human operator, and — for the types that
    /// block them — posts the macOS banner for it too. Recording is a no-op
    /// until `configureNotifications` has been called; the banner is not, since
    /// an unfocused user needs to hear about a gate whether or not this project
    /// keeps an inbox.
    ///
    /// `itemID`/`projectPath` name the backlog item the notice is about, so its
    /// row can open that item's page; `rollUpKey` marks it a reading of a live
    /// state, which resolves whatever pending notice already holds that key.
    func notify(agentID: String, type: NotificationItem.NotificationType, title: String, body: String,
                itemID: String? = nil, projectPath: String? = nil, rollUpKey: String? = nil) {
        let item = NotificationItem(agentID: agentID, type: type, title: title, body: body,
                                    itemID: itemID, projectPath: projectPath, rollUpKey: rollUpKey)
        if let store = notificationStore {
            Task { await store.add(item) }
        }
        NotificationService.shared.deliverSystemNotification(for: item)
        PushRelay.shared.relay(item)
    }

    /// Closes the notice an agent's `ask_human` filed, now that it is answered:
    /// the row is actionable, so it would otherwise keep counting in the badge
    /// until somebody clicked ✓ on work already done.
    func resolveQuestionNotices(agentID: String) {
        guard let store = notificationStore else { return }
        Task { await store.resolveQuestions(agentID: agentID, closure: .answered) }
    }

    /// Enables checkpoint persistence and crash-resume for workflows, storing
    /// checkpoints under the given directory.
    func configureWorkflowCheckpointing(baseURL: URL, projectName: String) {
        let store = WorkflowCheckpointStore(baseURL: baseURL)
        Task { await workflowEngine.setCheckpointStore(store) }
        configureResumeService(checkpointStore: store, projectName: projectName)
    }

    func configureResumeService(checkpointStore: WorkflowCheckpointStore, projectName: String) {
        guard let bridge = workflowEventBridge else { return }
        self.workflowResumeService = WorkflowResumeService(
            checkpointStore: checkpointStore,
            engine: workflowEngine,
            eventBridge: bridge,
            projectName: projectName
        )
    }

    /// Clears out checkpoints no resume could use, then loads the ones that are
    /// genuinely resumable. Pruning first is what keeps the scan — and the
    /// prompt it feeds — proportional to the runs that actually stopped mid-flight.
    func scanForIncompleteWorkflows() {
        guard let resumeService = workflowResumeService else { return }
        Task {
            let pruned = await resumeService.pruneSettledCheckpoints()
            if pruned > 0 {
                resumeLog.info("pruned \(pruned, privacy: .public) settled execution checkpoint dir(s)")
            }
            let incomplete = await resumeService.scanForIncomplete()
            await MainActor.run {
                self.incompleteExecutions = incomplete
            }
        }
    }

    /// What a Resume press actually did, surfaced in the resume prompt. A row
    /// disappearing is not a result: the user is told either that the workflow
    /// resumed or why it did not.
    struct ResumeReport: Sendable, Equatable {
        let executionID: String
        let message: String
        let succeeded: Bool
    }

    func resumeWorkflow(executionID: String) {
        Task { await attemptResume(executionID: executionID) }
    }

    /// Resumes an execution and reports the outcome. The row is dropped only
    /// when the resume actually took — a failed resume leaves it in the list so
    /// what is on screen matches what is in the app.
    @discardableResult
    func attemptResume(executionID: String) async -> ResumeReport {
        let label = incompleteExecutions.first { $0.id == executionID }?.displayName ?? executionID

        guard let resumeService = workflowResumeService else {
            return record(ResumeReport(
                executionID: executionID,
                message: "Can't resume \"\(label)\": workflow checkpointing isn't configured for this project.",
                succeeded: false
            ))
        }

        do {
            try await resumeService.resume(executionID: executionID)
        } catch {
            return record(ResumeReport(
                executionID: executionID,
                message: "Can't resume \"\(label)\": \(error.localizedDescription)",
                succeeded: false
            ))
        }

        incompleteExecutions.removeAll { $0.id == executionID }
        return record(ResumeReport(
            executionID: executionID,
            message: "Resumed \"\(label)\".",
            succeeded: true
        ))
    }

    /// Publishes a resume outcome to the prompt and to the notification inbox,
    /// so it survives the sheet closing.
    func record(_ report: ResumeReport) -> ResumeReport {
        lastResumeReport = report
        notify(
            agentID: "workflow",
            type: report.succeeded ? .event : .error,
            title: report.succeeded ? "Workflow resumed" : "Workflow resume failed",
            body: report.message
        )
        return report
    }

    func dismissWorkflow(executionID: String) {
        Task { await attemptDismiss(executionID: executionID) }
    }

    @discardableResult
    func attemptDismiss(executionID: String) async -> ResumeReport {
        await WorkflowDismiss(orchestrator: self).one(executionID: executionID)
    }

    func dismissAllWorkflows() {
        Task { await attemptDismissAll() }
    }

    @discardableResult
    func attemptDismissAll() async -> ResumeReport {
        await WorkflowDismiss(orchestrator: self).all()
    }

    func configureKnowledgeRecall(store: AgentKnowledgeStore) {
        self.knowledgeRecallService = KnowledgeRecallService(knowledgeStore: store)
    }

    func configureAgentCards(knowledgeStore: AgentKnowledgeStore) {
        self.agentCardService = AgentCardService(knowledgeStore: knowledgeStore)
    }
}
