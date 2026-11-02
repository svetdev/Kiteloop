import KiteloopCore
import SwiftUI
import UniformTypeIdentifiers
import os.log

private let mainWindowLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "main-window")

private final class BacklogAutopilotCache {
    var instances: [String: BacklogAutopilot] = [:]
}

/// Per-project AI editor + scoping engine backing the Backlog tab, cached so
/// switching projects/tabs preserves their state (mirrors BacklogAutopilotCache).
@MainActor
private final class BacklogEditorsCache {
    var instances: [String: (ai: BacklogAIEditor, scope: TaskScopingEngine)] = [:]
}

struct MainWindow: View {
    let projectStore: ProjectStore
    @ObservedObject var statusLine: StatusLineService
    let runtimeFactory: () -> any AgentRuntime
    let agentCatalogStore: AgentCatalogStore
    let packageResolver: PackageResolver?
    let globalConfigStore: GlobalConfigStore
    let repoCloneService: RepoCloneService
    let orgManifestLoader: OrgManifestLoader
    let activeOrchestratorTracker: ActiveOrchestratorTracker
    let taskMetricStore: TaskMetricStore
    /// The queryable projection of the same ledgers `taskMetricStore` appends
    /// to. Read-only here: the backlog's item history asks it what an item's
    /// runs and approvals were rather than re-walking the JSONL.
    let metricIndex: MetricIndex
    let controlRegistry: ControlSessionRegistry
    /// Portfolio-wide daily spend, threaded to each project's autopilot so the
    /// cap is shared rather than per-project.
    let dailySpendLedger: DailySpendLedger
    /// The portfolio-level refill loop. Owned by the app rather than this window
    /// because it chooses *between* projects and the control API drives the same
    /// one — a second instance would groom for its own favourite in parallel.
    let queueRefill: CoordinatorQueueRefill
    /// The portfolio-level run scheduler, owned by the app alongside the refill
    /// loop. Off by default; this window only wires it to the portfolio and
    /// starts its timer, which does nothing while the switch is off.
    let runScheduler: CoordinatorRunScheduler
    /// The app's caller of the fleet-wide hold, over the same seam
    /// `POST /v1/fleet/quiesce` drives. Owned by the app because the hold is
    /// portfolio-wide and the gate it keeps is read on the path that starts
    /// runs; this window shows it and takes the operator's clicks.
    let fleetQuiesce: FleetQuiesceControl

    @State private var openProjects: [KiteloopProject] = []
    @State private var activeProjectID: String?
    @State private var sessions: [String: ProjectSession] = [:]
    @State private var recentProjects: [RecentProject] = []
    /// The mode picked on the welcome screen for the team agents that name
    /// none. Nil until someone picks one: the project being opened then
    /// decides, through its configured mode (`Agent.initialPermissionMode`).
    @State private var selectedPermissionMode: String?
    @State private var showingNewAgent = false
    @State private var showingProjectSettings = false
    /// The page the settings sheet opens on: General from the sidebar entry,
    /// Autopilot from the gear on the Autopilot tab.
    @State private var projectSettingsPage: ProjectSettingsPage = .general
    @State private var editingAgentID: String?
    @State private var unreadProjects: Set<String> = []
    /// Projects with a run in flight, as of the last refresh — what puts the
    /// spinner on a tab. See `refreshRunningProjects()`: this is read from the
    /// autopilot, not derived here.
    @State private var runningProjects: Set<String> = []
    @State private var claudeVersion: String?
    @State private var dropTargetProjectID: String?
    @State private var showingSetupWizard = false
    @State private var isLoadingProject = false
    private let backlogSidebarID = "__backlog__"
    private let memorySidebarID = "__memory__"
    private let autopilotSidebarID = "__autopilot__"
    private let portfolioSidebarID = "__portfolio__"

    /// The cross-project backlog list. One per window, not one per project: it
    /// reads `~/.kiteloop/portfolio.md` and the projects that names, so which
    /// tab happens to be in front changes nothing about what it shows. Held here
    /// so its file watcher survives switching tabs.
    @State private var portfolioViewModel = PortfolioViewModel()
    @State private var showSidebar = true
    @State private var showInspector = false
    @State private var inspectorTab: InspectorTab = .preview
    /// The Coordinator drawer — its own flag and width rather than a third
    /// Inspector tab, so it and the Inspector can be open at once without
    /// fighting over one column. Persisted next to the panel's own reading preferences: it is
    /// something you leave open across days, not a per-launch choice.
    @AppStorage("coordinatorDrawerOpen") private var showCoordinatorDrawer = false
    @AppStorage("coordinatorDrawerWidth") private var coordinatorDrawerWidth = 420.0
    /// The fleet drawer — its own flag and width beside the Coordinator's, and
    /// persisted the same way. Pausing a fleet is something you watch drain over
    /// minutes, so it is a pane you leave open, not a per-launch choice.
    @AppStorage("fleetDrawerOpen") private var showFleetDrawer = false
    @AppStorage("fleetDrawerWidth") private var fleetDrawerWidth = 420.0
    /// The waiting-on-you drawer, persisted like the two beside it. What is
    /// blocked on a person is something you keep in view for as long as you are
    /// clearing it, so the open/closed choice survives a launch.
    @AppStorage("waitingDrawerOpen") private var showWaitingDrawer = false
    @AppStorage("waitingDrawerWidth") private var waitingDrawerWidth = 420.0
    /// The one drawer open of the three, read off their saved flags and written
    /// back to all three, so opening one closes the others.
    private var openDrawer: SidebarDrawer? {
        get { SidebarDrawer.open(coordinator: showCoordinatorDrawer, fleet: showFleetDrawer, waiting: showWaitingDrawer) }
        nonmutating set {
            showCoordinatorDrawer = newValue == .coordinator
            showFleetDrawer = newValue == .fleet
            showWaitingDrawer = newValue == .waiting
        }
    }
    /// Each open project's pending notifications, by project id — the inbox
    /// data the waiting list takes its wording and its clock from. Kept here
    /// because reading a project's inbox crosses an actor hop, so the view keeps
    /// the last answer and re-asks on the run-indicator cadence.
    @State private var pendingNotices: [String: [NotificationItem]] = [:]
    @State private var showBottomDrawer = false
    @State private var consoleTab: ConsoleTab = .activity
    /// Drag-resizable pane widths (Xcode-style left navigator / right inspector).
    @State private var sidebarWidth: CGFloat = KiteloopTokens.Sidebar.width
    @State private var inspectorWidth: CGFloat = 520
    /// Edge the incoming detail screen slides in from (set by selection direction).
    @State private var detailSlideEdge: Edge = .trailing
    /// Screen pinned to the top half of a split view; nil = single pane.
    @State private var pinnedDetailID: String?
    @State private var webPreviewVM = WebPreviewViewModel(addressStore: .standard)
    @State private var webPreviewWindowManager = WebPreviewWindowManager()
    @State private var errorMessage: String?
    @State private var resumePromptSuppressed: Set<String> = []
    @State private var showingNotifications = false
    @State private var actionableNotificationCount = 0
    @State private var autopilotCache = BacklogAutopilotCache()
    @State private var backlogEditorsCache = BacklogEditorsCache()
    @State private var repoStatusStore: RepoStatusStore?
    /// The item each project's backlog surface has been asked to open, by
    /// project id — how the app-level open-item action reaches a page that is
    /// presented by `EpicBacklogView` rather than by this window. Cleared by
    /// that surface once the page is up, so pressing Back doesn't reopen it.
    @State private var pendingItemPages: [String: String] = [:]
    /// Why the last open-item request went nowhere. Named, and shown as its own
    /// notice rather than through the error alert: a mention that has gone stale
    /// is an ordinary thing to click, not a fault.
    @State private var itemLinkRefusal: String?
    /// The project whose close is waiting on the in-flight-run confirmation, and
    /// the message it shows.
    @State private var pendingClose: (projectID: String, message: String)?

    private var currentSession: ProjectSession? {
        activeProjectID.flatMap { sessions[$0] }
    }

    /// `PaneResizer` drags a `CGFloat`; `@AppStorage` stores a `Double`.
    private var coordinatorDrawerWidthBinding: Binding<CGFloat> {
        Binding(get: { CGFloat(coordinatorDrawerWidth) },
                set: { coordinatorDrawerWidth = Double($0) })
    }

    /// The same conversion for the fleet drawer beside it.
    private var fleetDrawerWidthBinding: Binding<CGFloat> {
        Binding(get: { CGFloat(fleetDrawerWidth) },
                set: { fleetDrawerWidth = Double($0) })
    }

    /// And for the waiting-on-you drawer.
    private var waitingDrawerWidthBinding: Binding<CGFloat> {
        Binding(get: { CGFloat(waitingDrawerWidth) },
                set: { waitingDrawerWidth = Double($0) })
    }

    /// The settings sheet presents by its page, not by a flag: a page read only
    /// inside an `isPresented` sheet's content is the value from before it was
    /// set, so every link opened the sheet on General.
    private var projectSettingsSheetPage: Binding<ProjectSettingsPage?> {
        Binding(get: { showingProjectSettings ? projectSettingsPage : nil },
                set: { if $0 == nil { showingProjectSettings = false } })
    }

    /// What only a person can clear, across every open project.
    ///
    /// Read in `body`'s path rather than kept as state, so the parts of it that
    /// are observable — an item leaving the gate, an agent's question being
    /// answered — reach the footer and the drawer as they happen rather than at
    /// the next tick. Only the notices behind it are cached, and they carry the
    /// wording, never whether a row exists.
    private var waitingOnYou: WaitingOnYou {
        WaitingOnYou.capture(projects: openProjects.compactMap { project in
            guard let session = sessions[project.id] else { return nil }
            let items = session.backlogViewModel.backlogFile?.sections.flatMap(\.items) ?? []
            let agents = session.orchestrator.agents
            return WaitingOnYou.ProjectReading(
                id: project.id,
                name: project.rootURL.lastPathComponent,
                path: project.rootURL.path(percentEncoded: false),
                gatedItems: session.backlogViewModel.gatedItemsForDrawer,
                // An agent holding an `ask_human` or an unanswered plan card —
                // the same flags its chat draws the answer box and the card's
                // buttons from, so the row goes the moment either is answered.
                askingAgents: session.chatViewModels
                    .filter { $0.value.pendingHumanToolCallID != nil || $0.value.hasOpenPlanCard }
                    .map { agentID, _ in
                        .init(id: agentID,
                              name: agents.first { $0.id == agentID }?.name ?? agentID)
                    },
                // Read from the cache `refreshStaleFlags` keeps current, not
                // recomputed here: this is `body`'s own path, and a live git
                // log per open item is exactly the synchronous I/O it must
                // never do.
                staleItems: session.backlogViewModel.staleFlags.map { flag in
                    .init(id: flag.itemID, title: flag.title, status: flag.status, lastTouched: flag.lastTouched)
                },
                pending: pendingNotices[project.id] ?? []
            )
        })
    }

    /// The grooming budget the footer reads, or nil with the loop unwired —
    /// an unwired loop's counters describe nothing that could stop, so showing
    /// them would answer "how close are we to stopping?" with a number about a
    /// loop that was never going to run. Read here, in `body`'s path, so the
    /// footer tracks the loop's published state without a timer of its own.
    private var coordinatorBudget: QueueRefill.Budget? {
        queueRefill.isConfigured ? queueRefill.budget : nil
    }

    /// The day's shared ceiling joined with what the whole portfolio has spent
    /// against it — the pair the ceiling box states and edits.
    ///
    /// Unconditional, unlike `coordinatorBudget` beside it: that one describes a
    /// loop and is hidden when the loop is unwired, while this describes the
    /// money and is true whether either loop is running. An absent ceiling is
    /// the box's most important reading, not a reason to hide it — it is why
    /// neither loop can arm.
    private var dailyBudget: DailyBudget {
        DailyBudget(budgetUSD: globalConfigStore.config.dailyBudgetUSD,
                    spentUSD: dailySpendLedger.spentTodayUSD)
    }

    /// The same liveness line for the loop that *starts* runs. The Planner's box
    /// has said "next look ~7m" for a while; the fleet's said nothing, so an
    /// armed scheduler that simply had not ticked yet read exactly like a broken
    /// one — for up to five minutes after every launch, since the timer sleeps
    /// its interval before the first tick rather than looking straight away.
    private var fleetNextLook: String? {
        guard runScheduler.enabled else { return nil }
        let interval = runScheduler.checkInterval
        guard let last = runScheduler.lastTickAt else {
            return "first look ≤ \(Int(interval / 60))m"
        }
        let remaining = interval - Date().timeIntervalSince(last)
        if remaining > 60 { return "next look ~\(Int((remaining / 60).rounded()))m" }
        return "next look due"
    }

    /// Grooming having stopped rather than merely being between passes, for the
    /// same footer line the ceiling uses. Nil while the loop is ticking over.
    ///
    /// Read here in `body`'s path like the budget beside it, so the footer picks
    /// it up from the loop's published state without a timer of its own — a pass
    /// ended at its deadline is a change to that state, and a pass reaped on the
    /// next attempt is another.
    private var coordinatorStall: String? {
        queueRefill.isConfigured ? queueRefill.stallNotice() : nil
    }

    /// One word of state for the footer chip — "On" or "Off". The most
    /// consequential global the loop has, and until now invisible without
    /// opening the drawer.
    private var coordinatorModeLabel: String? {
        guard queueRefill.isConfigured else { return nil }
        return queueRefill.enabled ? "On" : "Off"
    }

    /// Liveness for the footer box: a pass running now, or roughly when the
    /// next look is due. Approximate on purpose — the footer redraws on the
    /// loop's publishes, not a clock, so the estimate refreshes when the loop
    /// next changes state rather than counting down.
    private var coordinatorNextLook: String? {
        guard queueRefill.isConfigured, queueRefill.enabled else { return nil }
        if queueRefill.isPassing { return "pass running now" }
        // An exhausted ceiling means there is no next look today — promising
        // one ("next look ~7m") is exactly the lie this line existed to avoid.
        // Hit for real on 2026-08-11: the pass cap ran out overnight.
        let budget = queueRefill.budget
        if budget.isExhausted {
            return budget.passExhaustionReason != nil
                ? "resumes tomorrow — passes used"
                : "resumes tomorrow — budget spent"
        }
        let interval = queueRefill.checkInterval
        if let last = queueRefill.passHistory.last?.at {
            let remaining = interval - Date().timeIntervalSince(last)
            if remaining > 60 { return "next look ~\(Int((remaining / 60).rounded()))m" }
            return "next look due"
        }
        return "next look ≤ \(Int(interval / 60))m"
    }

    /// The day so far, merged beside filed — the rate the portfolio report
    /// leads with, at glance altitude. Nil on a day with nothing to say, so a
    /// quiet morning doesn't open with a row of zeros.
    private var coordinatorRollup: String? {
        guard queueRefill.isConfigured, queueRefill.enabled else { return nil }
        let start = Calendar.current.startOfDay(for: Date())
        let filed = queueRefill.groomingLedger.records(from: start, to: Date())
            .count { $0.event == .filedReady || $0.event == .filedDraft }
        let merged = taskMetricStore.records
            .count { $0.merged == true && $0.startedAt >= start }
        let budget = queueRefill.budget
        var parts: [String] = []
        if filed > 0 || merged > 0 { parts.append("\(filed) filed · \(merged) merged") }
        // Passes ride along whenever the day has a cap and any are spent, so
        // the ceiling that stopped grooming overnight on 2026-08-11 is visible
        // while it is still approaching, not only in the line that replaces
        // this one once it has hit.
        if let maxPasses = budget.maxPasses, budget.passes > 0 {
            parts.append("\(budget.passes)/\(maxPasses) passes")
        }
        guard !parts.isEmpty else { return nil }
        return "today " + parts.joined(separator: " · ")
    }

    /// The autonomous-run holds, only while there are any. A held project with
    /// a full ready queue is the "app looks stopped" failure mode — the footer
    /// is where it should surface, and silence otherwise.
    ///
    /// Every active hold, not just the first: they are per-project now, and a
    /// line that named one of two would be the more misleading of the two
    /// possible lies.
    private var coordinatorHold: String? {
        let active = runScheduler.holds.active
        guard !active.isEmpty else { return nil }
        return "runs halted — " + active.map(\.reason).joined(separator: "; ")
    }

    private var sessionContext: ProjectSessionContext {
        ProjectSessionContext(
            runtimeFactory: runtimeFactory,
            agentCatalogStore: agentCatalogStore,
            packageResolver: packageResolver,
            globalConfigStore: globalConfigStore,
            orgManifestLoader: orgManifestLoader,
            repoCloneService: repoCloneService,
            metricStore: taskMetricStore,
            groomingLedger: .shared
        )
    }

    var body: some View {
        Group {
            if activeProjectID != nil {
                HStack(spacing: 0) {
                    if showSidebar {
                        sidebarView
                            .transition(.move(edge: .leading))
                        PaneResizer(width: $sidebarWidth, range: 180...440, growsWithRightwardDrag: true)
                            .transition(.move(edge: .leading))
                    }
                    if openDrawer == .coordinator {
                        CoordinatorDrawer(
                            refill: queueRefill,
                            registry: controlRegistry,
                            recentProjects: recentProjects,
                            vaultURL: globalConfigStore.vaultURL,
                            metricStore: taskMetricStore,
                            groomingLedger: .shared,
                            scheduler: runScheduler,
                            globalConfigStore: globalConfigStore,
                            onClose: {
                                toggleDrawer(.coordinator)
                            }
                        )
                        .frame(width: CGFloat(coordinatorDrawerWidth))
                        .transition(.move(edge: .leading))
                        PaneResizer(width: coordinatorDrawerWidthBinding,
                                    range: 320...720,
                                    growsWithRightwardDrag: true)
                            .transition(.move(edge: .leading))
                    }
                    if openDrawer == .fleet {
                        FleetDrawer(
                            status: fleetQuiesce.status,
                            scheduler: runScheduler,
                            globalConfigStore: globalConfigStore,
                            registry: controlRegistry,
                            refill: queueRefill,
                            onQuiesce: { fleetQuiesce.quiesce() },
                            onResume: { fleetQuiesce.resume() },
                            onClose: {
                                toggleDrawer(.fleet)
                            }
                        )
                        .frame(width: CGFloat(fleetDrawerWidth))
                        .transition(.move(edge: .leading))
                        PaneResizer(width: fleetDrawerWidthBinding,
                                    range: 320...720,
                                    growsWithRightwardDrag: true)
                            .transition(.move(edge: .leading))
                    }
                    if openDrawer == .waiting {
                        WaitingOnYouDrawer(
                            waiting: waitingOnYou,
                            onOpen: { openGate($0) },
                            onClose: {
                                toggleDrawer(.waiting)
                            }
                        )
                        .frame(width: CGFloat(waitingDrawerWidth))
                        .transition(.move(edge: .leading))
                        PaneResizer(width: waitingDrawerWidthBinding,
                                    range: 320...720,
                                    growsWithRightwardDrag: true)
                            .transition(.move(edge: .leading))
                    }
                    centerColumn
                    if showInspector, let session = currentSession {
                        PaneResizer(width: $inspectorWidth, range: 360...860, growsWithRightwardDrag: false)
                        InspectorDrawer(
                            webPreviewVM: webPreviewVM,
                            metricStore: taskMetricStore,
                            projectPath: session.project.rootURL.path(percentEncoded: false),
                            projectName: session.project.rootURL.lastPathComponent,
                            onPopOutWebPreview: {
                                webPreviewWindowManager.show(viewModel: webPreviewVM)
                                withAnimation(.easeInOut(duration: 0.2)) { showInspector = false }
                            },
                            // Switching back to Preview re-parents the one web
                            // view into this drawer, so reclaim it from the
                            // detached window first — otherwise that window
                            // goes blank behind us.
                            tab: Binding(
                                get: { inspectorTab },
                                set: { newTab in
                                    if newTab == .preview { webPreviewWindowManager.closeDetachedWindow() }
                                    inspectorTab = newTab
                                }
                            )
                        )
                        .frame(width: inspectorWidth)
                        .transition(.move(edge: .trailing))
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        projectTabs
                    }
                    ToolbarItem(placement: .primaryAction) {
                        toolbarActions
                    }
                }
            } else if isLoadingProject {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Starting agents...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                startView
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            projectTabs
                        }
                    }
            }
        }
        .frame(minWidth: 700, minHeight: 400)
        .focusedSceneValue(\.projectSession, currentSession)
        // Installed here, over both the project view and the start screen, so
        // every surface in the window that names an item can open it without
        // being handed a navigation closure. See `OpenItemAction`.
        .environment(\.openItem, OpenItemAction { itemID, project in
            openItem(itemID, in: project)
        })
        .environment(\.openAgent, OpenAgentAction { agentID, projectPath in
            AgentLinkLanding.land(
                agentID: agentID, projectPath: projectPath,
                openProjects: openProjects, activeProjectID: activeProjectID,
                switchTo: { switchToProject($0) },
                select: { projectID, agentID in sessions[projectID]?.selectedAgentID = agentID },
                closeNotifications: { showingNotifications = false })
        })
        // Same shape for the settings sheet: any surface in the window can open
        // it on a page without being handed the sheet's state.
        .environment(\.openProjectSettings, OpenProjectSettingsAction { page in
            projectSettingsPage = page
            showingProjectSettings = true
        })
        .navigationTitle(activeProjectName)
        .sheet(isPresented: $showingNewAgent) {
            let agents = currentSession?.orchestrator.agents ?? []
            NewAgentSheet(packageResolver: packageResolver, existingAgentIDs: Set(agents.map(\.id)), agents: agents,
                          projectURL: currentSession?.project.rootURL,
                          appDefaultModel: globalConfigStore.config.defaultModel) { new in
                currentSession?.addAgent(
                    name: new.name, model: new.model, permissionMode: new.permissionMode, avatar: new.avatar,
                    runtimeKind: new.runtimeKind, systemPrompt: new.systemPrompt, tools: new.tools,
                    denied: new.denied, mcpServers: new.mcpServers, skills: new.skills
                )
            }
        }
        .sheet(item: projectSettingsSheetPage) { page in
            if let session = currentSession {
                ProjectSettingsView(
                    project: session.project,
                    globalConfigStore: globalConfigStore,
                    backlog: session.backlogViewModel,
                    autopilot: backlogAutopilot(for: session),
                    agents: session.orchestrator.teamAgents,
                    initialPage: page
                )
            }
        }
        .sheet(isPresented: Binding(
            get: { editingAgentID != nil },
            set: { if !$0 { editingAgentID = nil } }
        )) {
            if let agentID = editingAgentID,
               let session = currentSession {
                AgentEditorSheet(
                    agentID: agentID,
                    orchestrator: session.orchestrator,
                    project: session.project,
                    appConfig: globalConfigStore.config,
                    onSave: { session.persistTeamConfig() },
                    onRestart: { session.restartAgent(agentID) }
                )
            }
        }
        .sheet(isPresented: $showingSetupWizard) {
            SetupWizardView(
                packageResolver: packageResolver,
                repoCloneService: repoCloneService,
                globalConfig: globalConfigStore,
                onDismiss: { showingSetupWizard = false },
                onComplete: {
                    showingSetupWizard = false
                    isLoadingProject = true
                    Task {
                        await openProjectAt(KiteloopProject.homeWorkspace.rootURL)
                        isLoadingProject = false
                    }
                }
            )
        }
        .task {
            controlRegistry.openProject = { url in
                let outcome = await openProjectAt(url)
                guard controlRegistry.entry(forProject: url.path(percentEncoded: false)) != nil else {
                    return .failed
                }
                return outcome
            }
            controlRegistry.reorderProject = { projectID, beforeProjectID in
                reorderProject(projectID, beforeProjectID: beforeProjectID)
            }
            controlRegistry.projectOrder = openProjects.map(\.id)
            guard !UITestingSupport.isUnitTesting else { return }
            // The refill loop watches the portfolio. `configure` applies what was
            // stored — off unless a human said otherwise — and
            // `start()` only spins a timer if the stored setting turned it on.
            queueRefill.configure(registry: controlRegistry,
                                  globalConfigStore: globalConfigStore,
                                  runtimeFactory: runtimeFactory,
                                  metrics: taskMetricStore,
                                  spendLedger: dailySpendLedger)
            // …and hand it to the registry, which is how the control API reaches
            // window-owned state without reaching into view state.
            controlRegistry.queueRefill = queueRefill
            queueRefill.start()
            // The scheduler watches the same portfolio but has its own switch:
            // grooming a backlog and running it unattended are different levels
            // of trust. `configure` applies what was stored — off unless a
            // human turned it on — and `start()` only spins a timer if it did.
            runScheduler.configure(registry: controlRegistry,
                                   globalConfigStore: globalConfigStore,
                                   spendLedger: dailySpendLedger)
            runScheduler.start()
            recentProjects = await projectStore.recentProjects()
            let versionManager = ClaudeVersionManager()
            claudeVersion = await versionManager.currentVersion()
            // Per-project knowledge indexes start in ProjectSession.bootstrap()
            guard !UITestingSupport.isUITesting else { return }
            // Agent resolution and the wizard's package list need the background
            // package scan to have finished; the window stays responsive meanwhile.
            if let packageResolver {
                await packageResolver.ensureLoaded()
                await orgManifestLoader.loadIfNeeded(resolver: packageResolver)
            }
            let homeTeamURL = KiteloopProject.homeWorkspace.teamConfigURL
            let hasHomeWorkspace = FileManager.default.fileExists(atPath: homeTeamURL.path(percentEncoded: false))

            // The home workspace is *not* forced open here. It earns its place
            // on a first run — the `else if` below opens it when there is
            // nothing else to open — and used to keep that place forever,
            // inserted at slot 0 on every launch however many real projects
            // existed. An empty scratch workspace then sat in the tab bar, in
            // the fleet's board and in the Planner's roster as a project with a
            // queue, a paused switch and a consent switch, permanently reading
            // 0 ready · 0 blocked · 0 gate. Reopen it from the + menu.
            let urls = restoreAllBookmarks()

            if !urls.isEmpty {
                isLoadingProject = true
                // Restore all projects concurrently, then wait for them all.
                let openTasks = urls.map { url in
                    Task { @MainActor in await self.openProjectAt(url) }
                }
                for task in openTasks {
                    _ = await task.value
                }
                await projectStore.sortOpen(byURLOrder: urls)
                await reloadOpenProjects()
                isLoadingProject = false
                if let savedActive = UserDefaults.standard.string(forKey: "activeProjectID"),
                   openProjects.contains(where: { $0.id == savedActive }) {
                    activeProjectID = savedActive
                } else if let first = openProjects.first {
                    activeProjectID = first.id
                }
            } else if hasHomeWorkspace {
                isLoadingProject = true
                await openProjectAt(KiteloopProject.homeWorkspace.rootURL)
                isLoadingProject = false
            } else {
                showingSetupWizard = true
            }
            // A row clicked in the menu bar while no window was open posted a
            // request nobody observed; `onChange` never fires for a value that
            // was already set, so it is drained here — once the projects it
            // names are open, not at first draw.
            drainMenuBarRequests()
        }
        .task(id: orchestratorStreamingSnapshot) {
            checkForUnreadCompletions()
        }
        .task {
            // Whether a run is in flight can only be answered across an actor
            // hop (the workflow engine holds the execution), so the view can't
            // ask mid-body — it keeps the last answer and re-asks on a cadence.
            // A second or two of lag on a spinner is invisible; the alternative,
            // a flag the view maintains itself, is how two parts of the app come
            // to disagree about whether a project is busy.
            guard !UITestingSupport.isUnitTesting else { return }
            while !Task.isCancelled {
                await refreshRunningProjects()
                // The fleet reading rides the same cadence and for the same
                // reason: it crosses an actor hop per project, so the footer
                // box and the drawer it opens keep the last answer between them
                // and re-ask on this one cadence. It is what makes a drain
                // visible — the count falls as runs reach their gates without
                // anything here driving them.
                await fleetQuiesce.refresh()
                // And the inbox notices behind the waiting list, for the same
                // reason again: a project's inbox is an actor, so the wording
                // and the clock on each waiting row are kept between ticks.
                // The rows themselves are read live — see `waitingOnYou`.
                await refreshWaitingNotices()
                // And the active project's memory proposals, for the third time
                // the same reason: the sidebar's Memory badge is the only sign
                // a proposal is waiting, and until this tick read it the number
                // moved only when somebody opened the tab — the one moment it
                // had nothing left to say. Only the active project: no other
                // project's sidebar is on screen.
                await currentSession?.memoryViewModel.refreshPendingProposals()
                try? await Task.sleep(for: Self.runIndicatorRefreshInterval)
            }
        }
        .onChange(of: activeProjectID, initial: true) {
            activeOrchestratorTracker.orchestrator = currentSession?.orchestrator
            updateWebPreviewTarget()
            Task { await refreshNotificationCount() }
        }
        .onChange(of: currentSession?.selectedAgentID) {
            updateWebPreviewTarget()
        }
        // The menu bar extra is a separate scene and can't reach the action
        // installed above, so it posts its request to the tracker and this
        // drains it through the same one implementation.
        .onChange(of: activeOrchestratorTracker.openItemRequest) {
            drainMenuBarRequests()
        }
        // A waiting row clicked in the menu bar, drained the same way.
        .onChange(of: activeOrchestratorTracker.openGateRequest) {
            drainMenuBarRequests()
        }
        .sheet(isPresented: resumePromptBinding) {
            ResumePromptSheet(
                executions: currentSession?.orchestrator.incompleteExecutions ?? [],
                report: currentSession?.orchestrator.lastResumeReport,
                onResume: { currentSession?.orchestrator.resumeWorkflow(executionID: $0) },
                onDismiss: { currentSession?.orchestrator.dismissWorkflow(executionID: $0) },
                onDismissAll: { currentSession?.orchestrator.dismissAllWorkflows() }
            )
        }
        .alert("Something Went Wrong", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Can't Open That Item", isPresented: Binding(
            get: { itemLinkRefusal != nil },
            set: { if !$0 { itemLinkRefusal = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(itemLinkRefusal ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentHired)) { notification in
            handleAgentHired(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentFired)) { notification in
            handleAgentFired(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentSummoned)) { notification in
            handleAgentSummoned(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .crossAgentMessageCompleted)) { notification in
            handleCrossAgentMessage(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .teamConfigFileChanged)) { notification in
            handleTeamConfigFileChanged(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSetupWizard)) { _ in
            showingSetupWizard = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openBannerDestination)) { notification in
            openBannerDestination(notification)
        }
        // A gate that opened while the operator was looking at Kiteloop was
        // dropped by the notification service's frontmost guard and never
        // re-raised. Leaving is when that silence starts to cost something, so
        // the gates still open are handed over here — read live, the same value
        // the footer and the drawer draw from.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            NotificationService.shared.notifyOpenGatesOnLeaving(waitingOnYou.rows)
        }
    }

    // MARK: - Project Tabs

    private var projectTabs: some View {
        HStack(spacing: 0) {
            ForEach(openProjects) { project in
                projectTab(for: project)
            }

            addProjectButton
        }
        .background { projectTabShortcuts }
        .confirmationDialog("Close Project?", isPresented: Binding(
            get: { pendingClose != nil },
            set: { if !$0 { pendingClose = nil } }
        ), titleVisibility: .visible) {
            Button("Close Project", role: .destructive) {
                if let projectID = pendingClose?.projectID { closeProject(projectID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(pendingClose?.message ?? "")
        }
    }

    /// The ✕ and the context menu's Close Project: asks first while the
    /// project's run is in flight, closes at once otherwise.
    private func requestCloseProject(_ project: KiteloopProject) {
        let path = project.rootURL.path(percentEncoded: false)
        let item = activeOrchestratorTracker.inFlightItems.first { $0.projectPath == path }
        guard let message = ProjectClosePrompt.message(
            isRunning: runningProjects.contains(project.id), item: item
        ) else {
            closeProject(project.id)
            return
        }
        pendingClose = (project.id, message)
    }

    /// Zero-size buttons that carry ⌘1…⌘9 and ⌘⇧[ / ⌘⇧]; each lands on
    /// `switchToProject(_:)`, the same path a click on a tab takes.
    private var projectTabShortcuts: some View {
        ZStack {
            ForEach(1...9, id: \.self) { number in
                Button("") { switchToProjectTab(atShortcut: number) }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: [.command])
            }
            Button("") { switchToNeighbourTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("") { switchToNeighbourTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func switchToProjectTab(atShortcut number: Int) {
        let ids = openProjects.map(\.id)
        switchToProject(withID: ProjectTabNavigation.project(atShortcut: number, in: ids))
    }

    private func switchToNeighbourTab(offset: Int) {
        let ids = openProjects.map(\.id)
        switchToProject(withID: ProjectTabNavigation.neighbour(of: activeProjectID, in: ids, offset: offset))
    }

    private func switchToProject(withID id: String?) {
        guard let project = openProjects.first(where: { $0.id == id }) else { return }
        switchToProject(project)
    }

    private func projectTab(for project: KiteloopProject) -> some View {
        let isActive = project.id == activeProjectID
        let indicator = ProjectTabIndicator.forProject(
            isRunning: runningProjects.contains(project.id),
            isStreaming: sessions[project.id]?.orchestrator.isStreaming ?? false,
            isUnread: unreadProjects.contains(project.id)
        )
        let isDropTargeted = dropTargetProjectID == project.id

        return projectTabLabel(for: project, indicator: indicator, isActive: isActive)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor.opacity(0.12) : .clear)
        )
        .overlay(alignment: .leading) {
            if isDropTargeted {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2)
                    .padding(.vertical, 2)
            }
        }
        .contentShape(Rectangle())
        // Settings for a thing, on the thing's name — the sheet reads
        // `currentSession`, so the switch comes first and doubles as the
        // expected "right-click acts on this tab" behavior.
        .contextMenu { projectTabMenu(for: project) }
        .onTapGesture {
            unreadProjects.remove(project.id)
            switchToProject(project)
        }
        // Closing the project from the ✕ or the context menu takes the tab out
        // from under the pointer, and no un-hover follows.
        .hoverCursor()
        .draggable(project.id) {
            projectTabDragPreview(for: project)
        }
        .dropDestination(for: String.self) { items, _ in
            dropProjectTab(items.first, before: project.id)
        } isTargeted: { targeted in
            setProjectTabDropTarget(project.id, targeted: targeted)
        }
    }

    @ViewBuilder
    private func projectTabMenu(for project: KiteloopProject) -> some View {
        Button("Project Settings…") {
            unreadProjects.remove(project.id)
            switchToProject(project)
            projectSettingsPage = .general; showingProjectSettings = true
        }
        Divider()
        MainWindow.projectFolderMenuItems(path: project.rootURL.path(percentEncoded: false))
        Divider()
        Button("Close Project") { requestCloseProject(project) }
    }

    /// Where a project lives, as its tab and Portfolio card show it on hover:
    /// the full folder path with the home folder shortened to `~`, so two
    /// projects whose folders share a name still read differently.
    static func projectFolderHoverText(
        forPath path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Show in Finder and Copy Path for a project folder — the tab's and the
    /// Portfolio card's context menus both offer them.
    @ViewBuilder
    static func projectFolderMenuItems(path: String) -> some View {
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        }
    }

    private func projectTabLabel(
        for project: KiteloopProject, indicator: ProjectTabIndicator, isActive: Bool
    ) -> some View {
        HStack(spacing: 6) {
            projectTabIndicatorIcon(indicator, isActive: isActive)

            Text(project.rootURL.lastPathComponent)
                .font(.system(.body, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
                .help(MainWindow.projectFolderHoverText(forPath: project.rootURL.path(percentEncoded: false)))

            Button {
                requestCloseProject(project)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .opacity(isActive ? 1 : 0)
            .help("Close project")
        }
    }

    @ViewBuilder
    private func projectTabIndicatorIcon(_ indicator: ProjectTabIndicator, isActive: Bool) -> some View {
        switch indicator {
        case .busy:
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 12, height: 12)
        case .unread:
            Image(systemName: "bell.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
        case .idle:
            Image(systemName: "folder.fill")
                .font(.caption)
                .foregroundStyle(isActive ? .primary : .secondary)
        }
    }

    private func projectTabDragPreview(for project: KiteloopProject) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.caption)
            Text(project.rootURL.lastPathComponent)
                .font(.body)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.18))
        )
    }

    private func dropProjectTab(_ droppedID: String?, before projectID: String) -> Bool {
        dropTargetProjectID = nil
        guard let droppedID, droppedID != projectID else { return false }
        reorderProject(droppedID, beforeProjectID: projectID)
        return true
    }

    private func setProjectTabDropTarget(_ projectID: String, targeted: Bool) {
        dropTargetProjectID = targeted ? projectID : (dropTargetProjectID == projectID ? nil : dropTargetProjectID)
    }

    /// Whether a home workspace has been set up at all — the same file the
    /// launch path tests, so the menu offers it exactly when it exists.
    private var homeWorkspaceExists: Bool {
        FileManager.default.fileExists(
            atPath: KiteloopProject.homeWorkspace.teamConfigURL.path(percentEncoded: false))
    }

    private var isHomeWorkspaceOpen: Bool {
        openProjects.contains { $0.id == KiteloopProject.homeWorkspace.id }
    }

    private var addProjectButton: some View {
        Menu {
            Button("Open Project…") {
                openProject()
            }
            .keyboardShortcut("o", modifiers: [.command])

            // `~/.kiteloop/home` is a hidden directory, so once it stopped being
            // pinned open there was no way back to it through the file picker.
            if homeWorkspaceExists, !isHomeWorkspaceOpen {
                Button("Home Workspace") {
                    Task { await openProjectAt(KiteloopProject.homeWorkspace.rootURL) }
                }
            }

            Button("Try a Sample Project") {
                Task { await createAndOpenSampleProject() }
            }

            if !recentProjects.isEmpty {
                Divider()
                ForEach(recentProjects.prefix(8)) { recent in
                    Button(recent.name) {
                        openRecentProject(recent)
                    }
                    .accessibilityIdentifier("start-recent-project")
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Open project")
        .dropDestination(for: String.self) { items, _ in
            guard let droppedID = items.first else { return false }
            reorderProject(droppedID, beforeProjectID: nil)
            return true
        }
    }

    private var activeProjectName: String {
        guard let id = activeProjectID,
              let project = openProjects.first(where: { $0.id == id }) else {
            return "Kiteloop"
        }
        return project.rootURL.lastPathComponent
    }

    /// The tab array from the store, and the registry told its order — the
    /// control API lists projects the way these tabs sit.
    private func reloadOpenProjects() async {
        openProjects = await projectStore.openProjects()
        controlRegistry.projectOrder = openProjects.map(\.id)
    }

    private func reorderProject(_ projectID: String, beforeProjectID targetID: String?) {
        guard let fromIndex = openProjects.firstIndex(where: { $0.id == projectID }) else { return }
        let project = openProjects.remove(at: fromIndex)
        if let targetID, let toIndex = openProjects.firstIndex(where: { $0.id == targetID }) {
            openProjects.insert(project, at: toIndex)
        } else {
            openProjects.append(project)
        }
        controlRegistry.projectOrder = openProjects.map(\.id)
        Task {
            await projectStore.reorder(projectID, before: targetID)
            saveAllBookmarks()
        }
    }

    private func closeProject(_ projectID: String) {
        sessions[projectID]?.shutdown()
        sessions.removeValue(forKey: projectID)

        Task {
            // Awaited, and first: unregistering closes the run records of
            // whatever this project had finished before it drops the entry, and
            // after that nothing can reach those runs again.
            await controlRegistry.unregister(projectID: projectID)
            await projectStore.close(projectID)
            await reloadOpenProjects()
            if let active = await projectStore.activeProject() {
                activeProjectID = active.id
            } else {
                activeProjectID = nil
            }
            saveAllBookmarks()
        }
    }

    // MARK: - Sidebar Support

    /// Shows the interrupted-workflows prompt when the active project's orchestrator
    /// found incomplete executions. Closing the sheet without acting suppresses the
    /// prompt for that project until the app relaunches; checkpoints stay on disk.
    private var resumePromptBinding: Binding<Bool> {
        Binding(
            get: {
                guard let projID = activeProjectID,
                      !resumePromptSuppressed.contains(projID),
                      let session = sessions[projID] else { return false }
                return !session.orchestrator.incompleteExecutions.isEmpty
            },
            set: { shown in
                if !shown, let projID = activeProjectID {
                    resumePromptSuppressed.insert(projID)
                }
            }
        )
    }

    private var selectedBinding: Binding<String?> {
        Binding<String?>(
            get: { currentSession?.selectedAgentID },
            set: { newID in
                // Slide the detail pane in the direction of travel through the
                // sidebar order (down → in from the right, up → from the left),
                // so Chat ↔ Backlog ↔ Autopilot feel like one paged workspace.
                detailSlideEdge = detailOrderRank(newID) >= detailOrderRank(currentSession?.selectedAgentID) ? .trailing : .leading
                currentSession?.selectedAgentID = newID
            }
        )
    }

    /// Vertical rank of a detail screen, matching sidebar order — drives slide direction.
    private func detailOrderRank(_ id: String?) -> Int {
        switch id {
        case backlogSidebarID: return 0
        case memorySidebarID: return 1
        case autopilotSidebarID: return 2
        case portfolioSidebarID: return 3
        default:
            if let id, let idx = currentSession?.orchestrator.agents.firstIndex(where: { $0.id == id }) {
                return 10 + idx
            }
            return 100
        }
    }

    private var detailSelectionKey: String { currentSession?.selectedAgentID ?? "__none__" }

    /// Human-readable name for a detail screen id (for the split pane's header).
    private func detailScreenName(for id: String) -> String {
        switch id {
        case backlogSidebarID: return "Backlog"
        case memorySidebarID: return "Memory"
        case autopilotSidebarID: return "Autopilot"
        case portfolioSidebarID: return "Portfolio"
        default: return currentSession?.orchestrator.agents.first { $0.id == id }?.name ?? "Chat"
        }
    }

    private var detailSlideTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: detailSlideEdge),
            removal: .move(edge: detailSlideEdge == .trailing ? .leading : .trailing)
        )
    }

    /// Opens `drawer` in place of whichever drawer is open, or closes it when it
    /// is the open one.
    private func toggleDrawer(_ drawer: SidebarDrawer) {
        withAnimation(.easeInOut(duration: 0.2)) {
            openDrawer = SidebarDrawer.afterToggling(drawer, from: openDrawer)
        }
    }

    /// The left navigator column (team, backlog, sessions).
    private var sidebarView: some View {
        KiteloopSidebar(
            agents: currentSession?.orchestrator.agents ?? [],
            width: sidebarWidth,
            selectedID: selectedBinding,
            pendingMemoryCount: currentSession?.memoryViewModel.pendingProposals.count ?? 0,
            claudeVersion: claudeVersion,
            onNewAgent: { showingNewAgent = true },
            onQuickAdd: { quickAddAgent($0) },
            onTeamSettings: { projectSettingsPage = .general; showingProjectSettings = true },
            onOpenCoordinator: {
                toggleDrawer(.coordinator)
            },
            isCoordinatorOpen: openDrawer == .coordinator,
            coordinatorBudget: coordinatorBudget,
            dailyBudget: dailyBudget,
            setDailyBudgetUSD: { globalConfigStore.setDailyBudgetUSD($0) },
            coordinatorStall: coordinatorStall,
            coordinatorModeLabel: coordinatorModeLabel,
            coordinatorNextLook: coordinatorNextLook,
            coordinatorRollup: coordinatorRollup,
            coordinatorHold: coordinatorHold,
            onClearCoordinatorHold: { runScheduler.resetBreaker() },
            fleetStatus: fleetQuiesce.status,
            fleetNextLook: fleetNextLook,
            onQuiesceFleet: { fleetQuiesce.quiesce() },
            onResumeFleet: { fleetQuiesce.resume() },
            onOpenFleet: {
                toggleDrawer(.fleet)
            },
            isFleetOpen: openDrawer == .fleet,
            waitingOnYou: waitingOnYou,
            onOpenWaiting: {
                toggleDrawer(.waiting)
            },
            isWaitingOpen: openDrawer == .waiting,
            onPinToSplit: { id in
                withAnimation(.easeInOut(duration: 0.2)) { pinnedDetailID = id }
            },
            onStopAgent: { currentSession?.stopAgent($0) },
            onStartAgent: { currentSession?.startAgent($0) },
            onRemoveAgent: { currentSession?.removeAgent($0) },
            onEditAgent: { editingAgentID = $0 },
            onRestartAgent: { currentSession?.restartAgent($0) },
            hasAgentSession: { currentSession?.orchestrator.hasSession(for: $0) ?? false },
            sessionStore: currentSession?.sessionStore,
            onSwitchSession: { session in
                guard let vm = currentSession?.chatViewModels[session.agentID] else { return }
                Task { await vm.switchToSession(session) }
            },
            openSessionID: currentSession?.selectedAgentID.flatMap { currentSession?.chatViewModels[$0]?.currentSession?.id },
            onNewSession: {
                Task { await currentSession?.startNewChatForSelectedAgent() }
            },
            onDeleteSession: { session in
                guard let vm = currentSession?.chatViewModels[session.agentID] else { return }
                Task { await vm.deleteSession(session) }
            },
            onRenameSession: { session, name in
                currentSession?.chatViewModels[session.agentID]?.renameSession(session, to: name)
            },
            onExportSession: { exportChat($0) },
            repoStatusStore: repoStatusStore,
            repoCloneService: repoCloneService,
            githubOrg: globalConfigStore.config.githubOrg ?? "",
            unattendedAgentIDs: currentSession?.orchestrator.unattendedAgentIDs ?? [],
            stoppedAgentIDs: currentSession?.orchestrator.stoppedAgentIDs ?? []
        )
    }

    /// Export Chat…: asks where to save the chat as Markdown and writes it; a
    /// write that fails is shown, not swallowed.
    private func exportChat(_ session: ChatSession) {
        guard let markdown = currentSession?.chatViewModels[session.agentID]?.exportMarkdown(for: session),
              let url = chooseChatExportURL(for: session) else { return }
        errorMessage = Self.saveChatExport(markdown, to: url) ?? errorMessage
    }

    /// The save panel Export Chat… asks with; nil when it is cancelled.
    private func chooseChatExportURL(for session: ChatSession) -> URL? {
        PermissionAuditLogger.shared.log(.filePanel, purpose: "export chat to disk")
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = ChatMarkdownExporter.fileName(for: session)
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Writes an exported chat to `url`. Nil when it was saved, otherwise the
    /// message the window shows, naming the file and why it could not be written.
    static func saveChatExport(_ markdown: String, to url: URL) -> String? {
        do {
            try Data(markdown.utf8).write(to: url)
            return nil
        } catch {
            return "\(url.lastPathComponent) could not be saved: \(error.localizedDescription)"
        }
    }

    /// Trailing toolbar cluster: notifications and the Xcode-style
    /// navigator/console/inspector show-hide controls.
    private var toolbarActions: some View {
        HStack(spacing: 8) {
            notificationsButton
            panelControls
        }
    }

    private var notificationsButton: some View {
        Button {
            showingNotifications.toggle()
        } label: {
            Image(systemName: "bell")
                .overlay(alignment: .topTrailing) {
                    NotificationBadge(count: actionableNotificationCount)
                        .offset(x: 8, y: -6)
                }
        }
        .help("Notifications")
        .popover(isPresented: $showingNotifications) {
            NotificationListView(store: combinedNotificationStore, onChange: {
                Task { await refreshNotificationCount() }
            }, agentName: notificationAgentName)
            .frame(width: 380, height: 420)
        }
        .onChange(of: showingNotifications) {
            Task { await refreshNotificationCount() }
        }
    }

    /// Names a notice's agent from every open project's team, read when the row
    /// is drawn so an agent hired since the notice was filed is still named.
    private func notificationAgentName(_ agentID: String, projectPath: String?) -> String {
        let rosters = sessions.values.map { session in
            NotificationAgentRoster(
                projectPath: session.project.rootURL.path(percentEncoded: false),
                names: Dictionary(session.orchestrator.agents.map { ($0.id, $0.name) },
                                  uniquingKeysWith: { first, _ in first }))
        }
        return NotificationListContents.agentName(agentID, projectPath: projectPath, rosters: rosters)
    }

    /// Segmented navigator / console / inspector toggles (Xcode's ⌘0, ⌘⇧Y, ⌘⌥0).
    private var panelControls: some View {
        ControlGroup {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showSidebar.toggle() }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help("Toggle Navigator (⌘0)")
            .keyboardShortcut("0", modifiers: [.command])
            .accessibilityIdentifier("sidebar-toggle")
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showBottomDrawer.toggle() }
            } label: {
                Image(systemName: "terminal")
            }
            .help("Toggle Console (⌘⇧Y)")
            .keyboardShortcut("y", modifiers: [.command, .shift])
            .accessibilityIdentifier("console-toggle")
            Button {
                // Reopening on Preview puts the web view back in the drawer;
                // only one host can hold it, so close the popped-out window.
                if !showInspector, inspectorTab == .preview {
                    webPreviewWindowManager.closeDetachedWindow()
                }
                withAnimation(.easeInOut(duration: 0.2)) { showInspector.toggle() }
            } label: {
                Image(systemName: "sidebar.right")
            }
            .help("Toggle Inspector — Preview · Insights (⌘⌥0)")
            .keyboardShortcut("0", modifiers: [.command, .option])
            .accessibilityIdentifier("inspector-toggle")
        }
    }

    /// The editor column: the detail area, plus a resizable bottom console
    /// drawer (Xcode debug-area style) when open.
    @ViewBuilder
    private var centerColumn: some View {
        if showBottomDrawer, let session = currentSession {
            VSplitView {
                detailArea
                    .frame(minHeight: 220)
                bottomDrawer(session: session)
                    .frame(minHeight: 120, idealHeight: 220)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            detailArea
        }
    }

    /// Runtime console: a live Activity feed (workflow/autopilot/agent events)
    /// and per-turn Traces (cost/tokens/duration), behind a tab switch.
    private func bottomDrawer(session: ProjectSession) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: KiteloopTokens.Spacing.sm) {
                Image(systemName: "terminal").font(.caption2).foregroundStyle(.secondary)
                Picker("", selection: $consoleTab) {
                    ForEach(ConsoleTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("console-tab-picker")
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showBottomDrawer = false }
                } label: {
                    Image(systemName: "xmark").font(.caption2)
                }
                .buttonStyle(.plain)
                .help("Close console (⌘⇧Y)")
            }
            .padding(.horizontal, KiteloopTokens.Spacing.md)
            .padding(.vertical, KiteloopTokens.Spacing.xs)
            .background(.ultraThinMaterial)
            Divider()
            switch consoleTab {
            case .activity:
                ActivityFeedView(viewModel: session.activityFeed)
            case .traces:
                if let vm = session.traceViewModel {
                    TraceListView(viewModel: vm)
                } else {
                    PanelEmptyState(
                        icon: "chart.bar.xaxis",
                        title: "No traces yet",
                        message: "Cost, tokens, and duration per turn appear here once an agent runs in this project."
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The center work area: a single detail pane, or a resizable top/bottom
    /// split when a screen is pinned (top = pinned, bottom = sidebar selection).
    @ViewBuilder
    private var detailArea: some View {
        if let pinnedID = pinnedDetailID, let session = currentSession {
            VSplitView {
                splitPane(title: detailScreenName(for: pinnedID), onClose: { pinnedDetailID = nil }) {
                    detailView(for: pinnedID, session: session)
                }
                .frame(minHeight: 120)
                singleDetail
                    .frame(minHeight: 120)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            singleDetail
        }
    }

    private var singleDetail: some View {
        ZStack {
            detailContent
                .id(detailSelectionKey)
                .transition(detailSlideTransition)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(.easeInOut(duration: 0.22), value: detailSelectionKey)
    }

    private func splitPane<Content: View>(
        title: String,
        onClose: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: KiteloopTokens.Spacing.sm) {
                Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                Text(title).font(.system(.caption, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.caption2)
                }
                .buttonStyle(.plain)
                .help("Close split")
            }
            .padding(.horizontal, KiteloopTokens.Spacing.md)
            .padding(.vertical, KiteloopTokens.Spacing.xs)
            .background(.ultraThinMaterial)
            Divider()
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var detailContent: some View {
        if let session = currentSession, let agentID = session.selectedAgentID {
            detailView(for: agentID, session: session)
        } else {
            ContentUnavailableView("Select an Agent", systemImage: "person.crop.circle")
        }
    }

    /// Renders the detail screen for a given sidebar/agent id — reused for both
    /// the single detail pane and each half of a split.
    @ViewBuilder
    private func detailView(for agentID: String, session: ProjectSession) -> some View {
        let projID = session.project.id
        Group {
            if agentID == backlogSidebarID {
                let editors = backlogEditors(for: session)
                EpicBacklogView(
                    viewModel: session.backlogViewModel,
                    projectName: session.project.rootURL.lastPathComponent,
                    projectPath: session.project.rootURL.path(percentEncoded: false),
                    aiEditor: editors.ai,
                    scopingEngine: editors.scope,
                    metricStore: taskMetricStore,
                    metricIndex: metricIndex,
                    // The same cached instance the Autopilot panel drives, so an
                    // item's history offers the run that panel would start.
                    autopilot: backlogAutopilot(for: session),
                    // This surface presents the item page, so the app-level
                    // open-item action routes here rather than opening a second
                    // page of its own. See `openItem(_:in:)`.
                    openRequest: pendingItemPage(for: projID),
                    onOpenFailed: { itemLinkRefusal = $0 },
                    onShowInsights: {
                        inspectorTab = .insights
                        withAnimation(.easeInOut(duration: 0.2)) { showInspector = true }
                    }
                )
                .id("\(projID)-backlog")
            } else if agentID == memorySidebarID {
                MemoryBrowserView(
                    viewModel: session.memoryViewModel,
                    agents: session.orchestrator.agents
                )
                .id("\(projID)-memory")
            } else if agentID == autopilotSidebarID {
                AutopilotView(
                    autopilot: backlogAutopilot(for: session),
                    // Team only: an aside is ephemeral, so offering it as a
                    // worker or reviewer would assign a run role to something
                    // that won't exist after the next restart.
                    agents: session.orchestrator.teamAgents,
                    chatViewModels: session.chatViewModels,
                    backlogViewModel: session.backlogViewModel,
                    // The same two stores the Backlog tab hands the item page,
                    // so an item opened from a history row here shows exactly
                    // what it shows opened from its backlog line.
                    metricStore: taskMetricStore,
                    metricIndex: metricIndex,
                    // The autonomy ladder is assessed from the portfolio loops,
                    // and it is drawn here because this is the tab somebody sets
                    // a project up in.
                    refill: queueRefill,
                    scheduler: runScheduler,
                    globalConfigStore: globalConfigStore,
                    controlRegistry: controlRegistry
                )
                .id("\(projID)-autopilot")
            } else if agentID == portfolioSidebarID {
                PortfolioView(
                    viewModel: portfolioViewModel,
                    // Only ever a starting point for a portfolio file that does
                    // not exist yet — the file, once written, is what is read.
                    openProjectPaths: openProjects.map(\.id)
                )
                // Not keyed on the project: this surface is the same list in
                // every tab, and re-identifying it per project would tear down
                // its watcher and reload on every tab switch.
                .id("portfolio")
            } else if let vm = session.chatViewModels[agentID] {
                ChatView(
                    viewModel: vm,
                    statusLine: statusLine,
                    otherAgents: session.orchestrator.agents.filter { $0.id != agentID },
                    onForwardToAgent: { text, targetID in
                        session.chatViewModels[targetID]?.receiveHandoff(text, from: agentID)
                        session.selectedAgentID = targetID
                    }
                )
                .id("\(projID)-\(agentID)")
            } else {
                ContentUnavailableView("Select an Agent", systemImage: "person.crop.circle")
            }
        }
    }

    // MARK: - Start View

    private var startView: some View {
        VStack(spacing: 16) {
            Image(systemName: "building.2")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Kiteloop")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Select a project directory to start")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Permission Mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { selectedPermissionMode ?? Agent.defaultPermissionMode },
                    set: { selectedPermissionMode = $0 }
                )) {
                    Text("Auto (Claude Code decides)").tag("auto")
                    Text("Accept Edits").tag("acceptEdits")
                    Text("Plan Mode (read-only)").tag("plan")
                    Text("Default (refuse what would ask)").tag("default")
                    Text("Bypass All Permissions").tag("bypassPermissions")
                }
                .pickerStyle(.menu)
                .frame(width: 250)
            }

            if UITestingSupport.isUITesting {
                Button("Quick Start") {
                    Task { await openProjectAt(UITestingSupport.quickStartDirectory()) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("quick-start-button")
            } else {
                Button("Open Project...") {
                    openProject()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("open-project-button")
            }

            if !recentProjects.isEmpty {
                Divider()
                    .frame(width: 320)

                PortfolioSection(
                    recentProjects: recentProjects,
                    onOpenRecent: { openRecentProject($0) },
                    vaultURL: globalConfigStore.vaultURL,
                    globalConfigStore: globalConfigStore,
                    coordinator: queueRefill,
                    metricStore: taskMetricStore,
                    groomingLedger: .shared,
                    runScheduler: runScheduler,
                    registry: controlRegistry
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Project Management

    private func openProject() {
        PermissionAuditLogger.shared.log(.filePanel, purpose: "open project directory")
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a project directory"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveBookmark(for: url)
        Task {
            await openProjectAt(url)
            saveAllBookmarks()
        }
    }

    private func openRecentProject(_ recent: RecentProject) {
        let url = URL(fileURLWithPath: recent.path)
        Task {
            await openProjectAt(url)
            saveAllBookmarks()
        }
    }

    /// Installs the bundled demo project on first use — a no-op on every later
    /// click, since `SampleProjectService.install` leaves an existing copy
    /// alone — and opens it the same way a project picked from the file panel
    /// would be.
    private func createAndOpenSampleProject() async {
        do {
            let url = try SampleProjectService.install()
            saveBookmark(for: url)
            await openProjectAt(url)
            saveAllBookmarks()
        } catch {
            mainWindowLog.error("Failed to install sample project: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Couldn't set up the sample project: \(error.localizedDescription)"
        }
    }

    /// Opens a project, or re-reads one that is already open.
    ///
    /// Re-opening is not a no-op: it re-reads the backlog from disk. Opening a
    /// project is the only lever a headless driver has on a running app, and an
    /// "opened" that changed nothing is how a backlog groomed outside the app
    /// stays invisible until someone restarts it.
    @discardableResult
    private func openProjectAt(_ url: URL) async -> ControlSessionRegistry.OpenOutcome {
        do {
            let project = try await projectStore.open(url)
            let outcome = await attachSession(for: project, at: url)
            await reconcileAfterOpen(project, outcome: outcome)

            activeProjectID = project.id
            await reloadOpenProjects()
            recentProjects = await projectStore.recentProjects()

            statusLine.updateSessionData(cwd: url.path)
            statusLine.start()
            return outcome
        } catch {
            mainWindowLog.error("Failed to open project at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            errorMessage = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
            return .failed
        }
    }

    /// Bootstraps and registers a session for a project not yet open, or
    /// refreshes the backlog of the one that is.
    private func attachSession(
        for project: KiteloopProject, at url: URL
    ) async -> ControlSessionRegistry.OpenOutcome {
        switch Self.sessionAttachment(for: project.id, open: sessions, registry: controlRegistry) {
        case .refresh(let session):
            // Re-resolves the backlog path and re-arms its watcher as well as
            // re-parsing, so this also recovers a session whose watcher died.
            session.backlogViewModel.refresh()
            return .reloaded
        case .adopt(let entry):
            sessions[project.id] = entry.session
            autopilotCache.instances[project.id] = entry.autopilot
            return .reloaded
        case .bootstrap:
            return await bootstrapSession(for: project, at: url)
        }
    }

    /// What opening a project does with the sessions already alive.
    enum SessionAttachment {
        /// Already open in this window: its backlog is re-read.
        case refresh(ProjectSession)
        /// Not open here, but the app still holds its live session and
        /// autopilot — a window opened after the last one closed starts with
        /// empty state. Taken over instead of bootstrapping a second copy that
        /// would overwrite the registry entry and leave the first running unseen.
        case adopt(ControlSessionRegistry.Entry)
        /// Nothing alive for it anywhere: a new session is booted.
        case bootstrap
    }

    /// Which of the three `attachSession` does. Adoption goes by exactly this
    /// project id — a different project that merely shares its folder name is
    /// not taken over.
    static func sessionAttachment(
        for projectID: String, open: [String: ProjectSession], registry: ControlSessionRegistry
    ) -> SessionAttachment {
        if let session = open[projectID] { return .refresh(session) }
        if let entry = registry.registeredEntry(projectID: projectID) { return .adopt(entry) }
        return .bootstrap
    }

    /// Boots and registers a session for a project nothing holds yet.
    private func bootstrapSession(
        for project: KiteloopProject, at url: URL
    ) async -> ControlSessionRegistry.OpenOutcome {
        if repoStatusStore == nil, packageResolver != nil {
            repoStatusStore = RepoStatusStore(cloneService: repoCloneService)
        }
        let session = await ProjectSession.bootstrap(
            project: project,
            url: url,
            context: sessionContext,
            selectedPermissionMode: selectedPermissionMode,
            repoStatusStore: repoStatusStore,
            onError: { errorMessage = $0 }
        )
        sessions[project.id] = session
        // Expose the session + its autopilot to the local control API.
        controlRegistry.register(session: session, autopilot: backlogAutopilot(for: session))
        return .opened
    }

    /// A project claiming to be busy with no run behind it is not busy.
    /// Autopilot instances are cached per project, so a status left
    /// non-idle by a run that ended outlives a close and reopen — and used
    /// to refuse every item afterwards. This is where that is put right,
    /// for a project opened by hand and for each one restored at launch,
    /// which comes through here too.
    private func reconcileAfterOpen(
        _ project: KiteloopProject, outcome: ControlSessionRegistry.OpenOutcome
    ) async {
        let returned = await Self.reconcileAfterOpen(
            outcome: outcome,
            autopilot: controlRegistry.entry(forProject: project.id)?.autopilot,
            backlog: sessions[project.id]?.backlogViewModel
        )
        if !returned.isEmpty {
            mainWindowLog.info("Returned \(returned.count, privacy: .public) stranded item(s) to ready in \(project.rootURL.lastPathComponent, privacy: .public): \(returned.joined(separator: ", "), privacy: .public)")
        }
    }

    /// The reconciliation itself: the autopilot's status first, then the
    /// backlog's items. Returns the ids of the items put back to `ready`.
    static func reconcileAfterOpen(
        outcome: ControlSessionRegistry.OpenOutcome, autopilot: BacklogAutopilot?, backlog: BacklogViewModel?
    ) async -> [String] {
        let reason = outcome == .opened ? "project opened" : "project reopened"
        var inFlightItemID: String?
        if let autopilot {
            await autopilot.reconcileStatus(reason: reason)
            inFlightItemID = await autopilot.inFlightRun()?.itemID
        }
        // The same disagreement on the item side: run records don't survive a
        // restart, so an item still marked `active` here was interrupted, and
        // nothing but a hand edit would ever free it. Asked after the status
        // reconciliation above so the two read the same run — an item a run is
        // genuinely executing is the one thing left alone.
        guard let backlog else { return [] }
        return await backlog.reconcileActiveItems(reason: reason, inFlightItemID: inFlightItemID)
    }

    /// How often the tabs re-ask which projects are running. Slow on purpose:
    /// nothing acts on this but a spinner.
    /// The main window's scene id, which the menu bar opens it by.
    static let windowID = "main"

    private static let runIndicatorRefreshInterval: Duration = .seconds(2)

    /// Re-reads which open projects have a run in flight.
    ///
    /// The answer is `BacklogAutopilot.inFlightRun()` — the check the run-busy
    /// guard makes and the one `GET /v1/projects` reports — so a tab showing a
    /// spinner is exactly a project that would refuse the next item. Deliberately
    /// not `Orchestrator.isStreaming` (which goes false for the length of every
    /// tool call) and not the autopilot's `status` (which can be left claiming a
    /// run that never began).
    private func refreshRunningProjects() async {
        var running: Set<String> = []
        var inFlight: [ActiveOrchestratorTracker.InFlightItem] = []
        for entry in controlRegistry.openProjects {
            guard let run = await entry.autopilot.inFlightRun() else { continue }
            running.insert(entry.session.project.id)
            // The menu bar names what *every* open project is working on, not
            // the active one alone — with the window behind everything else it
            // is the only place a run in another project is visible at all.
            if let itemID = run.itemID {
                inFlight.append(ActiveOrchestratorTracker.InFlightItem(
                    id: itemID,
                    title: run.itemTitle ?? "",
                    projectPath: entry.session.project.rootURL.path(percentEncoded: false)))
            }
        }
        // A project whose run state can't be read isn't in `running` — unknown is
        // not running.
        if running != runningProjects { runningProjects = running }
        if activeOrchestratorTracker.inFlightItems != inFlight {
            activeOrchestratorTracker.inFlightItems = inFlight
        }
    }

    @State private var previouslyStreaming: Set<String> = []

    private var orchestratorStreamingSnapshot: [String: Bool] {
        sessions.mapValues { $0.orchestrator.isStreaming }
    }

    private func checkForUnreadCompletions() {
        var nowStreaming = Set<String>()
        for (id, session) in sessions where session.orchestrator.isStreaming {
            nowStreaming.insert(id)
        }
        let justFinished = previouslyStreaming.subtracting(nowStreaming)
        for id in justFinished where id != activeProjectID {
            unreadProjects.insert(id)
            if let name = openProjects.first(where: { $0.id == id })?.rootURL.lastPathComponent {
                // A run autopilot is driving finishes a turn every few minutes
                // and each one landed its own row — 648 of them in one project
                // by 2026-08-15. Those are readings of one thing ("this project
                // is working, and has just stopped for a moment"), so they roll
                // up: the newest resolves the one before it. A completion nobody
                // is driving — a person asked an agent something — carries no
                // key and stacks exactly as it always has.
                sessions[id]?.orchestrator.notify(
                    agentID: "",
                    type: .complete,
                    title: "Agents finished in \(name)",
                    body: "A background project's agents completed their work.",
                    rollUpKey: runningProjects.contains(id)
                        ? NotificationItem.runFinishedRollUpKey(projectID: id) : nil
                )
            }
        }
        previouslyStreaming = nowStreaming
        Task { await refreshNotificationCount() }
    }

    /// View over the active project's notifications, powering the toolbar bell.
    private var combinedNotificationStore: CompositeNotificationStore {
        var stores: [NotificationStoring] = []
        if let projectStore = currentSession?.orchestrator.notificationStore {
            stores.append(projectStore)
        }
        return CompositeNotificationStore(stores: stores)
    }

    /// The badge tracks only what needs a human. Completions and events are
    /// still recorded and still listed — they just don't ring the bell.
    ///
    /// The number itself comes off `pendingNotices`, so opening the popover and
    /// switching projects re-read the same map the tick keeps rather than
    /// computing a second answer beside it.
    private func refreshNotificationCount() async {
        await refreshWaitingNotices()
    }

    // MARK: - Opening an item from anywhere

    /// Every project open in this window, reduced to what resolution needs.
    /// A project whose backlog hasn't been read yet carries no id set, which is
    /// what stops a still-loading backlog from declaring its items missing.
    private var itemLinkProjects: [ItemLinkResolver.OpenProject] {
        openProjects.map { project in
            ItemLinkResolver.OpenProject(
                id: project.id,
                path: project.rootURL.path(percentEncoded: false),
                itemIDs: sessions[project.id]?.backlogViewModel.backlogFile
                    .map { Set($0.sections.flatMap(\.items).map(\.id)) })
        }
    }

    /// The one implementation behind the app-level open-item action: switch to
    /// the item's project tab when it isn't the active one, land on the backlog
    /// surface, and leave the request for that surface to pick up.
    ///
    /// The page itself is presented by `EpicBacklogView` rather than here, so
    /// that a page opened from a mention and one opened from the item's own
    /// backlog row are the same page over the same list — and Back lands on the
    /// backlog either way.
    private func openItem(_ itemID: String, in project: ItemLinkProject) {
        let destination = ItemLinkResolver.resolve(
            itemID: itemID, in: project,
            openProjects: itemLinkProjects,
            closedProjects: recentProjects.map { .init(path: $0.path) })
        switch destination {
        case .refused(let reason):
            itemLinkRefusal = reason
        case .open(let projectID, let resolvedID):
            // A mention can be clicked in a popover sitting over the window —
            // the notification inbox — and that popover is then in front of the
            // page it just asked for.
            showingNotifications = false
            if activeProjectID != projectID,
               let target = openProjects.first(where: { $0.id == projectID }) {
                switchToProject(target)
            }
            land(itemID: resolvedID, inProject: projectID)
        case .openProject(let path, let resolvedID):
            showingNotifications = false
            let url = URL(fileURLWithPath: path)
            isLoadingProject = true
            Task {
                let outcome = await openProjectAt(url)
                isLoadingProject = false
                let projectID = KiteloopProject(rootURL: url).id
                guard outcome != .failed, sessions[projectID] != nil else {
                    itemLinkRefusal = "\(resolvedID) is in \(url.lastPathComponent), "
                        + "which couldn't be opened, so there is no backlog to show it on."
                    return
                }
                land(itemID: resolvedID, inProject: projectID)
            }
        }
    }

    /// Lands a resolved request on the project's backlog surface, which is what
    /// presents the page — see `EpicBacklogView.openRequest`.
    private func land(itemID: String, inProject projectID: String) {
        sessions[projectID]?.selectedAgentID = backlogSidebarID
        pendingItemPages[projectID] = itemID
    }

    /// Routes whatever the menu bar has posted to the tracker, taking each
    /// request so it is handled once — the one path both the window's restore
    /// and the `onChange` handlers call.
    private func drainMenuBarRequests() {
        if let request = activeOrchestratorTracker.takeOpenItemRequest() {
            // Clicked from the menu bar, the window is very likely behind
            // everything else — landing a page on a window nobody can see is the
            // same as doing nothing.
            NSApplication.shared.activate(ignoringOtherApps: true)
            openItem(request.itemID, in: request.project)
        }
        // Sent through the drawer's own `openGate` — one destination per gate kind.
        if let request = activeOrchestratorTracker.takeOpenGateRequest() {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openGate(request.row)
        }
    }

    // MARK: - Opening a gate from the waiting list

    /// Lands on the surface where one waiting row is actually cleared: the
    /// project's Autopilot panel for an item at the approval gate, the agent's
    /// own chat for an unanswered question.
    ///
    /// Not the item's page, which is where an `ItemLink` goes. A page states
    /// what an item is; Approve and Reject live on the Autopilot panel, and
    /// sending someone to read about the decision they came to make is the kind
    /// of near-miss that makes a list like this feel like a directory rather
    /// than a way to get through the work.
    ///
    /// The drawer is left open. It is a pane rather than a popover, and clearing
    /// three gates in a row should not mean reopening it twice; each row leaves
    /// the list as its gate closes.
    private func openGate(_ row: WaitingOnYou.Row) {
        // The rows were built from `openProjects` in this same pass, so the only
        // way to miss here is a project closed between the draw and the click —
        // in which case its rows are gone on the next redraw anyway.
        guard let target = openProjects.first(where: { $0.id == row.projectID }) else { return }
        open(row.gate, in: target)
    }

    /// Switches to `project` and opens the place `gate` is dealt with — the
    /// one destination the drawer row and a clicked banner share.
    private func open(_ gate: WaitingOnYou.Row.Gate, in project: KiteloopProject) {
        if activeProjectID != project.id {
            switchToProject(project)
        }
        switch gate {
        case .approval:
            sessions[project.id]?.selectedAgentID = autopilotSidebarID
        case .question(let agentID):
            sessions[project.id]?.selectedAgentID = agentID
        case .stale(let itemID):
            // Not the Autopilot panel and not a chat: a flag is nothing to
            // approve or answer, only to look at — so this goes straight to
            // the item's own page, the same as an `ItemLink` would.
            pendingItemPages[project.id] = itemID
        }
    }

    /// A clicked gate or finished-turn banner. The project is matched among
    /// the open tabs by id or by root path; one closed since the banner was
    /// posted — or never open — leaves the window where it is, since the click
    /// already raised it.
    private func openBannerDestination(_ notification: Notification) {
        guard let landing = Self.bannerLanding(for: notification.object, among: openProjects) else { return }
        open(landing.gate, in: landing.project)
    }

    /// Where a clicked banner lands: the open project it names, and the gate
    /// whose surface opens there. A finished turn lands where a question does —
    /// that agent's chat — since both only select the agent. Nil for a banner
    /// with no destination, or for a project not open.
    static func bannerLanding(
        for object: Any?, among openProjects: [KiteloopProject]
    ) -> (project: KiteloopProject, gate: WaitingOnYou.Row.Gate)? {
        guard let destination = object as? BannerDestination,
              let target = openProjects.first(where: { project in
                  project.id == destination.project
                      || KiteloopProject.isSamePath(project.rootURL.path(percentEncoded: false), destination.project)
              }) else { return nil }
        return (target, destination.gate ?? .question(agentID: destination.id))
    }

    /// Re-reads each open project's inbox.
    ///
    /// Only the notices — what a gate said and when it said it. Whether a row
    /// exists at all is read live in `waitingOnYou`, off the backlog and the
    /// chats, so a gate cleared between two of these ticks leaves the list at
    /// once rather than at the next one.
    ///
    /// The bell's badge rides this read too: it is the same inbox, already
    /// crossed, and a notice arriving with nothing else changing moves the
    /// number here rather than waiting for somebody to open the popover.
    private func refreshWaitingNotices() async {
        var notices: [String: [NotificationItem]] = [:]
        for project in openProjects {
            guard let store = sessions[project.id]?.orchestrator.notificationStore else { continue }
            notices[project.id] = await store.pending()
        }
        pendingNotices = notices
        actionableNotificationCount = NotificationBadgeCount.forActiveProject(
            pending: notices, activeProjectID: activeProjectID)
        // The menu bar extra is a separate scene and cannot read `body`'s
        // `waitingOnYou`, so it is handed the same value here — after
        // `pendingNotices` is assigned, so this reads the map this pass wrote.
        // Assigned only on a change, the way `inFlightItems` is.
        let waiting = waitingOnYou
        if activeOrchestratorTracker.waiting != waiting {
            activeOrchestratorTracker.waiting = waiting
        }
    }

    /// The open-item request for one project's backlog surface, which clears it
    /// once the page is up.
    private func pendingItemPage(for projectID: String) -> Binding<String?> {
        Binding(get: { pendingItemPages[projectID] },
                set: { pendingItemPages[projectID] = $0 })
    }

    private func switchToProject(_ project: KiteloopProject) {
        unreadProjects.remove(project.id)
        activeProjectID = project.id
        Task { await projectStore.setActive(project) }
        // A tab switch doesn't change any project's URL or the open set, so there's no
        // need to regenerate security-scoped bookmarks (a slow, synchronous disk call per
        // open project). Only the active ID needs persisting; bookmarks are regenerated at
        // the points where the open set actually changes (open/close/restore).
        UserDefaults.standard.set(project.id, forKey: "activeProjectID")
        statusLine.updateSessionData(cwd: project.rootURL.path)
        statusLine.refresh()
    }

    // MARK: - Agent Management

    private func quickAddAgent(_ preset: QuickAddPreset) {
        let isOllama = preset.runtimeKind == "ollama"
        let tools: [String] = isOllama
            ? ["Read", "Edit", "Write", "Bash", "Glob", "Grep", "message_agent", "publish_event", "ask_human"]
            : []
        let denied: [String] = isOllama ? [] : ["Read", "Edit", "Write", "Bash", "Glob", "Grep"]
        // A Claude agent starts in the project's configured mode; an Ollama
        // agent's runtime has no such modes, so it keeps its own.
        let permissionMode = isOllama
            ? "acceptEdits" : Agent.initialPermissionMode(forProjectAt: currentSession?.project.rootURL)

        currentSession?.addAgent(
            name: preset.label,
            model: preset.model,
            permissionMode: permissionMode,
            avatar: preset.avatar,
            runtimeKind: preset.runtimeKind,
            systemPrompt: preset.systemPrompt,
            tools: tools,
            denied: denied
        )
    }

    private func backlogAutopilot(for session: ProjectSession) -> BacklogAutopilot {
        let projectID = session.project.id
        if let existing = autopilotCache.instances[projectID] {
            return existing
        }
        let autopilot = BacklogAutopilot()
        autopilot.configure(
            orchestrator: session.orchestrator,
            backlogViewModel: session.backlogViewModel,
            configURL: session.project.autopilotConfigURL,
            metricStore: taskMetricStore,
            projectPath: session.project.rootURL.path(percentEncoded: false),
            projectName: session.project.rootURL.lastPathComponent,
            runtimeFactory: runtimeFactory,
            globalConfigStore: globalConfigStore,
            dailySpendLedger: dailySpendLedger
        )
        autopilot.onExecutionStarted = { [weak autopilot, controlRegistry] execID in
            Task {
                // Every run leaves a durable record, whichever surface started it.
                // A run begun from the Autopilot tab reaches neither `POST
                // /v1/runs` nor the scheduler, so without this it appeared in no
                // history at all and could not be asked afterwards how it ended.
                // Here is the one moment both halves of its identity are known —
                // the execution, and the item it is running.
                guard let autopilot,
                      let inFlight = await autopilot.inFlightRun(),
                      let itemID = inFlight.itemID else { return }
                await MainActor.run {
                    controlRegistry.adoptRun?(session.project.id, itemID,
                                              inFlight.itemTitle ?? itemID, execID,
                                              inFlight.startedAt ?? Date())
                }
            }
        }
        autopilot.onStarted = {
            session.selectedAgentID = self.autopilotSidebarID
        }
        // The same fleet-wide hold `POST /v1/runs` and the scheduler read —
        // without this the Start button reached neither and would begin a
        // fresh run into a fleet parked for a restart.
        autopilot.isFleetQuiesced = { [fleetQuiesce] in fleetQuiesce.isQuiesced }
        // The fleet board's own pause — read fresh from disk on every start,
        // since parking a project while it sits idle leaves `status` untouched.
        // Without this the Autopilot tab's Run button would begin a fresh run
        // into a project a human just paused.
        autopilot.isProjectPaused = {
            session.project.loadConfig().paused == true
        }
        // A finished run is the moment this project's queue is most likely to be
        // empty — the timer would find it eventually, this finds it now.
        autopilot.onRunFinished = { [queueRefill, runScheduler, controlRegistry] in
            queueRefill.queueDrained()
            // And the moment the fleet is most likely to be free with runnable
            // work still waiting. The scheduler only ever looked on its own
            // timer, so a project that went idle here sat out up to a whole
            // `checkInterval` — five minutes, measured — with items ready the
            // entire time. It looks now, through every gate a timed look goes
            // through.
            runScheduler.runFinished()
            // And the moment its records are closable. Left to the next request,
            // a run the app is quit under stays open and reads `interrupted` at
            // the following launch — said about work that landed perfectly well,
            // and a UI-driven install may see no request for days.
            Task { @MainActor in await controlRegistry.finalizeRuns?() }
        }
        autopilotCache.instances[projectID] = autopilot
        return autopilot
    }

    private func backlogEditors(for session: ProjectSession) -> (ai: BacklogAIEditor, scope: TaskScopingEngine) {
        let projectID = session.project.id
        if let existing = backlogEditorsCache.instances[projectID] { return existing }
        let pair = (
            ai: BacklogAIEditor(runtimeFactory: runtimeFactory, globalConfigStore: globalConfigStore),
            scope: TaskScopingEngine(runtimeFactory: runtimeFactory, globalConfigStore: globalConfigStore, store: taskMetricStore)
        )
        backlogEditorsCache.instances[projectID] = pair
        return pair
    }

    private func runBacklogItemInCurrentAgent(_ item: BacklogItem, session: ProjectSession) {
        guard let agentID = session.selectedAgentID,
              let vm = session.chatViewModels[agentID] else { return }

        session.backlogViewModel.updateItemStatus(itemID: item.id, newStatus: .active)

        vm.inputText = Self.backlogItemPrompt(item, detail: session.backlogViewModel.loadDetail(for: item))
    }

    static func backlogItemPrompt(_ item: BacklogItem, detail: BacklogItemDetail?) -> String {
        var prompt = "Working on \(item.id): \(item.title)"
        if let detail {
            prompt += Self.detailProse(detail) + Self.detailLists(detail)
        } else {
            prompt += "\nVerify: \(item.verify ?? "swift build -scheme Kiteloop && swift test")"
        }
        return prompt + "\nBudget: stop after $50 or 100 queries."
    }

    static func detailProse(_ detail: BacklogItemDetail) -> String {
        var text = ""
        if let what = detail.what { text += "\n\nWhat: \(what)" }
        if let approach = detail.approach { text += "\n\nSuggested approach: \(approach)" }
        if let why = detail.why { text += "\nWhy: \(why)" }
        return text
    }

    static func detailLists(_ detail: BacklogItemDetail) -> String {
        var text = ""
        if !detail.acceptanceCriteria.isEmpty {
            text += "\nValidation: \(detail.acceptanceCriteria.joined(separator: "; "))"
        }
        if !detail.outOfScope.isEmpty {
            text += "\nOut of scope: \(detail.outOfScope.joined(separator: "; "))"
        }
        if !detail.verifyCommands.isEmpty {
            let cmds = detail.verifyCommands.map { "\($0.name): \($0.cmd)" }.joined(separator: "\n  ")
            text += "\nVerify:\n  \(cmds)"
        }
        return text
    }

    // MARK: - Web Preview

    /// Name of the agent a screenshot would attach to (nil when the current
    /// selection isn't a chattable agent).
    private var selectedAgentName: String? {
        guard let session = currentSession,
              let id = session.selectedAgentID,
              session.chatViewModels[id] != nil else { return nil }
        return session.orchestrator.agents.first { $0.id == id }?.name
    }

    /// Keeps the web preview's screenshot target pointed at the selected agent,
    /// so both the inline panel and a popped-out window attach to the right chat —
    /// and gives that chat's VM the reverse reference to the pane.
    private func updateWebPreviewTarget() {
        let target = currentSession.flatMap { session in
            session.selectedAgentID.flatMap { session.chatViewModels[$0] }
        }
        webPreviewVM.retarget(to: target, agentName: selectedAgentName)
    }

    // MARK: - Agent Notifications (hire / fire / summon)

    private func handleAgentHired(_ notification: Notification) {
        guard let agent = notification.userInfo?["agent"] as? Agent,
              let projID = notification.userInfo?["projectID"] as? String,
              let projectURL = notification.userInfo?["projectURL"] as? URL,
              let session = sessions[projID] else { return }
        session.handleAgentHired(agent, projectURL: projectURL)
    }

    private func handleAgentFired(_ notification: Notification) {
        guard let agentID = notification.userInfo?["agentID"] as? String,
              let projID = notification.userInfo?["projectID"] as? String else { return }
        sessions[projID]?.handleAgentFired(agentID)
    }

    private func handleAgentSummoned(_ notification: Notification) {
        guard let agent = notification.userInfo?["agent"] as? Agent,
              let projID = notification.userInfo?["projectID"] as? String,
              let projectURL = notification.userInfo?["projectURL"] as? URL,
              let initialMessage = notification.userInfo?["initialMessage"] as? String,
              let session = sessions[projID] else { return }
        session.handleAgentSummoned(agent, projectURL: projectURL, initialMessage: initialMessage)
    }

    private func handleCrossAgentMessage(_ notification: Notification) {
        guard let targetAgentID = notification.userInfo?["targetAgentID"] as? String,
              let senderName = notification.userInfo?["senderName"] as? String,
              let query = notification.userInfo?["query"] as? String,
              let response = notification.userInfo?["response"] as? String else { return }

        for session in sessions.values {
            if let targetVM = session.chatViewModels[targetAgentID] {
                targetVM.injectCrossAgentExchange(from: senderName, query: query, response: response)
                break
            }
        }
    }

    private func handleTeamConfigFileChanged(_ notification: Notification) {
        guard let projID = notification.userInfo?["projectID"] as? String,
              let projURL = notification.userInfo?["projectURL"] as? URL,
              let templates = notification.userInfo?["templates"] as? [AgentTemplate] else { return }
        sessions[projID]?.syncTeamFromConfig(templates: templates, projectURL: projURL)
    }

    // MARK: - Security-Scoped Bookmarks

    private func saveBookmark(for url: URL) {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            var allBookmarks = UserDefaults.standard.dictionary(forKey: "securityScopedBookmarks") as? [String: Data] ?? [:]
            allBookmarks[url.path] = data
            UserDefaults.standard.set(allBookmarks, forKey: "securityScopedBookmarks")
        } catch {
            mainWindowLog.error("Failed to create security-scoped bookmark for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveAllBookmarks() {
        for project in openProjects {
            saveBookmark(for: project.rootURL)
        }
        let entries: [[String: String]] = openProjects.map { project in
            ["path": project.rootURL.path, "id": project.id]
        }
        UserDefaults.standard.set(entries, forKey: "openProjectBookmarks")
        UserDefaults.standard.set(activeProjectID, forKey: "activeProjectID")
    }

    private func restoreAllBookmarks() -> [URL] {
        guard let entries = UserDefaults.standard.array(forKey: "openProjectBookmarks") as? [[String: String]] else {
            return []
        }
        return entries.compactMap { entry in
            guard let path = entry["path"] else { return nil }
            return resolveSecurityScopedBookmark(forPath: path)
        }
    }

    private func resolveSecurityScopedBookmark(forPath path: String) -> URL? {
        guard let allBookmarks = UserDefaults.standard.dictionary(forKey: "securityScopedBookmarks") as? [String: Data],
              let data = allBookmarks[path] else {
            let url = URL(fileURLWithPath: path)
            return FileManager.default.fileExists(atPath: path) ? url : nil
        }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                saveBookmark(for: url)
            }
            PermissionAuditLogger.shared.log(.bookmark, purpose: "access project: \(url.lastPathComponent)")
            guard url.startAccessingSecurityScopedResource() else {
                mainWindowLog.error("Failed to start accessing security-scoped resource: \(url.path, privacy: .public)")
                return nil
            }
            return url
        } catch {
            mainWindowLog.error("Failed to resolve bookmark for \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

// MARK: - Portfolio Home

/// Per-project rollup for the portfolio landing, derived from a project's root
/// `BACKLOG.md`. Sendable so it can cross back from the off-main loader.
struct PortfolioProjectSummary: Identifiable, Sendable {
    let id: String
    let name: String
    let path: String
    let hasBacklog: Bool
    let awaitingApproval: Int
    /// The items behind that count, so the strip can name them rather than only
    /// total them — and, named, link to them. Bounded where it is drawn, not
    /// here: the count above stays the truth about how many there are.
    var awaitingApprovalItems: [AwaitingItem] = []
    let openItems: Int
    let blocked: Int
    /// Items sitting at `ready` — the queue depth the coordinator tops up, and
    /// the number that says which project it would groom for next.
    let readyItems: Int
    /// How much of that `ready` column anything could actually start, and what is
    /// holding the rest. `readyItems` on its own is the number that made a
    /// stalled queue read as the healthiest project in the portfolio.
    var queue: QueueHealth = .empty
    /// Whether a human has parked this project. Unstated reads as running.
    var paused: Bool = false
    /// What the human said this project is for. Nil when unstated.
    var goal: String?

    /// One item sitting at the approval gate, and the project it is in — enough
    /// for the strip to name it and to open it.
    struct AwaitingItem: Identifiable, Sendable, Equatable {
        let id: String
        let title: String
        let projectPath: String

        /// The item as a reader knows it: its title when it has one, its id when
        /// it doesn't — the same rule the Coordinator's start rows use.
        var headline: String { title.isEmpty ? id : title }
    }
}

/// Reads each recent project's root `BACKLOG.md` and rolls up item counts, plus
/// whether the project is parked and its goal, from the project's own config.
/// Strictly read-only; never writes. Runs off the main actor.
enum PortfolioSummaryLoader {
    /// Persist an edited paused switch and goal to the project's own
    /// `.kiteloop/config.json`, so the statement travels with the repo. Runs off
    /// the main actor — the Portfolio must not stall on a disk write. A write
    /// that fails is reported and returns false, so the caller can put the
    /// switch back to what is on disk: the loops read the file, not the card.
    @discardableResult
    nonisolated static func save(paused: Bool, goal: String?, projectPath: String,
                                 reporter: StoreProblemReporter = .shared) async -> Bool {
        let project = KiteloopProject(rootURL: URL(fileURLWithPath: projectPath))
        do {
            try project.setPaused(paused, goal: goal)
            return true
        } catch {
            reporter.report(store: KiteloopProject.configStoreName, operation: .write,
                            url: project.configURL, error: error)
            return false
        }
    }

    /// - Parameter grooming: the pre-run ledger, read once on the main actor and
    ///   handed across as a value. Without it a project's queue still reports how
    ///   much of it is groomed; what it cannot report is what the grounding check
    ///   and the retry ceiling refused last time they looked — see `QueueHealth`.
    nonisolated static func load(_ recents: [RecentProject], vaultURL: URL?,
                                 grooming: [GroomingRecord] = []) async -> [PortfolioProjectSummary] {
        recents.map { recent in
            let config = KiteloopProject(rootURL: URL(fileURLWithPath: recent.path)).loadConfig()
            let paused = config.paused ?? false
            let goal = KiteloopProject.normalizedStatement(config.goal)
            // The same three-layer resolution BacklogViewModel does: a
            // project-local BACKLOG.md wins, then the shared branch's private
            // checkout, then the vault. Read-only on purpose — this loader must
            // not adopt or fetch, so a clone never opened still reads
            // no-backlog here, which is true. Skipping the middle layer is what
            // had every branch-backed project reporting "nothing to groom into"
            // while the grooming loop filed items into it (2026-08-15).
            let localURL = URL(fileURLWithPath: recent.path).appending(path: "BACKLOG.md")
            let branchURL = BacklogBranch.backlogFileURL(
                projectRoot: URL(fileURLWithPath: recent.path, isDirectory: true))
            let exists = { (url: URL) in
                FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
            }
            let backlogURL: URL? = exists(localURL) ? localURL
                : exists(branchURL) ? branchURL
                : vaultURL.flatMap { BacklogParser.findBacklogPath(vaultURL: $0, repoPath: recent.path) }
            guard let backlogURL, let data = try? Data(contentsOf: backlogURL) else {
                return PortfolioProjectSummary(
                    id: recent.id, name: recent.name, path: recent.path,
                    hasBacklog: false, awaitingApproval: 0, openItems: 0, blocked: 0,
                    readyItems: 0, queue: .empty, paused: paused, goal: goal
                )
            }
            let items = BacklogParser.parse(String(decoding: data, as: UTF8.self)).sections.flatMap(\.items) // Lossy: a bad byte is not "no backlog".
            return PortfolioProjectSummary(
                id: recent.id, name: recent.name, path: recent.path,
                hasBacklog: true,
                awaitingApproval: items.count { $0.status == .awaitingApproval },
                awaitingApprovalItems: items.filter { $0.status == .awaitingApproval }
                    .map { .init(id: $0.id, title: $0.title, projectPath: recent.path) },
                openItems: items.count { $0.status != .done },
                blocked: items.count { $0.status == .blocked },
                readyItems: items.count { $0.status == .ready },
                queue: QueueHealth.make(
                    items: items,
                    detail: { detail(for: $0, backlogURL: backlogURL) },
                    refusals: QueueHealth.recordedRefusals(
                        grooming, projectPath: recent.path,
                        detailModified: { itemID in
                            guard let item = items.first(where: { $0.id == itemID }) else { return nil }
                            return detailModified(for: item, backlogURL: backlogURL)
                        })),
                paused: paused, goal: goal
            )
        }
    }

    /// An item's groomed detail, resolved relative to the backlog file rather
    /// than to the project root — the same resolution `BacklogViewModel.detailURL`
    /// does, which is what makes a vault-hosted backlog's details resolve at all.
    ///
    /// Off the main actor, and only for the ready items `QueueHealth` asks about:
    /// this is one file read per item that could plausibly run, not per item in
    /// the backlog.
    nonisolated private static func detail(for item: BacklogItem,
                                           backlogURL: URL) -> BacklogItemDetail? {
        guard let detailPath = item.detailPath else { return nil }
        return BacklogParser.parseDetail(
            at: backlogURL.deletingLastPathComponent().appending(path: detailPath))
    }

    /// An item's groomed detail file's last-edited date, resolved the same way
    /// `detail(for:backlogURL:)` resolves the file itself — so a recorded
    /// refusal is compared against the same file this summary reads, and the
    /// landing screen cannot come to a different answer than the panel.
    nonisolated private static func detailModified(for item: BacklogItem, backlogURL: URL) -> Date? {
        guard let detailPath = item.detailPath else { return nil }
        let url = backlogURL.deletingLastPathComponent().appending(path: detailPath)
        return (try? FileManager.default.attributesOfItem(
            atPath: url.path(percentEncoded: false)))?[.modificationDate] as? Date
    }
}

/// Landing-screen portfolio: a "needs you" strip aggregating items awaiting
/// approval across all projects, the Coordinator's own section, plus a card per
/// project. Selecting a card opens that project. Read-only aggregation over
/// existing `BACKLOG.md` files.
struct PortfolioSection: View {
    let recentProjects: [RecentProject]
    let onOpenRecent: (RecentProject) -> Void
    let vaultURL: URL?
    /// Where the portfolio-level statement lives. Optional so the section still
    /// renders (without that field) anywhere the store isn't handy.
    var globalConfigStore: GlobalConfigStore?
    /// The window's portfolio-level refill loop. Optional for the same reason as
    /// the store above — without it the Coordinator section is simply absent
    /// rather than the whole landing screen failing to compile a caller.
    var coordinator: CoordinatorQueueRefill?
    /// The two ledgers behind the Coordinator section's day rollup.
    var metricStore: TaskMetricStore?
    var groomingLedger: GroomingLedger?
    /// The autonomous-run switch the Coordinator section operates. Separate from
    /// `coordinator` because the two switches are deliberately separate.
    var runScheduler: CoordinatorRunScheduler?
    /// For the autonomy ladder's per-project switches; optional like the rest.
    var registry: ControlSessionRegistry?

    @State private var summaries: [PortfolioProjectSummary] = []
    @State private var portfolioGoalDraft = ""
    @FocusState private var portfolioGoalFocused: Bool

    private var totalAwaiting: Int { summaries.reduce(0) { $0 + $1.awaitingApproval } }
    private var totalOpen: Int { summaries.reduce(0) { $0 + $1.openItems } }
    private var projectsWithApproval: Int { summaries.count { $0.awaitingApproval > 0 } }

    var body: some View {
        VStack(spacing: KiteloopTokens.Spacing.xl) {
            if let coordinator {
                CoordinatorPanel(
                    refill: coordinator,
                    projects: summaries.map(Self.coordinatorInput),
                    metricStore: metricStore,
                    groomingLedger: groomingLedger,
                    scheduler: runScheduler,
                    globalConfigStore: globalConfigStore,
                    registry: registry
                )
            }

            needsYouStrip

            if globalConfigStore != nil {
                portfolioGoalField
            }

            if summaries.isEmpty {
                // The grid is 360pt of nothing until the summaries land, and
                // stays that way for a portfolio nothing has been opened into.
                PanelEmptyState(.portfolioProjects)
                    .frame(height: 160)
                    .accessibilityIdentifier("portfolio-empty-state")
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 260), spacing: KiteloopTokens.Spacing.lg)],
                        spacing: KiteloopTokens.Spacing.lg
                    ) {
                        ForEach(summaries) { summary in
                            PortfolioProjectCard(
                                summary: summary,
                                onOpen: {
                                    if let recent = recentProjects.first(where: { $0.id == summary.id }) {
                                        onOpenRecent(recent)
                                    }
                                },
                                onUpdate: { paused, goal in
                                    update(summary, paused: paused, goal: goal)
                                }
                            )
                            .accessibilityIdentifier("start-recent-project")
                        }
                    }
                    .padding(.horizontal, KiteloopTokens.Spacing.xs)
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(maxWidth: 760)
        .task(id: recentProjects.map(\.id).joined(separator: ",")) {
            summaries = await reload()
            portfolioGoalDraft = globalConfigStore?.portfolioGoal ?? ""
        }
    }

    /// Re-read every project's backlog. The grooming ledger is copied here, on the
    /// main actor, and the aggregation itself runs off it — the records are plain
    /// `Sendable` values, like the panel's day rollup.
    private func reload() async -> [PortfolioProjectSummary] {
        await PortfolioSummaryLoader.load(recentProjects, vaultURL: vaultURL,
                                          grooming: groomingLedger?.records ?? [])
    }

    /// The projects whose ready column holds work nothing could pick up, in the
    /// order the grid lists them.
    private var stalledProjects: [(name: String, queue: QueueHealth)] {
        summaries.filter { $0.hasBacklog && $0.queue.isStalled }
            .map { (name: $0.name, queue: $0.queue) }
    }

    /// The portfolio-level statement — what the human is after across every
    /// project, for when per-project priorities tie. Empty is a legitimate
    /// state, so there is no validation and no placeholder-as-error.
    @ViewBuilder
    private var portfolioGoalField: some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.xs) {
            Text("What I'm after right now")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Across every project — optional", text: $portfolioGoalDraft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .accessibilityIdentifier("portfolio-goal-field")
                .focused($portfolioGoalFocused)
                .onSubmit { savePortfolioGoal() }
                // On commit and on leaving the field, not per keystroke — every
                // save is a durable rewrite of the global config.
                .onChange(of: portfolioGoalFocused) { _, focused in
                    if !focused { savePortfolioGoal() }
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, KiteloopTokens.Spacing.xs)
    }

    private func savePortfolioGoal() {
        globalConfigStore?.setPortfolioGoal(portfolioGoalDraft)
    }

    /// The same rollup the cards render, reduced to what the Coordinator section
    /// ranks on. Reused rather than re-read: the loader has already been to disk
    /// for every one of these. Not private because `CoordinatorDrawer` mounts the
    /// same panel and has to feed it the same shape.
    static func coordinatorInput(_ summary: PortfolioProjectSummary)
        -> CoordinatorPanelModel.ProjectInput {
        CoordinatorPanelModel.ProjectInput(
            id: summary.id, name: summary.name, paused: summary.paused,
            goal: summary.goal, readyCount: summary.readyItems, hasBacklog: summary.hasBacklog,
            queue: summary.queue
        )
    }

    /// Persist an edited card and reflect it locally, so the grid doesn't wait
    /// on a re-read of every project to show what the human just said.
    private func update(_ summary: PortfolioProjectSummary,
                        paused: Bool, goal: String?) {
        let normalized = KiteloopProject.normalizedStatement(goal)
        guard let index = summaries.firstIndex(where: { $0.id == summary.id }) else { return }
        let previous = (paused: summaries[index].paused, goal: summaries[index].goal)
        summaries[index].paused = paused
        summaries[index].goal = normalized
        let path = summary.path
        Task { @MainActor in
            let saved = await PortfolioSummaryLoader.save(paused: paused, goal: normalized, projectPath: path)
            // Unsaved means nothing is parked: show what is actually on disk.
            guard !saved, let at = summaries.firstIndex(where: { $0.id == summary.id }) else { return }
            summaries[at].paused = previous.paused
            summaries[at].goal = previous.goal
        }
    }

    /// The strip's own state. A fleet with nothing to approve is not necessarily
    /// a fleet that is working: a stalled queue is the failure this whole screen
    /// used to hide, so it outranks "all caught up" and is never folded into it.
    private var stallLine: String? { QueueHealth.fleetStallLine(stalledProjects) }

    /// Every item at the approval gate, portfolio-wide, in the order the grid
    /// lists their projects.
    private var awaitingItems: [PortfolioProjectSummary.AwaitingItem] {
        summaries.flatMap(\.awaitingApprovalItems)
    }

    /// How many the strip names before it stops. The count above is still the
    /// truth about how many there are, and `namedOverflow` says what was left
    /// out — a list that looks complete and isn't is the worse failure.
    private static let namedAwaitingLimit = 4

    private var namedOverflow: Int {
        max(0, awaitingItems.count - Self.namedAwaitingLimit)
    }

    @ViewBuilder
    private var needsYouStrip: some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.sm) {
            needsYouHeadline
            // The strip used to total the gate and name none of it, so the one
            // screen that says "something needs you" could not say *what* — the
            // id had to be remembered and found in the right project's backlog.
            if !awaitingItems.isEmpty {
                awaitingItemsList
            }
        }
        .font(.callout)
        .padding(.horizontal, KiteloopTokens.Spacing.xl)
        .padding(.vertical, KiteloopTokens.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: KiteloopTokens.Radius.lg)
                .fill((totalAwaiting > 0 || stallLine != nil ? Color.orange : Color.green)
                    .opacity(KiteloopTokens.Opacity.light))
        )
    }

    /// The named gate items, each opening its own page — which means opening
    /// its project first, since this screen is only on with nothing open.
    private var awaitingItemsList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(awaitingItems.prefix(Self.namedAwaitingLimit)) { item in
                ItemLink(item.id, in: .path(item.projectPath)) {
                    HStack(spacing: KiteloopTokens.Spacing.sm) {
                        Image(systemName: "arrow.right.circle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        Text(item.headline)
                            .font(.caption)
                            .lineLimit(1)
                        Text(URL(fileURLWithPath: item.projectPath).lastPathComponent)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if namedOverflow > 0 {
                Text("…and \(namedOverflow) more")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityIdentifier("portfolio-awaiting-overflow")
            }
        }
        .accessibilityIdentifier("portfolio-awaiting-items")
    }

    @ViewBuilder
    private var needsYouHeadline: some View {
        HStack(spacing: KiteloopTokens.Spacing.md) {
            if totalAwaiting > 0 {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(.orange)
                Text("\(totalAwaiting) \(totalAwaiting == 1 ? "item needs" : "items need") your approval")
                    .fontWeight(.semibold)
                Text("across \(projectsWithApproval) of \(String(count: summaries.count, noun: "project"))")
                    .foregroundStyle(.secondary)
            } else if let stallLine {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Nothing can start")
                    .fontWeight(.semibold)
                Text("· \(stallLine)")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("portfolio-stall-line")
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("You're all caught up")
                    .fontWeight(.semibold)
                if totalOpen > 0 {
                    Text("· \(totalOpen) open across \(String(count: summaries.count, noun: "project"))")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button {
                Task { summaries = await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
        }
    }
}

/// A single project card on the portfolio landing, plus the two things the human
/// says about the project: whether it is parked, and its goal.
///
/// The rollup is a button that opens the project; the paused and goal controls
/// sit outside it, so editing them never opens the project by accident.
private struct PortfolioProjectCard: View {
    let summary: PortfolioProjectSummary
    let onOpen: () -> Void
    let onUpdate: (Bool, String?) -> Void

    @State private var goalDraft: String = ""
    @FocusState private var goalFocused: Bool

    private var needsYou: Bool { summary.awaitingApproval > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.md) {
            Button(action: onOpen) { rollup }
                .buttonStyle(.plain)

            Divider()

            pausedAndGoal
        }
        .padding(KiteloopTokens.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: KiteloopTokens.Radius.lg)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: KiteloopTokens.Radius.lg)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .opacity(summary.paused ? 0.7 : 1)
        .contextMenu { MainWindow.projectFolderMenuItems(path: summary.path) }
        .task(id: summary.id) { goalDraft = summary.goal ?? "" }
    }

    private var borderColor: Color {
        if summary.paused { return Color.gray.opacity(0.5) }
        if needsYou { return Color.orange.opacity(0.5) }
        return Color.gray.opacity(KiteloopTokens.Opacity.medium)
    }

    @ViewBuilder
    private var rollup: some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.md) {
            HStack(spacing: KiteloopTokens.Spacing.md) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(summary.name)
                    .font(.headline)
                    .lineLimit(1)
                    .help(MainWindow.projectFolderHoverText(forPath: summary.path))
                Spacer(minLength: 0)
                if needsYou {
                    Text("\(summary.awaitingApproval)")
                        .font(.caption).fontWeight(.bold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange))
                }
            }

            Text(summary.path)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            Divider()

            HStack(spacing: KiteloopTokens.Spacing.lg) {
                if summary.hasBacklog {
                    statChip(value: summary.openItems, label: "open", color: .secondary)
                    if needsYou {
                        statChip(value: summary.awaitingApproval, label: "needs you", color: .orange)
                    }
                    if summary.blocked > 0 {
                        statChip(value: summary.blocked, label: "blocked", color: .red)
                    }
                } else {
                    Text("no backlog yet")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }

            if summary.hasBacklog {
                queueLine
            }
        }
        .contentShape(Rectangle())
    }

    /// What this project's queue actually is — the ready count next to how much
    /// of it could start, and the reasons when those differ. One line, not a
    /// dashboard: the counts alone were what made a queue nobody could pick up
    /// read as the deepest one in the portfolio.
    @ViewBuilder
    private var queueLine: some View {
        Text(summary.queue.summary)
            .font(.caption2)
            .foregroundStyle(summary.queue.isStalled ? Color.orange : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("portfolio-queue-\(summary.name)")
    }

    /// What the human says about this project: one switch that parks it, and
    /// what it is for. Parking is a stop, so it is a switch rather than the
    /// bottom of a ranking — the fleet orders itself by which project has been
    /// idle longest.
    @ViewBuilder
    private var pausedAndGoal: some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.xs) {
            HStack(spacing: KiteloopTokens.Spacing.sm) {
                Toggle("Paused", isOn: pausedBinding)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .accessibilityIdentifier("portfolio-paused-\(summary.name)")
                    .help("Park this project: no run starts for it — unattended, from its Run button or over the control API — "
                          + "until it is unparked. A run already in flight finishes, and items at the approval gate stay there.")

                if summary.paused {
                    Label("no work picked up", systemImage: "pause.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            TextField("What this project is for — optional", text: $goalDraft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .lineLimit(1...3)
                .focused($goalFocused)
                .accessibilityIdentifier("portfolio-goal-\(summary.name)")
                .onSubmit { saveGoal() }
                // Committed on leaving the field, not per keystroke — each save
                // rewrites the project's config file.
                .onChange(of: goalFocused) { _, focused in
                    if !focused { saveGoal() }
                }
        }
    }

    private var pausedBinding: Binding<Bool> {
        Binding(
            get: { summary.paused },
            set: { onUpdate($0, goalDraft) }
        )
    }

    private func saveGoal() {
        guard KiteloopProject.normalizedStatement(goalDraft) != summary.goal else { return }
        onUpdate(summary.paused, goalDraft)
    }

    @ViewBuilder
    private func statChip(value: Int, label: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Text("\(value)").fontWeight(.semibold).foregroundStyle(color)
            Text(label).foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}

/// Which surface the bottom console is showing.
enum ConsoleTab: String, CaseIterable, Identifiable {
    case activity
    case traces

    var id: String { rawValue }

    var title: String {
        switch self {
        case .activity: "Activity"
        case .traces: "Traces"
        }
    }
}

/// A hairline divider that resizes its adjacent pane by dragging. Shows a
/// horizontal-resize cursor on hover; clamps the width to `range`.
private struct PaneResizer: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    /// `true` when dragging rightward should grow the pane (left navigator);
    /// `false` when dragging leftward grows it (right inspector).
    let growsWithRightwardDrag: Bool

    @State private var startWidth: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let base = startWidth ?? width
                                if startWidth == nil { startWidth = base }
                                let delta = growsWithRightwardDrag ? value.translation.width : -value.translation.width
                                width = min(max(base + delta, range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            }
    }
}
