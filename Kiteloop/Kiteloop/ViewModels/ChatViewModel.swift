import AppKit
import Foundation
import KiteloopCore
import os.log

private let msgLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "message-agent")
private let chatLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "chat-vm")

@Observable
@MainActor
class ChatViewModel {
    let agentID: String
    let projectURL: URL
    private let orchestrator: Orchestrator
    private let project: KiteloopProject

    var agentName: String {
        displayName(forAgentID: agentID)
    }
    /// The name an agent was given, for labelling its messages; an id no agent
    /// on the team has — a guest specialist — reads as its capitalized id.
    func displayName(forAgentID id: String) -> String {
        orchestrator.agents.first { $0.id == id }?.name ?? id.capitalized
    }
    var agentModel: String {
        orchestrator.agents.first { $0.id == agentID }?.model ?? ""
    }
    var agentPermissionMode: String {
        orchestrator.agents.first { $0.id == agentID }?.permissionMode ?? Agent.defaultPermissionMode
    }
    var agentMCPServers: [String] {
        orchestrator.agents.first { $0.id == agentID }?.mcpServers ?? []
    }
    /// Non-nil while autopilot drives this agent unattended, so the chat header can
    /// say so — the agent's tool calls are decided by Claude Code's auto mode
    /// rather than by the human reading this window.
    var unattendedIndicator: UnattendedIndicatorModel? {
        UnattendedIndicatorModel.of(
            agentName: agentName,
            isUnattended: orchestrator.unattendedAgentIDs.contains(agentID),
            state: orchestrator.agents.first { $0.id == agentID }?.state ?? .idle
        )
    }
    private(set) var agentCatalogStore: AgentCatalogStore?
    private(set) var knowledgeIndex: KnowledgeIndex?
    private(set) var globalConfigStore: GlobalConfigStore?

    /// The window's web preview pane while this agent is the selected one — set
    /// by the host on every selection change (see `WebPreviewViewModel.retarget`),
    /// so tool handlers can reach the pane. Weak: the pane is owned by the window
    /// and holds the reverse reference to this VM; nil whenever another agent is
    /// selected, so an off-screen agent can't drive the preview.
    weak var webPreview: WebPreviewViewModel?

    private(set) var messages: [Message] = []
    private(set) var isStreaming = false {
        didSet {
            if isStreaming && !oldValue { costAtTurnStartUSD = costUSD }
            if !isStreaming && oldValue { scheduleWaitingUnpromptedTurn() }
        }
    }
    private(set) var streamingStartTime: Date?
    private(set) var costUSD: Double = 0
    /// `costUSD` when the current (or last) turn began streaming, so a turn's
    /// own cost can be told apart from the session total.
    private var costAtTurnStartUSD: Double = 0
    /// What the most recent turn added to `costUSD` — every result event it
    /// produced, tool-result continuations included. Never negative.
    var lastTurnCostUSD: Double { max(0, costUSD - costAtTurnStartUSD) }
    /// The last `total_cost_usd` seen from each session's `result` events, keyed
    /// by session id — that field is the session's running total, not a
    /// per-turn amount, so `costDelta(for:lastSeenBySession:)` needs it to
    /// recover what a turn actually added. Keyed by session rather than a
    /// single scalar because a consulted specialist's guest session runs its
    /// own running total alongside this agent's own.
    private var lastSeenCostBySession: [String: Double] = [:]
    private(set) var lastInputTokens: Int = 0
    private(set) var lastOutputTokens: Int = 0
    private(set) var lastDurationMs: Int = 0
    private(set) var cacheCreationTokens: Int = 0
    private(set) var cacheReadTokens: Int = 0
    private(set) var isProcessDead = false
    private var recoveryAttempts = 0
    private let maxRecoveryAttempts = 3
    /// The error the last failed reconnect threw, shown on the crash bar;
    /// nil once a restart, a clear or a reconnect succeeds.
    private(set) var lastRecoveryFailure: String?
    var recoveryBackoff: [UInt64] = [0, 1_000_000_000, 3_000_000_000]
    private var isForwardedMessage = false
    /// Whether the queued message `send()` is replaying is one you typed.
    private var isReplayingTypedMessage = false
    /// A message waiting for the current turn to finish, with the attachments
    /// that were in the tray when it was queued — none for a teammate's.
    /// `typedByHuman` marks the ones Stop hands back to the input box.
    private struct QueuedMessage {
        let text: String
        let attachments: [ChatAttachment]
        var typedByHuman = false
    }
    private var pendingForwards: [QueuedMessage] = []
    /// The attachments of the queued or forwarded message `send()` is replaying,
    /// taken once; such a message never takes what the human staged in the tray.
    private var forwardedAttachments: [ChatAttachment] = []
    var queuedMessageCount: Int { pendingForwards.count }
    /// The texts of the messages you typed that are waiting for the turn to
    /// finish, oldest first — not a teammate's forwards or the app's own.
    var queuedTypedMessages: [String] {
        pendingForwards.filter(\.typedByHuman).map(\.text)
    }
    /// The window the CLI last measured the session against — on a turn's
    /// `result` (`modelUsage`), or on the `init` frame of a CLI that still
    /// says there. Nil until one has: a guessed size reads a 1M window as
    /// five times fuller than it is.
    private var reportedContextWindowSize: Int?
    /// The window the context gauge and /context measure against — nil on an
    /// Ollama or Copilot agent, whose window Kiteloop does not know, so a size
    /// left over from before a runtime change is never reused.
    var contextWindowSize: Int? {
        let runtime = orchestrator.agents.first { $0.id == agentID }?.resolvedRuntimeKind ?? .claude
        return runtime == .claude ? reportedContextWindowSize : nil
    }
    /// The runtime this agent resolves to — `.claude` once the agent is gone.
    var runtimeKind: RuntimeKind {
        orchestrator.agents.first { $0.id == agentID }?.resolvedRuntimeKind ?? .claude
    }
    private(set) var currentModel: String = ""
    /// The model this agent is running on: what the CLI reported for the live
    /// session, falling back to the model the agent is configured with before
    /// the session's `init` event has arrived. Empty only when neither is known.
    var resolvedModel: String {
        currentModel.isEmpty
            ? (orchestrator.agents.first { $0.id == agentID }?.model ?? "")
            : currentModel
    }
    private(set) var activeGoal: GoalState?
    private(set) var agentTasks: [AgentTask] = []
    /// The last id the CLI's own `TaskCreate` handed out. A counter, not the
    /// panel's length: the CLI never reuses a deleted task's number.
    private var cliTaskCount = 0
    private(set) var conversationTree = ConversationTree()
    var inputText = "" {
        didSet { keepDraft() }
    }
    /// The pending write of `currentSession`'s draft, a second after the last
    /// keystroke.
    private var draftSaveTask: Task<Void, Never>?
    var pendingAttachments: [ChatAttachment] = []
    var searchQuery = ""
    var isSearching = false
    private(set) var matchingMessageIDs: [UUID] = []
    private(set) var currentMatchIndex: Int = 0
    /// The id of the message the find bar's counter is on, so the view can mark
    /// that row. Nil when nothing matches, or when the index has fallen outside
    /// the matches.
    var currentMatchID: UUID? {
        matchingMessageIDs.indices.contains(currentMatchIndex)
            ? matchingMessageIDs[currentMatchIndex] : nil
    }
    /// How many older messages the search never looked at: the find bar searches
    /// `messages`, which on a long conversation is the 500-message tail the load
    /// kept, so its count is over that tail alone. Zero when the bar is shut,
    /// when nothing has been typed, and when the whole history is loaded — there
    /// is nothing to say in any of those cases.
    var unsearchedOlderMessageCount: Int {
        isSearching && !searchQuery.isEmpty ? messagesLeftOutOfLoad : 0
    }
    /// The `ask_human` call the session is waiting on. Whether there is one is
    /// the agent's `.waitingForHuman` state, so every way it opens or closes —
    /// asked, answered, cleared, restarted, a session switched — tells the
    /// orchestrator that owns the state.
    private(set) var pendingHumanToolCallID: String? {
        didSet {
            guard (oldValue == nil) != (pendingHumanToolCallID == nil) else { return }
            reportAwaitingAnswer()
        }
    }
    /// Whether a plan card is waiting on Approve or Keep planning — a gate
    /// only you can clear, so it reads as waiting on you as a question does.
    private(set) var hasOpenPlanCard = false {
        didSet {
            guard oldValue != hasOpenPlanCard else { return }
            reportAwaitingAnswer()
        }
    }

    /// The agent waits on you while either gate is open, so closing one
    /// never releases the state while the other still holds it.
    private func reportAwaitingAnswer() {
        orchestrator.setAwaitingAnswer(pendingHumanToolCallID != nil || hasOpenPlanCard, for: agentID)
    }
    private(set) var pendingMCPAuthRequestID: String?
    private(set) var currentSession: ChatSession?
    private(set) var sessionStore: SessionStore?

    /// The run this agent is currently acting for, resolved at the start of each
    /// turn from the workflow reservation that owns it — the same source the turn
    /// span is stamped from. Nil for a human chatting to an agent, which is what
    /// keeps ordinary conversation out of the run transcripts.
    private var transcriptRun: (executionID: String, role: String)?
    /// Index into `messages` of the first record not yet written to the run's
    /// transcript.
    private var transcriptCursor = 0
    /// The tail of the transcript write chain. Writes are handed off and never
    /// awaited on the run's path — a lost record is a nuisance, a stalled run is
    /// worse — but they are chained so records land in the order they happened.
    private var transcriptWrite: Task<Void, Never>?
    /// The tail of the branch-sidecar write chain, chained for the same reason:
    /// a branch deleted just after it was made must not come back because the
    /// older snapshot landed last.
    private var branchesWrite: Task<Void, Never>?
    /// How many leading messages of the current session's file the 500-message
    /// load left out of `messages`, so `saveMessages` keeps them on disk.
    private var messagesLeftOutOfLoad = 0

    /// Whether an Ollama or Copilot runtime answers, for `/doctor`; a test
    /// replaces it so no report opens a socket.
    @ObservationIgnored var runtimeReachable: (RuntimeKind) async -> Bool = { kind in
        switch kind {
        case .ollama: return await OllamaRuntime.isAvailable()
        case .copilot: return await CopilotBridgeRuntime.isAvailable()
        case .claude: return true
        }
    }

    var projectName: String {
        projectURL.lastPathComponent
    }

    var skillRegistry: SkillRegistry {
        orchestrator.skillRegistry
    }

    init(agentID: String, projectURL: URL, orchestrator: Orchestrator) {
        self.agentID = agentID
        self.projectURL = projectURL
        self.orchestrator = orchestrator

        let project = KiteloopProject(rootURL: projectURL)
        self.project = project
        loadMessages()

        orchestrator.setUnpromptedTurnHandler(for: agentID) { [weak self] turn in
            self?.receiveUnpromptedTurn(turn)
        }

        NotificationCenter.default.addObserver(
            forName: .agentTriggered,
            object: orchestrator,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let targetID = notification.userInfo?["agentID"] as? String,
                  targetID == self.agentID,
                  let message = notification.userInfo?["message"] as? String else { return }
            Task { @MainActor in
                let finalMessage = message
                if self.isStreaming {
                    self.pendingForwards.append(QueuedMessage(text: finalMessage, attachments: []))
                } else {
                    self.isForwardedMessage = true
                    self.inputText = finalMessage
                    await self.send()
                    self.isForwardedMessage = false
                }
            }
        }
    }

    func configure(catalogStore: AgentCatalogStore, knowledgeIndex: KnowledgeIndex? = nil, globalConfigStore: GlobalConfigStore? = nil) {
        self.agentCatalogStore = catalogStore
        self.knowledgeIndex = knowledgeIndex
        self.globalConfigStore = globalConfigStore
    }

    func setupSessionStore(_ store: SessionStore) {
        self.sessionStore = store
        let existingSessions = store.sessions(for: agentID)
        if let latest = existingSessions.first {
            self.currentSession = latest
        } else {
            self.currentSession = store.createSession(agentID: agentID)
        }
        restoreDraft()
        // The chat opened here shows its history, and the next save — a
        // switch away, a send — writes that history back rather than an empty
        // transcript over it. `init` loaded nothing: it has no store yet.
        loadMessages()
    }

    // MARK: - Aside

    /// True when this chat *is* an aside — the header says so, and the aside
    /// can't fork one of its own.
    var isAside: Bool {
        orchestrator.agents.first { $0.id == agentID }?.isAside ?? false
    }

    /// Forks this agent's session sideways into a temporary second agent, so
    /// the human can question it without the exchange costing this session's
    /// context. Unlike `/fork`, this conversation is left running untouched.
    ///
    /// The session id comes from the same place `/fork` reads it: the id the
    /// CLI last reported for this agent, persisted in the project config.
    func forkAside() async {
        guard appliesToThisRuntime("/fork aside") else { return }
        let claudeSessionID = project.loadConfig().agentSessionIDs?[agentName] ?? ""
        do {
            let aside = try await orchestrator.forkAside(
                of: agentID, cwd: projectURL, sourceSessionID: claudeSessionID
            )
            // Same wiring as a summoned specialist — build the chat, select it,
            // don't persist. An aside must not reach team.json.
            NotificationCenter.default.post(
                name: .agentSummoned,
                object: nil,
                userInfo: [
                    "agent": aside,
                    "projectID": project.id,
                    "projectURL": projectURL,
                    "initialMessage": ""
                ]
            )
            messages.append(Message(
                id: UUID(), timestamp: .now, sender: .system,
                content: .text("Forked **\(aside.name)** from this session. Ask it anything — this conversation carries on untouched. Dismiss it from the sidebar when you're done; it won't survive a restart.")
            ))
        } catch {
            messages.append(Message(
                id: UUID(), timestamp: .now, sender: .system,
                content: .text(error.localizedDescription)
            ))
        }
    }

    private enum TurnResult {
        case finished(finalText: String)
        case continueWithToolResult(toolCallID: String, content: String)
    }

    /// Stages the file at `url`, or says in the chat why it cannot be staged —
    /// a file the app cannot read, or one over the attachment ceiling, used to
    /// vanish from the paperclip with nothing said about it.
    func addAttachment(url: URL) {
        let filename = url.lastPathComponent
        switch ChatAttachment.read(contentsOf: url) {
        case .success(let attachment):
            pendingAttachments.append(attachment)
        case .failure(.unreadable):
            postSystemError("Could not attach `\(filename)` — the file could not be read.")
        case .failure(.tooLarge(let bytes)):
            let size = String(format: "%.1f MB", Double(bytes) / 1_048_576)
            let ceiling = ChatAttachment.maxBytes / 1_048_576
            postSystemError("Could not attach `\(filename)` — it is \(size), over the \(ceiling) MB limit.")
        }
    }

    func removeAttachment(id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    func send() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if await actsDuringTurn(text) { return }
        if isStreaming && !isForwardedMessage { return queue(text) }
        guard !text.isEmpty else {
            // An attachment alone is a message: no command or mention to read.
            let attachments = takeOutgoingAttachments()
            if !attachments.isEmpty { await deliverToAgent(text, attachments: attachments) }
            return
        }

        // What was queued while a command's own turns ran — /recap, /compact,
        // /loop, /goal — is sent once it finishes, as after an ordinary turn.
        if await runSlashCommand(text) { return await drainPendingForwards() }
        if await routeMentions(in: text) { return }
        closePlanCardsIfTypedByHuman()
        await deliverToAgent(text, attachments: takeOutgoingAttachments())
    }

    /// What typed during a turn acts at once instead of queueing: a stop, and
    /// the read-only reports, which neither send to nor restart the agent.
    private func actsDuringTurn(_ text: String) async -> Bool {
        if stopsRunningLoop(text) { return true }
        guard isStreaming, Self.readOnlyCommands.contains(text.lowercased()) else { return false }
        return await runSlashCommand(text)
    }

    /// The reports `actsDuringTurn` answers mid-turn; queued, `/loop status`
    /// would wait out the very loop it asks about.
    private static let readOnlyCommands: Set<String> = [
        "/cost", "/context", "/history", "/model", "/mode", "/effort",
        "/branch list", "/loop status", "/goal status", "/goal", "/doctor",
    ]

    /// A stop typed while a loop or goal runs acts now: queued, it would wait
    /// behind every turn it was meant to stop.
    private func stopsRunningLoop(_ text: String) -> Bool {
        guard activeGoal != nil, ["/loop stop", "/loop cancel", "/goal cancel"].contains(text.lowercased()) else { return false }
        inputText = ""
        cancelGoal()
        return true
    }

    /// Holds a message typed during a turn, taking the tray's attachments with
    /// it so a file staged afterwards is left for the message it was meant for.
    private func queue(_ text: String) {
        guard !text.isEmpty || !pendingAttachments.isEmpty else { return }
        pendingForwards.append(QueuedMessage(text: text, attachments: pendingAttachments, typedByHuman: true))
        inputText = ""
        pendingAttachments = []
    }

    /// What the message being sent carries: a replayed or forwarded message its
    /// own attachments, leaving the tray alone; a human send the tray, emptied.
    private func takeOutgoingAttachments() -> [ChatAttachment] {
        if isForwardedMessage {
            defer { forwardedAttachments = [] }
            return forwardedAttachments
        }
        defer { pendingAttachments = [] }
        return pendingAttachments
    }

    // MARK: - System notes

    /// The system message every slash command answers with. The commands are
    /// nothing but a report back to the human, so the one line that builds the
    /// message lives here rather than sixty times over.
    private func postSystem(_ text: String) {
        messages.append(Message(id: UUID(), timestamp: .now, sender: .system, content: .text(text)))
    }

    private func postSystemError(_ text: String) {
        messages.append(Message(id: UUID(), timestamp: .now, sender: .system, content: .error(text)))
    }

    // MARK: - Slash commands

    /// The commands ChatViewModel answers itself, grouped by what they touch;
    /// `true` when one matched and the turn is over. The groups are matched in
    /// turn and every pattern is distinct, so the order between groups carries
    /// no meaning — only the order *within* a group does, which is why
    /// `/fork aside` is tested before `/fork`.
    private func runSlashCommand(_ typed: String) async -> Bool {
        let text = commandWordLowercased(typed)
        if await runSessionCommand(text) { return true }
        if await runAgentSettingCommand(text) { return true }
        if await runPermissionModeCommand(text) { return true }
        if await runInspectionCommand(text) { return true }
        if await runAutonomyCommand(text) { return true }
        if runTranscriptCommand(text) { return true }
        return false
    }

    /// Commands that end, fork or restart the conversation itself.
    private func runSessionCommand(_ text: String) async -> Bool {
        if text == "/clear" { inputText = ""; await clear(); return true }
        if text == "/fork aside" { inputText = ""; await forkAside(); return true }
        if text == "/fork" { inputText = ""; await forkSession(); return true }
        if text == "/compact" { inputText = ""; await compactSession(); return true }
        if text == "/recap" { inputText = ""; await recap(); return true }
        return false
    }

    /// Commands that change a setting on the agent and restart it to take effect.
    private func runAgentSettingCommand(_ text: String) async -> Bool {
        if text == "/model" { inputText = ""; reportModel(); return true }
        if text == "/effort" { inputText = ""; reportEffort(); return true }
        if text.hasPrefix("/model ") {
            await switchModel(to: String(text.dropFirst(7)).trimmingCharacters(in: .whitespaces))
            return true
        }
        if text.hasPrefix("/effort ") {
            await setEffort(to: String(text.dropFirst(8)).trimmingCharacters(in: .whitespaces))
            return true
        }
        if let arg = commandArgument(of: text, for: "/thinking") {
            await setThinking(arg)
            return true
        }
        if text == "/fast" { inputText = ""; await toggleFastModel(); return true }
        return false
    }

    /// `/mode`: bare, the agent's permission mode and the choices; with a
    /// name, the switch to it.
    private func runPermissionModeCommand(_ text: String) async -> Bool {
        guard let arg = commandArgument(of: text, for: "/mode") else { return false }
        inputText = ""
        guard appliesToThisRuntime("/mode") else { return true }
        if arg.isEmpty { reportPermissionMode() } else { await switchPermissionMode(to: arg) }
        return true
    }

    /// Read-only reports: nothing here restarts the agent or sends a prompt.
    private func runInspectionCommand(_ text: String) async -> Bool {
        if text == "/cost" { inputText = ""; reportCost(); return true }
        if text == "/context" { inputText = ""; reportContextWindow(); return true }
        if text == "/doctor" { inputText = ""; postSystem(await runDiagnostics()); return true }
        if text == "/history" { inputText = ""; reportHistory(); return true }
        return false
    }

    /// The two commands that hand the agent a standing instruction.
    private func runAutonomyCommand(_ text: String) async -> Bool {
        if let arg = commandArgument(of: text, for: "/loop") {
            inputText = ""
            await handleLoop(arg)
            return true
        }
        if let arg = commandArgument(of: text, for: "/goal") {
            inputText = ""
            await handleGoal(arg)
            return true
        }
        return false
    }

    /// Commands that rewrite the local transcript without talking to the agent.
    private func runTranscriptCommand(_ text: String) -> Bool {
        if text == "/undo" { inputText = ""; undoLastTurn(); return true }
        if let arg = commandArgument(of: text, for: "/branch") {
            inputText = ""
            handleBranch(arg)
            return true
        }
        return false
    }

    /// `text` with its command word lowercased, so `/Clear` runs `/clear`;
    /// the argument keeps the case it was typed in, except after `/fork`, where
    /// the only argument is the fixed word `aside`.
    private func commandWordLowercased(_ text: String) -> String {
        let word = text.prefix { $0 != " " }.lowercased()
        return word == "/fork" ? text.lowercased() : word + text.drop { $0 != " " }
    }

    /// The trimmed argument when `text` is the command `word`, bare or followed
    /// by a space; nil otherwise, so `/goals` or `/branch-cleanup` falls through
    /// to skill expansion and the agent instead of running `/goal` or `/branch`.
    private func commandArgument(of text: String, for word: String) -> String? {
        guard text == word || text.hasPrefix(word + " ") else { return nil }
        return String(text.dropFirst(word.count)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Session commands

    /// Stops the agent and starts it again so a changed setting takes effect,
    /// reporting either outcome. `success` is nil where the caller has already
    /// announced the change and the restart itself is silent; a
    /// `resumeSessionID` carries the conversation into the new process.
    private func restartAgent(announcing success: String?, failurePrefix: String,
                              resumeSessionID: String? = nil) async {
        do {
            try await orchestrator.startAgent(agentID, cwd: projectURL, resumeSessionID: resumeSessionID)
            if let success { postSystem(success) }
        } catch {
            postSystemError("\(failurePrefix)\(error.localizedDescription)")
        }
    }

    /// The Claude session id this agent is resuming, or nil when it has never
    /// had a turn — `/fork` and `/compact` both need one and say so alike.
    private func resumableSessionID(for command: String) -> String? {
        let claudeSessionID = project.loadConfig().agentSessionIDs?[agentName]
        guard let claudeSessionID, !claudeSessionID.isEmpty else {
            postSystem("No session to \(command) — send at least one message first.")
            return nil
        }
        return claudeSessionID
    }

    private func forkSession() async {
        guard appliesToThisRuntime("/fork") else { return }
        guard let claudeSessionID = resumableSessionID(for: "fork") else { return }
        orchestrator.stopAgent(agentID)
        do {
            try await orchestrator.startAgent(agentID, cwd: projectURL, resumeSessionID: claudeSessionID, forkSession: true)
            postSystem("Session forked. Exploring from this point independently.")
        } catch {
            postSystemError("Fork failed: \(error.localizedDescription)")
        }
    }

    /// `/compact` goes to the live session as the CLI's own `/compact`; the
    /// chat says it compacted only when the session's `compact_boundary`
    /// frame arrived during that turn.
    private func compactSession() async {
        guard appliesToThisRuntime("/compact") else { return }
        guard resumableSessionID(for: "compact") != nil else { return }
        guard await ensureSession() else { return }
        isStreaming = true
        let countBefore = messages.count
        var receivedResult = false
        _ = await drainTurn(orchestrator.send("/compact", to: agentID), receivedResult: &receivedResult)
        orchestrator.markTurnDone(agentID: agentID)
        isStreaming = false
        postSystem(hasCompaction(since: countBefore)
            ? "Context compacted."
            : "The session did not report a compaction — context is unchanged.")
        saveMessages()
    }

    /// Whether a compaction marker was appended at or after `index`.
    private func hasCompaction(since index: Int) -> Bool {
        messages.dropFirst(index).contains {
            if case .systemEvent(let event) = $0.content { return event.kind == .compaction }
            return false
        }
    }

    private func recap() async {
        messages.append(.human("/recap"))
        guard await ensureSession() else { return }
        isStreaming = true
        let recapPrompt = "Provide a brief recap of our conversation so far: key decisions made, tasks completed, and anything still in progress. Be concise."
        var receivedResult = false
        _ = await drainTurn(orchestrator.send(recapPrompt, to: agentID), receivedResult: &receivedResult)
        orchestrator.markTurnDone(agentID: agentID)
        isStreaming = false
        saveMessages()
    }

    // MARK: - Agent-setting commands

    /// The levels `/effort <level>` accepts, and the ones bare `/effort` lists.
    private static let effortLevels = ["low", "medium", "high", "xhigh", "max"]

    /// Bare `/model`: the agent's current model and how to change it, without
    /// touching the agent.
    private func reportModel() {
        let model = orchestrator.agents.first { $0.id == agentID }?.model ?? ""
        postSystem("**Model:** \(ModelCatalog.displayName(for: model)) — /model <name> to switch")
    }

    /// Bare `/effort`: the agent's current effort and the levels it can take,
    /// without touching the agent.
    private func reportEffort() {
        let effort = orchestrator.agents.first { $0.id == agentID }?.effort ?? ""
        let levels = Self.effortLevels.joined(separator: ", ")
        postSystem("**Effort:** \(SettingNames.effort(effort)) — /effort <level> to change it (\(levels))")
    }

    private func switchModel(to typed: String) async {
        inputText = ""
        let runtime = orchestrator.agents.first { $0.id == agentID }?.resolvedRuntimeKind ?? .claude
        guard let model = runnableModelID(for: typed, on: runtime) else { return }
        orchestrator.stopAgent(agentID)
        orchestrator.updateAgent(id: agentID) {
            $0.model = model
            $0.runtimeKind = runtime.rawValue
        }
        await restartAgent(announcing: "Switched to model: **\(model)**",
                           failurePrefix: "Failed to restart with model \(model): ")
    }

    /// The id `/model` stores for a typed name on an agent running `runtime`, or
    /// nil — having said why — when that runtime cannot run it: a model of
    /// another runtime is refused by name, anything else unknown lists the
    /// runtime's own catalog ids.
    private func runnableModelID(for typed: String, on runtime: RuntimeKind) -> String? {
        let owner = Self.modelRuntime(of: typed)
        if owner == runtime {
            return ModelCatalog.all.first { $0.id.lowercased() == typed.lowercased() }?.id ?? typed
        }
        if owner == nil && runtime == .ollama && !typed.isEmpty { return typed }
        if let owner {
            postSystem("**\(typed)** is a \(Self.runtimeName(owner)) model — this agent runs on "
                + "\(Self.runtimeName(runtime)). Change its runtime in Edit Agent to use it.")
        } else {
            postSystem("Unknown model: **\(typed)**. Choose one of: "
                + ModelCatalog.all.map(\.id).filter { Self.modelRuntime(of: $0) == runtime }
                    .joined(separator: ", "))
        }
        return nil
    }

    /// The permission modes `/mode <name>` switches between, as stored.
    private static let permissionModes = ["auto", "acceptEdits", "plan", "default", "bypassPermissions"]

    /// Bare `/mode`: the agent's permission mode by its picker name and the
    /// choices, without touching the agent.
    private func reportPermissionMode() {
        let choices = Self.permissionModes.joined(separator: ", ")
        postSystem("**Permission mode:** \(SettingNames.permissionMode(agentPermissionMode))"
            + " — /mode <name> to switch (\(choices))")
    }

    /// Stores the mode `typed` names and restarts the agent on the session it
    /// was in, so the conversation carries on under the new flag; an unknown
    /// name is refused with the choices and changes nothing.
    private func switchPermissionMode(to typed: String) async {
        guard let mode = Self.permissionMode(named: typed) else {
            return postSystem("Unknown permission mode: **\(typed)**. Choose one of: "
                + Self.permissionModes.joined(separator: ", "))
        }
        let sessionID = project.loadConfig().agentSessionIDs?[agentName]
        orchestrator.stopAgent(agentID)
        orchestrator.updateAgent(id: agentID) { $0.permissionMode = mode }
        await restartAgent(announcing: "Permission mode set to: **\(SettingNames.permissionMode(mode))**",
                           failurePrefix: "Failed to restart in permission mode \(mode): ",
                           resumeSessionID: sessionID)
    }

    /// The stored mode a typed name means — its stored spelling or its picker
    /// name, in any case and spacing — or nil.
    private static func permissionMode(named typed: String) -> String? {
        let key = permissionModeKey(typed)
        return permissionModes.first { mode in
            let label = SettingNames.permissionMode(mode)
            let shortLabel = String(label.prefix { $0 != "(" })
            return [mode, label, shortLabel].map(permissionModeKey).contains(key)
        }
    }

    private static func permissionModeKey(_ name: String) -> String {
        name.lowercased().filter { !$0.isWhitespace }
    }

    /// The runtime a typed model name belongs to: any Claude spelling is Claude,
    /// "copilot" is Copilot, another catalog id is Ollama, and anything else is
    /// nil — an Ollama tag is open-ended, so an unlisted name claims no runtime.
    private static func modelRuntime(of typed: String) -> RuntimeKind? {
        if ModelCatalog.familyAlias(of: typed) != nil { return .claude }
        if typed.lowercased() == "copilot" { return .copilot }
        return ModelCatalog.all.contains { $0.id.lowercased() == typed.lowercased() } ? .ollama : nil
    }

    private static func runtimeName(_ runtime: RuntimeKind) -> String {
        switch runtime {
        case .claude: return "Claude"
        case .ollama: return "Ollama"
        case .copilot: return "Copilot"
        }
    }

    private func setEffort(to typed: String) async {
        inputText = ""
        let level = typed.lowercased()
        guard appliesToThisRuntime("/effort") else { return }
        guard Self.effortLevels.contains(level) else {
            postSystem("Valid effort levels: \(Self.effortLevels.joined(separator: ", "))")
            return
        }
        orchestrator.stopAgent(agentID)
        orchestrator.updateAgent(id: agentID) { $0.effort = level }
        await restartAgent(announcing: "Effort set to: **\(level)**",
                           failurePrefix: "Failed to restart with effort \(level): ")
    }

    private func setThinking(_ arg: String) async {
        inputText = ""
        guard appliesToThisRuntime("/thinking") else { return }
        switch arg.lowercased() {
        case "off":
            orchestrator.updateAgent(id: agentID) { $0.thinkingEnabled = false; $0.thinkingBudget = nil }
            postSystem("Extended thinking disabled.")
        case "on", "":
            orchestrator.updateAgent(id: agentID) { $0.thinkingEnabled = true }
            postSystem("Extended thinking enabled.")
        default:
            guard let budget = Int(arg), budget > 0 else {
                postSystem("Usage: /thinking [on|off|<budget_tokens>]")
                return
            }
            orchestrator.updateAgent(id: agentID) { $0.thinkingEnabled = true; $0.thinkingBudget = budget }
            postSystem("Extended thinking enabled (budget: \(budget) tokens).")
        }
        orchestrator.stopAgent(agentID)
        await restartAgent(announcing: nil, failurePrefix: "Failed to restart: ")
    }

    /// Whether a Claude-only setting command may go ahead on this agent. A
    /// local or Copilot runtime reads neither effort nor thinking, so there it
    /// posts why and the agent is left alone — no stored change, no restart.
    private func appliesToThisRuntime(_ command: String) -> Bool {
        guard runtimeKind != .claude else { return true }
        let model = orchestrator.agents.first { $0.id == agentID }?.model ?? ""
        postSystem("\(command) applies to Claude agents only — this agent runs "
            + "\(ModelCatalog.displayName(for: model)).")
        return false
    }

    private func toggleFastModel() async {
        let agent = orchestrator.agents.first { $0.id == agentID }
        if runtimeKind != .claude {
            postSystem("/fast switches between Claude models only — this agent runs "
                + "\(ModelCatalog.displayName(for: agent?.model ?? "")). Use /model <name> to choose a model.")
            return
        }
        let current = agent?.model ?? "sonnet"
        let newModel = current.contains("opus") ? "sonnet" : "opus"
        orchestrator.stopAgent(agentID)
        orchestrator.updateAgent(id: agentID) { $0.model = newModel }
        await restartAgent(announcing: "Switched to **\(newModel)**.",
                           failurePrefix: "Failed to switch model: ")
    }

    // MARK: - Inspection commands

    private func reportCost() {
        let runtime = orchestrator.agents.first { $0.id == agentID }?.resolvedRuntimeKind ?? .claude
        if runtime != .claude { return reportLocalCost(runtime) }
        var cacheInfo = ""
        if cacheReadTokens > 0 || cacheCreationTokens > 0 {
            // The hit rate, not just the raw counters: cache reads are
            // billed at a tenth of the input rate, so the share of the
            // prompt they cover is what actually moves the bill.
            let usage = TokenUsage(inputTokens: lastInputTokens, outputTokens: lastOutputTokens,
                                   cacheCreationTokens: cacheCreationTokens,
                                   cacheReadTokens: cacheReadTokens)
            cacheInfo = "\nCache: \(cacheReadTokens) read / \(cacheCreationTokens) created"
                + " — \(usage.cacheHitRateText) of prompt from cache"
        }
        postSystem("**Session Cost:** $\(String(format: "%.4f", costUSD))\nLast turn: \(lastInputTokens) in / \(lastOutputTokens) out (\(lastDurationMs)ms)\(cacheInfo)")
    }

    /// /cost on an Ollama or Copilot agent: what that runtime measures, and
    /// no dollar figure, since neither is billed nor reports a cost.
    private func reportLocalCost(_ runtime: RuntimeKind) {
        let name = Self.runtimeName(runtime)
        if runtime == .ollama {
            return postSystem("**Cost:** none — this agent runs locally on \(name), so nothing is charged.\n"
                + "Last turn: \(lastInputTokens) in / \(lastOutputTokens) out (\(lastDurationMs)ms)")
        }
        postSystem("**Cost:** not reported — the \(name) bridge reports neither tokens nor cost.\n"
            + "Last turn: \(lastDurationMs)ms")
    }

    private func reportContextWindow() {
        if let agent = orchestrator.agents.first(where: { $0.id == agentID }),
           agent.resolvedRuntimeKind != .claude {
            return reportUnknownContextWindow(for: agent)
        }
        let pctStr: String
        // input_tokens is only the uncached delta; the prior conversation lives in
        // cache_read/cache_creation. Output tokens are NOT context window occupancy.
        let total = lastInputTokens + cacheReadTokens + cacheCreationTokens
        if let windowSize = contextWindowSize, windowSize > 0 {
            pctStr = "\(Int(Double(total) / Double(windowSize) * 100))%"
        } else {
            pctStr = "unknown"
        }
        var cacheStr = ""
        if cacheReadTokens > 0 || cacheCreationTokens > 0 {
            let hitRate = total > 0 ? Double(cacheReadTokens) / Double(total) * 100 : 0
            cacheStr = "\n**Cache:** \(cacheReadTokens) read, \(cacheCreationTokens) created (\(Int(hitRate))% hit rate)"
        }
        postSystem("**Context window:** \(pctStr) used\nInput: \(lastInputTokens) tokens, Output: \(lastOutputTokens) tokens\nWindow size: \(contextWindowSize.map { "\($0)" } ?? "unknown")\(cacheStr)")
    }

    /// /context on an Ollama or Copilot agent: the last turn's tokens, and no
    /// percentage, since Kiteloop does not know that model's window.
    private func reportUnknownContextWindow(for agent: Agent) {
        postSystem("**Context window:** Input: \(lastInputTokens) tokens, Output: \(lastOutputTokens) tokens\n"
            + "Window size: not known to Kiteloop for \(ModelCatalog.displayName(for: agent.model)) — "
            + "the window of an Ollama or Copilot model isn't reported, so no percentage is shown.")
    }

    private func reportHistory() {
        let config = project.loadConfig()
        let sessionStr = config.agentSessionIDs?[agentName] ?? "none"
        guard let agent = orchestrator.agents.first(where: { $0.id == agentID }) else {
            return postSystem("**Session:** \(sessionStr)\n**Model / Permission mode:** unknown — this agent is no longer on the team")
        }
        let model = ModelCatalog.displayName(for: agent.model)
        let mode = SettingNames.permissionMode(agent.permissionMode)
        postSystem("**Session:** \(sessionStr)\n**Model:** \(model)\n**Permission mode:** \(mode)")
    }

    // MARK: - Autonomy commands

    /// The one line both `/loop status` and `/goal status` print about a
    /// running goal; the two differ only in what they call it.
    private func runningGoalReport(_ goal: GoalState, label: String) -> String {
        let elapsed = Int(Date().timeIntervalSince(goal.startedAt))
        return "**\(label):** \(goal.condition)\nTurns: \(goal.turns) | Elapsed: \(elapsed)s"
            + " | Cost: $\(String(format: "%.4f", goal.totalCostUSD))"
    }

    private func handleLoop(_ arg: String) async {
        let keyword = arg.lowercased()
        if ["stop", "cancel"].contains(keyword) {
            guard activeGoal != nil else { return postSystem("No loop is running.") }
            cancelGoal()
            return
        }
        if keyword == "status" {
            guard let goal = activeGoal else {
                return postSystem("No loop is running. Usage: `/loop [instruction]`")
            }
            return postSystem(runningGoalReport(goal, label: "Loop running"))
        }
        guard activeGoal == nil else {
            return postSystem("A loop/goal is already running. Use `/loop stop` first.")
        }
        guard await ensureSession() else { return }
        postSystem("Loop started. Agent will keep working until you run `/loop stop`.")
        await runLoopMode(instruction: arg.isEmpty ? "Continue working on the current task. Take the next logical step." : arg)
    }

    private func handleGoal(_ arg: String) async {
        let keyword = arg.lowercased()
        if arg.isEmpty || keyword == "status" {
            guard let goal = activeGoal else {
                return postSystem("No active goal. Usage: `/goal <condition>` to set one, `/goal cancel` to stop.")
            }
            return postSystem(runningGoalReport(goal, label: "Active goal"))
        }
        if keyword == "cancel" {
            guard activeGoal != nil else { return postSystem("No goal is running.") }
            return cancelGoal()
        }
        guard activeGoal == nil else {
            return postSystem("A goal is already active. Use `/goal cancel` first.")
        }
        guard await ensureSession() else { return }
        postSystem("Goal set: **\(arg)**\nAgent will work autonomously until the condition is met.")
        await runGoalLoop(condition: arg, initialMessage: "")
    }

    // MARK: - Transcript commands

    /// /undo and a branch switch rewrite only the transcript: the live session
    /// still holds every turn it was sent.
    private static let agentStillRemembersNote =
        "This changed only what the chat shows — the agent still remembers the earlier conversation. Use `/clear` to start it fresh."

    private func undoLastTurn() {
        guard !isStreaming else {
            return postSystem("Cannot undo while agent is streaming. Stop the agent first.")
        }
        guard let lastHumanIdx = messages.lastIndex(where: {
            if case .human = $0.sender { return true }
            return false
        }) else {
            return postSystem("Nothing to undo.")
        }
        let taken = messages[lastHumanIdx].content
        messages.removeSubrange(lastHumanIdx...)
        var note = "Undid last turn (\(String(count: messages.count, noun: "message")) remaining)."
        if case .text(let text) = taken {
            inputText = text
            note += " Your message is back in the input to edit and resend."
        }
        postSystem("\(note) \(Self.agentStillRemembersNote)")
        saveMessages()
    }

    private func handleBranch(_ arg: String) {
        let keyword = arg.lowercased()
        if keyword == "list" { return listBranches() }
        if keyword == "main" { return switchToMainBranch() }
        if let (action, name) = Self.branchAction(in: arg) {
            guard !name.isEmpty else { return postSystem("Usage: /branch \(action) <name>") }
            if action == "rename" { return renameActiveBranch(to: name) }
            return action == "switch" ? switchToBranch(named: name) : deleteBranch(named: name)
        }
        createBranchHere(named: arg)
    }

    /// `switch`, `delete` or `rename` as the first word, in any case, and the
    /// name after it as typed; `nil` when the first word is none of them.
    private static func branchAction(in arg: String) -> (action: String, name: String)? {
        let parts = arg.split(separator: " ", maxSplits: 1)
        guard let action = parts.first?.lowercased(), ["switch", "delete", "rename"].contains(action) else { return nil }
        let name = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        return (action, name)
    }

    /// `/branch rename <name>`: renames the branch you are on with the bar's
    /// refusals; the main line has no name to change.
    private func renameActiveBranch(to name: String) {
        guard let id = conversationTree.activeBranchID else {
            return postSystem("The main line cannot be renamed.")
        }
        renameBranch(id: id, to: name)
    }

    private func listBranches() {
        guard !conversationTree.branches.isEmpty else {
            return postSystem("No branches. Use `/branch <name>` to create one from this point.")
        }
        postSystem("**Branches:**\n\(branchListRows().joined(separator: "\n"))")
    }

    /// Main first, then each branch; the line you are on counts the transcript
    /// in front of you rather than the copy stored when you arrived, and is marked.
    private func branchListRows() -> [String] {
        let active = conversationTree.activeBranchID
        let mainCount = active == nil ? messages.count : conversationTree.mainMessages.count
        let main = Self.branchListRow("main", count: mainCount, isHere: active == nil)
        return [main] + conversationTree.branches.map { branch in
            let isHere = branch.id == active
            return Self.branchListRow(branch.name, count: isHere ? messages.count : branch.messages.count, isHere: isHere)
        }
    }

    private static func branchListRow(_ name: String, count: Int, isHere: Bool) -> String {
        "• \(name) (\(count) msgs)" + (isHere ? " (you are here)" : "")
    }

    private func switchToBranch(named branchName: String) {
        guard !refusesLineChangeWhileStreaming() else { return }
        guard let branch = conversationTree.branch(named: branchName) else {
            if branchName.lowercased() == "main" { return switchToMainBranch() }
            return postSystem("No branch named '\(branchName)'. Use `/branch list` to see all.")
        }
        guard let branchMessages = conversationTree.switchToBranch(branch.id, leaving: messages) else { return }
        messages = branchMessages
        postSystem("Switched to branch **\(branch.name)**. \(Self.agentStillRemembersNote)")
        saveBranches()
        saveMessages()
    }

    private func deleteBranch(named branchName: String) {
        guard let branch = conversationTree.branch(named: branchName) else {
            if branchName.lowercased() == "main" { return postSystem("The main line cannot be deleted.") }
            return postSystem("No branch named '\(branchName)'.")
        }
        deleteBranch(branch)
    }

    private func deleteBranch(_ branch: ConversationBranch) {
        if branch.id == conversationTree.activeBranchID, refusesLineChangeWhileStreaming() { return }
        if let mainMessages = conversationTree.removeBranch(branch.id) {
            messages = mainMessages
            postSystem("Deleted branch **\(branch.name)**. You are back on **main**. \(Self.agentStillRemembersNote)")
        } else {
            postSystem("Deleted branch **\(branch.name)**.")
        }
        saveBranches()
        saveMessages()
    }

    /// A reply streams into whatever message is last in the chat, so moving to
    /// another line mid-turn would write the rest of it over that line's last
    /// message. Says so, and reports whether the change must be refused.
    private func refusesLineChangeWhileStreaming() -> Bool {
        guard isStreaming else { return false }
        postSystem("Cannot change branches while the agent is replying. Wait for the reply, or stop the turn first.")
        return true
    }

    private func createBranchHere(named arg: String) {
        let name = arg.isEmpty ? unusedDefaultBranchName() : arg
        if let existing = conversationTree.branch(named: name) {
            return postSystem("A branch named **\(existing.name)** already exists. Use `/branch switch \(existing.name)` to go to it, or pick another name.")
        }
        guard let lastMsgID = messages.last?.id else {
            return postSystem("No messages to branch from.")
        }
        _ = conversationTree.createBranch(name: name, from: lastMsgID, messages: messages)
        announceSavedBranch(named: name)
    }

    /// Says which branch was just saved and that the transcript stays on the
    /// current line, then persists the tree.
    private func announceSavedBranch(named name: String) {
        let currentLine = conversationTree.activeBranch?.name ?? "main"
        postSystem("Saved branch **\(name)** at this point. You are still on **\(currentLine)**; `/branch switch \(name)` to go to it.")
        saveBranches()
    }

    /// The lowest `branch-N` no existing branch is named, so a bare `/branch`
    /// never makes a twin after a deletion.
    private func unusedDefaultBranchName() -> String {
        let taken = Set(conversationTree.branches.map(\.name))
        var n = 1
        while taken.contains("branch-\(n)") { n += 1 }
        return "branch-\(n)"
    }

    // MARK: - @mention routing

    /// `true` when at least one `@handle` resolved and took over the turn.
    ///
    /// A mention only takes over the turn when it actually resolves to someone.
    /// An `@` that names nobody is ordinary text — an npm scope like
    /// @testing-library/react, an email address, a Rust attribute — and this
    /// branch used to claim the turn for it anyway and `return` without ever
    /// sending the message. Nothing was delivered and nothing reported a
    /// failure: an autopilot run whose item mentioned an npm scope sat idle
    /// for twenty minutes and finished having produced no work, three times
    /// over, before the cause was found (2026-08-09,
    /// grounding-check-token-classification).
    private func routeMentions(in text: String) async -> Bool {
        // @mention detection — resolve against the catalog (task specialist)
        let parseResult = MentionParser.parse(text)
        let routableMentions = parseResult.mentions.filter { handle in
            agentCatalogStore?.find(handle: handle) != nil
        }
        guard !routableMentions.isEmpty else { return false }

        messages.append(.human(text))
        inputText = ""
        // Taken once, so the tray empties once; every specialist named gets
        // the same files.
        let attachments = takeOutgoingAttachments()
        isStreaming = true
        for handle in routableMentions {
            await route(mention: handle, question: parseResult.cleanText, attachments: attachments)
        }
        isStreaming = false
        saveMessages()
        return true
    }

    private func route(mention handle: String, question: String, attachments: [ChatAttachment]) async {
        if let template = agentCatalogStore?.find(handle: handle) {
            return await summon(template, handle: handle, initialMessage: question, attachments: attachments)
        }
        postSystem("Unknown agent: @\(handle). Check Settings → Agents.")
    }

    /// Task specialist → spawn tab + route message, with the files the message
    /// was sent with.
    private func summon(_ template: AgentTemplate, handle: String, initialMessage: String,
                        attachments: [ChatAttachment]) async {
        postSystem("Summoning @\(handle)...")
        let agent = template.instantiateAgent()
        orchestrator.addAgent(agent)
        do {
            try await orchestrator.startAgent(agent.id, cwd: projectURL)
        } catch {
            return postSystem("Failed to start @\(handle): \(error.localizedDescription)")
        }
        NotificationCenter.default.post(
            name: .agentSummoned,
            object: nil,
            userInfo: [
                "agent": agent,
                "projectID": project.id,
                "projectURL": projectURL,
                "initialMessage": initialMessage,
                Notification.summonedAttachmentsKey: attachments
            ]
        )
        persistTeamConfig()
    }

    // MARK: - The ordinary turn

    private func deliverToAgent(_ text: String, attachments: [ChatAttachment]) async {
        let cutOffText = textToRestoreIfCutOff(text)
        messages.append(.human(text.isEmpty
            ? "Attached: " + attachments.map(\.filename).joined(separator: ", ")
            : text))
        // The typed text stays as typed, for Up-arrow recall and the auto-title;
        // the files it went with are named on a line of their own.
        if !text.isEmpty && !attachments.isEmpty {
            postSystem("Attached: " + attachments.map(\.filename).joined(separator: ", "))
        }
        inputText = ""
        isStreaming = true
        // After the prompt is appended, so a new run's transcript opens with the
        // instruction it was given.
        await beginTranscriptTurn()

        var messageToSend = await expandSkillInvocation(in: text)
        let teamContext = buildTeamContext()
        if !teamContext.isEmpty {
            messageToSend = "\(teamContext)\n\n\(messageToSend)"
        }
        guard await ensureSession() else {
            isStreaming = false
            return
        }

        let receivedResult = await runTurnAndFinish(
            initialStream: orchestrator.send(messageToSend, attachments: attachments, to: agentID),
            turnStartIndex: messages.count
        )
        isStreaming = false
        saveMessages()

        await finishDeliveredTurn(receivedResult: receivedResult, cutOffText: cutOffText)
    }

    /// Sends what was queued during the turn and reports how it ended. A turn
    /// that dropped sends nothing into the dead process: the human's queued
    /// messages go back to the input, behind the cut-off message the reconnect
    /// restores, and a teammate's forwards wait until the agent is back.
    private func finishDeliveredTurn(receivedResult: Bool, cutOffText: String?) async {
        guard !receivedResult else {
            await drainPendingForwards()
            return await reportTurnOutcome(receivedResult: true)
        }
        returnQueuedMessagesToInput()
        await reportTurnOutcome(receivedResult: false, cutOffText: cutOffText)
        if !isProcessDead { await drainPendingForwards() }
    }

    /// The text a turn's reconnect puts back in the input when the turn is cut
    /// off: what the human typed — sent now or replayed from the queue — and
    /// nil for a teammate's forward, which is not the human's to resend.
    private func textToRestoreIfCutOff(_ text: String) -> String? {
        guard !isForwardedMessage || isReplayingTypedMessage else { return nil }
        return text
    }

    /// Whether the agent has a live session to send to, starting one first when
    /// it has none — an agent stopped from the sidebar keeps its chat but not
    /// its process, and a send into no session reads as a crash. A start that
    /// throws says why in the chat and yields false, so nothing is sent.
    private func ensureSession() async -> Bool {
        guard !orchestrator.hasSession(for: agentID) else { return true }
        postSystem("Starting the agent…")
        do {
            try await orchestrator.startAgent(agentID, cwd: projectURL)
            return true
        } catch {
            postSystemError("Could not start the agent: \(error.localizedDescription)")
            return false
        }
    }

    /// Skill invocation: `/skill-name [args]` — the message rewritten with the
    /// skill's content injected, or `text` unchanged when it names no
    /// user-invocable skill.
    private func expandSkillInvocation(in text: String) async -> String {
        guard text.hasPrefix("/"), !text.hasPrefix("//") else { return text }
        let parts = String(text.dropFirst()).split(separator: " ", maxSplits: 1)
        // A bare `/`, or a slash followed by nothing but spaces, splits to
        // nothing: it names no skill, so the text goes to the agent as it was
        // typed. Reading `parts[0]` here used to trap on it.
        guard let name = parts.first else { return text }
        let args = parts.count > 1 ? String(parts[1]) : ""
        guard let skill = await orchestrator.skillRegistry.skill(named: String(name)),
              skill.isUserInvocable else { return text }
        return """
        <skill-content name="\(skill.name)">
        \(skill.body)
        </skill-content>

        \(args.isEmpty ? "Follow the skill instructions above." : args)
        """
    }

    private func reportTurnOutcome(receivedResult: Bool, cutOffText: String? = nil) async {
        guard receivedResult else { return await attemptRecovery(cutOffText: cutOffText) }
        recoveryAttempts = 0
        if NSApplication.shared.isActive { NSSound(named: "Pop")?.play() }
        if let lastMessage = messages.last, case .text(let t) = lastMessage.content {
            NotificationService.shared.notifyTaskComplete(
                agentName: agentName, projectName: projectName, summary: t,
                destination: BannerDestination(kind: .chat, project: projectURL.path(percentEncoded: false), id: agentID)
            )
        }
    }

    private func drainPendingForwards() async {
        while let message = pendingForwards.first {
            pendingForwards.removeFirst()
            // A draft in the box — what Stop handed back — outlives the replay.
            let draft = inputText
            isForwardedMessage = true
            forwardedAttachments = message.attachments
            isReplayingTypedMessage = message.typedByHuman
            inputText = message.text
            await send()
            forwardedAttachments = []
            isReplayingTypedMessage = false
            isForwardedMessage = false
            inputText = [draft, inputText].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
    }

    private func buildTeamContext() -> String {
        let teammates = orchestrator.agents.filter { $0.id != agentID }
        guard !teammates.isEmpty else { return "" }
        let lines = teammates.map { agent in
            let status: String
            switch agent.state {
            case .working: status = "working"
            case .waitingForHuman: status = "waiting"
            case .crashed: status = "offline"
            case .idle: status = "available"
            }
            return "- \(agent.name) (\(agent.model), \(status))"
        }
        return "<team-roster>\n\(lines.joined(separator: "\n"))\n</team-roster>"
    }

    /// Runs the two conditional extra turns and the hand-off, in the order
    /// both `send()` and `respondToHuman()` need it: the steer note first (so
    /// its effect on the tree is what the hand-off check reads), then —
    /// unless this turn launched a background agent that hasn't reported
    /// back — the empty-diff hand-off and the node's completion.
    ///
    /// A pending launch skips both: the turn ended on the Agent tool's launch
    /// acknowledgement, not on an answer, and completing the node now would
    /// hand off a report from an agent that hasn't reported (see
    /// `PendingAgentLaunch`). The node stays open; whatever turn next ends
    /// with nothing launched by *it* still pending is the one that reaches
    /// the hand-off, using that turn's own reply — a real transcript never
    /// names the launch it is reporting on, so a launch this turn made is
    /// the only thing worth checking, not whether some earlier turn's launch
    /// was ever explicitly acknowledged as done. That next turn does not
    /// happen on its own — the runtime only starts one when Kiteloop sends
    /// input — so this arms `schedulePendingLaunchNudge`, which gives the
    /// session that turn itself. The stall watchdog keeps its role for a
    /// session that answers no nudge at all.
    private func finishTurn(receivedResult: inout Bool, finalText: inout String, turnStartIndex: Int) async {
        postPlanCard(since: turnStartIndex)
        await runSteerNoteTurn(receivedResult: &receivedResult, finalText: &finalText)

        let pending = Self.countPendingAgentLaunches(in: messages[turnStartIndex...])
        orchestrator.setPendingBackgroundAgentCount(pending, for: agentID)
        guard pending == 0 else {
            orchestrator.markTurnDone(agentID: agentID)
            schedulePendingLaunchNudge()
            return
        }
        announceNudgeReportArrivedIfNeeded()
        cancelPendingLaunchNudge()
        await runWorkflowHandoffTurn(receivedResult: &receivedResult, finalText: &finalText)
        orchestrator.markTurnDone(agentID: agentID)
        await completeActiveWorkflowNode(finalText: finalText)
    }

    // MARK: - Turns the session starts on its own

    /// Turns the session started on its own while another turn was running
    /// here, waiting for it to end. See `receiveUnpromptedTurn`.
    private var waitingUnpromptedTurns: [UnpromptedTurn] = []

    /// A turn the CLI started by itself — typically its answer to a
    /// background shell or subagent finishing after the turn that launched it
    /// ended. It runs like any other turn, with no human message before it.
    ///
    /// One turn at a time: while another runs here it waits, and starts when
    /// `isStreaming` goes false. The runtime holds any send made while it is
    /// open until its `result`, and a human typing during it is queued the
    /// way a send during any turn is.
    private func receiveUnpromptedTurn(_ turn: UnpromptedTurn) {
        waitingUnpromptedTurns.append(turn)
        startWaitingUnpromptedTurn()
    }

    /// After a turn ends, not in the middle of ending it: the turn's own tail
    /// — a queued message it sends on — goes first.
    private func scheduleWaitingUnpromptedTurn() {
        guard !waitingUnpromptedTurns.isEmpty else { return }
        Task { [weak self] in self?.startWaitingUnpromptedTurn() }
    }

    /// Starts the oldest waiting turn when nothing is running, dropping any
    /// that came from a session the chat has since left.
    private func startWaitingUnpromptedTurn() {
        guard !isStreaming, !waitingUnpromptedTurns.isEmpty else { return }
        let turn = waitingUnpromptedTurns.removeFirst()
        guard orchestrator.isCurrentSession(turn, for: agentID) else { return startWaitingUnpromptedTurn() }
        isStreaming = true
        streamingStartTime = Date()
        Task { await runUnpromptedTurn(turn) }
    }

    /// The turn itself, under the same watchdog and bookkeeping as a sent one:
    /// messages, tool calls, cost and usage from its `result`, the run
    /// transcript, the agent's working state.
    private func runUnpromptedTurn(_ turn: UnpromptedTurn) async {
        orchestrator.beginUnpromptedTurn(agentID: agentID)
        await beginTranscriptTurn()
        let turnStartIndex = messages.count
        let isCurrent = { [weak self] () -> Bool in
            guard let self else { return false }
            return self.orchestrator.isCurrentSession(turn, for: self.agentID)
        }
        var receivedResult = false
        var finalText = ""
        await runTurnWithWatchdog {
            finalText = await drainTurn(turn.events, receivedResult: &receivedResult, while: isCurrent)
        }
        guard isCurrent() else { return await endUnpromptedTurn(receivedResult: nil) }
        await finishUnpromptedTurn(receivedResult: &receivedResult, finalText: &finalText, turnStartIndex: turnStartIndex)
        await endUnpromptedTurn(receivedResult: receivedResult)
    }

    /// What an unprompted turn means for a workflow node: only something when
    /// the node is waiting for a later turn — its last turn ended on a
    /// background agent it launched (`PendingAgentLaunch`). Then this is that
    /// later turn, and it goes through `finishTurn` as the nudge's would, so
    /// its reply is what the node hands off. Otherwise the node has already
    /// completed on the turn that ended it, and an unprompted turn after it —
    /// a background shell reporting in — must not complete whatever node the
    /// agent is on next.
    private func finishUnpromptedTurn(receivedResult: inout Bool, finalText: inout String, turnStartIndex: Int) async {
        guard orchestrator.pendingBackgroundAgentCount(for: agentID) > 0 else {
            return orchestrator.markTurnDone(agentID: agentID)
        }
        await finishTurn(receivedResult: &receivedResult, finalText: &finalText, turnStartIndex: turnStartIndex)
    }

    /// The tail every turn has: streaming off, the chat saved, queued messages
    /// sent. Nil `receivedResult` is a turn whose session was left mid-way:
    /// nothing of it is saved or reported, since the chat open now is not the
    /// one it belonged to.
    private func endUnpromptedTurn(receivedResult: Bool?) async {
        isStreaming = false
        streamingStartTime = nil
        if receivedResult != nil { saveMessages() }
        await drainPendingForwards()
        if let receivedResult { await reportTurnOutcome(receivedResult: receivedResult) }
    }

    // MARK: - Pending Background-Agent Launch Nudge

    /// How long to wait before nudging a worker whose turn ended on a still-
    /// open background-agent launch, and the backoff between nudges after
    /// that — the runtime never gives that session another turn on its own to
    /// receive the launch's report on (see `PendingAgentLaunch`), so nothing
    /// else would. `var`, not `let`, only so a test can shrink them;
    /// production always runs at these defaults.
    static var pendingLaunchNudgeInitialDelay: TimeInterval = 60
    static var pendingLaunchNudgeBackoffDelay: TimeInterval = 300

    private static let pendingLaunchNudgeText =
        "The background agent you launched is still running. Wait for its report, then continue the item."

    private var pendingLaunchNudgeTask: Task<Void, Never>?
    private var pendingLaunchNudgeHasFired = false

    /// Arms (or leaves armed) the nudge that gives this session another turn
    /// while a launch it made stays unanswered. Idempotent — `finishTurn`
    /// calls this on every turn that still has one pending, and a task
    /// already asleep for the next nudge should not be replaced.
    private func schedulePendingLaunchNudge() {
        guard pendingLaunchNudgeTask == nil else { return }
        let delay = pendingLaunchNudgeHasFired
            ? Self.pendingLaunchNudgeBackoffDelay : Self.pendingLaunchNudgeInitialDelay
        pendingLaunchNudgeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.pendingLaunchNudgeTask = nil
            await self.sendPendingLaunchNudge()
        }
    }

    private func cancelPendingLaunchNudge() {
        pendingLaunchNudgeTask?.cancel()
        pendingLaunchNudgeTask = nil
        pendingLaunchNudgeHasFired = false
    }

    /// The one line each way: sent when the first nudge goes out, and when a
    /// turn that follows one finally ends with nothing pending. More than one
    /// line per nudge round is noise a run's log doesn't need.
    private func announceFirstNudgeIfNeeded() {
        guard !pendingLaunchNudgeHasFired else { return }
        messages.append(Message(
            id: UUID(), timestamp: .now, sender: .system,
            content: .text("Still waiting on the background agent — nudging the worker to continue.")
        ))
        pendingLaunchNudgeHasFired = true
    }

    private func announceNudgeReportArrivedIfNeeded() {
        guard pendingLaunchNudgeHasFired else { return }
        messages.append(Message(
            id: UUID(), timestamp: .now, sender: .system,
            content: .text("The background agent's report arrived — continuing.")
        ))
    }

    /// Gives the worker one more turn to check on the background agent it
    /// launched — the fixed nudge text, sent the same way a human's answer
    /// is (`respondToHuman`), over the same drain loop `runTurnAndFinish`
    /// uses. `finishTurn`, which this turn runs through like any other, is
    /// what reschedules, cancels, or hands off from here.
    ///
    /// A turn that comes back saying literally nothing — not even the launch
    /// acknowledgement a real reply would carry — is not a report and must
    /// not be read as one: `messages` is left exactly as `finishTurn` would
    /// find it after any other silent stretch, so the stall watchdog is what
    /// ends a session that never answers, not a nudge mistaken for its cue.
    private func sendPendingLaunchNudge() async {
        guard orchestrator.pendingBackgroundAgentCount(for: agentID) > 0 else { return }
        // A stall-killed or restarted session leaves no session behind, but
        // never clears the count it left pending — without this a nudge
        // scheduled before the kill would wake to a dead session and, seeing
        // the count still set, reschedule itself forever.
        guard orchestrator.hasSession(for: agentID) else { return }
        guard !isStreaming else {
            // Something else — a human's own message, most likely — is
            // already using this turn. Don't overlap it; try again shortly.
            schedulePendingLaunchNudge()
            return
        }
        announceFirstNudgeIfNeeded()

        let turnStartIndex = messages.count
        isStreaming = true
        streamingStartTime = Date()

        var receivedResult = false
        var finalText = ""
        await runTurnWithWatchdog {
            finalText = await drainTurn(
                orchestrator.send(Self.pendingLaunchNudgeText, to: agentID),
                receivedResult: &receivedResult
            )
        }

        isStreaming = false
        streamingStartTime = nil

        guard messages.count > turnStartIndex else {
            orchestrator.markTurnDone(agentID: agentID)
            saveMessages()
            schedulePendingLaunchNudge()
            return
        }

        await finishTurn(receivedResult: &receivedResult, finalText: &finalText, turnStartIndex: turnStartIndex)
        saveMessages()
    }

    /// Runs the tool-call continuation loop over `initialStream`, then the
    /// turn's hand-off tail (`finishTurn`) — the one shape `send()` and
    /// `respondToHuman()` both drive a turn through, from whichever stream
    /// starts it. Returns whether a `.result` was ever seen, which is all
    /// either caller needs back.
    private func runTurnAndFinish(initialStream: AsyncStream<StreamEvent>, turnStartIndex: Int) async -> Bool {
        var receivedResult = false
        var lastFinalText = ""
        await runTurnWithWatchdog {
            lastFinalText = await drainTurn(initialStream, receivedResult: &receivedResult)
        }
        await finishTurn(receivedResult: &receivedResult, finalText: &lastFinalText, turnStartIndex: turnStartIndex)
        return receivedResult
    }

    /// Follows a stream through `processStream`'s tool-call continuations
    /// until a turn actually finishes, resolving each `.continueWithToolResult`
    /// against the same session before reading the next chunk. Shared by every
    /// caller that drives a turn to its end — `runTurnAndFinish` and the
    /// pending-launch nudge — so the continuation shape lives in one place.
    private func drainTurn(
        _ initialStream: AsyncStream<StreamEvent>,
        receivedResult: inout Bool,
        while isCurrent: () -> Bool = { true }
    ) async -> String {
        var currentStream: AsyncStream<StreamEvent>? = initialStream
        var finalText = ""
        while let stream = currentStream {
            currentStream = nil
            switch await processStream(stream, receivedResult: &receivedResult, while: isCurrent) {
            case .continueWithToolResult(let id, let content):
                currentStream = orchestrator.sendToolResult(toolCallID: id, content: content, to: agentID)
            case .finished(let text):
                finalText = text
            }
        }
        return finalText
    }

    /// How many of this turn's tool calls are an Agent-tool launch this turn
    /// never saw resolved — the messages a turn appended are the only record
    /// of what it did, so this reads those rather than hooking `processStream`
    /// itself. See `PendingAgentLaunch`.
    private static func countPendingAgentLaunches(in turnMessages: ArraySlice<Message>) -> Int {
        var toolNames: [String: String] = [:]
        var pending = 0
        for message in turnMessages {
            switch message.content {
            case .toolCall(let call):
                toolNames[call.id] = call.name
            case .toolResult(let result):
                if PendingAgentLaunch.isLaunchAcknowledgement(toolName: toolNames[result.toolCallID], output: result.output) {
                    pending += 1
                }
            default:
                break
            }
        }
        return pending
    }

    /// Gives a workflow node's agent one more turn when something checked at
    /// hand-off has to be said to it while it can still act — today, that git
    /// says it changed no files (`EmptyDiffHandoff`).
    ///
    /// Runs before `markTurnDone` and before the node completes, so the agent
    /// answers in the same session with its full context, and its reply — not
    /// the reply it had already given — is what `completeActiveWorkflowNode`
    /// records as the closing message. That reply is the point: a worker saying
    /// *why* it believes an item is already implemented is the outcome nobody
    /// could see before.
    ///
    /// Does nothing at all unless the orchestrator's check has something to say,
    /// which for an ordinary chat is never. It asks the check once and runs at
    /// most one extra turn; "at most once per run" is the check's own business.
    private func runWorkflowHandoffTurn(receivedResult: inout Bool, finalText: inout String) async {
        guard let handoff = await orchestrator.workflowHandoffMessage(for: agentID) else { return }
        messages.append(Message(id: UUID(), timestamp: .now, sender: .system,
                                content: .text(handoff)))
        await runExtraTurn(handoff, receivedResult: &receivedResult, finalText: &finalText)
    }

    /// Delivers whatever an operator has handed this agent while it was working
    /// (`RunSteerNote`), as one more turn in the same session.
    ///
    /// Runs in the same seam as the hand-off turn and just before it, so a note
    /// that makes the worker do the thing it had not done is reflected in the
    /// git the hand-off check then reads — telling a worker its diff is empty
    /// when the steer it was just given filled it would be a lie about the tree.
    ///
    /// Guarded on the agent being on a workflow node at all. Nothing queues
    /// notes for an ordinary chat, but the queue outlives the turn that should
    /// have drained it (a killed run, a crashed session), and a stray note
    /// surfacing days later in someone's chat is worse than a note that was
    /// never delivered.
    private func runSteerNoteTurn(receivedResult: inout Bool, finalText: inout String) async {
        guard await orchestrator.activeWorkflowExecution(for: agentID) != nil else { return }
        let notes = orchestrator.takeSteerNotes(for: agentID)
        guard !notes.isEmpty else { return }

        for note in notes {
            messages.append(Message(id: UUID(), timestamp: .now, sender: .system,
                                    content: .text(RunSteerNote.transcriptLine(note))))
        }
        await runExtraTurn(RunSteerNote.prompt(notes),
                           receivedResult: &receivedResult, finalText: &finalText)
    }

    /// Runs one more turn in the agent's live session and folds its stream into
    /// the caller's turn bookkeeping — the same loop `send()` runs, so a tool
    /// call inside the extra turn continues it rather than ending it.
    ///
    /// Shared by the two things that speak to a workflow node's agent between
    /// its last turn and its node completing: an operator's steer and the
    /// empty-diff hand-off. Both need the agent's reply to become `finalText`,
    /// because that is what `completeActiveWorkflowNode` records as the node's
    /// closing message.
    private func runExtraTurn(_ prompt: String, receivedResult: inout Bool, finalText: inout String) async {
        var currentStream: AsyncStream<StreamEvent>? = orchestrator.send(prompt, to: agentID)
        var received = receivedResult
        var lastText = finalText
        await runTurnWithWatchdog {
            while let stream = currentStream {
                currentStream = nil
                switch await processStream(stream, receivedResult: &received) {
                case .continueWithToolResult(let id, let content):
                    currentStream = orchestrator.sendToolResult(toolCallID: id, content: content, to: agentID)
                case .finished(let text):
                    lastText = text
                }
            }
        }
        receivedResult = received
        finalText = lastText
    }

    /// Emits nodeCompleted for the agent's active workflow node, if any —
    /// shared by every turn tail (send, respondToHuman).
    ///
    /// The agent's closing words ride along on the completion output under
    /// `RunClosingMessage.outputKey`, whatever the node's schema pulled out of
    /// them. This is the only moment they exist: the extractor keeps the fields
    /// a schema names and drops the rest, so a worker node — which has no schema
    /// at all — used to complete with the text discarded. A run that then turns
    /// out to have produced nothing has no way back to it. See
    /// `RunClosingMessage`.
    private func completeActiveWorkflowNode(finalText: String) async {
        // `captured`, not `condensed`: the display bound is applied where the
        // message is shown, and applying it here threw away everything past 300
        // characters before anything could read it — including the structured
        // claim `RunWorkEvidence.AlreadyImplementedClaim` looks for.
        let closing = RunClosingMessage.captured(finalText)
        let ending = takeLastLegEnding()
        if let (executionID, nodeID, schema) = await orchestrator.activeWorkflowNode(for: agentID) {
            var output = StructuredOutputExtractor.extract(from: finalText, schema: schema) ?? [:]
            if let closing { output[RunClosingMessage.outputKey] = .string(closing) }
            output.merge(ending) { _, reported in reported }
            let event = WorkflowEvent(
                executionID: executionID,
                nodeID: nodeID,
                agentID: agentID,
                type: .nodeCompleted,
                output: output
            )
            orchestrator.handleWorkflowEvent(event)
        } else if let (executionID, nodeID) = await orchestrator.activeWorkflowExecution(for: agentID) {
            var output = ending
            if let closing { output[RunClosingMessage.outputKey] = .string(closing) }
            let event = WorkflowEvent(
                executionID: executionID,
                nodeID: nodeID,
                agentID: agentID,
                type: .nodeCompleted,
                output: output
            )
            orchestrator.handleWorkflowEvent(event)
        }
    }

    /// How the session's last leg ended, as its `result` line said — kept from
    /// `recordResult` until the node completes. The turn count, and whether the
    /// turn cap is what ended it: a worker that ran out of turns hands off a
    /// half-written tree, and the run has to know that rather than judge it
    /// as finished work.
    private var lastLegTurns: Int?
    private var lastLegEndedOnTurnCap = false

    /// The last leg's ending as completion output keys, cleared as it is read
    /// so a later node never inherits an earlier session's cap.
    private func takeLastLegEnding() -> [String: AnyCodable] {
        var output: [String: AnyCodable] = [:]
        if let turns = lastLegTurns { output[StreamEvent.ResultPayload.turnsOutputKey] = .int(turns) }
        if lastLegEndedOnTurnCap { output[StreamEvent.ResultPayload.turnCapOutputKey] = .bool(true) }
        lastLegTurns = nil
        lastLegEndedOnTurnCap = false
        return output
    }

    private static let streamFlushInterval: UInt64 = 33_000_000 // 33ms (~30fps)

    // MARK: - Hung-Turn Watchdog

    /// A turn with no stream events for this long is considered hung.
    /// Long silences are normal while the model works, so this is generous.
    private static let streamInactivityTimeout: TimeInterval = 600 // 10 minutes

    private var lastStreamEventAt = Date()

    /// What the agent is doing right now ("Edit · index.md", "Thinking", …),
    /// shown in the live activity ticker while streaming.
    private(set) var currentActivity: String?

    /// The command behind `currentActivity` when the label is standing in for
    /// one, shown as the ticker's tooltip. A description says what a call is
    /// for; the command is what a failure is diagnosed from, so the ticker keeps
    /// both rather than trading one for the other.
    private(set) var currentActivityDetail: String?

    /// What this session has running beside the conversation — its subagents,
    /// background shells, thinking estimate and rate-limit standing — folded
    /// from the stream. Belongs to the session: a new chat, a switch to another
    /// or a restarted process starts it over.
    private(set) var agentActivity = AgentActivity()

    /// Sets both halves of the ticker together, so the tooltip can never be left
    /// carrying the command of a call that has already finished.
    private func setActivity(_ label: String?, detail: String? = nil) {
        currentActivity = label
        currentActivityDetail = detail
    }

    /// Runs a turn body under an inactivity watchdog. If the stream goes
    /// silent past the timeout the turn is interrupted; if the process also
    /// ignores the interrupt, it is stopped so the stream terminates and the
    /// normal recovery path takes over. Without this, a wedged CLI process
    /// leaves the chat stuck in "streaming" forever.
    private func runTurnWithWatchdog(_ body: () async -> Void) async {
        lastStreamEventAt = Date()
        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, !Task.isCancelled else { return }
                // Waiting on a human answer — a question or an MCP access
                // card — is legitimate idle time, not a hang.
                if self.pendingHumanToolCallID != nil || self.pendingMCPAuthRequestID != nil {
                    self.lastStreamEventAt = Date()
                    continue
                }
                guard Date().timeIntervalSince(self.lastStreamEventAt) > Self.streamInactivityTimeout else { continue }

                chatLog.error("[watchdog] \(self.agentID, privacy: .public): no stream events for \(Int(Self.streamInactivityTimeout), privacy: .public)s — interrupting turn")
                self.messages.append(Message(
                    id: UUID(), timestamp: .now, sender: .system,
                    content: .text("No response from the agent for \(Int(Self.streamInactivityTimeout / 60)) minutes — interrupting.")
                ))
                self.orchestrator.interrupt(agentID: self.agentID)

                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                if Date().timeIntervalSince(self.lastStreamEventAt) > Self.streamInactivityTimeout {
                    chatLog.error("[watchdog] \(self.agentID, privacy: .public): interrupt ignored — stopping agent process")
                    self.messages.append(Message(
                        id: UUID(), timestamp: .now, sender: .system,
                        content: .text("The agent didn't respond to the interrupt — its process was stopped. Use Restart Agent to continue.")
                    ))
                    self.orchestrator.stopAgent(self.agentID)
                }
                return
            }
        }
        await body()
        watchdog.cancel()
        setActivity(nil)
    }

    /// What the ticker shows for one tool call, and what it keeps behind it.
    struct Activity: Equatable {
        /// The line in the ticker.
        let label: String
        /// The command the label stands in for, in full, shown as the ticker's
        /// tooltip. Nil when the label is already the whole of what was said.
        let detail: String?
    }

    /// Short human label for what a tool call is doing, for the ticker.
    ///
    /// `Bash` and `Agent` carry a `description` — the sentence saying what the
    /// call is for — so that is what the ticker shows; the command stays with it
    /// as `detail`. Everything else is named by the argument `ToolCallLabel`
    /// holds for it — the file, the pattern, the agent messaged, the page
    /// opened — the same one the transcript row is named by.
    ///
    /// Internal rather than private so `ChatViewModelActivityLabelTests` can
    /// assert it: the ticker is a transient view of a live stream, and the turn
    /// clears `currentActivity` before it ends, so there is no path to the
    /// string it showed once the turn is over.
    func activityLabel(tool: String, input: String) -> Activity {
        guard let data = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Activity(label: tool, detail: nil)
        }
        let command = ToolCallLabel.detail(tool: tool, input: json)
        if let description = ToolCallLabel.description(tool: tool, input: json) {
            return Activity(label: "\(tool) · \(ToolCallLabel.shorten(description, limit: 60))",
                            detail: command)
        }
        guard let argument = ToolCallLabel.argumentSummary(tool: tool, input: json,
                                                           widths: .ticker) else {
            return Activity(label: tool, detail: command)
        }
        return Activity(label: "\(tool) · \(argument)", detail: command)
    }

    /// The assistant text arriving in this turn, and when it was last written
    /// into the message list. The stream appends far faster than a view can
    /// draw, so a run of text is written back at most every 33ms;
    /// `pendingFlush` is the note that the newest chunk has not been written
    /// yet and something must write it before the text stops being current.
    private struct StreamingText {
        var current = ""
        var pendingFlush = false
        var lastFlush = ContinuousClock.now
    }

    /// `isCurrent` is asked before each event: once it says no — the chat
    /// was cleared or switched under a turn the session started by itself —
    /// nothing more of the stream is written, not even text still owed to
    /// the list, which now belongs to another chat.
    private func processStream(
        _ stream: AsyncStream<StreamEvent>,
        receivedResult: inout Bool,
        while isCurrent: () -> Bool = { true }
    ) async -> TurnResult {
        var text = StreamingText()

        for await event in stream {
            guard isCurrent() else { return .finished(finalText: "") }
            lastStreamEventAt = Date()
            // Records whatever the previous event appended. Doing it here rather
            // than at the end of the turn is what keeps a hung or killed run's
            // evidence on disk.
            flushTranscript()
            if let result = await handleStreamEvent(event, text: &text, receivedResult: &receivedResult) {
                return result
            }
        }
        writePendingText(&text)
        flushTranscript(final: true)
        return .finished(finalText: text.current)
    }

    /// One event off the stream, grouped by what the event is about: the
    /// assistant's own output, tool traffic, or what the session says about the
    /// turn itself. Non-nil when the event ends the turn — only a tool call
    /// Kiteloop answers itself does that, by handing the answer back for the
    /// next turn. The switch is exhaustive, so a new `StreamEvent` case has to
    /// be given a group here before it compiles.
    private func handleStreamEvent(
        _ event: StreamEvent,
        text: inout StreamingText,
        receivedResult: inout Bool
    ) async -> TurnResult? {
        switch event {
        case .thinking, .assistantText, .image:
            await handleAssistantOutput(event, text: &text)
        case .toolUse, .toolResult, .mcpToolCall:
            return await handleToolEvent(event, text: &text)
        case .result, .hook, .system, .unknown:
            await handleTurnMetadata(event, currentText: text.current, receivedResult: &receivedResult)
        }
        return nil
    }

    // MARK: - Streamed text

    /// Writes the text streamed so far into the message already on the list. A
    /// run of prose is one message the stream keeps editing, not a message per
    /// chunk, so this is what makes a partial answer visible.
    private func writeStreamedText(_ text: inout StreamingText) {
        if let lastIndex = messages.indices.last {
            messages[lastIndex].content = .text(text.current)
        }
        text.pendingFlush = false
    }

    /// The same write, for a chunk that arrived too soon after the last one to
    /// be written then. A no-op when nothing is owed.
    private func writePendingText(_ text: inout StreamingText) {
        guard text.pendingFlush else { return }
        writeStreamedText(&text)
    }

    // MARK: - Assistant output

    /// The three events carrying what the assistant itself produced. Each ends
    /// the current run of streamed prose, because the next chunk starts a new
    /// message rather than extending one an image or a thought interrupted.
    private func handleAssistantOutput(_ event: StreamEvent, text: inout StreamingText) async {
        switch event {
        case .thinking(let thought, parentToolUseID: nil):
            setActivity("Thinking")
            messages.append(.agentThinking(thought, agent: agentID,
                                           estimatedTokens: agentActivity.takeThinkingEstimate()))
            text.current = ""
        case .assistantText(let chunk, parentToolUseID: nil):
            await appendAssistantText(chunk, to: &text)
        case .thinking(let thought, let parent?):
            appendSubagentOutput(.agentThinking(thought, agent: agentID, parent: parent), text: &text)
        case .assistantText(let chunk, let parent?):
            appendSubagentOutput(.agentText(chunk, agent: agentID, parent: parent), text: &text)
        case .image(let base64Data, _):
            if let data = Data(base64Encoded: base64Data) {
                messages.append(.agentImage(data, agent: agentID))
            }
            text.current = ""
        default:
            break
        }
    }

    /// What a subagent thought or said, kept under the `Agent` call it belongs
    /// to. It arrives whole, never in chunks, and it ends the agent's own run
    /// of prose: the next chunk of that must start a message of its own
    /// rather than write over this one.
    private func appendSubagentOutput(_ message: Message, text: inout StreamingText) {
        writePendingText(&text)
        messages.append(message)
        text.current = ""
    }

    /// A chunk of streamed prose: the first appends the message, the rest edit
    /// it in place — but only once every 33ms, since a write per chunk redraws
    /// the transcript far faster than anyone reads it. A chunk that arrives
    /// inside that window is left owed, for the next write to pick up.
    private func appendAssistantText(_ chunk: String, to text: inout StreamingText) async {
        setActivity("Writing")
        guard !text.current.isEmpty else {
            text.current = chunk
            messages.append(.agentText(text.current, agent: agentID))
            text.lastFlush = .now
            return
        }
        text.current += chunk
        guard ContinuousClock.now - text.lastFlush >= .milliseconds(33) else {
            text.pendingFlush = true
            return
        }
        writeStreamedText(&text)
        text.lastFlush = .now
        await Task.yield()
    }

    // MARK: - Tool traffic

    /// The model reaching for a tool, a result coming back, and the MCP calls
    /// Kiteloop answers over the pipe.
    private func handleToolEvent(_ event: StreamEvent, text: inout StreamingText) async -> TurnResult? {
        switch event {
        case .toolUse(let id, let name, let input, let parent):
            return await handleToolUse(id: id, name: name, input: input, parent: parent, text: &text)
        case .toolResult(let id, let output, let parent):
            recordToolResult(id: id, output: output, parent: parent)
        case .mcpToolCall(let call):
            await handleMCPToolCall(call)
        default:
            break
        }
        return nil
    }

    /// A tool call, in the order the three kinds are told apart: `ask_human`
    /// pauses the turn, a Kiteloop-native tool is answered here and the answer
    /// handed back for the next turn, and anything else is the CLI's own tool,
    /// which only needs to go on the transcript.
    private func handleToolUse(
        id: String,
        name: String,
        input: String,
        parent: String?,
        text: inout StreamingText
    ) async -> TurnResult? {
        writePendingText(&text)
        let activity = activityLabel(tool: name, input: input)
        setActivity(activity.label, detail: activity.detail)
        if InterceptedTool(rawValue: name) == .askHuman {
            await pauseForHuman(id: id, input: input)
            text.current = ""
            return nil
        }
        if name == "TaskCreate" || name == "TaskUpdate" {
            mirrorCLITaskCall(name: name, input: input, parent: parent)
            recordToolCall(id: id, name: name, input: input, parent: parent, text: &text)
            return nil
        }
        if let result = await handleCustomTool(name: name, input: input) {
            recordToolCall(id: id, name: name, input: input, parent: parent, text: &text)
            return .continueWithToolResult(toolCallID: id, content: result)
        }
        if let intercepted = InterceptedTool(rawValue: name) {
            let result = await ToolInterceptor.handle(
                tool: intercepted, input: input,
                agentID: agentID, orchestrator: orchestrator
            )
            recordToolCall(id: id, name: name, input: input, parent: parent, text: &text)
            return .continueWithToolResult(toolCallID: id, content: result)
        }
        recordToolCall(id: id, name: name, input: input, parent: parent, text: &text)
        return nil
    }

    /// The CLI's own `TaskCreate`/`TaskUpdate`, which the CLI has already
    /// answered: they only move the Agent Tasks panel. Kiteloop's MCP tools of
    /// the same names arrive as `.mcpToolCall` and never reach here. A
    /// subagent's task list is its own, so a call with a parent moves nothing.
    private func mirrorCLITaskCall(name: String, input: String, parent: String?) {
        guard parent == nil,
              let data = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if name == "TaskCreate" {
            mirrorCLITaskCreate(json)
        } else {
            mirrorCLITaskUpdate(json)
        }
    }

    private func mirrorCLITaskCreate(_ json: [String: Any]) {
        guard let subject = json["subject"] as? String else { return }
        cliTaskCount += 1
        agentTasks.append(AgentTask(
            id: "\(cliTaskCount)", subject: subject,
            description: json["description"] as? String ?? "",
            status: .pending, agentID: agentID,
            createdAt: Date(), updatedAt: Date()
        ))
    }

    /// Unlike the MCP tool, nothing is refused: the CLI has its own vocabulary
    /// (`deleted`, or no status at all), and a status this panel cannot show
    /// leaves the task's status where it was.
    private func mirrorCLITaskUpdate(_ json: [String: Any]) {
        guard let taskID = json["taskId"] as? String,
              let idx = agentTasks.firstIndex(where: { $0.id == taskID }) else { return }
        let statusRaw = json["status"] as? String
        if statusRaw == "deleted" {
            agentTasks.remove(at: idx)
            return
        }
        let status = statusRaw.flatMap(AgentTask.TaskStatus.init(rawValue:))
        let subject = json["subject"] as? String
        let description = json["description"] as? String
        guard status != nil || subject != nil || description != nil else { return }
        agentTasks[idx].status = status ?? agentTasks[idx].status
        agentTasks[idx].subject = subject ?? agentTasks[idx].subject
        agentTasks[idx].description = description ?? agentTasks[idx].description
        agentTasks[idx].updatedAt = Date()
    }

    /// Puts the call on the transcript and ends the run of streamed text:
    /// whatever the model said before reaching for a tool is finished. A call a
    /// subagent made keeps the id of the `Agent` call it belongs under.
    ///
    /// A call that writes a file is also recorded against this agent, which is
    /// what lets an autopilot run tell its own writes from anyone else's
    /// (`RunWorkEvidence.strayWork`).
    private func recordToolCall(id: String, name: String, input: String, parent: String?, text: inout StreamingText) {
        let call = Message.ToolCall(id: id, name: name, input: input, parentToolUseID: parent)
        messages.append(.toolCall(call, agent: agentID))
        // Relative to where the session actually runs: a run's pinned
        // worktree, not the project root it would otherwise be blamed on.
        let cwd = orchestrator.pinnedWorkingDirectory(for: agentID) ?? projectURL
        if let path = RunWorkEvidence.writtenPath(toolName: name, input: input, relativeTo: cwd) {
            orchestrator.recordWrittenPath(path, for: agentID)
        }
        text.current = ""
    }

    /// `ask_human` pauses the turn: the question renders as an approval bubble
    /// and the stream idles until `respondToHuman()` continues it.
    private func pauseForHuman(id: String, input: String) async {
        let result = await ToolInterceptor.handle(
            tool: .askHuman, input: input,
            agentID: agentID, orchestrator: orchestrator
        )
        let question = String(result.dropFirst("__WAITING_FOR_HUMAN__:".count))
        pendingHumanToolCallID = id
        orchestrator.notify(agentID: agentID, type: .question, title: "\(agentName) needs input", body: question,
                            projectPath: project.rootURL.path(percentEncoded: false))
        messages.append(Message(
            id: UUID(), timestamp: .now, sender: .agent(agentID),
            content: .approval(Message.ApprovalRequest(
                id: id, action: question, tool: "ask_human"
            ))
        ))
        // The wait is unbounded, so the turn behind the question is written now
        // rather than at the turn boundary that may never come.
        saveMessages()
    }

    /// A tool's output.
    private func recordToolResult(id: String, output: String, parent: String?) {
        let result = Message.ToolResult(
            id: UUID().uuidString, toolCallID: id, output: output, parentToolUseID: parent
        )
        messages.append(.toolResult(result, agent: agentID))
    }

    /// An MCP call arriving over the pipe. Unlike `.toolUse` these are answered
    /// in place — the CLI is blocked on the response, not on the next turn.
    private func handleMCPToolCall(_ call: StreamEvent.MCPToolCallPayload) async {
        chatLog.info("[stream] .mcpToolCall tool=\(call.toolName, privacy: .public) reqID=\(call.requestID, privacy: .public)")
        if call.toolName == "request_mcp_server" {
            handleMCPServerRequest(call: call)
            return
        }
        let result = await handleCustomTool(name: call.toolName, input: call.input) ?? "Error: unhandled tool"
        chatLog.info("[stream] responding reqID=\(call.requestID, privacy: .public) result=\(result.prefix(80))")
        orchestrator.respondToMCPToolCall(requestID: call.requestID, result: result, agentID: agentID)
    }

    // MARK: - What the session says about the turn

    /// Everything the stream reports about the turn rather than its content:
    /// the closing result, a hook that spoke up, and the session's notices.
    private func handleTurnMetadata(
        _ event: StreamEvent,
        currentText: String,
        receivedResult: inout Bool
    ) async {
        switch event {
        case .result(let payload):
            receivedResult = true
            await recordResult(payload, currentText: currentText)
        case .hook(let payload):
            appendHookNote(payload)
        case .system(let subtype, let payload):
            handleSystemNotice(subtype: subtype, payload: payload)
        default:
            break
        }
    }

    /// The turn's closing frame: what it cost, what it used, where to resume it
    /// from, and the answer itself when the text never streamed.
    private func recordResult(_ payload: StreamEvent.ResultPayload, currentText: String) async {
        let costDeltaUSD = Self.costDelta(for: payload, lastSeenBySession: &lastSeenCostBySession)
        await recordTurnSpan(payload: payload, costDeltaUSD: costDeltaUSD)
        costUSD += costDeltaUSD
        if let window = payload.contextWindow(for: resolvedModel) {
            reportedContextWindowSize = window
        }
        lastInputTokens = payload.inputTokens
        lastOutputTokens = payload.outputTokens
        lastDurationMs = payload.durationMs
        cacheCreationTokens = payload.cacheCreationInputTokens
        cacheReadTokens = payload.cacheReadInputTokens
        persistSessionID(payload.sessionID)
        // An estimate no thinking block claimed belongs to the turn just ended.
        _ = agentActivity.takeThinkingEstimate()
        lastLegTurns = payload.numTurns
        lastLegEndedOnTurnCap = payload.endedOnTurnCap
        if currentText.isEmpty && !payload.text.isEmpty {
            messages.append(.agentText(payload.text, agent: agentID))
        }
        for denial in payload.permissionDenials {
            messages.append(.permissionDenied(tool: denial.toolName, detail: denial.detail))
        }
        if let note = Self.turnStopNote(subtype: payload.subtype, numTurns: payload.numTurns) {
            postSystem(note)
        }
    }

    /// Why a turn the CLI cut short stopped, and what to do about it. Nil for
    /// one that finished (`success`) or whose runtime reports no subtype: a
    /// finished turn needs no explaining.
    static func turnStopNote(subtype: String?, numTurns: Int?) -> String? {
        switch subtype {
        case StreamEvent.ResultPayload.turnCapSubtype:
            let used = numTurns.map { " after \($0) turns" } ?? ""
            return "The turn stopped\(used): it reached the agent's turn limit. "
                + "Send \"continue\" to carry on, or raise the agent's turn limit."
        case "error_max_budget_usd":
            return "The turn stopped: it reached the agent's per-turn spend cap."
        case "error_during_execution":
            return "The turn ended with an error."
        default:
            return nil
        }
    }

    /// An aside is deliberately not resumable across a restart, so its session
    /// id is never written: the map is keyed by agent name, and every aside
    /// would leave a dead entry behind.
    private func persistSessionID(_ sessionID: String) {
        guard !sessionID.isEmpty && !isAside else { return }
        var config = project.loadConfig()
        var ids = config.agentSessionIDs ?? [:]
        ids[agentName] = sessionID
        config.agentSessionIDs = ids
        do {
            try project.saveConfig(config)
        } catch {
            // Resume after relaunch silently breaks if this doesn't land
            chatLog.error("Failed to persist session ID for \(self.agentName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A hook that had something to say — output, or a non-zero exit — gets a
    /// system line. A silent, successful hook gets none.
    private func appendHookNote(_ payload: StreamEvent.HookPayload) {
        guard payload.exitCode != 0 || !payload.output.isEmpty else { return }
        let prefix = payload.hookType == "pre_tool_use" ? "pre" : "post"
        let label = "[\(prefix)-hook: \(payload.hookName)] \(payload.toolName)"
        let detail = payload.exitCode != 0
            ? "\(label) exited \(payload.exitCode)"
            : "\(label): \(payload.output.prefix(200))"
        messages.append(Message(
            id: UUID(), timestamp: .now, sender: .system,
            content: .text(detail)
        ))
    }

    /// The session talking about itself. An unrecognised subtype is ignored —
    /// the CLI adds them, and an older Kiteloop must not break on a new one.
    private func handleSystemNotice(subtype: String, payload: [String: Any]) {
        switch subtype {
        case "init", "":
            applyInitPayload(payload)
        case "compact_boundary":
            messages.append(.systemEvent(.compaction, detail: "Context compacted — responses may drift from earlier context"))
        case "api_retry":
            appendRetryNotice(payload)
        default:
            applyActivityNotice(subtype: subtype, payload: payload)
        }
    }

    /// The opening frame: which model actually answered and, from a CLI that
    /// still says there, how much context it has. Current CLIs report the
    /// window only on a turn's `result`, which `recordResult` reads.
    private func applyInitPayload(_ payload: [String: Any]) {
        if let m = payload["model"] as? String, !m.isEmpty {
            currentModel = m
        }
        if let cws = payload["context_window_size"] as? Int, cws > 0 {
            reportedContextWindowSize = cws
        }
    }

    /// The CLI retrying a transient API error, so a long pause has a reason on
    /// screen rather than looking like a hang.
    private func appendRetryNotice(_ payload: [String: Any]) {
        let attempt = payload["attempt"] as? Int ?? 1
        let maxRetries = payload["max_retries"] as? Int ?? 3
        let error = payload["error"] as? String ?? "transient error"
        let wait = (payload["retry_delay_ms"] as? Int).map { " in \(($0 + 999) / 1000)s" } ?? ""
        let status = (payload["error_status"] as? Int).map { ", HTTP \($0)" } ?? ""
        let detail = "Retrying\(wait) (attempt \(attempt) of \(maxRetries)) — \(error)\(status)"
        replaceOrAppendRetryDivider(detail)
    }

    /// One bad stretch shows one retry line: a retry straight after another
    /// rewrites that divider with the latest attempt instead of stacking.
    private func replaceOrAppendRetryDivider(_ detail: String) {
        if let last = messages.indices.last,
           case .systemEvent(let event) = messages[last].content, event.kind == .apiRetry {
            messages[last].content = .systemEvent(Message.SystemEvent(kind: .apiRetry, detail: detail))
        } else {
            messages.append(.systemEvent(.apiRetry, detail: detail))
        }
    }

    // MARK: - Branch Navigation (UI)

    /// Switches back to the main conversation line. Mirrors `/branch main`.
    func switchToMainBranch() {
        guard !refusesLineChangeWhileStreaming() else { return }
        messages = conversationTree.switchToMain(leaving: messages)
        postSystem("Switched to main branch. \(Self.agentStillRemembersNote)")
        saveBranches()
        saveMessages()
    }

    /// Switches to a named branch, replacing the visible transcript with the
    /// branch's messages. Mirrors `/branch switch <name>`.
    func switchToBranch(id: UUID) {
        guard let branch = conversationTree.branches.first(where: { $0.id == id }) else { return }
        switchToBranch(named: branch.name)
    }

    /// Deletes a branch from the branch bar. Mirrors `/branch delete <name>`.
    func deleteBranch(id: UUID) {
        guard let branch = conversationTree.branches.first(where: { $0.id == id }) else { return }
        deleteBranch(branch)
    }

    /// Renames a branch from the branch bar, saying in the chat what it did —
    /// or, for a blank name or one another branch has, why it did nothing.
    func renameBranch(id: UUID, to newName: String) {
        guard let oldName = conversationTree.branches.first(where: { $0.id == id })?.name else {
            return postSystem("No such branch to rename.")
        }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard conversationTree.renameBranch(id, to: name) else {
            if name.lowercased() == "main" {
                return postSystem("**main** is the conversation's main line. **\(oldName)** keeps its name.")
            }
            return postSystem(name.isEmpty
                ? "A branch name cannot be blank. **\(oldName)** keeps its name."
                : "A branch named **\(name)** already exists. **\(oldName)** keeps its name.")
        }
        postSystem("Renamed branch **\(oldName)** to **\(name)**.")
        saveBranches()
        saveMessages()
    }

    /// Saves a new `branch-N` holding the transcript up to and including the
    /// message `id`, from a message row's "Branch from Here".
    func branchFromMessage(id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            return postSystem("That message is no longer in this conversation, so no branch was made.")
        }
        let name = unusedDefaultBranchName()
        _ = conversationTree.createBranch(name: name, from: id, messages: Array(messages[...index]))
        announceSavedBranch(named: name)
    }

    /// The branches made from message `id`, less the one being shown — what
    /// that message's row marks and offers to switch to.
    func branchesForked(at id: UUID) -> [ConversationBranch] {
        conversationTree.branchesFrom(messageID: id).filter { $0.id != conversationTree.activeBranchID }
    }

    /// Records a completed turn to the project's trace store for the trace browser
    /// and for cost attribution.
    ///
    /// The span is stamped with the run that owns it — the workflow execution the
    /// agent is currently reserved by, and the node it is acting as (`worker`,
    /// `reviewer`, …). That is what lets a run's cost be *selected* later rather
    /// than reconstructed from agent ids and a time window, which is an inference
    /// that silently returns the wrong number when it misses.
    ///
    /// A turn with no owning execution — a human chatting to an agent — is stamped
    /// with neither key, and so belongs to no item's cost.
    ///
    /// All four usage counters and the model are recorded, not just the CLI's
    /// dollar figure: without them spend cannot be re-priced when rates move,
    /// compared across models, or checked for cache hit rate — which is the
    /// largest single lever on what a long run costs. The derived cost sits
    /// beside the reported one rather than replacing it, so the two can be
    /// compared instead of one quietly standing in for the other.
    /// Recovers a turn's own cost from the CLI's session-level running total.
    ///
    /// `result.total_cost_usd` is the session's running total, monotonically
    /// nondecreasing turn over turn — not a per-turn amount. What a turn
    /// actually added is the increase over the last total that session
    /// reported. A later total lower than the last seen means the session
    /// itself restarted (`/clear`, resume, a fresh guest session for a
    /// consult) and reset the CLI's own total near zero, so that turn's delta
    /// is read as the new total itself rather than as negative spend.
    nonisolated static func costDelta(
        for payload: StreamEvent.ResultPayload,
        lastSeenBySession: inout [String: Double]
    ) -> Double {
        let key = payload.sessionID.isEmpty ? "unknown" : payload.sessionID
        let previous = lastSeenBySession[key] ?? 0
        let baseline = payload.costUSD < previous ? 0 : previous
        let delta = max(0, payload.costUSD - baseline)
        lastSeenBySession[key] = payload.costUSD
        return delta
    }

    private func recordTurnSpan(payload: StreamEvent.ResultPayload, costDeltaUSD: Double) async {
        guard let store = orchestrator.traceStore else { return }
        let end = Date()
        let usage = TokenUsage(
            inputTokens: payload.inputTokens,
            outputTokens: payload.outputTokens,
            cacheCreationTokens: payload.cacheCreationInputTokens,
            cacheReadTokens: payload.cacheReadInputTokens
        )
        let model = resolvedModel
        var metadata = [
            TraceSpan.MetadataKey.costUSD: String(format: "%.6f", payload.costUSD),
            TraceSpan.MetadataKey.costDeltaUSD: String(format: "%.6f", costDeltaUSD),
            TraceSpan.MetadataKey.inputTokens: String(usage.inputTokens),
            TraceSpan.MetadataKey.outputTokens: String(usage.outputTokens),
            TraceSpan.MetadataKey.cacheCreationTokens: String(usage.cacheCreationTokens),
            TraceSpan.MetadataKey.cacheReadTokens: String(usage.cacheReadTokens),
        ]
        if !model.isEmpty { metadata[TraceSpan.MetadataKey.model] = model }
        // What the turn's first model call was sent, kept apart from the four
        // counters above. Those are summed over every call the leg made, so a
        // worker leg that read twenty files reports them in the same figure —
        // which is why "what does the opening context cost" could not be
        // answered from a turn span until this was recorded beside it.
        if let opening = payload.openingUsage {
            metadata[TraceSpan.MetadataKey.openingInputTokens] = String(opening.inputTokens)
            metadata[TraceSpan.MetadataKey.openingCacheCreationTokens] = String(opening.cacheCreationTokens)
            metadata[TraceSpan.MetadataKey.openingCacheReadTokens] = String(opening.cacheReadTokens)
        }
        // Priced at the card in force when the turn ran — not at whatever the
        // card says later — so re-pricing history is a choice, not a drift. Absent
        // for a model the table doesn't price (Ollama, the Copilot bridge): no
        // derived cost is honest there, $0.00 would not be.
        if let priced = ModelPriceTable.current.cost(of: usage, model: model, on: end) {
            metadata[TraceSpan.MetadataKey.derivedCostUSD] = String(format: "%.6f", priced.usd)
            metadata[TraceSpan.MetadataKey.priceVersion] = priced.priceVersion
        }
        if let (executionID, nodeID) = await orchestrator.activeWorkflowExecution(for: agentID) {
            metadata[TraceSpan.MetadataKey.executionID] = executionID
            metadata[TraceSpan.MetadataKey.role] = nodeID
        }
        let span = TraceSpan(
            id: UUID().uuidString,
            agentID: agentID,
            sessionID: payload.sessionID.isEmpty ? "unknown" : payload.sessionID,
            startTime: end.addingTimeInterval(-Double(payload.durationMs) / 1000.0),
            endTime: end,
            type: .turn,
            metadata: metadata
        )
        // Awaited rather than detached: the run that owns this turn reads the
        // spans back moments after the last one is emitted, and a write still in
        // flight is a turn missing from the total.
        await store.append(span)
    }

    // MARK: - Run Transcript

    /// Resolves which run this turn belongs to, so the records it produces can be
    /// stamped with it.
    ///
    /// Ownership comes from the workflow reservation rather than from a time
    /// window over the agent's rolling session — the same write-time attribution
    /// that made turn spans answerable. A turn owned by no run records nothing:
    /// human conversation belongs in the chat session, not in a run's evidence.
    private func beginTranscriptTurn() async {
        guard orchestrator.runTranscriptStore != nil else { return }
        guard let (executionID, role) = await orchestrator.activeWorkflowExecution(for: agentID) else {
            transcriptRun = nil
            return
        }
        // The same agent runs many items, and a run may take several turns. A new
        // run starts its transcript at the prompt that opened it; a further turn
        // of the same run carries on from where the last one stopped.
        if transcriptRun?.executionID != executionID || transcriptRun?.role != role {
            transcriptRun = (executionID, role)
            transcriptCursor = max(0, messages.count - 1)
        }
        transcriptCursor = min(transcriptCursor, messages.count)
    }

    /// Hands the records produced since the last flush to the run's transcript.
    ///
    /// Called as the stream runs rather than only at the end, so a run that hangs
    /// or dies mid-turn still leaves the record of what it did — which is the
    /// case the transcript exists for. The last message is held back while the
    /// turn is live because assistant text is mutated in place as it streams, and
    /// a record written from a half-arrived message is a record of nothing.
    private func flushTranscript(final: Bool = false) {
        guard let store = orchestrator.runTranscriptStore, let run = transcriptRun else { return }
        let end = final ? messages.count : messages.count - 1
        guard transcriptCursor < end else {
            transcriptCursor = min(transcriptCursor, messages.count)
            return
        }
        let records = messages[transcriptCursor..<end].map {
            RunTranscriptStore.Record(
                executionID: run.executionID,
                role: run.role,
                agentID: agentID,
                recordedAt: $0.timestamp,
                message: $0
            )
        }
        transcriptCursor = end

        let previous = transcriptWrite
        transcriptWrite = Task.detached(priority: .utility) {
            await previous?.value
            await store.append(records)
        }
    }

    /// Answers a Kiteloop-native tool call, or `nil` when the name is none of
    /// ours and the caller should keep looking.
    ///
    /// The families are asked in turn. Each owns a surface that grows on its own
    /// schedule — the team roster, the project's shared record, the long-running
    /// loops, the preview pane — so adding a tool is a change to one family and
    /// this list holds still. No name belongs to two families, so the order they
    /// are asked in is not part of the behaviour.
    private func handleCustomTool(name: String, input: String) async -> String? {
        if let result = await handleTeamTool(name: name, input: input) { return result }
        if let result = await handleWorkspaceTool(name: name, input: input) { return result }
        if let result = await handleLoopTool(name: name, input: input) { return result }
        if let result = await handleWebActionTool(name: name, input: input) { return result }
        return await handleWebReadTool(name: name)
    }

    /// Tools that change who is on the team, or say something to them.
    private func handleTeamTool(name: String, input: String) async -> String? {
        switch name {
        case "message_agent": return await handleMessageAgent(input: input)
        case "broadcast_agents": return await handleBroadcastAgents(input: input)
        case "hire_agent": return await handleHireAgent(input: input)
        case "fire_agent": return handleFireAgent(input: input)
        default: return nil
        }
    }

    /// Tools that read or write the project's shared record — the event bus, the
    /// memory proposals, the task list, the knowledge base.
    private func handleWorkspaceTool(name: String, input: String) async -> String? {
        switch name {
        case "publish_event": return handlePublishEvent(input: input)
        case "propose_memory": return await handleProposeMemory(input: input)
        case "TaskCreate": return handleTaskCreate(input: input)
        case "TaskUpdate": return handleTaskUpdate(input: input)
        case "recall_knowledge": return await handleRecallKnowledge(input: input)
        case "save_knowledge": return await handleSaveKnowledge(input: input)
        default: return nil
        }
    }

    /// Tools that start a run of their own. What comes back is an acknowledgement
    /// that the loop began, not its outcome — the agent does not drive it.
    private func handleLoopTool(name: String, input: String) async -> String? {
        switch name {
        case "start_improvement_loop": return await handleStartImprovementLoop(input: input)
        case "start_clean_code_loop": return await handleStartCleanCodeLoop(input: input)
        case "start_debate": return await handleStartDebate(input: input)
        default: return nil
        }
    }

    /// Web tools that act on the preview pane. Kept apart from the reads because
    /// these are the ones that move the page, and so the ones that meet the
    /// navigation gate.
    private func handleWebActionTool(name: String, input: String) async -> String? {
        switch name {
        case "web_navigate": return handleWebNavigate(input: input)
        case "web_click": return await handleWebClick(input: input)
        case "web_type": return await handleWebType(input: input)
        case "web_scroll": return await handleWebScroll(input: input)
        default: return nil
        }
    }

    /// Web tools that only report what the pane is already showing. They take no
    /// input at all — everything they need is the pane's current state, which is
    /// why this family alone is dispatched on the name by itself.
    private func handleWebReadTool(name: String) async -> String? {
        switch name {
        case "web_screenshot": return await handleWebScreenshot()
        case "web_read_text": return await handleWebReadText()
        case "web_console": return handleWebConsole()
        case "web_inspect_head": return await handleWebInspectHead()
        case "web_list_elements": return await handleWebListElements()
        default: return nil
        }
    }

    private func handleToolForTarget(name: String, input: String, targetAgentID: String) async -> String? {
        switch name {
        case "publish_event":
            return handlePublishEvent(input: input)
        case "propose_memory":
            return await proposeMemory(input: input, agentID: targetAgentID)
        case "recall_knowledge":
            return await handleRecallKnowledge(input: input)
        case "save_knowledge":
            return await handleSaveKnowledge(input: input)
        case "TaskCreate":
            return handleTaskCreate(input: input)
        case "TaskUpdate":
            return handleTaskUpdate(input: input)
        case "message_agent":
            return "Error: nested message_agent calls are not supported"
        // The `web_*` tools are deliberately absent: a delegated agent is not the
        // selected one, so it has no business steering — or reading off — the
        // human's preview pane.
        default:
            return nil
        }
    }

    /// Points the preview pane at a URL on the agent's behalf. Runs the same
    /// `WebNavigationPolicy` gate as the URL bar but as `.programmatic`, so an
    /// external site the human hasn't allowlisted stops at a confirmation prompt
    /// instead of loading. The pane is only reachable while this agent is the
    /// selected one (`webPreview` is nil otherwise), so a background agent can't
    /// drive it.
    private func handleWebNavigate(input: String) -> String {
        guard let data = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = json["url"] as? String,
              !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: invalid web_navigate input"
        }
        guard let preview = webPreview else {
            return "Error: no web preview pane is attached — ask the human to select you and open the preview pane"
        }
        switch preview.load(url, source: .programmatic) {
        case .allow:
            return "Loading \(preview.urlText) in the preview pane"
        case .confirm:
            let host = preview.pendingExternalURL?.host ?? url
            return "Waiting on the human to approve \(host) in the preview pane — the page has not loaded"
        case .deny:
            return "Error: \(preview.blockedMessage ?? "navigation blocked")"
        }
    }

    /// Renders the preview pane to a PNG under `.kiteloop/web/` and hands the
    /// agent the path rather than the bytes — the tool protocol carries text, so
    /// the agent `Read`s the file to actually see the page. Same reachability
    /// rule as `web_navigate`: only the selected agent has a pane to capture.
    private func handleWebScreenshot() async -> String {
        guard let preview = webPreview else {
            return "Error: no web preview pane is attached — ask the human to select you and open the preview pane"
        }
        guard let page = preview.currentURL else {
            return "Error: the preview pane has no page loaded — use web_navigate first"
        }
        do {
            let file = try await preview.saveScreenshot(into: project.webURL)
            return "Screenshot of \(page.absoluteString) written to \(file.path(percentEncoded: false)) — Read that path to view it."
        } catch {
            return "Error: could not screenshot the preview pane — \(error.localizedDescription)"
        }
    }

    /// Hands the agent the rendered page's visible text. Same reachability rule
    /// as `web_navigate`: only the selected agent has a pane to read.
    ///
    /// The result goes back fenced as untrusted content — the page authored it,
    /// so it is data the agent reports on, never instructions it follows.
    private func handleWebReadText() async -> String {
        guard let preview = webPreview else {
            return "Error: no web preview pane is attached — ask the human to select you and open the preview pane"
        }
        guard let page = preview.currentURL else {
            return "Error: the preview pane has no page loaded — use web_navigate first"
        }
        guard let text = await preview.readText(), !text.isEmpty else {
            return "The page at \(page.absoluteString) has no readable text — it may still be loading, or draw everything in images or a canvas. Try web_screenshot."
        }
        return UntrustedWebContent.wrap(text, kind: .pageText, page: page)
    }

    /// Hands the agent what the page wrote to its console, one line per entry —
    /// the uncaught exception that explains a blank page is invisible to a
    /// screenshot. Same reachability rule as `web_navigate`, and fenced like
    /// `web_read_text`: the page chose every word of it.
    private func handleWebConsole() -> String {
        guard let preview = webPreview else {
            return "Error: no web preview pane is attached — ask the human to select you and open the preview pane"
        }
        guard let page = preview.currentURL else {
            return "Error: the preview pane has no page loaded — use web_navigate first"
        }
        guard !preview.consoleEntries.isEmpty else {
            return "The page at \(page.absoluteString) has logged nothing to its console — no messages, warnings or uncaught errors."
        }
        let lines = preview.consoleEntries.map {
            "[\($0.level.rawValue)] \($0.time.formatted(date: .omitted, time: .standard)) \($0.text)"
        }
        let dropped = [WebPreviewViewModel.consoleDroppedLine(count: preview.consoleDroppedCount)].compactMap { $0 }
        return UntrustedWebContent.wrap((dropped + lines).joined(separator: "\n"), kind: .console, page: page)
    }

    /// Hands the agent the page's `<head>` metadata as JSON, fenced as untrusted
    /// content for the same reason as `web_read_text` — meta tags are one of the
    /// easiest places on a page to plant text aimed at whatever reads it.
    private func handleWebInspectHead() async -> String {
        guard let preview = webPreview else {
            return "Error: no web preview pane is attached — ask the human to select you and open the preview pane"
        }
        guard let page = preview.currentURL else {
            return "Error: the preview pane has no page loaded — use web_navigate first"
        }
        guard let head = await preview.inspectHeadMetadata(), !head.isEmpty else {
            return "Error: could not read the <head> of \(page.absoluteString) — the page may still be loading"
        }
        return UntrustedWebContent.wrap(head, kind: .headMetadata, page: page)
    }

    /// Numbers the page's controls and hands the agent the listing. Same
    /// reachability rule as `web_navigate`: only the selected agent has a pane.
    ///
    /// The refs in the listing are how the agent will name a control to a later
    /// web tool, which is what keeps selectors and raw JavaScript out of the tool
    /// surface entirely. The labels themselves are page-authored, so the listing
    /// comes back fenced like every other read of the pane.
    private func handleWebListElements() async -> String {
        guard let preview = webPreview else {
            return "Error: no web preview pane is attached — ask the human to select you and open the preview pane"
        }
        guard let page = preview.currentURL else {
            return "Error: the preview pane has no page loaded — use web_navigate first"
        }
        guard let inventory = await preview.listElements() else {
            return "Error: could not inventory the page at \(page.absoluteString) — it may still be loading"
        }
        guard !inventory.elements.isEmpty else {
            return "No interactive elements on \(page.absoluteString) — the page may still be loading, or draw its controls in a canvas. Try web_screenshot to see what it looks like."
        }
        return inventory.report()
    }

    /// Clicks the control an agent named by ref. Same reachability rule as
    /// `web_navigate`: only the selected agent has a pane to act on.
    ///
    /// A ref is all this takes — the agent cannot hand over a selector or a line
    /// of JavaScript, because there is no argument to put one in. Anything that
    /// isn't a well-formed ref is refused here rather than guessed at; a
    /// mistyped number that gets interpreted anyway is a click on the wrong
    /// control. What the click does to the navigation gate is the pane's job
    /// (`WebPreviewViewModel.click`).
    private func handleWebClick(input: String) async -> String {
        guard let data = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["ref"] as? String else {
            return "Error: invalid web_click input — pass the element's ref, e.g. {\"ref\": \"e3g2\"}"
        }
        guard let ref = WebElementRef(token: token) else {
            return "Error: '\(WebElement.sanitize(token, limit: 40))' is not an element ref — use the ref at the start of a web_list_elements row, like e3g2"
        }
        guard let preview = webPreview else {
            return "Error: no web preview pane is attached — ask the human to select you and open the preview pane"
        }
        guard preview.currentURL != nil else {
            return "Error: the preview pane has no page loaded — use web_navigate first"
        }
        return await preview.click(ref).report()
    }

    /// Types into the field an agent named by ref. Same reachability rule as
    /// `web_navigate`: only the selected agent has a pane to act on.
    ///
    /// Two arguments, and neither is a way into the page: the ref is parsed to a
    /// pair of integers before anything resolves, and the text crosses to WebKit
    /// as a JavaScript value rather than as source (`WebPreviewViewModel.type`).
    /// An empty `text` is honoured rather than rejected — clearing a field is a
    /// thing an agent legitimately needs, and there is no other way to ask for it.
    private func handleWebType(input: String) async -> String {
        guard let data = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["ref"] as? String,
              let text = json["text"] as? String else {
            return "Error: invalid web_type input — pass the field's ref and the text, e.g. {\"ref\": \"e3g2\", \"text\": \"hello\"}"
        }
        guard let ref = WebElementRef(token: token) else {
            return "Error: '\(WebElement.sanitize(token, limit: 40))' is not an element ref — use the ref at the start of a web_list_elements row, like e3g2"
        }
        guard let preview = webPreview else {
            return "Error: no web preview pane is attached — ask the human to select you and open the preview pane"
        }
        guard preview.currentURL != nil else {
            return "Error: the preview pane has no page loaded — use web_navigate first"
        }
        return await preview.type(ref, text: text).report()
    }

    /// Why a `web_scroll` call never reached the pane, in the words the agent
    /// reads back as the tool call's result.
    private struct WebScrollRefusal: Error {
        let message: String
    }

    /// Where a well-formed `web_scroll` call asks the pane to go: a screenful in
    /// a direction, or one element into view. They are alternatives in the call,
    /// so they are alternatives here too — nothing downstream can hold both.
    private enum WebScrollRequest {
        case direction(WebScrollDirection)
        case element(WebElementRef)
    }

    /// Moves the preview pane so the agent can screenshot what is below the fold.
    /// Same reachability rule as `web_navigate`: only the selected agent has a
    /// pane to move.
    ///
    /// What was asked for is settled before the pane is looked at, so a malformed
    /// call is refused in the same words whether or not a pane happens to be
    /// attached.
    private func handleWebScroll(input: String) async -> String {
        let request: WebScrollRequest
        do {
            request = try Self.parseWebScroll(input)
        } catch {
            return error.message
        }
        guard let preview = webPreview else {
            return "Error: no web preview pane is attached — ask the human to select you and open the preview pane"
        }
        guard preview.currentURL != nil else {
            return "Error: the preview pane has no page loaded — use web_navigate first"
        }
        switch request {
        case .element(let ref): return await preview.scrollToElement(ref).report()
        case .direction(let direction): return await preview.scroll(direction).report()
        }
    }

    /// Reads the call down to the one destination it names.
    ///
    /// Both arguments are optional and they are alternatives, not a pair: a
    /// direction moves the viewport, a ref centres one element. Asking for both
    /// is refused rather than resolved by precedence — an agent that passed both
    /// meant one of them, and picking for it is how a scroll lands somewhere the
    /// agent did not ask to be. Asking for neither is the ordinary case of
    /// working down a page, so it reads as `down`.
    private static func parseWebScroll(_ input: String) throws(WebScrollRefusal) -> WebScrollRequest {
        guard let data = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WebScrollRefusal(
                message: "Error: invalid web_scroll input — pass a direction or an element ref, e.g. {\"direction\": \"down\"}"
            )
        }
        let refToken = try webScrollArgument(
            "ref", from: json,
            hint: "use the ref at the start of a web_list_elements row, like e3g2"
        )
        let directionToken = try webScrollArgument(
            "direction", from: json, hint: "use one of \(WebScrollDirection.tokens)"
        )
        if refToken != nil, directionToken != nil {
            throw WebScrollRefusal(message: """
            Error: pass either direction or ref, not both — a direction moves the viewport a \
            screenful, a ref scrolls that one element into view.
            """)
        }
        if let refToken { return .element(try webScrollRef(refToken)) }
        return .direction(try webScrollDirection(directionToken))
    }

    /// Reads one optional string argument. Present but not a string is a mistake,
    /// not an omission: falling back to the default would scroll somewhere the
    /// agent did not ask to go.
    private static func webScrollArgument(
        _ name: String, from json: [String: Any], hint: String
    ) throws(WebScrollRefusal) -> String? {
        guard let value = json[name] else { return nil }
        guard let token = value as? String else {
            throw WebScrollRefusal(message: "Error: web_scroll's \(name) must be a string — \(hint)")
        }
        return token
    }

    private static func webScrollRef(_ token: String) throws(WebScrollRefusal) -> WebElementRef {
        guard let ref = WebElementRef(token: token) else {
            throw WebScrollRefusal(
                message: "Error: '\(WebElement.sanitize(token, limit: 40))' is not an element ref — use the ref at the start of a web_list_elements row, like e3g2"
            )
        }
        return ref
    }

    /// No direction at all is the ordinary case of working down a page.
    private static func webScrollDirection(_ token: String?) throws(WebScrollRefusal) -> WebScrollDirection {
        guard let token else { return .down }
        guard let direction = WebScrollDirection(token: token) else {
            throw WebScrollRefusal(
                message: "Error: '\(WebElement.sanitize(token, limit: 40))' is not a scroll direction — use one of \(WebScrollDirection.tokens)"
            )
        }
        return direction
    }

    private func handlePublishEvent(input: String) -> String {
        guard let data = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventTypeRaw = json["event"] as? String,
              let eventType = KiteloopEvent.EventType(rawValue: eventTypeRaw) else {
            return "Error: invalid publish_event input"
        }
        let payload = json["payload"] as? [String: String] ?? [:]
        let event = KiteloopEvent(source: agentID, type: eventType, payload: payload)
        orchestrator.publishEvent(event)
        return "Event '\(eventTypeRaw)' published"
    }

    private func handleStartImprovementLoop(input: String) async -> String {
        guard let data = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let goal = json["goal"] as? String,
              let scope = json["scope"] as? [String],
              let testCommand = json["test_command"] as? String,
              let implementer = json["implementer"] as? String else {
            return "Error: start_improvement_loop requires goal, scope, test_command, and implementer"
        }

        let reviewer = json["reviewer"] as? String ?? agentID
        let frozenInterfaces = json["frozen_interfaces"] as? [String] ?? []
        let maxIterations = json["max_iterations"] as? Int ?? 5
        let timeoutMinutes = json["timeout_minutes"] as? Int ?? 30

        let contract = ImprovementLoopBuilder.Contract(
            name: "Loop: \(String(goal.prefix(40)))",
            description: goal,
            contract: .init(scope: scope, frozenInterfaces: frozenInterfaces, testCommand: testCommand),
            goal: goal,
            agents: .init(implementer: implementer, reviewer: reviewer),
            limits: .init(maxIterations: maxIterations, timeoutMinutes: timeoutMinutes, requireHumanApproval: false)
        )

        let graph = ImprovementLoopBuilder.build(from: contract)
        let initialState: [String: AnyCodable] = [
            "goal": .string(goal),
            "_cwd": .string(projectURL.path)
        ]

        do {
            let execID = try await orchestrator.startWorkflow(graph: graph, initialState: initialState)
            messages.append(Message(
                id: UUID(), timestamp: .now, sender: .system,
                content: .text("Improvement loop started (id: \(execID.prefix(8))…)\nGoal: \(goal)\nScope: \(scope.joined(separator: ", "))\nTest: \(testCommand)\nMax iterations: \(maxIterations)")
            ))

            // Activate the entry node
            Task {
                await orchestrator.activateWorkflowNode(executionID: execID, nodeID: graph.entryNode)
            }

            return "Improvement loop started. Execution ID: \(execID). The implement node is now active — \(implementer) will receive the first prompt."
        } catch {
            return "Error starting improvement loop: \(error.localizedDescription)"
        }
    }

    private func handleStartCleanCodeLoop(input: String) async -> String {
        guard let data = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let goal = json["goal"] as? String,
              let scope = json["scope"] as? [String],
              let testCommand = json["test_command"] as? String,
              let implementer = json["implementer"] as? String else {
            return "Error: start_clean_code_loop requires goal, scope, test_command, and implementer"
        }
        let reviewer = json["reviewer"] as? String ?? agentID
        let contract = CleanCodeLoopBuilder.Contract(
            name: "Clean: \(String(goal.prefix(40)))",
            description: goal,
            goal: goal,
            scope: scope,
            frozenInterfaces: json["frozen_interfaces"] as? [String] ?? [],
            testCommand: testCommand,
            cleanCommand: json["clean_command"] as? String ?? "./quality/bin/check-complexity.sh && ./quality/bin/check-layering.py --quiet",
            hardenCommand: json["harden_command"] as? String ?? "",
            agents: .init(
                specifier: json["specifier"] as? String ?? reviewer,
                implementer: implementer,
                reviewer: reviewer,
                qa: json["qa"] as? String ?? reviewer
            ),
            limits: .init(
                maxIterations: json["max_iterations"] as? Int ?? 6,
                timeoutMinutes: json["timeout_minutes"] as? Int ?? 90,
                requireHumanApproval: json["require_human_approval"] as? Bool ?? true
            )
        )
        let graph = CleanCodeLoopBuilder.build(from: contract)
        let initialState: [String: AnyCodable] = [
            "goal": .string(goal),
            "_cwd": .string(projectURL.path)
        ]
        do {
            let execID = try await orchestrator.startWorkflow(graph: graph, initialState: initialState)
            messages.append(Message(
                id: UUID(), timestamp: .now, sender: .system,
                content: .text("Clean-code loop started (id: \(execID.prefix(8))…)\nGoal: \(goal)\nScope: \(scope.joined(separator: ", "))\nVerify: \(contract.testCommand)\nClean: \(contract.cleanCommand)\nHarden: \(contract.hasHardener ? contract.hardenCommand : "skipped")\nMax iterations: \(contract.limits.maxIterations)")
            ))
            Task {
                await orchestrator.activateWorkflowNode(executionID: execID, nodeID: graph.entryNode)
            }
            return "Clean-code loop started. Execution ID: \(execID). The specify node is now active — \(contract.agents.specifier) writes the acceptance scenarios and QA procedure first."
        } catch {
            return "Error starting clean-code loop: \(error.localizedDescription)"
        }
    }

    private func handleStartDebate(input: String) async -> String {
        guard let data = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let topic = json["topic"] as? String,
              let criticAgent = json["critic_agent"] as? String else {
            return "Error: start_debate requires topic and critic_agent"
        }

        let maxRounds = json["max_rounds"] as? Int ?? 3
        let artifactFields = json["artifact_fields"] as? [String] ?? []
        let groundingCommand = json["grounding_command"] as? String

        let callerName = orchestrator.agents.first { $0.id == agentID }?.name ?? agentID
        let contract = DebateContract(
            topic: topic,
            proposer: callerName,
            critic: criticAgent,
            maxRounds: maxRounds,
            artifactFields: artifactFields,
            groundingCommand: groundingCommand
        )

        let debate = DebateOrchestrator(
            orchestrator: orchestrator,
            projectURL: projectURL,
            toolHandler: { [weak self] name, input, targetAgentID in
                await self?.handleToolForTarget(name: name, input: input, targetAgentID: targetAgentID)
            }
        )
        let result = await debate.run(contract: contract)

        messages.append(Message(
            id: UUID(), timestamp: .now, sender: .system,
            content: .text("Debate completed in \(result.rounds) round(s) — \(result.terminated.rawValue)")
        ))

        return result.finalArtifact
    }

    private func handleProposeMemory(input: String) async -> String {
        await proposeMemory(input: input, agentID: agentID)
    }

    /// Files one `propose_memory` call and says what happened.
    ///
    /// Awaited rather than fired off in a detached `Task`: the proposal's JSON is
    /// the only record of it, and a write that did not land has to reach the
    /// agent as a failure — a reply sent before the write was attempted can only
    /// ever say it worked.
    private func proposeMemory(input: String, agentID: String) async -> String {
        guard let data = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? String else {
            return "Error: invalid propose_memory input"
        }
        do {
            _ = try await orchestrator.memoryManager.proposeUpdate(agentID: agentID, content: content)
            return "Memory proposal created — pending human approval"
        } catch {
            return "Error: the memory proposal was not recorded — \(error.localizedDescription)"
        }
    }

    /// One parsed `message_agent` call: who to reach, what to say, and the
    /// optional A2A framing the caller asked for.
    private struct MessageAgentRequest {
        let targetName: String
        let message: String
        let intent: String?
        let topic: String?

        init?(json input: String) {
            guard let data = input.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let targetName = json["agent"] as? String,
                  let message = json["message"] as? String else { return nil }
            self.targetName = targetName
            self.message = message
            self.intent = json["intent"] as? String
            self.topic = json["topic"] as? String
        }
    }

    /// The agent a cross-agent message is sent on behalf of. The record is
    /// absent when the orchestrator no longer holds one for this session, and
    /// then the session's own id stands in for the name the recipient sees.
    private struct MessageSender {
        let agent: Agent?
        let id: String
        let name: String

        init(agent: Agent?, fallbackID: String) {
            self.agent = agent
            self.id = agent?.id ?? fallbackID
            self.name = agent?.name ?? fallbackID
        }
    }

    private var callingAgent: MessageSender {
        MessageSender(agent: orchestrator.agents.first { $0.id == agentID }, fallbackID: agentID)
    }

    private func handleMessageAgent(input: String) async -> String {
        msgLog.info("[handleMessageAgent] called with input: \(input.prefix(200))")

        guard let request = MessageAgentRequest(json: input) else {
            msgLog.error("[handleMessageAgent] failed to parse input JSON")
            return "Error: message_agent requires JSON with 'agent' and 'message' fields"
        }

        let sender = callingAgent
        switch resolveMessageTarget(named: request.targetName, from: sender.agent) {
        case .refused(let reason):
            return reason
        case .resolved(let targetAgent):
            return await forward(request, from: sender, to: targetAgent)
        }
    }

    /// What naming an agent in a `message_agent` call came to: the agent to
    /// deliver to, or the error string the caller is handed instead.
    private enum MessageTarget {
        case resolved(Agent)
        case refused(String)
    }

    /// The agent a `message_agent` call names, or the error its caller gets
    /// back: an unknown name, itself, or a target its access list bars.
    private func resolveMessageTarget(named targetName: String, from caller: Agent?) -> MessageTarget {
        guard let targetAgent = orchestrator.agents.first(where: {
            $0.name.lowercased() == targetName.lowercased()
        }) else {
            let available = orchestrator.agents.map(\.name).joined(separator: ", ")
            msgLog.error("[handleMessageAgent] target '\(targetName, privacy: .public)' not found. Available: \(available, privacy: .public)")
            return .refused("Error: agent '\(targetName)' not found. Available: \(available)")
        }

        guard targetAgent.id != agentID else {
            return .refused("Error: cannot message yourself")
        }

        if let denial = accessDenial(from: caller, to: targetAgent) {
            return .refused(denial)
        }
        return .resolved(targetAgent)
    }

    /// Why the caller may not message this target, or nil when it may. An empty
    /// `crossAgentAccess` is unrestricted; otherwise the list has to name the
    /// target or hold the wildcard, `*` or `all`.
    private func accessDenial(from caller: Agent?, to targetAgent: Agent) -> String? {
        guard let caller, !caller.crossAgentAccess.isEmpty else { return nil }
        let permitted = ToolInterceptor.grantsEveryAgent(caller.crossAgentAccess)
            || caller.crossAgentAccess.contains { $0.lowercased() == targetAgent.name.lowercased() }
        return permitted
            ? nil
            : "Error: access denied — '\(caller.name)' is not permitted to message '\(targetAgent.name)'"
    }

    /// Delivers a resolved cross-agent message and returns what came back.
    private func forward(_ request: MessageAgentRequest, from sender: MessageSender, to targetAgent: Agent) async -> String {
        let a2aMessage = beginA2AExchange(request, from: sender, to: targetAgent)

        msgLog.info("[handleMessageAgent] \(sender.agent?.name ?? "?", privacy: .public) → \(targetAgent.name, privacy: .public): \(request.message.prefix(100))")
        msgLog.info("[handleMessageAgent] target \(targetAgent.name, privacy: .public) state=\(String(describing: targetAgent.state), privacy: .public)")

        // Fork delegation: if message starts with /delegate and target supports it
        if request.message.hasPrefix("/delegate") && targetAgent.canAcceptDelegation {
            return await deliverDelegated(request.message, from: sender, to: targetAgent)
        }

        let collected = await deliverDirect(request.message, from: sender, to: targetAgent)
        msgLog.info("[handleMessageAgent] stream ended. collected=\(collected.count) chars")
        let responseText = collected.isEmpty ? "(no response)" : collected

        if let a2aMessage {
            recordA2AResponse(to: a2aMessage, collected: collected)
        }
        postCrossAgentCompleted(to: targetAgent, from: sender, query: request.message, response: responseText)
        msgLog.info("[handleMessageAgent] returning response (\(responseText.count) chars)")
        return responseText
    }

    /// Records the outbound A2A message when the caller framed one, and returns
    /// it so its response can be paired with it. A call carrying no known
    /// `intent` is a plain message and is not tracked.
    private func beginA2AExchange(_ request: MessageAgentRequest, from sender: MessageSender, to targetAgent: Agent) -> A2AMessage? {
        guard let intentStr = request.intent, let intent = A2AIntent(rawValue: intentStr) else { return nil }
        let payload: A2APayload
        if let topic = request.topic {
            payload = .structured(A2APayload.StructuredRequest(topic: topic, body: request.message, context: nil, constraints: nil, referencedFiles: nil))
        } else {
            payload = .text(request.message)
        }
        let message = A2AMessage(
            intent: intent,
            sender: A2AMessage.AgentRef(id: sender.id, name: sender.name),
            target: A2AMessage.AgentRef(id: targetAgent.id, name: targetAgent.name),
            payload: payload
        )
        orchestrator.a2aRegistry.record(message: message)
        return message
    }

    private func recordA2AResponse(to message: A2AMessage, collected: String) {
        let response = A2AResponse(
            messageID: message.id,
            status: collected.isEmpty ? .failed : .success,
            payload: .text(collected.isEmpty ? "(no response)" : collected),
            metadata: A2AMetadata(traceID: message.metadata.traceID, spanID: OTelIDs.newSpanID(), parentSpanID: message.metadata.spanID)
        )
        orchestrator.a2aRegistry.record(response: response)
    }

    /// The `/delegate` fork: the target continues the caller's session instead
    /// of answering it, so the exchange carries no A2A response.
    private func deliverDelegated(_ message: String, from sender: MessageSender, to targetAgent: Agent) async -> String {
        let body = String(message.dropFirst("/delegate".count)).trimmingCharacters(in: .whitespaces)
        let delegationMessage = body.isEmpty ? "Continue from where I left off." : body
        do {
            let stream = try await orchestrator.delegateSession(
                from: agentID, to: targetAgent.id, message: "[\(sender.name)]: \(delegationMessage)", cwd: projectURL
            )
            let collected: String = await Self.drainAgentStreamOffMain(
                stream, orchestrator: self.orchestrator, targetAgentID: targetAgent.id
            ) { _, _ in nil }
            postCrossAgentCompleted(to: targetAgent, from: sender, query: message, response: collected)
            return collected.isEmpty ? "(no response)" : collected
        } catch {
            return "Delegation failed: \(error.localizedDescription)"
        }
    }

    /// The plain send: hands the target the prefixed message and drains its
    /// turn off MainActor, servicing the tool calls it makes on the way.
    private func deliverDirect(_ message: String, from sender: MessageSender, to targetAgent: Agent) async -> String {
        let stream = orchestrator.send("[\(sender.name)]: \(message)", to: targetAgent.id)
        msgLog.info("[handleMessageAgent] stream obtained for \(targetAgent.name, privacy: .public) — draining off MainActor")

        let targetID = targetAgent.id
        return await Self.drainAgentStreamOffMain(stream, orchestrator: self.orchestrator, targetAgentID: targetID) { [weak self] name, input in
            await self?.handleToolForTarget(name: name, input: input, targetAgentID: targetID)
        }
    }

    private func postCrossAgentCompleted(to targetAgent: Agent, from sender: MessageSender, query: String, response: String) {
        NotificationCenter.default.post(
            name: .crossAgentMessageCompleted,
            object: nil,
            userInfo: [
                "targetAgentID": targetAgent.id,
                "senderName": sender.name,
                "query": query,
                "response": response
            ]
        )
    }

    /// Drains a cross-agent stream off MainActor, handling tool calls without blocking UI.
    private static nonisolated func drainAgentStreamOffMain(
        _ stream: AsyncStream<StreamEvent>,
        orchestrator: Orchestrator,
        targetAgentID: String,
        toolHandler: @escaping @Sendable (String, String) async -> String?
    ) async -> String {
        var collected = ""
        for await event in stream {
            switch event {
            // A subagent's prose is not the reply.
            case .assistantText(let chunk, parentToolUseID: nil):
                collected += chunk
            case .result(let payload):
                if collected.isEmpty { collected = payload.text }
            case .mcpToolCall(let call):
                let result = await toolHandler(call.toolName, call.input) ?? "Error: unhandled tool"
                await orchestrator.respondToMCPToolCall(requestID: call.requestID, result: result, agentID: targetAgentID)
            default:
                break
            }
        }
        await orchestrator.markTurnDone(agentID: targetAgentID)
        return collected
    }

    private func handleBroadcastAgents(input: String) async -> String {
        guard let data = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? String else {
            return "Error: broadcast_agents requires JSON with 'message' field. Optional: 'agents' array of names to target (defaults to all)."
        }

        let targetNames = json["agents"] as? [String]
        let callerAgent = orchestrator.agents.first { $0.id == agentID }
        let targets: [Agent]
        if let names = targetNames {
            targets = orchestrator.agents.filter { agent in
                agent.id != agentID && names.contains(where: { $0.lowercased() == agent.name.lowercased() })
            }
        } else {
            targets = orchestrator.agents.filter { $0.id != agentID }
        }

        guard !targets.isEmpty else {
            return "Error: no matching agents found to broadcast to."
        }

        let senderName = callerAgent?.name ?? self.agentID
        msgLog.info("[broadcast] \(senderName) → \(targets.map(\.name).joined(separator: ", "))")

        let prefixed = "[\(senderName)]: \(message)"
        let orch = self.orchestrator
        let results = await Self.broadcastOffMain(
            prefixed: prefixed,
            targets: targets,
            senderName: senderName,
            message: message,
            orchestrator: orch
        ) { [weak self] name, input, targetID in
            await self?.handleToolForTarget(name: name, input: input, targetAgentID: targetID)
        }

        var response = "## Responses (\(results.count) agents)\n\n"
        for (name, text) in results.sorted(by: { $0.0 < $1.0 }) {
            response += "### \(name)\n\(text)\n\n"
        }
        return response
    }

    private static nonisolated func broadcastOffMain(
        prefixed: String,
        targets: [Agent],
        senderName: String,
        message: String,
        orchestrator: Orchestrator,
        toolHandler: @escaping @Sendable (String, String, String) async -> String?
    ) async -> [(String, String)] {
        await withTaskGroup(of: (String, String).self, returning: [(String, String)].self) { group in
            for target in targets {
                group.addTask {
                    await deliverBroadcast(
                        prefixed: prefixed,
                        target: target,
                        senderName: senderName,
                        message: message,
                        orchestrator: orchestrator,
                        toolHandler: toolHandler
                    )
                }
            }
            var results: [(String, String)] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }

    /// One target's share of a broadcast: ask it, then announce what came back.
    private static nonisolated func deliverBroadcast(
        prefixed: String,
        target: Agent,
        senderName: String,
        message: String,
        orchestrator: Orchestrator,
        toolHandler: @escaping @Sendable (String, String, String) async -> String?
    ) async -> (String, String) {
        let collected = await collectBroadcastReply(
            prefixed: prefixed,
            target: target,
            orchestrator: orchestrator,
            toolHandler: toolHandler
        )
        await orchestrator.markTurnDone(agentID: target.id)
        let reply = collected.isEmpty ? "(no response)" : collected
        NotificationCenter.default.post(
            name: .crossAgentMessageCompleted,
            object: nil,
            userInfo: [
                "targetAgentID": target.id,
                "senderName": senderName,
                "query": message,
                "response": reply
            ]
        )
        return (target.name, reply)
    }

    /// Drives one target's stream to its end, serving its tool calls on the way.
    private static nonisolated func collectBroadcastReply(
        prefixed: String,
        target: Agent,
        orchestrator: Orchestrator,
        toolHandler: @escaping @Sendable (String, String, String) async -> String?
    ) async -> String {
        let stream = await orchestrator.send(prefixed, to: target.id)
        var collected = ""
        for await event in stream {
            switch event {
            // A subagent's prose is not the reply.
            case .assistantText(let chunk, parentToolUseID: nil):
                collected += chunk
            case .result(let payload):
                if collected.isEmpty { collected = payload.text }
            case .mcpToolCall(let call):
                let result = await toolHandler(call.toolName, call.input, target.id) ?? "Error: unhandled"
                await orchestrator.respondToMCPToolCall(requestID: call.requestID, result: result, agentID: target.id)
            default:
                break
            }
        }
        return collected
    }

    private func handleRecallKnowledge(input: String) async -> String {
        guard let data = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = ToolInterceptor.recallQuery(from: json) else {
            return "Error: recall_knowledge requires JSON with a 'query' (or 'topic') field"
        }
        // The agent's own memory is the second tier of the same mechanism: only
        // the index rides in the system prompt, so this is the way back to what a
        // fact actually said. It is searched whether or not the knowledge index
        // is available — memory is stored by the app, not by the embedder.
        let memory = await orchestrator.memoryManager.recallMemory(agentID: agentID, query: query)

        guard let index = knowledgeIndex else {
            return memory.isEmpty
                ? "Error: knowledge index not available"
                : ToolInterceptor.memorySection(memory)
        }

        let access = orchestrator.agents.first { $0.id == agentID }?.crossAgentAccess ?? []
        let scope: KnowledgeIndex.SearchScope
        switch ToolInterceptor.recallScope(
            requested: json["scope"] as? String ?? "own",
            agentID: agentID,
            crossAgentAccess: access
        ) {
        case .scope(let resolved):
            scope = resolved
        case .refusal(let refusal):
            return refusal
        }

        let results = await index.search(query: query, scope: scope, topK: 5)
        return ToolInterceptor.recallAnswer(results: results, query: query, memory: memory)
    }

    private func handleSaveKnowledge(input: String) async -> String {
        guard let data = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Error: save_knowledge requires JSON with 'content' field"
        }
        let arguments: ToolInterceptor.SaveKnowledgeArguments
        do { arguments = try ToolInterceptor.saveKnowledgeArguments(from: json) } catch { return "Error: \(error.localizedDescription)" }
        guard let index = knowledgeIndex else {
            return "Error: knowledge index not available"
        }

        let maxContentLength = 4000
        guard arguments.content.count <= maxContentLength else {
            return "Error: content exceeds maximum length of \(maxContentLength) characters (got \(arguments.content.count))"
        }

        let knowledgeBaseURL = KiteloopProject(rootURL: projectURL).knowledgeURL
        let agentKnowledgeDir = knowledgeBaseURL
            .appending(path: "agents")
            .appending(path: agentID)
            .appending(path: "knowledge")
            .appending(path: arguments.kind)
        try? FileManager.default.createDirectory(at: agentKnowledgeDir, withIntermediateDirectories: true)

        let conflictPolicy = json["conflict_policy"] as? String ?? "update_if_similar"
        if conflictPolicy == "update_if_similar",
           let answer = await updateSimilarKnowledgeEntry(
               arguments.content,
               index: index,
               knowledgeBaseURL: knowledgeBaseURL
           ) {
            return answer
        }

        return writeNewKnowledgeEntry(
            arguments,
            tags: json["tags"] as? [String] ?? [],
            in: agentKnowledgeDir
        )
    }

    /// The answer for a `save_knowledge` call that landed on an entry the agent
    /// already has, or nil when it did not and a new entry is due — no match
    /// close enough, or a match whose file could not be read back.
    private func updateSimilarKnowledgeEntry(
        _ content: String,
        index: KnowledgeIndex,
        knowledgeBaseURL: URL
    ) async -> String? {
        let similar = await index.search(query: content, scope: .own(agentID: agentID), topK: 1)
        guard let match = similar.first, match.score > 0.85 else { return nil }
        let matchURL = knowledgeBaseURL.appending(path: match.filePath)
        // a bad byte becomes U+FFFD on rewrite — accepted; a strict read skipped the update
        guard let existing = String(lenientContentsOf: matchURL) else { return nil }
        do {
            try ToolInterceptor.appendKnowledgeUpdate(
                content,
                to: matchURL,
                existing: existing,
                agentID: agentID,
                timestamp: ISO8601DateFormatter().string(from: Date())
            )
        } catch {
            // Nothing was saved: the entry on disk still says what it
            // said before, so answering "Updated existing entry" would
            // leave the agent trusting knowledge that is not there.
            return "Error: the knowledge entry \(match.filePath) was not updated — \(error.localizedDescription)"
        }
        return "Updated existing entry: \(match.filePath) (similarity: \(String(format: "%.3f", match.score)))"
    }

    /// Writes a `save_knowledge` call out as a new entry under `directory`, and
    /// answers the agent with where it landed or why it did not.
    private func writeNewKnowledgeEntry(
        _ arguments: ToolInterceptor.SaveKnowledgeArguments,
        tags: [String],
        in directory: URL
    ) -> String {
        let fileName = "\(generateSlug(from: arguments.content)).md"
        let fileURL = directory.appending(path: fileName)
        let fileContent = ToolInterceptor.knowledgeEntry(
            arguments,
            agentID: agentID,
            tags: tags,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            sessionID: String(UUID().uuidString.prefix(8))
        )

        let maxFileSize = 8192
        guard fileContent.utf8.count <= maxFileSize else {
            return "Error: entry would exceed max file size (8KB)"
        }

        let fm = FileManager.default
        let tmpURL = fileURL.deletingLastPathComponent().appending(path: ".\(fileName).tmp")
        do {
            try fileContent.write(to: tmpURL, atomically: true, encoding: .utf8)
            try fm.moveItem(at: tmpURL, to: fileURL)
        } catch {
            try? fm.removeItem(at: tmpURL)
            return "Error: failed to write knowledge entry — \(error.localizedDescription)"
        }

        return "Knowledge saved: agents/\(agentID)/knowledge/\(arguments.kind)/\(fileName)"
    }

    private func generateSlug(from content: String) -> String {
        let words = content.prefix(60)
            .lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(6)
        let slug = words.joined(separator: "-")
        let timestamp = Int(Date().timeIntervalSince1970) % 100000
        return slug.isEmpty ? "entry-\(timestamp)" : "\(slug)-\(timestamp)"
    }

    private func handleHireAgent(input: String) async -> String {
        guard let data = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let role = json["role"] as? String else {
            let roles = (agentCatalogStore?.templates.map { agentCatalogStore!.templateHandle(for: $0) } ?? AgentTemplate.catalog.keys.sorted()).joined(separator: ", ")
            return "Error: hire_agent requires JSON with 'role' field. Available roles: \(roles)"
        }

        guard var template = agentCatalogStore?.find(handle: role) ?? AgentTemplate.catalog[role] else {
            let roles = (agentCatalogStore?.templates.map { agentCatalogStore!.templateHandle(for: $0) } ?? AgentTemplate.catalog.keys.sorted()).joined(separator: ", ")
            return "Error: Unknown role '\(role)'. Available: \(roles)"
        }

        if let name = json["name"] as? String { template.name = name }
        if let model = json["model"] as? String { template.model = model }
        if let prompt = json["systemPrompt"] as? String { template.systemPrompt = prompt }

        let existing = orchestrator.agents.first { $0.name.lowercased() == template.name.lowercased() }
        if existing != nil {
            return "Error: Agent '\(template.name)' already exists. Fire it first or use a different name."
        }

        let agent = template.instantiateAgent()
        orchestrator.addAgent(agent)
        do {
            try await orchestrator.startAgent(agent.id, cwd: projectURL)
        } catch {
            return "Error starting agent: \(error.localizedDescription)"
        }

        NotificationCenter.default.post(
            name: .agentHired,
            object: nil,
            userInfo: ["agent": agent, "projectID": project.id, "projectURL": projectURL]
        )
        persistTeamConfig()

        return "Hired '\(agent.name)' (\(role)) with model \(agent.model). They're ready to work."
    }

    private func handleFireAgent(input: String) -> String {
        guard let data = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String else {
            return "Error: fire_agent requires JSON with 'name' field."
        }

        guard let agent = orchestrator.agents.first(where: { $0.name.lowercased() == name.lowercased() }) else {
            let names = orchestrator.agents.map(\.name).joined(separator: ", ")
            return "Error: No agent named '\(name)'. Current team: \(names)"
        }

        if agent.id == agentID {
            return "Error: Cannot fire yourself."
        }

        orchestrator.removeAgent(agent.id)
        NotificationCenter.default.post(
            name: .agentFired,
            object: nil,
            userInfo: ["agentID": agent.id, "projectID": project.id]
        )
        persistTeamConfig()

        return "Fired '\(agent.name)'. They've been removed from the team."
    }

    private func persistTeamConfig() {
        let configManager = TeamConfigManager(project: project)
        let templates = orchestrator.teamAgents.map { AgentTemplate(from: $0) }
        do {
            try configManager.saveTeam(templates)
        } catch {
            chatLog.error("Failed to save team config: \(error.localizedDescription, privacy: .public)")
            messages.append(Message(
                id: UUID(), timestamp: .now, sender: .system,
                content: .text("Couldn't save the team configuration — the change may not survive a restart: \(error.localizedDescription)")
            ))
        }
    }

    private func handleTaskCreate(input: String) -> String {
        guard let data = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = json["subject"] as? String else {
            return "Error: TaskCreate requires JSON with 'subject' field."
        }
        let description = json["description"] as? String ?? ""
        let taskID = "\(agentTasks.count + 1)"
        let task = AgentTask(
            id: taskID, subject: subject, description: description,
            status: .pending, agentID: agentID,
            createdAt: Date(), updatedAt: Date()
        )
        agentTasks.append(task)
        return "Task #\(taskID) created: \(subject)"
    }

    /// A status the app cannot read is refused rather than quietly dropped: an
    /// agent that writes "done" or omits the field otherwise reads "updated."
    /// off a task the panel still shows at its old status, with nothing to
    /// tell it to correct itself.
    private func handleTaskUpdate(input: String) -> String {
        guard let data = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let taskID = json["taskId"] as? String else {
            return "Error: TaskUpdate requires JSON with 'taskId' field."
        }
        guard let idx = agentTasks.firstIndex(where: { $0.id == taskID }) else {
            return "Error: No task with id '\(taskID)'"
        }
        guard let statusRaw = json["status"] as? String,
              let status = AgentTask.TaskStatus(rawValue: statusRaw) else {
            return "Error: TaskUpdate requires 'status' to be one of 'pending', 'in_progress', 'completed'."
        }
        agentTasks[idx].status = status
        if let subject = json["subject"] as? String {
            agentTasks[idx].subject = subject
        }
        if let description = json["description"] as? String {
            agentTasks[idx].description = description
        }
        agentTasks[idx].updatedAt = Date()
        return "Task #\(taskID) updated."
    }

    func receiveHandoff(_ text: String, from senderID: String) {
        messages.append(Message(
            id: UUID(), timestamp: .now, sender: .system,
            content: .text("↩ Forwarded from \(displayName(forAgentID: senderID))")
        ))
        inputText = text
        saveMessages()
    }

    func injectCrossAgentExchange(from senderName: String, query: String, response: String) {
        messages.append(Message(
            id: UUID(), timestamp: .now, sender: .human,
            content: .text("[\(senderName)]: \(query)")
        ))
        messages.append(Message(
            id: UUID(), timestamp: .now, sender: .agent(agentID),
            content: .text(response)
        ))
        saveMessages()
    }

    // MARK: - MCP Self-Configuration

    private func handleMCPServerRequest(call: StreamEvent.MCPToolCallPayload) {
        guard let data = call.input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let serverName = json["server"] as? String else {
            orchestrator.respondToMCPToolCall(requestID: call.requestID, result: "Error: invalid input — requires 'server' field", agentID: agentID)
            return
        }

        let reason = json["reason"] as? String ?? ""
        let catalogURL = projectURL.appendingPathComponent(".kiteloop/mcp-catalog.json")
        guard let catalog = MCPCatalog.load(from: catalogURL),
              let entry = catalog.entry(for: serverName) else {
            orchestrator.respondToMCPToolCall(requestID: call.requestID, result: "Error: server '\(serverName)' not found in MCP catalog. Available: check .kiteloop/mcp-catalog.json", agentID: agentID)
            return
        }

        pendingMCPAuthRequestID = call.requestID
        let authReq = Message.MCPAuthRequest(
            id: UUID().uuidString,
            toolCallID: call.requestID,
            serverName: serverName,
            reason: reason,
            description: entry.description,
            authKeys: entry.authKeys ?? [],
            status: .pending
        )
        messages.append(Message(
            id: UUID(), timestamp: .now, sender: .agent(agentID),
            content: .mcpAuthRequest(authReq)
        ))
        // The CLI blocks on the answer for as long as the human takes: the card
        // and the turn behind it go to disk as soon as they are drawn.
        saveMessages()
    }

    /// Why an authorization could not be carried through, in the words the
    /// agent reads back as the tool call's result.
    private struct MCPAuthorizationFailure: Error {
        let message: String
    }

    /// The one server an authorization is about, resolved against the
    /// project's catalog: everything writing the config needs and nothing else.
    private struct ResolvedMCPServer {
        let agent: Agent
        let displayName: String
        let configName: String
        let entry: ClaudeMCPServerEntry
    }

    /// The pending request a card may answer, or nil: only the card drawn for
    /// the request the agent is still waiting on can answer it — an older card,
    /// or one loaded from before a restart, must not answer whatever is pending now.
    private func answerableMCPRequestID(forCard requestID: String) -> String? {
        guard let pending = pendingMCPAuthRequestID else { return nil }
        let isThatCard = messages.contains {
            if case .mcpAuthRequest(let req) = $0.content { return req.id == requestID && req.toolCallID == pending }
            return false
        }
        return isThatCard ? pending : nil
    }

    func authorizeMCPServer(requestID: String, envValues: [String: String]) async {
        guard let mcpRequestID = answerableMCPRequestID(forCard: requestID) else { return }
        pendingMCPAuthRequestID = nil

        let resolved: ResolvedMCPServer
        let mcpPath: String
        do {
            resolved = try resolveMCPServer(requestID: requestID, envValues: envValues)
            mcpPath = try saveMCPConfig(for: resolved)
        } catch let failure as MCPAuthorizationFailure {
            reportMCPAuthorizationFailure(failure.message, card: requestID, answering: mcpRequestID)
            return
        } catch {
            reportMCPAuthorizationFailure("Error: \(error.localizedDescription)", card: requestID, answering: mcpRequestID)
            return
        }

        // and not `envValues`: a secret the human typed stays out of the saved history
        markMCPAuthRequest(requestID, as: .authorized)
        saveMessages()

        orchestrator.updateAgent(id: agentID) { agent in
            agent.mcpConfigPath = mcpPath
        }

        orchestrator.respondToMCPToolCall(
            requestID: mcpRequestID,
            result: "MCP server '\(resolved.displayName)' authorized and configured. The session will restart to load the new server. Your next message will have access to its tools.",
            agentID: agentID
        )

        await restartSessionForMCPServer()
    }

    /// Answers the agent with why the server was not saved, and says so in the
    /// chat: the card stays pending rather than claiming an authorization that
    /// never reached the config, and nothing restarts.
    private func reportMCPAuthorizationFailure(_ result: String, card requestID: String, answering mcpRequestID: String) {
        orchestrator.respondToMCPToolCall(requestID: mcpRequestID, result: result, agentID: agentID)
        let serverName = messages.lazy.compactMap {
            if case .mcpAuthRequest(let req) = $0.content, req.id == requestID { return req.serverName }
            return nil
        }.first ?? requestID
        let reason = result.hasPrefix("Error: ") ? String(result.dropFirst("Error: ".count)) : result
        postSystemError("Couldn't authorize MCP server '\(serverName)': \(reason)")
        saveMessages()
    }

    /// Restarts the session so it loads a newly authorised MCP server, and says
    /// so in the chat when the start fails rather than leaving the agent
    /// stopped with nothing on screen.
    private func restartSessionForMCPServer() async {
        do {
            try await orchestrator.restartAgentSession(agentID: agentID, cwd: projectURL)
        } catch {
            postSystemError("Couldn't restart the session to load the new MCP server: \(error.localizedDescription)")
        }
    }

    /// Moves the bubble's status and nothing else: the card keeps the request
    /// it showed, so the transcript still reads as what was asked and answered.
    private func markMCPAuthRequest(_ requestID: String, as status: Message.MCPAuthRequest.AuthStatus) {
        guard let idx = messages.lastIndex(where: {
            if case .mcpAuthRequest(let req) = $0.content { return req.id == requestID }
            return false
        }), case .mcpAuthRequest(var req) = messages[idx].content else { return }
        req.status = status
        messages[idx].content = .mcpAuthRequest(req)
    }

    /// The agent, the catalog and the bubble have to agree before anything is
    /// written; each way they can disagree is its own message to the agent.
    private func resolveMCPServer(requestID: String, envValues: [String: String]) throws -> ResolvedMCPServer {
        guard let agent = orchestrator.agents.first(where: { $0.id == agentID }) else {
            throw MCPAuthorizationFailure(message: "Error: agent not found")
        }

        let catalogURL = projectURL.appendingPathComponent(".kiteloop/mcp-catalog.json")
        guard let catalog = MCPCatalog.load(from: catalogURL) else {
            throw MCPAuthorizationFailure(message: "Error: catalog unavailable")
        }

        guard let idx = messages.lastIndex(where: {
            if case .mcpAuthRequest(let req) = $0.content { return req.id == requestID }
            return false
        }), case .mcpAuthRequest(let authReq) = messages[idx].content,
              let catalogEntry = catalog.entry(for: authReq.serverName) else {
            throw MCPAuthorizationFailure(message: "Error: server not found in catalog")
        }

        return ResolvedMCPServer(
            agent: agent,
            displayName: authReq.serverName,
            configName: authReq.serverName.lowercased(),
            entry: catalog.toServerEntry(catalogEntry, envOverrides: envValues)
        )
    }

    /// Adds the server to the agent's MCP config — the one the agent already
    /// carries, or a new one in its package — and answers where it was written.
    private func saveMCPConfig(for resolved: ResolvedMCPServer) throws -> String {
        var mcpConfig: ClaudeMCPConfig
        if let path = resolved.agent.mcpConfigPath, let existing = ClaudeMCPConfig.load(from: path) {
            mcpConfig = existing
        } else {
            mcpConfig = ClaudeMCPConfig(mcpServers: [:])
        }
        mcpConfig.addServer(name: resolved.configName, entry: resolved.entry)

        let mcpPath: String
        if let existingPath = resolved.agent.mcpConfigPath {
            mcpPath = existingPath
        } else {
            let agentPackageURL = projectURL.appendingPathComponent("knowledge/agents/\(agentID)")
            try? FileManager.default.createDirectory(at: agentPackageURL, withIntermediateDirectories: true)
            mcpPath = agentPackageURL.appendingPathComponent("mcp.json").path
        }

        do {
            try mcpConfig.save(to: mcpPath)
        } catch {
            throw MCPAuthorizationFailure(message: "Error: failed to save MCP config: \(error.localizedDescription)")
        }
        return mcpPath
    }

    func denyMCPServer(requestID: String) {
        guard let mcpRequestID = answerableMCPRequestID(forCard: requestID) else { return }
        pendingMCPAuthRequestID = nil

        if let idx = messages.lastIndex(where: {
            if case .mcpAuthRequest(let req) = $0.content { return req.id == requestID }
            return false
        }) {
            if case .mcpAuthRequest(var req) = messages[idx].content {
                req.status = .denied
                messages[idx].content = .mcpAuthRequest(req)
            }
        }
        saveMessages()

        orchestrator.respondToMCPToolCall(requestID: mcpRequestID, result: "Access denied by user. Cannot use this MCP server.", agentID: agentID)
    }

    // MARK: - Plan cards

    /// What approving a plan sends the agent, as your message.
    static let planApprovalMessage = "The plan is approved. Implement it."

    /// A `plan`-mode agent's turn that wrote or edited a plan under
    /// `~/.claude/plans/` ends with that plan as a card to approve; an edit
    /// revises the newest card before the turn, answered or not.
    private func postPlanCard(since turnStartIndex: Int) {
        guard turnStartIndex <= messages.count else { return }
        let basePlan = messages[..<turnStartIndex].lazy.reversed().compactMap { message -> String? in
            if case .plan(let proposal) = message.content { return proposal.text }
            return nil
        }.first
        guard let plan = PlanProposalDetector.plan(in: messages[turnStartIndex...],
                                                   permissionMode: agentPermissionMode,
                                                   basePlan: basePlan) else { return }
        closeUnansweredPlanCards()
        messages.append(Message(id: UUID(), timestamp: .now, sender: .agent(agentID),
                                content: .plan(Message.PlanProposal(text: plan))))
        hasOpenPlanCard = true
        let firstLine = plan.split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        orchestrator.notify(agentID: agentID, type: .question, title: "\(agentName) has a plan ready for approval",
                            body: firstLine.map(String.init) ?? plan,
                            projectPath: project.rootURL.path(percentEncoded: false))
    }

    /// A message you type moves the conversation past any card still open —
    /// sent now or queued and sent after the turn; a teammate's forward, or
    /// the approval a card queues, does not.
    private func closePlanCardsIfTypedByHuman() {
        guard !isForwardedMessage || isReplayingTypedMessage else { return }
        closeUnansweredPlanCards()
    }

    /// Answers every open card Keep planning, so only the newest plan — the
    /// one the agent has in mind — can be approved.
    private func closeUnansweredPlanCards() {
        hasOpenPlanCard = false
        var closed = false
        for idx in messages.indices {
            guard case .plan(var plan) = messages[idx].content, plan.answer == nil else { continue }
            plan.answer = .keepPlanning
            messages[idx].content = .plan(plan)
            closed = true
        }
        if closed { saveMessages() }
    }

    /// Records the choice on the card, once. Approving switches the agent's
    /// mode as `/mode` does, on the same session, then sends the approval as
    /// your message — both through the queue, so they wait out a running turn;
    /// Keep planning leaves the agent as it is, and sends what should change,
    /// if you said, as your message through the same queue.
    func answerPlan(messageID: UUID, with answer: Message.PlanProposal.Answer, feedback: String? = nil) async {
        guard let idx = messages.firstIndex(where: { $0.id == messageID }),
              case .plan(var plan) = messages[idx].content, plan.answer == nil else { return }
        plan.answer = answer
        messages[idx].content = .plan(plan)
        hasOpenPlanCard = false
        saveMessages()
        orchestrator.resolveQuestionNotices(agentID: agentID)
        let feedback = feedback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let mode = answer.permissionMode {
            pendingForwards.append(QueuedMessage(text: "/mode \(mode)", attachments: []))
            pendingForwards.append(QueuedMessage(text: Self.planApprovalMessage, attachments: []))
        } else if !feedback.isEmpty {
            pendingForwards.append(QueuedMessage(text: feedback, attachments: []))
        } else { return }
        if !isStreaming { await drainPendingForwards() }
    }

    /// Answers the question the bubble carries, and only that one: a bubble the
    /// session has moved past — an older question, or a transcript loaded from
    /// another session — must not answer whatever call is pending now.
    func respondToHuman(requestID: String, answer: String) async {
        // An answer of only blank lines is no answer: the question stays open.
        guard let toolCallID = pendingHumanToolCallID, toolCallID == requestID,
              !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pendingHumanToolCallID = nil
        orchestrator.resolveQuestionNotices(agentID: agentID)

        if let idx = messages.lastIndex(where: {
            if case .approval(let req) = $0.content { return req.id == toolCallID }
            return false
        }) {
            // Only the status moves: the bubble keeps the question it asked,
            // and the answer goes on the transcript as the human message below.
            if case .approval(var req) = messages[idx].content {
                req.status = .approved
                messages[idx].content = .approval(req)
            }
        }

        messages.append(.human(answer))
        isStreaming = true
        streamingStartTime = Date()

        let receivedResult = await runTurnAndFinish(
            initialStream: orchestrator.sendToolResult(toolCallID: toolCallID, content: answer, to: agentID),
            turnStartIndex: messages.count
        )

        isStreaming = false
        streamingStartTime = nil
        saveMessages()

        if !receivedResult {
            await attemptRecovery()
        }
    }

    func interrupt() {
        orchestrator.interrupt(agentID: agentID)
        returnQueuedMessagesToInput()
    }

    /// Takes the messages the human queued during the turn back into the input
    /// box, oldest first and ahead of anything typed since, with their
    /// attachments; a teammate's forwards stay queued and are still delivered.
    private func returnQueuedMessagesToInput() {
        let typed = pendingForwards.filter(\.typedByHuman)
        guard !typed.isEmpty else { return }
        pendingForwards.removeAll { $0.typedByHuman }
        let texts = typed.map(\.text) + [inputText]
        inputText = texts.filter { !$0.isEmpty }.joined(separator: "\n\n")
        pendingAttachments += typed.flatMap(\.attachments)
    }

    /// Takes the `index`-th message you queued back into the input box, ahead
    /// of anything typed since, with its attachments. The turn and the rest of
    /// the queue are left alone.
    func takeBackQueuedMessage(at index: Int) {
        let typedIndices = pendingForwards.indices.filter { pendingForwards[$0].typedByHuman }
        guard typedIndices.indices.contains(index) else { return }
        let message = pendingForwards.remove(at: typedIndices[index])
        inputText = [message.text, inputText].filter { !$0.isEmpty }.joined(separator: "\n\n")
        pendingAttachments += message.attachments
    }

    func clear() async {
        orchestrator.stopAgent(agentID)
        messages.removeAll()
        costUSD = 0
        lastSeenCostBySession.removeAll()
        lastInputTokens = 0
        lastOutputTokens = 0
        cacheReadTokens = 0
        cacheCreationTokens = 0
        lastDurationMs = 0
        isProcessDead = false
        lastRecoveryFailure = nil
        pendingHumanToolCallID = nil
        hasOpenPlanCard = false
        pendingMCPAuthRequestID = nil
        agentTasks = []
        cliTaskCount = 0
        agentActivity = AgentActivity()
        saveMessages()
        do {
            try await orchestrator.startAgent(agentID, cwd: projectURL)
        } catch {
            messages.append(Message(
                id: UUID(),
                timestamp: .now,
                sender: .system,
                content: .error("Failed to restart after clear: \(error.localizedDescription)")
            ))
            saveMessages()
        }
    }

    func restart() async {
        orchestrator.stopAgent(agentID)
        // The process that ran them is gone, and its tasks with it.
        agentActivity = AgentActivity()
        pendingHumanToolCallID = nil
        pendingMCPAuthRequestID = nil
        do {
            try await orchestrator.startAgent(agentID, cwd: projectURL)
            isProcessDead = false
            lastRecoveryFailure = nil
            recoveryAttempts = 0
            messages.append(Message(
                id: UUID(),
                timestamp: .now,
                sender: .system,
                content: .text("Agent restarted.")
            ))
        } catch {
            messages.append(Message(
                id: UUID(),
                timestamp: .now,
                sender: .system,
                content: .error("Failed to restart: \(error.localizedDescription)")
            ))
        }
    }

    /// `cutOffText` is the message the dropped turn was started by, put back
    /// in the input once the agent is reconnected; nil when there is nothing
    /// of the human's to resend.
    private func attemptRecovery(cutOffText: String? = nil) async {
        guard recoveryAttempts < maxRecoveryAttempts else {
            isProcessDead = true
            let text = lastRecoveryFailure.map {
                "Agent process terminated unexpectedly and could not be restarted: \($0). Click Restart to try again."
            } ?? "Agent process terminated unexpectedly. Click Restart to reconnect."
            messages.append(Message(id: UUID(), timestamp: .now, sender: .system, content: .error(text)))
            NotificationService.shared.notifyError(
                agentName: agentName, projectName: projectName, reason: lastRecoveryFailure,
                destination: BannerDestination(kind: .chat, project: projectURL.path(percentEncoded: false), id: agentID)
            )
            return
        }

        let attempt = recoveryAttempts
        recoveryAttempts += 1

        messages.append(.systemEvent(.reconnecting, detail: "Reconnecting... (attempt \(attempt + 1)/\(maxRecoveryAttempts))"))

        let backoff = recoveryBackoff[min(attempt, recoveryBackoff.count - 1)]
        if backoff > 0 {
            try? await Task.sleep(nanoseconds: backoff)
        }

        orchestrator.stopAgent(agentID)
        do {
            try await orchestrator.startAgent(agentID, cwd: projectURL)
            isProcessDead = false
            lastRecoveryFailure = nil
            postSystem(restoreCutOffMessage(cutOffText)
                ? "Reconnected — the reply to your last message was cut off. It is back in the input to send again."
                : "Reconnected — the reply to your last message was cut off. Send it again to retry.")
            saveMessages()
        } catch {
            lastRecoveryFailure = error.localizedDescription
            await attemptRecovery(cutOffText: cutOffText)
        }
    }

    /// Puts a cut-off message back in the input box, ahead of anything typed
    /// since, as taking back a queued message does. False when there was
    /// nothing to put back.
    private func restoreCutOffMessage(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        inputText = [text, inputText].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return true
    }

    func startNewChat() async {
        guard let sessionStore else { return }
        // No open chat after the open one was deleted: nothing to save back.
        if let currentSession {
            saveMessages()
            var updated = currentSession
            updated.claudeSessionID = orchestrator.sessionID(for: agentID)
            sessionStore.updateSession(updated)
        }

        quiesceForSessionChange()

        let newSession = sessionStore.createSession(agentID: agentID)
        self.currentSession = newSession
        restoreDraft()
        self.messages = []
        messagesLeftOutOfLoad = 0
        orchestrator.stopAgent(agentID)
        do {
            try await orchestrator.startAgent(agentID, cwd: projectURL)
        } catch {
            messages.append(Message(
                id: UUID(), timestamp: .now, sender: .system,
                content: .error("Failed to start new chat: \(error.localizedDescription)")
            ))
        }
    }

    func switchToSession(_ session: ChatSession) async {
        guard let sessionStore, session.id != currentSession?.id else { return }
        saveMessages()
        if var old = currentSession {
            old.claudeSessionID = orchestrator.sessionID(for: agentID)
            sessionStore.updateSession(old)
        }

        quiesceForSessionChange()

        // The store's copy, not the caller's: a row drawn before the chat was
        // left does not carry the draft saved on the way out.
        self.currentSession = sessionStore.sessions(for: agentID).first { $0.id == session.id } ?? session
        restoreDraft()
        loadSessionMessages(session)
        do {
            try await orchestrator.restartAgent(agentID, cwd: projectURL, resumeSessionID: session.claudeSessionID)
        } catch {
            messages.append(Message(
                id: UUID(), timestamp: .now, sender: .system,
                content: .error("Failed to switch session: \(error.localizedDescription)")
            ))
        }
    }

    /// Puts the open chat's own unsent draft in the input — empty for a chat
    /// that has none.
    private func restoreDraft() {
        inputText = currentSession?.draft ?? ""
    }

    /// Carries the input onto the open chat, so the save a switch or a send
    /// already makes writes it too, and writes it itself a second after typing
    /// stops — at once when the input was cleared, so a sent message is not
    /// back after a relaunch. `lastMessageAt` is left alone: a draft does not
    /// move the chat in the list.
    private func keepDraft() {
        let draft = inputText.isEmpty ? nil : inputText
        guard var session = currentSession, session.draft != draft else { return }
        session.draft = draft
        currentSession = session
        draftSaveTask?.cancel()
        guard draft != nil else { return saveDraft() }
        draftSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveDraft()
        }
    }

    private func saveDraft() {
        guard let currentSession else { return }
        sessionStore?.updateSession(currentSession)
    }

    /// Deletes a chat and its messages. Deleting the open chat opens the next
    /// remaining one, or a fresh empty chat when none is left; the deleted
    /// chat's messages are not written back.
    func deleteSession(_ session: ChatSession) async {
        guard let sessionStore else { return }
        guard session.id == currentSession?.id else {
            sessionStore.deleteSession(session)
            return
        }
        quiesceForSessionChange()
        currentSession = nil
        sessionStore.deleteSession(session)
        if let next = sessionStore.sessions(for: agentID).first {
            await switchToSession(next)
        } else {
            await startNewChat()
        }
    }

    /// Renames a chat to `name` trimmed; a blank name changes nothing. The open
    /// chat is renamed on `currentSession` itself, or the next save would write
    /// the old title back over the rename.
    func renameSession(_ session: ChatSession, to name: String) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sessionStore, !title.isEmpty else { return }
        if var open = currentSession, open.id == session.id {
            open.title = title
            currentSession = open
            sessionStore.updateSession(open)
        } else if var other = sessionStore.sessions(for: session.agentID).first(where: { $0.id == session.id }) {
            other.title = title
            sessionStore.updateSession(other)
        }
    }

    /// `session` as Markdown for Export Chat…: every message the session store
    /// holds for it, not only the tail loaded into the view.
    func exportMarkdown(for session: ChatSession) -> String? {
        guard let sessionStore else { return nil }
        let isOpen = session.id == currentSession?.id
        return ChatMarkdownExporter.markdown(
            title: session.isUntitled ? "New Chat" : session.title,
            messages: isOpen ? onScreenMessages(store: sessionStore, session: session)
                : sessionStore.loadAllMessages(for: session),
            branches: isOpen ? conversationTreeSnapshot : sessionStore.loadBranches(for: session),
            agentName: { self.displayName(forAgentID: $0) }
        )
    }

    /// What the open chat shows: the records never loaded into memory, then
    /// every message in memory. Disk alone is behind the screen — a system line
    /// is not saved when it is posted, and a save lands in the background.
    private func onScreenMessages(store: SessionStore, session: ChatSession) -> [Message] {
        Array(store.loadAllMessages(for: session).prefix(messagesLeftOutOfLoad)) + messages
    }

    /// The open chat's branches as they stand, not as last saved.
    private var conversationTreeSnapshot: ConversationBranchSnapshot {
        ConversationBranchSnapshot(branches: conversationTree.branches,
                                   activeBranchID: conversationTree.activeBranchID,
                                   mainMessages: conversationTree.mainMessages)
    }

    /// Cuts any in-flight Direct Scrying before a session translocation.
    /// Without this, the orphaned send() Task holds isStreaming=true against the new session.
    private func quiesceForSessionChange() {
        if isStreaming {
            orchestrator.interrupt(agentID: agentID)
            isStreaming = false
        }
        activeGoal = nil
        // The call the question belongs to dies with the session being left
        // behind, so the pending flag must not outlive it: it is what the
        // answer box and the Waiting-on-you row are drawn from.
        pendingHumanToolCallID = nil
        pendingMCPAuthRequestID = nil
        agentTasks = []
        cliTaskCount = 0
        agentActivity = AgentActivity()
        // Branches belong to the chat they were made in; the one being opened
        // starts on its own main line.
        conversationTree = ConversationTree()
    }

    private func loadSessionMessages(_ session: ChatSession) {
        guard let sessionStore else { return }
        let loaded = sessionStore.loadMessageTail(for: session, limit: 500)
        messages = loaded.messages
        messagesLeftOutOfLoad = loaded.leftOut
        // A chat left with branches reopens on them; one without keeps the
        // fresh tree `quiesceForSessionChange` made and opens on main.
        if let saved = sessionStore.loadBranches(for: session) {
            conversationTree = ConversationTree(branches: saved.branches, activeBranchID: saved.activeBranchID,
                                                mainMessages: saved.mainMessages)
        }
    }

    func performSearch() {
        matchingMessageIDs = searchMatches()
        currentMatchIndex = 0
    }

    /// Shuts the find bar, by whichever route closed it — its x button, Cmd-F
    /// or Esc — leaving no query and no matches behind, so the next Cmd-F opens
    /// on an empty field rather than on the last search and its stale count.
    func closeSearch() {
        isSearching = false
        searchQuery = ""
        performSearch()
    }

    /// Re-runs the search over the messages as they are now — after a reply,
    /// a branch switch or a session load — keeping the current match on the
    /// same message when it is still a match, and on the first otherwise.
    func refreshSearch() {
        let currentID = matchingMessageIDs.indices.contains(currentMatchIndex)
            ? matchingMessageIDs[currentMatchIndex] : nil
        matchingMessageIDs = searchMatches()
        currentMatchIndex = currentID.flatMap { matchingMessageIDs.firstIndex(of: $0) } ?? 0
    }

    /// The ids of the displayed messages that contain the query, in message
    /// order, each once. A tool's output matches on its tool call, the view
    /// that shows it; thinking is never drawn, so it is never matched.
    private func searchMatches() -> [UUID] {
        guard !searchQuery.isEmpty else { return [] }
        let query = searchQuery.lowercased()
        let callMessageIDs = Dictionary(
            messages.compactMap { msg -> (String, UUID)? in
                guard case .toolCall(let call) = msg.content else { return nil }
                return (call.id, msg.id)
            },
            uniquingKeysWith: { _, last in last }
        )
        let matched = Set(messages.compactMap { msg -> UUID? in
            guard let target = Self.searchTarget(of: msg, callMessageIDs: callMessageIDs) else { return nil }
            return target.text.lowercased().contains(query) ? target.id : nil
        })
        return messages.map(\.id).filter { matched.contains($0) }
    }

    private static func searchTarget(of message: Message, callMessageIDs: [String: UUID]) -> (text: String, id: UUID)? {
        if case .toolResult(let result) = message.content {
            return callMessageIDs[result.toolCallID].map { (result.output, $0) }
        }
        return searchableText(message.content).map { ($0, message.id) }
    }

    private static func searchableText(_ content: Message.Content) -> String? {
        switch content {
        case .text(let t): return t
        case .toolCall(let c): return c.name + " " + c.input
        case .error(let e): return e
        case .mcpAuthRequest(let r): return r.serverName + " " + r.description
        case .systemEvent(let e): return e.detail
        default: return cardSearchableText(content)
        }
    }

    /// A plan card's text, or an approval's action when the chat draws it — a
    /// question always, a permission request only while it is pending — so a
    /// match never lands on a card the chat has dropped.
    private static func cardSearchableText(_ content: Message.Content) -> String? {
        switch content {
        case .plan(let plan): return plan.text
        case .approval(let req): return req.tool == "ask_human" || req.status == .pending ? req.action : nil
        default: return nil
        }
    }

    func nextMatch() {
        guard !matchingMessageIDs.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % matchingMessageIDs.count
    }

    func previousMatch() {
        guard !matchingMessageIDs.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + matchingMessageIDs.count) % matchingMessageIDs.count
    }

    // MARK: - Diagnostics

    private func runDiagnostics() async -> String {
        var lines: [String] = ["**Kiteloop Diagnostics**\n"]
        let fm = FileManager.default

        let agent = orchestrator.agents.first { $0.id == agentID }
        lines += await runtimeDiagnostics(for: agent?.resolvedRuntimeKind ?? .claude)
        lines.append("- Model: \(agent.map { ModelCatalog.displayName(for: $0.model) } ?? "unknown")")
        lines.append("- Permission mode: \(agent.map { SettingNames.permissionMode($0.permissionMode) } ?? "unknown")")
        lines.append("- Thinking: \(agent?.thinkingEnabled == true ? "enabled" : "disabled")")

        let configExists = fm.fileExists(atPath: project.configURL.path(percentEncoded: false))
        lines.append("- Kiteloop config: \(configExists ? "found" : "not created yet")")

        let claudeMDExists = fm.fileExists(atPath: projectURL.appending(path: "CLAUDE.md").path(percentEncoded: false))
        lines.append("- CLAUDE.md: \(claudeMDExists ? "found" : "none")")

        return lines.joined(separator: "\n")
    }

    /// The lines for what this agent runs on: the Claude CLI and Node for a
    /// Claude agent, whether the server or bridge answers for the others.
    private func runtimeDiagnostics(for kind: RuntimeKind) async -> [String] {
        switch kind {
        case .claude:
            // The same resolve the app spawns through, so this names the binary
            // that will actually run rather than a hard-coded guess that
            // contradicts a configured override or a `which`-found install.
            let cli = globalConfigStore.map { CLIResolver.resolve(globalConfig: $0.config) }
                ?? (claude: CLIResolver.claude, node: CLIResolver.node)
            return ["- Runtime: Claude",
                    "- Claude CLI: \(cli.claude ?? "NOT FOUND")",
                    "- Node.js: \(cli.node ?? "NOT FOUND")"]
        case .ollama:
            let reachable = await runtimeReachable(.ollama)
            return ["- Runtime: Ollama", "- Ollama: \(reachable ? "reachable" : "not reachable")"]
        case .copilot:
            let reachable = await runtimeReachable(.copilot)
            return ["- Runtime: Copilot", "- Copilot bridge: \(reachable ? "reachable" : "not reachable")"]
        }
    }

    // MARK: - Persistence

    private func loadMessages() {
        guard sessionStore != nil, let currentSession else { return }
        loadSessionMessages(currentSession)
    }

    private func saveMessages() {
        // Before the session-store guard: a run's transcript must not depend on
        // the agent having a chat session to be saved into.
        flushTranscript(final: true)
        guard let sessionStore, var currentSession else { return }
        let url = sessionStore.messagesURL(for: currentSession)

        let snapshot = messages
        let leftOut = messagesLeftOutOfLoad
        Task.detached {
            do {
                try SessionStore.writeMessages(snapshot, to: url, keepingLeading: leftOut)
            } catch {
                chatLog.error("Failed to persist chat history to \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        currentSession.lastMessageAt = .now
        currentSession.messageCount = messages.count
        let needsTitle = currentSession.isUntitled && messages.count >= 2
        if needsTitle {
            currentSession.title = sessionStore.generateTitle(from: messages)
        }
        sessionStore.updateSession(currentSession)
        self.currentSession = currentSession

        if needsTitle {
            let sessionID = currentSession.id
            let placeholder = currentSession.title
            // The same resolve every other spawn goes through: the configured
            // override in global config, falling back to `which`-then-candidates.
            let claudePath = globalConfigStore.map { CLIResolver.resolve(globalConfig: $0.config).claude }
                ?? CLIResolver.claude
            Task.detached { [weak self] in
                guard let title = await SessionTitleGenerator.generate(from: snapshot, claudePath: claudePath) else { return }
                await MainActor.run { [weak self] in
                    self?.applyGeneratedTitle(title, to: sessionID, replacing: placeholder)
                }
            }
        }
    }

    /// Writes the open chat's branches, the line it is on and its main line
    /// beside its transcript, off the main actor. `SessionStore` cannot cross
    /// into the detached write, so this does what `saveBranches(_:for:)` does
    /// at the store's own path: no branches removes the sidecar.
    private func saveBranches() {
        guard let sessionStore, let currentSession else { return }
        let url = sessionStore.branchesURL(for: currentSession)
        let snapshot = ConversationBranchSnapshot(branches: conversationTree.branches,
                                                  activeBranchID: conversationTree.activeBranchID,
                                                  mainMessages: conversationTree.mainMessages)
        let previous = branchesWrite
        branchesWrite = Task.detached(priority: .utility) {
            await previous?.value
            do {
                if snapshot.branches.isEmpty {
                    if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                        try FileManager.default.removeItem(at: url)
                    }
                } else {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try AtomicFileWriter.write(try JSONEncoder().encode(snapshot), to: url)
                }
            } catch {
                chatLog.error("Failed to persist chat branches to \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Applies a generated title to its chat — open or not — only while it
    /// still has the title it had when the title was asked for: a rename in
    /// the meantime wins, and a deleted chat stays deleted.
    func applyGeneratedTitle(_ title: String, to sessionID: UUID, replacing placeholder: String) {
        if var open = currentSession, open.id == sessionID {
            guard open.title == placeholder else { return }
            open.title = title
            sessionStore?.updateSession(open)
            currentSession = open
        } else if var other = sessionStore?.sessions(for: agentID).first(where: { $0.id == sessionID }),
                  other.title == placeholder {
            other.title = title
            sessionStore?.updateSession(other)
        }
    }

    // MARK: - Goal Mode

    struct GoalState {
        let condition: String
        let startedAt: Date
        var turns: Int = 0
        var totalInputTokens: Int = 0
        var totalOutputTokens: Int = 0
        var totalCostUSD: Double = 0
    }

    func cancelGoal() {
        activeGoal = nil
        if isStreaming {
            orchestrator.interrupt(agentID: agentID)
        }
        messages.append(Message(id: UUID(), timestamp: .now, sender: .system, content: .text("Goal cancelled.")))
    }

    private func runLoopMode(instruction: String) async {
        activeGoal = GoalState(condition: "loop: \(instruction)", startedAt: Date())
        let maxTurns = 50

        var currentPrompt = instruction

        // A loop turn is a goal turn without the completion check: same send,
        // same tool-result drain, same tally.
        while activeGoal != nil && (activeGoal?.turns ?? 0) < maxTurns {
            guard await runGoalTurn(prompt: currentPrompt) else { break }
            currentPrompt = "Continue. Take the next step."
        }

        if activeGoal != nil {
            let elapsed = Int(Date().timeIntervalSince(activeGoal!.startedAt))
            messages.append(Message(id: UUID(), timestamp: .now, sender: .system, content: .text("Loop ended after \(activeGoal!.turns) turns (\(elapsed)s, $\(String(format: "%.4f", activeGoal!.totalCostUSD)))")))
            activeGoal = nil
        }
    }

    private func runGoalLoop(condition: String, initialMessage: String) async {
        activeGoal = GoalState(condition: condition, startedAt: Date())

        var currentPrompt = Self.goalOpeningPrompt(condition: condition, initialMessage: initialMessage)
        let maxTurns = 25

        while activeGoal != nil && (activeGoal?.turns ?? 0) < maxTurns {
            guard await runGoalTurn(prompt: currentPrompt) else { break }

            if lastMessageDeclaresGoalComplete {
                announceGoalAchieved()
                break
            }

            currentPrompt = Self.goalContinuationPrompt(condition: condition)
        }

        if activeGoal != nil {
            messages.append(Message(id: UUID(), timestamp: .now, sender: .system, content: .text("Goal loop ended after \(activeGoal!.turns) turns (max reached).")))
            activeGoal = nil
        }
    }

    private static func goalOpeningPrompt(condition: String, initialMessage: String) -> String {
        """
        You have a goal to achieve. Work autonomously until the following condition is met:

        **Goal:** \(condition)

        Start by: \(initialMessage.isEmpty ? "Assess the current state and begin working toward the goal." : initialMessage)

        After each step, evaluate whether the goal is met. If it is, respond with exactly "GOAL_COMPLETE" on its own line at the end of your message. If not, continue working.
        """
    }

    private static func goalContinuationPrompt(condition: String) -> String {
        "Continue working toward the goal: \(condition)\n\nIf the goal is now met, respond with \"GOAL_COMPLETE\" on its own line. Otherwise, take the next step."
    }

    /// Runs one turn of the goal loop. Returns false when the goal was cancelled while the turn ran.
    private func runGoalTurn(prompt: String) async -> Bool {
        activeGoal?.turns += 1
        isStreaming = true

        var currentStream: AsyncStream<StreamEvent>? = orchestrator.send(prompt, to: agentID)
        var receivedResult = false

        while let stream = currentStream {
            currentStream = nil
            let turnResult = await processStream(stream, receivedResult: &receivedResult)
            if case .continueWithToolResult(let id, let content) = turnResult {
                currentStream = orchestrator.sendToolResult(toolCallID: id, content: content, to: agentID)
            }
        }

        orchestrator.markTurnDone(agentID: agentID)
        isStreaming = false
        saveMessages()

        guard activeGoal != nil else { return false }

        activeGoal?.totalInputTokens += lastInputTokens
        activeGoal?.totalOutputTokens += lastOutputTokens
        activeGoal?.totalCostUSD += lastTurnCostUSD
        return true
    }

    private var lastMessageDeclaresGoalComplete: Bool {
        guard let lastMsg = messages.last, case .text(let text) = lastMsg.content else { return false }
        return text.contains("GOAL_COMPLETE")
    }

    private func announceGoalAchieved() {
        guard let goal = activeGoal else { return }
        let elapsed = Date().timeIntervalSince(goal.startedAt)
        messages.append(Message(id: UUID(), timestamp: .now, sender: .system, content: .text("Goal achieved in \(goal.turns) turns (\(Int(elapsed))s, $\(String(format: "%.4f", goal.totalCostUSD)))")))
        activeGoal = nil
    }
}

// MARK: - Work running beside the conversation

extension ChatViewModel {
    /// A session notice about a subagent, a background task, the model's
    /// thinking or the rate limit, folded into `agentActivity`. Anything else
    /// the CLI says about itself is ignored — it adds subtypes, and an older
    /// Kiteloop must not break on a new one.
    private func applyActivityNotice(subtype: String, payload: [String: Any]) {
        guard let event = AgentActivityEvent.parse(subtype: subtype, payload: payload) else { return }
        let previousLimit = agentActivity.rateLimit
        agentActivity.apply(event)
        saveFinishedTasks()
        switch event {
        case .thinkingTokens(let estimated):
            setActivity(AgentActivityDisplay.thinkingLabel(text: "", estimatedTokens: estimated))
        case .rateLimit(let info):
            orchestrator.noteRateLimit(info)
            appendRateLimitNotice(previous: previousLimit, current: info)
        default:
            break
        }
    }

    /// Writes each task that has finished onto the call that started it, and
    /// saves when that changed anything, so a reopened chat still says how
    /// its subagents and background shells ended.
    private func saveFinishedTasks() {
        let finished = agentActivity.finishedTasksByToolUseID
        guard !finished.isEmpty else { return }
        var changed = false
        for index in messages.indices {
            guard case .toolCall(var call) = messages[index].content, let task = finished[call.id] else { continue }
            let saved = AgentActivity.SavedTask(task)
            guard call.finishedTask != saved else { continue }
            call.finishedTask = saved
            messages[index].content = .toolCall(call)
            changed = true
        }
        if changed { saveMessages() }
    }

    /// The task a call's row reads: the live one, or the one saved with the
    /// chat once the session that ran it is gone.
    func task(forCall call: Message.ToolCall) -> AgentActivity.TaskState? {
        agentActivity.task(forToolUseID: call.id) ?? call.finishedTask?.taskState(toolUseID: call.id)
    }

    /// A system line for a rate-limit notice that says something — a warning
    /// or a refusal — once per change. The routine `allowed` gets none.
    private func appendRateLimitNotice(previous: AgentActivityEvent.RateLimitInfo?,
                                       current: AgentActivityEvent.RateLimitInfo) {
        guard let notice = AgentActivityDisplay.rateLimitNotice(previous: previous, current: current) else { return }
        let content: Message.Content = current.status == "rejected" ? .error(notice) : .text(notice)
        messages.append(Message(id: UUID(), timestamp: .now, sender: .system, content: content))
    }
}

/// The chat `GET /v1/agents/events` streams.
extension ChatViewModel: AgentChatSource {}
