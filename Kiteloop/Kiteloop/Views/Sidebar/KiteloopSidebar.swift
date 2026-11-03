import KiteloopCore
import SwiftUI

struct KiteloopSidebar: View {
    let agents: [Agent]
    var width: CGFloat = KiteloopTokens.Sidebar.width
    @Binding var selectedID: String?
    var pendingMemoryCount: Int = 0
    var claudeVersion: String? = nil
    var onNewAgent: () -> Void
    var onQuickAdd: ((QuickAddPreset) -> Void)? = nil
    var onTeamSettings: () -> Void
    /// Opens the Coordinator drawer. Portfolio-level rather than project-level,
    /// so it sits in the footer next to Project Settings instead of in the
    /// per-project list above. Absent (nil) wherever there is no drawer to open.
    var onOpenCoordinator: (() -> Void)? = nil
    /// Whether that drawer is currently showing — the footer button reads as a
    /// toggle, so it has to say which way it is set.
    var isCoordinatorOpen: Bool = false
    /// The coordinator's grooming budget, read straight off the refill loop's
    /// observed state — nil where no loop is wired into this window.
    ///
    /// It is here because "are we about to stop grooming?" is a standing
    /// question and the numbers answering it were reachable only by opening the
    /// Coordinator panel. A value rather than the loop itself: the footer reads
    /// this, it cannot start a pass, and it has no timer — the loop publishes,
    /// the footer redraws.
    var coordinatorBudget: QueueRefill.Budget? = nil
    /// The day's shared ceiling and what has been spent against it, for the box
    /// that stands beside the Planner's and the fleet's rather than in one of
    /// them. Nil leaves the box out entirely, the way the two above it work.
    var dailyBudget: DailyBudget? = nil
    /// Writes a new ceiling; nil clears it. Held here rather than reached for,
    /// so the sidebar stays a thing that renders state and reports intent.
    var setDailyBudgetUSD: ((Double?) -> Void)? = nil
    /// Grooming having *stopped* — a pass stuck past its deadline, or the last
    /// one having been ended at it. Nil while the loop is merely between passes.
    ///
    /// It shares the budget's line rather than getting one of its own: both
    /// answer "is grooming about to stop, or has it?", and a nearest ceiling
    /// still has room by definition while it is only the nearest.
    var coordinatorStall: String? = nil
    /// One word of state — "On" or "Off" — chipped beside the name, so the
    /// box's first line says what the loop *is* before what it's doing. Nil
    /// hides the chip entirely (no loop wired).
    var coordinatorModeLabel: String? = nil
    /// "pass running now" or "next look ~7m" — liveness at glance altitude.
    var coordinatorNextLook: String? = nil
    /// The day so far ("today 12 filed · 9 merged"). Nil on a quiet day, so
    /// the box doesn't open a morning with a row of zeros.
    var coordinatorRollup: String? = nil
    /// The autonomous-run holds while there are any — a red news line, absent
    /// otherwise, same pattern as the stall. It names which project is not
    /// starting runs and on what evidence, because "runs halted" alone is what
    /// somebody read at 3am and could do nothing with.
    var coordinatorHold: String? = nil
    /// Clear those holds — `resetBreaker`, the human override. Offered on the
    /// line itself: until now that line was display-only text and the only
    /// lever was `PUT /v1/coordinator/scheduling`, which is exactly where a
    /// person reading a sidebar cannot reach. Nil hides the control (no
    /// scheduler wired), leaving the line as it was.
    var onClearCoordinatorHold: (() -> Void)? = nil
    /// The fleet-wide hold, portfolio-level like the Coordinator box above it —
    /// it holds every open project's queue, not this one's. Nil where no fleet
    /// is wired, and before the first reading has been taken.
    var fleetStatus: FleetQuiesceStatus?
    /// When the run scheduler will next look, or nil when it is switched off.
    var fleetNextLook: String? = nil
    /// Hold every advancing queue and refuse new runs. Called on the control
    /// when it reads Pause.
    var onQuiesceFleet: (() -> Void)? = nil
    /// Lift that hold. Called on the same control when it reads Resume.
    var onResumeFleet: (() -> Void)? = nil
    /// Opens the fleet drawer — the same state with the room to draw it: a row
    /// per open project, the item each is on, and the same two controls. Absent
    /// (nil) wherever there is no drawer to open, leaving the box a readout.
    var onOpenFleet: (() -> Void)? = nil
    /// Whether that drawer is currently showing — the box reads as a toggle, so
    /// it has to say which way it is set, like the Coordinator's above it.
    var isFleetOpen: Bool = false
    /// Everything across the open projects that only a person can clear. Nil
    /// where no window state feeds it, which leaves the box out entirely — the
    /// same way an unwired fleet leaves its own box out.
    var waitingOnYou: WaitingOnYou? = nil
    /// Opens the drawer that lists it. Absent (nil) leaves the box a readout,
    /// like the fleet's.
    var onOpenWaiting: (() -> Void)? = nil
    /// Whether that drawer is currently showing.
    var isWaitingOpen: Bool = false
    /// Pins a screen id to the top of a split view.
    var onPinToSplit: ((String) -> Void)? = nil
    var onStopAgent: (String) -> Void
    /// Brings a stopped agent back up. Nil starts nothing.
    var onStartAgent: ((String) -> Void)? = nil
    var onRemoveAgent: (String) -> Void
    var onEditAgent: ((String) -> Void)? = nil
    /// Restarts an agent's live session, so an MCP key saved in Configure…
    /// reaches it. Nil restarts nothing.
    var onRestartAgent: ((String) -> Void)? = nil
    /// Whether an agent has a live session to restart.
    var hasAgentSession: (String) -> Bool = { _ in false }
    var sessionStore: SessionStore? = nil
    var onSwitchSession: ((ChatSession) -> Void)? = nil
    /// The id of the chat the selected agent has open. Absent (nil) highlights
    /// the newest chat.
    var openSessionID: UUID? = nil
    var onNewSession: (() -> Void)? = nil
    var onDeleteSession: ((ChatSession) -> Void)? = nil
    var onRenameSession: ((ChatSession, String) -> Void)? = nil
    var onExportSession: ((ChatSession) -> Void)? = nil
    var repoStatusStore: RepoStatusStore? = nil
    var repoCloneService: RepoCloneService? = nil
    var githubOrg: String = ""
    /// Agents autopilot is currently driving unattended — badged in the roster.
    var unattendedAgentIDs: Set<String> = []
    /// Agents with no live session — their row reads "Stopped" and offers Start.
    var stoppedAgentIDs: Set<String> = []

    @State private var infoAgentID: String?
    @State private var configAgentID: String?
    @State private var repoPopoverAgentID: String?
    @State private var pendingRemoveAgent: Agent?
    @State private var pendingDeleteSession: ChatSession?
    @State private var pendingRenameSession: ChatSession?
    @State private var renameText = ""
    @State private var sessionQuery = ""
    @State private var ollamaProbe = RuntimeProbe { await OllamaRuntime.isAvailable() }
    @State private var copilotProbe = RuntimeProbe { await CopilotBridgeRuntime.isAvailable() }

    private let backlogID = "__backlog__"
    private let memoryID = "__memory__"
    private let autopilotID = "__autopilot__"
    private let portfolioID = "__portfolio__"

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    sectionHeader("Team")

                    SidebarRow(
                        icon: Image(systemName: "checklist")
                            .font(.system(size: 13))
                            .foregroundStyle(.indigo),
                        label: "Backlog",
                        isSelected: selectedID == backlogID,
                        splitAction: { onPinToSplit?(backlogID) },
                        action: { selectedID = backlogID }
                    )
                    .accessibilityIdentifier("backlog-sidebar-entry")

                    SidebarRow(
                        icon: Image(systemName: "brain")
                            .font(.system(size: 13))
                            .foregroundStyle(.purple),
                        label: "Memory",
                        badge: pendingMemoryCount > 0 ? pendingMemoryCount : nil,
                        isSelected: selectedID == memoryID,
                        splitAction: { onPinToSplit?(memoryID) },
                        action: { selectedID = memoryID }
                    )
                    .accessibilityIdentifier("memory-sidebar-entry")

                    SidebarRow(
                        icon: Image(systemName: "bolt.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.yellow),
                        label: "Autopilot",
                        isSelected: selectedID == autopilotID,
                        splitAction: { onPinToSplit?(autopilotID) },
                        action: { selectedID = autopilotID }
                    )
                    .accessibilityIdentifier("autopilot-sidebar-entry")

                    // Portfolio-wide rather than per-project: it reads
                    // `~/.kiteloop/portfolio.md` and shows those projects'
                    // backlogs together, so it draws the same list whichever tab
                    // it is opened from. It sits here rather than in the footer
                    // because it is a screen you select, and the footer's
                    // portfolio-global entries are drawers and toggles.
                    SidebarRow(
                        icon: Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 13))
                            .foregroundStyle(.teal),
                        label: "Portfolio",
                        isSelected: selectedID == portfolioID,
                        splitAction: { onPinToSplit?(portfolioID) },
                        action: { selectedID = portfolioID }
                    )
                    .accessibilityIdentifier("portfolio-sidebar-entry")

                    // In the project section because that is its scope — it
                    // lived in the footer, where everything else is portfolio-
                    // global, until 2026-08-12. Opens a sheet, so no selection
                    // and no split.
                    SidebarRow(
                        icon: Image(systemName: "gearshape")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary),
                        label: "Project Settings",
                        isSelected: false,
                        action: { onTeamSettings() }
                    )
                    .accessibilityIdentifier("project-settings-sidebar-entry")

                    Spacer()
                        .frame(height: KiteloopTokens.Sidebar.sectionSpacing)

                    HStack {
                        Text("AGENTS")
                            .font(.system(.caption2, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Menu {
                            ForEach(QuickAddPreset.all) { preset in
                                let available = presetAvailable(preset)
                                Button {
                                    onQuickAdd?(preset)
                                } label: {
                                    Label(
                                        available ? preset.label : "\(preset.label) (not running)",
                                        systemImage: preset.icon
                                    )
                                }
                                .disabled(!available)
                            }
                            Divider()
                            Button {
                                onNewAgent()
                            } label: {
                                Label("New Agent...", systemImage: "plus.circle")
                            }
                            // Menu content appears each time the menu opens: re-read
                            // the runtimes then, so one started since the last look
                            // is pickable on the next open. Once, on one item, not
                            // on every row.
                            .onAppear { Task { await checkOllamaStatus() } }
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityIdentifier("new-agent-button")
                        .help("Add Agent")
                    }
                    .padding(.horizontal, KiteloopTokens.Sidebar.rowPadding + 11)
                    .padding(.bottom, 4)
                    .task { await checkOllamaStatus() }

                    if agents.isEmpty {
                        emptyRoster
                    }

                    ForEach(groupedAgents, id: \.key) { group in
                        if let groupName = group.key {
                            Text(groupName.uppercased())
                                .font(.system(.caption2))
                                .foregroundStyle(.quaternary)
                                .padding(.horizontal, KiteloopTokens.Sidebar.rowPadding + 11)
                                .padding(.top, 6)
                        }
                        ForEach(group.agents) { agent in
                            SidebarRow(
                                icon: AgentAvatarView(
                                    agent: agent,
                                    size: KiteloopTokens.Sidebar.avatarSize,
                                    hasMissingRepos: repoStatusStore?.hasMissingRepos(agent.id) ?? false,
                                    isUnattended: unattendedAgentIDs.contains(agent.id),
                                    onBadgeTap: { repoPopoverAgentID = agent.id }
                                ),
                                label: agent.name,
                                subtitle: KiteloopSidebar.agentSubtitle(for: agent, isStopped: stoppedAgentIDs.contains(agent.id)),
                                isSelected: selectedID == agent.id,
                                infoAction: { infoAgentID = agent.id },
                                // An aside is meant to be closed when the
                                // question is answered, so it gets a one-click
                                // dismiss rather than only a context menu.
                                dismissAction: agent.isAside ? { onRemoveAgent(agent.id) } : nil,
                                dismissHelp: "Dismiss this aside",
                                action: { selectedID = agent.id }
                            )
                            .accessibilityIdentifier("agent-\(agent.id)")
                            .popover(isPresented: Binding(
                                get: { repoPopoverAgentID == agent.id },
                                set: { if !$0 { repoPopoverAgentID = nil } }
                            ), arrowEdge: .trailing) {
                                if let store = repoStatusStore, let cloneService = repoCloneService {
                                    RepoResolutionPopover(
                                        agentName: agent.name,
                                        missingRepos: store.missingRepos(for: agent.id),
                                        cloneService: cloneService,
                                        repoStatusStore: store,
                                        org: githubOrg
                                    )
                                }
                            }
                            .popover(isPresented: Binding(
                                get: { infoAgentID == agent.id },
                                set: { if !$0 { infoAgentID = nil } }
                            ), arrowEdge: .trailing) {
                                AgentInfoPopover(agent: agent, onConfigure: {
                                    infoAgentID = nil
                                    configAgentID = agent.id
                                })
                            }
                            .contextMenu {
                                if repoStatusStore?.hasMissingRepos(agent.id) == true {
                                    Button("Resolve Missing Repos…") { repoPopoverAgentID = agent.id }
                                }
                                if agent.mcpConfigPath != nil {
                                    Button("Configure…") { configAgentID = agent.id }
                                }
                                Button("Edit Agent…") { onEditAgent?(agent.id) }
                                    .accessibilityIdentifier("edit-agent-\(agent.id)")
                                if stoppedAgentIDs.contains(agent.id) {
                                    Button("Start Agent") { onStartAgent?(agent.id) }
                                        .accessibilityIdentifier("start-agent-\(agent.id)")
                                } else {
                                    Button("Stop Agent") { onStopAgent(agent.id) }
                                        .accessibilityIdentifier("stop-agent-\(agent.id)")
                                }
                                Divider()
                                Button(agent.isAside ? "Dismiss Aside" : "Remove Agent", role: .destructive) {
                                    if agent.isAside {
                                        onRemoveAgent(agent.id)
                                    } else {
                                        pendingRemoveAgent = agent
                                    }
                                }
                                .accessibilityIdentifier("remove-agent-\(agent.id)")
                            }
                        }
                    }

                    if let sessionStore, let selectedID, let selectedAgent = agents.first(where: { $0.id == selectedID }) {
                        let agentSessions = sessionStore.sessions(for: selectedAgent.id)
                        let highlightedID = Self.highlightedSessionID(open: openSessionID, in: agentSessions.map(\.id))
                        if !agentSessions.isEmpty {
                            Spacer()
                                .frame(height: KiteloopTokens.Sidebar.sectionSpacing)

                            HStack {
                                Text("SESSIONS")
                                    .font(.system(.caption2, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                                Spacer()
                                Button { onNewSession?() } label: {
                                    Image(systemName: "plus")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("New Session")
                                .accessibilityIdentifier("new-session-button")
                            }
                            .padding(.horizontal, KiteloopTokens.Sidebar.rowPadding + 11)
                            .padding(.bottom, 4)

                            sessionList(agentSessions, highlightedID: highlightedID)
                        }
                    }

                }
                .padding(.vertical, 12)
                .padding(.horizontal, 8)
            }


            Divider()

            VStack(spacing: 6) {
                statusBlock

                HStack(spacing: 6) {
                    Text("Kiteloop \(appVersion)")
                    if let version = claudeVersion {
                        Text("· Claude Code \(version)")
                    }
                    Spacer()
                }
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: width)
        .background(.background)
        .accessibilityIdentifier("agent-sidebar")
        .sheet(isPresented: Binding(
            get: { configAgentID != nil },
            set: { if !$0 { configAgentID = nil } }
        )) {
            if let agentID = configAgentID,
               let agent = agents.first(where: { $0.id == agentID }),
               let mcpPath = agent.mcpConfigPath {
                AgentConfigSheet(
                    agentName: agent.name,
                    mcpConfigPath: mcpPath,
                    hasSession: hasAgentSession(agentID),
                    state: agent.state,
                    onRestart: { onRestartAgent?(agentID) }
                )
            }
        }
        .confirmationDialog(
            "Remove this agent from the team?",
            isPresented: Binding(
                get: { pendingRemoveAgent != nil },
                set: { if !$0 { pendingRemoveAgent = nil } }
            )
        ) {
            Button("Remove", role: .destructive) {
                guard let agent = pendingRemoveAgent else { return }
                pendingRemoveAgent = nil
                onRemoveAgent(agent.id)
            }
            Button("Cancel", role: .cancel) { pendingRemoveAgent = nil }
        } message: {
            Text(Self.removeAgentMessage(name: pendingRemoveAgent?.name ?? ""))
        }
        .confirmationDialog(
            "Delete this chat?",
            isPresented: Binding(
                get: { pendingDeleteSession != nil },
                set: { if !$0 { pendingDeleteSession = nil } }
            ),
            presenting: pendingDeleteSession
        ) { session in
            Button("Delete", role: .destructive) {
                pendingDeleteSession = nil
                onDeleteSession?(session)
            }
            Button("Cancel", role: .cancel) { pendingDeleteSession = nil }
        } message: { session in
            Text(Self.deleteChatMessage(for: session))
        }
        .alert(
            "Rename Chat",
            isPresented: Binding(
                get: { pendingRenameSession != nil },
                set: { if !$0 { pendingRenameSession = nil } }
            ),
            presenting: pendingRenameSession
        ) { session in
            TextField("Name", text: $renameText)
            Button("Save") {
                pendingRenameSession = nil
                onRenameSession?(session, renameText)
            }
            .disabled(!Self.isValidChatName(renameText))
            Button("Cancel", role: .cancel) { pendingRenameSession = nil }
        }
        .onChange(of: selectedID) { sessionQuery = "" }
    }

    /// What Remove Agent does, said before it does it: the live session stops
    /// and the agent, with its settings here, leaves this project's team.
    static func removeAgentMessage(name: String) -> String {
        "Stops the live session of “\(name)” and removes it, with its settings for this project, from this project's team."
    }

    /// What Delete Chat does, said before it does it: the chat, named by the
    /// title its row shows, goes with all of its messages.
    static func deleteChatMessage(for session: ChatSession) -> String {
        let title = session.isUntitled ? "New Chat" : session.title
        return "Deletes the chat “\(title)” and all of its messages. This can't be undone."
    }

    /// What Rename Chat's field starts from: the title the row shows.
    static func renameChatInitialText(for session: ChatSession) -> String {
        session.isUntitled ? "New Chat" : session.title
    }

    /// Whether Rename Chat can save `name`: blank or all-whitespace cannot.
    static func isValidChatName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The session row drawn selected: the open chat when it is listed,
    /// otherwise the first (newest) one; nil when there are none.
    static func highlightedSessionID(open: UUID?, in sessionIDs: [UUID]) -> UUID? {
        sessionIDs.first { $0 == open } ?? sessionIDs.first
    }

    /// A session row's subtitle: "Draft: " and the first non-blank line of
    /// the chat's unsent draft when it holds any text, otherwise
    /// `lastMessageTime`, the relative time of its last message.
    static func sessionSubtitle(for session: ChatSession, lastMessageTime: String) -> String {
        let firstLine = (session.draft ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let firstLine else { return lastMessageTime }
        return "Draft: " + firstLine
    }

    /// Whether the SESSIONS list offers a filter field: only once there is
    /// more than one chat to narrow.
    static func showsSessionFilter(for sessions: [ChatSession]) -> Bool {
        sessions.count > 1
    }

    /// The sessions whose shown title contains `query`, ignoring case, in
    /// their given order; all of them for a blank or all-whitespace query.
    /// An untitled chat is matched as "New Chat", the title its row shows.
    static func filteredSessions(_ sessions: [ChatSession], query: String) -> [ChatSession] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return sessions }
        return sessions.filter { renameChatInitialText(for: $0).localizedCaseInsensitiveContains(needle) }
    }

    /// The sessions the SESSIONS list shows: filtered by `query` only while
    /// the filter field is on screen, so text left behind when the field goes
    /// away never hides a chat nothing on screen could bring back.
    static func shownSessions(_ sessions: [ChatSession], query: String) -> [ChatSession] {
        filteredSessions(sessions, query: showsSessionFilter(for: sessions) ? query : "")
    }

    /// The SESSIONS rows under the header: a filter field once the agent has
    /// more than one chat, then the chats whose title matches it. The
    /// highlight is worked out by the caller over the unfiltered list.
    @ViewBuilder
    private func sessionList(_ sessions: [ChatSession], highlightedID: UUID?) -> some View {
        if Self.showsSessionFilter(for: sessions) {
            TextField("Filter chats", text: $sessionQuery)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .help("Show only the chats whose title contains this text")
                .padding(.horizontal, KiteloopTokens.Sidebar.rowPadding + 4)
                .padding(.bottom, 4)
                .accessibilityIdentifier("session-filter-field")
        }
        let shown = Self.shownSessions(sessions, query: sessionQuery)
        if shown.isEmpty {
            Text("No matching chats")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, KiteloopTokens.Sidebar.rowPadding + 11)
                .accessibilityIdentifier("session-filter-empty")
        }
        ForEach(shown) { session in
            SidebarRow(
                icon: Image(systemName: "bubble.left")
                    .font(.system(size: 13))
                    .foregroundStyle(session.id == highlightedID ? .blue : .secondary),
                label: session.isUntitled ? "New Chat" : session.title,
                subtitle: Self.sessionSubtitle(
                    for: session,
                    lastMessageTime: session.lastMessageAt.formatted(.relative(presentation: .named))
                ),
                isSelected: session.id == highlightedID,
                action: { onSwitchSession?(session) }
            )
            .contextMenu {
                Button("Rename Chat…") {
                    renameText = Self.renameChatInitialText(for: session)
                    pendingRenameSession = session
                }
                Button("Export Chat…") {
                    onExportSession?(session)
                }
                Button("Delete Chat…", role: .destructive) {
                    pendingDeleteSession = session
                }
            }
            .accessibilityIdentifier("session-\(session.id)")
        }
    }

    private var groupedAgents: [AgentGroup] {
        var groups: [String?: [Agent]] = [:]
        for agent in agents {
            groups[agent.group, default: []].append(agent)
        }
        let order = groups.keys.sorted { ($0 ?? "") < ($1 ?? "") }
        return order.map { AgentGroup(key: $0, agents: groups[$0]!) }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// The portfolio's four standing readouts — Planner, Fleet, Waiting on you
    /// and the day's budget — as one bordered block of one-line rows.
    ///
    /// Each was a card of its own, and four cards stacked to a third of a
    /// laptop's sidebar for what is four status lines, pushing the sessions off
    /// screen. A row keeps what a card was for at a glance — its name, its state
    /// and the click that opens its drawer — and the rest of what the card said
    /// is in the row's tooltip and in the drawer. A row whose source is not
    /// wired is left out, as its card was.
    ///
    /// Two lines stay outside the block, under it, while they last: the
    /// autonomous hold, which wraps because it names its way out and offers it,
    /// and a quit waiting on the fleet to drain.
    @ViewBuilder
    private var statusBlock: some View {
        if hasStatusRows {
            VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.sm) {
                if let onOpenCoordinator {
                    coordinatorButton(onOpenCoordinator)
                }
                if let fleetStatus {
                    fleetRow(fleetStatus)
                }
                if let waitingOnYou {
                    waitingSummary(waitingOnYou)
                }
                if let dailyBudget, let setDailyBudgetUSD {
                    AutonomyCeilingBox(budget: dailyBudget, setBudgetUSD: setDailyBudgetUSD)
                }
            }
            .padding(.horizontal, KiteloopTokens.Spacing.md)
            .padding(.vertical, KiteloopTokens.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: KiteloopTokens.Radius.md)
                    .fill(Color.primary.opacity(KiteloopTokens.Opacity.subtle))
            )
            .overlay(
                RoundedRectangle(cornerRadius: KiteloopTokens.Radius.md)
                    .strokeBorder(Color.primary.opacity(KiteloopTokens.Opacity.medium), lineWidth: 1)
            )
            .accessibilityIdentifier("sidebar-status-block")
        }
        if onOpenCoordinator != nil, let coordinatorHold {
            holdNotice(coordinatorHold, clear: onClearCoordinatorHold)
        }
        if let quitNotice = fleetStatus?.quitNotice {
            footerStatusLine(quitNotice, color: .orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("fleet-quiesce-quit-notice")
        }
    }

    /// Whether any of the block's four sources is wired — with none, there is
    /// no block rather than an empty frame.
    private var hasStatusRows: Bool {
        onOpenCoordinator != nil || fleetStatus != nil || waitingOnYou != nil
            || (dailyBudget != nil && setDailyBudgetUSD != nil)
    }

    /// The block's Planner row, and its toggle.
    ///
    /// The state it states is grooming's own: a stall when grooming has
    /// stopped, which is already true, otherwise the passes against their cap.
    /// The next look, the day's rollup and the abandoned passes the card drew
    /// under it are in the tooltip, word for word.
    private func coordinatorButton(_ open: @escaping () -> Void) -> some View {
        let status = coordinatorStall ?? coordinatorBudget?.passText ?? coordinatorNextLook
        return Button(action: open) {
            SidebarStatusRowLabel(icon: "point.3.connected.trianglepath.dotted", name: "Planner",
                                  isOpen: isCoordinatorOpen, status: status, tint: coordinatorTint,
                                  statusID: "coordinator-budget-readout") {
                if let coordinatorModeLabel {
                    Text(coordinatorModeLabel)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(KiteloopTokens.Opacity.light)))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .accessibilityIdentifier("coordinator-mode-chip")
                }
            }
        }
        .buttonStyle(.plain)
        .help(coordinatorRowHelp)
        .accessibilityIdentifier("coordinator-drawer-button")
    }

    /// Red for a stall, orange for passes used up, otherwise the small print's
    /// grey — the colours the card's budget line had.
    private var coordinatorTint: Color {
        if coordinatorStall != nil { return .red }
        guard let budget = coordinatorBudget, let maxPasses = budget.maxPasses else { return .secondary }
        return budget.passes >= maxPasses ? .orange : .secondary
    }

    /// The Planner row's tooltip: what the row is, then every line the card
    /// showed under its name.
    private var coordinatorRowHelp: String {
        [coordinatorHelp, coordinatorStall, coordinatorBudget?.helpText, coordinatorNextLook, coordinatorRollup]
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    /// The quit notice's small print — the shape a row's state is drawn in, so
    /// the line reads as part of the block above it.
    private func footerStatusLine(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(1)
    }

    /// The autonomous hold: what is being withheld, and the way out of it in
    /// the same place.
    ///
    /// It wraps rather than truncating, unlike the small print above it. The
    /// reason names the project, the failure and what would end the hold, and a
    /// single elided line of that is the state this line already had — a red
    /// sentence you cannot act on.
    private func holdNotice(_ text: String, clear: (() -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.red)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            if let clear {
                Button("Resume runs", action: clear)
                    .font(.system(size: 9))
                    .buttonStyle(.link)
                    .help("Clear the hold and let autonomous runs start again in this project.")
                    .accessibilityIdentifier("coordinator-hold-clear")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("coordinator-hold-notice")
    }

    /// The block's Fleet row: the fleet-wide hold, which acts on every open
    /// project rather than the one the rest of the sidebar is about. Which
    /// projects are still finishing, what each is on and whose queue a pause
    /// holds live in `FleetDrawer`, and the row opens it.
    ///
    /// It shows the drain rather than only offering the verb. Held and quiet are
    /// different facts and only the second one makes a restart safe, so the
    /// state re-reads as runs finish — "pausing" until the last one lands, then
    /// "paused — all quiet".
    ///
    /// The action stays on the row, beside the name, rather than moving into the
    /// drawer: parking the fleet before a restart is a one-click job.
    private func fleetRow(_ status: FleetQuiesceStatus) -> some View {
        HStack(spacing: KiteloopTokens.Spacing.sm) {
            fleetSummary(status)
            fleetActionButton(status)
                .fixedSize()
        }
    }

    /// The name and the state, as one click that opens the drawer — the state
    /// is the part somebody is reading when they decide they want more of it.
    /// With no drawer wired the same line is drawn plain: an affordance that
    /// leads nowhere is worse than text.
    @ViewBuilder
    private func fleetSummary(_ status: FleetQuiesceStatus) -> some View {
        if let onOpenFleet {
            Button(action: onOpenFleet) {
                fleetSummaryLabel(status)
            }
            .buttonStyle(.plain)
            .help(fleetRowHelp(status))
            .accessibilityIdentifier("fleet-drawer-button")
        } else {
            fleetSummaryLabel(status)
                .help(fleetRowHelp(status))
        }
    }

    private func fleetSummaryLabel(_ status: FleetQuiesceStatus) -> some View {
        SidebarStatusRowLabel(icon: "square.grid.2x2", name: "Fleet", isOpen: isFleetOpen,
                              status: status.stateLine, tint: fleetTint(status.state),
                              statusID: "fleet-quiesce-summary")
    }

    /// The Fleet row's tooltip: what the drawer holds, the whole state line, and
    /// when the scheduler will look again — the line the card drew under it.
    private func fleetRowHelp(_ status: FleetQuiesceStatus) -> String {
        ["Fleet — every open project: what it is running, whether its queue is held, "
            + "and the same Pause and Resume controls", status.stateLine, fleetNextLook]
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    /// The verb, kept on the row for the one-click path. Named "Pause" beside
    /// the row's Fleet, which is the whole of what distinguishes it from the
    /// per-project Pause above: this one also gates a new start, and the help
    /// says so.
    private func fleetActionButton(_ status: FleetQuiesceStatus) -> some View {
        Button {
            switch status.action {
            case .quiesce: onQuiesceFleet?()
            case .resume: onResumeFleet?()
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: status.action == .quiesce ? "pause.circle" : "play.circle")
                    .font(.system(size: 11))
                Text(status.action.title)
                    .font(.caption)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!status.canAct)
        .foregroundStyle(fleetTint(status.state))
        .help(status.help)
        .accessibilityIdentifier("fleet-quiesce-button")
    }

    /// The block's Waiting on you row: what the machines have stopped and
    /// handed back to a person, beside the two rows that say what they are
    /// doing on their own.
    ///
    /// The count is the row, and most of the time also the answer — "nothing is
    /// waiting on you" is worth reading without opening anything. The list
    /// behind it is a click away, in the drawer. With no drawer wired, the same
    /// line plain.
    @ViewBuilder
    private func waitingSummary(_ waiting: WaitingOnYou) -> some View {
        let help = "Waiting on you — every open project's approval gates and unanswered "
            + "agent questions in one list, each opening where it is cleared\n" + waiting.summary
        if let onOpenWaiting {
            Button(action: onOpenWaiting) {
                waitingSummaryLabel(waiting)
            }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityIdentifier("waiting-drawer-button")
        } else {
            waitingSummaryLabel(waiting)
                .help(help)
        }
    }

    private func waitingSummaryLabel(_ waiting: WaitingOnYou) -> some View {
        SidebarStatusRowLabel(icon: "hand.raised", name: "Waiting on you", isOpen: isWaitingOpen,
                              status: waiting.summary, tint: waiting.isEmpty ? .secondary : .orange,
                              statusID: "waiting-summary")
    }

    /// Paused-and-quiet is the state the control is pressed to reach, so it is
    /// the one that reads as good news; pausing is in-between and says so.
    private func fleetTint(_ state: FleetQuiesceStatus.State) -> Color {
        switch state {
        case .takingWork: .secondary
        case .draining: .orange
        case .held: .green
        }
    }

    private var coordinatorHelp: String {
        "Planner — portfolio grooming: state, passes, budget and the day's rollup"
    }

    /// The roster before anyone is hired. `PanelEmptyState`'s copy rules applied
    /// in place rather than the view itself: this is a 240pt column inside a
    /// scroller with the rest of the sidebar under it, which a full-bleed centred
    /// block with a `largeTitle` glyph would take over. The AGENTS header and its
    /// + menu sit directly above, so the message points at them.
    private var emptyRoster: some View {
        let copy = PanelEmptyState.Copy.agents
        return VStack(alignment: .leading, spacing: 2) {
            Text(copy.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(copy.message)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, KiteloopTokens.Sidebar.rowPadding + 11)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agents-empty-state")
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(.caption2, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, KiteloopTokens.Sidebar.rowPadding + 11)
            .padding(.bottom, 4)
    }

    private func presetAvailable(_ preset: QuickAddPreset) -> Bool {
        switch preset.runtimeKind {
        case "ollama": return ollamaProbe.value ?? false
        case "copilot": return copilotProbe.value ?? false
        default: return true
        }
    }

    /// The model line under an agent's name, spelled the way the rest of the app
    /// spells a model: a stored Bedrock inference-profile id reads as its family,
    /// and an id the catalog does not know is shown as stored.
    static func modelSubtitle(for agent: Agent) -> String {
        let model = ModelCatalog.displayName(for: agent.model)
        return agent.isAside ? "aside · \(model)" : model
    }

    /// The row's subtitle: the model line, led by "Stopped · " when the agent
    /// has no live session, so a stopped agent does not pass for an idle one.
    static func agentSubtitle(for agent: Agent, isStopped: Bool) -> String {
        isStopped ? "Stopped · \(modelSubtitle(for: agent))" : modelSubtitle(for: agent)
    }

    private func checkOllamaStatus() async {
        async let ollama: Void = ollamaProbe.refresh()
        async let copilot: Void = copilotProbe.refresh()
        _ = await (ollama, copilot)
    }
}

private struct AgentGroup: Hashable {
    let key: String?
    let agents: [Agent]

    func hash(into hasher: inout Hasher) { hasher.combine(key) }
    static func == (lhs: AgentGroup, rhs: AgentGroup) -> Bool { lhs.key == rhs.key }
}

/// One row of the sidebar's status block: an icon, the name, anything that
/// belongs beside the name, and the state in the block's small print, cut to one
/// line — the caller puts the whole of it in the row's tooltip.
///
/// The name never truncates; the state gives way first, because the name is
/// what a person scans the block for and the state is a hover away in full.
struct SidebarStatusRowLabel<Accessory: View>: View {
    let icon: String
    let name: String
    let isOpen: Bool
    let status: String?
    let tint: Color
    let statusID: String
    let accessory: Accessory

    init(icon: String, name: String, isOpen: Bool = false, status: String?, tint: Color,
         statusID: String, @ViewBuilder accessory: () -> Accessory) {
        self.icon = icon
        self.name = name
        self.isOpen = isOpen
        self.status = status
        self.tint = tint
        self.statusID = statusID
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .frame(width: 14)
            Text(name)
                .font(.caption)
                .lineLimit(1)
                .fixedSize()
            accessory
            Spacer(minLength: KiteloopTokens.Spacing.sm)
            if let status {
                Text(status)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier(statusID)
            }
        }
        .foregroundStyle(isOpen ? Color.accentColor : .secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

extension SidebarStatusRowLabel where Accessory == EmptyView {
    init(icon: String, name: String, isOpen: Bool = false, status: String?, tint: Color, statusID: String) {
        self.init(icon: icon, name: name, isOpen: isOpen, status: status, tint: tint, statusID: statusID) {
            EmptyView()
        }
    }
}
