import KiteloopCore
import SwiftUI

private struct OpenDiagnosticsMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Diagnostics") { openWindow(id: "diagnostics") }
            .keyboardShortcut("d", modifiers: [.command, .option])
    }
}

/// The front project window's session, published to the menu bar so File >
/// New Chat acts on the window in front.
struct FocusedProjectSessionKey: FocusedValueKey {
    typealias Value = ProjectSession
}

extension FocusedValues {
    var projectSession: ProjectSession? {
        get { self[FocusedProjectSessionKey.self] }
        set { self[FocusedProjectSessionKey.self] = newValue }
    }
}

/// File > **New Chat** (⌘N): a new chat with the agent selected in the front
/// project window — the sidebar's + for when the sidebar is hidden.
private struct NewChatMenuButton: View {
    @FocusedValue(\.projectSession) private var session
    var body: some View {
        Button("New Chat") {
            Task { await session?.startNewChatForSelectedAgent() }
        }
        .keyboardShortcut("n", modifiers: .command)
        .disabled(session?.selectedAgentID == nil)
    }
}

/// The app menu's **Check for Updates…**, right under About. Disabled while a
/// check is already on screen, and in a copy that does not update itself.
private struct CheckForUpdatesMenuButton: View {
    let updater: SoftwareUpdater
    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}

@main
struct KiteloopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @State private var projectStore = ProjectStore(recentsURL: KiteloopApp.recentsURL())
    @StateObject private var statusLine = StatusLineService()
    @State private var agentCatalogStore = AgentCatalogStore()
    @State private var globalConfigStore = GlobalConfigStore()
    @State private var softwareUpdater = SoftwareUpdater()
    // One ledger for the whole app: the daily budget is portfolio-wide, so every
    // project's autopilot charges the same day and reads the same total.
    @State private var dailySpendLedger = DailySpendLedger()
    // Scan paths and packages resolve in a background bootstrap task; touching the
    // filesystem here would block launch on a TCC consent prompt before any window
    // exists. Consumers await packageResolver.ensureLoaded() before resolving agents.
    @State private var packageResolver: PackageResolver? = {
        let configuredRepoPath = GlobalConfigStore().config.knowledgeRepoPath
        return PackageResolver(scanPathsProvider: {
            KnowledgePathResolver.resolveScanPaths(configuredRepoPath: configuredRepoPath)
        })
    }()
    @State private var orgManifestLoader = OrgManifestLoader()
    @State private var repoCloneService = RepoCloneService()
    @State private var activeOrchestratorTracker = ActiveOrchestratorTracker()
    @State private var taskMetricStore: TaskMetricStore
    /// The projection of the metric logs. One per app, shared by the control
    /// API's `/v1/metrics` and by the backlog's per-item history — a second
    /// instance would open a second connection to the same database to answer
    /// the same questions.
    @State private var metricIndex: MetricIndex
    @State private var controlRegistry: ControlSessionRegistry
    @State private var controlServer: KiteloopControlServer
    /// The portfolio-level refill loop — one per app, not one per window or
    /// project: it chooses *between* projects, so a second instance would pick
    /// its own favourite and groom for it in parallel.
    @State private var queueRefill: CoordinatorQueueRefill
    /// The portfolio-level run scheduler — one per app for the same reason the
    /// refill loop is: it chooses *between* projects, and a second instance
    /// would start runs the first one doesn't know about. Off unless a stored
    /// setting says otherwise.
    @State private var runScheduler: CoordinatorRunScheduler
    @State private var routineRunner = RoutineRunner()
    /// The app's caller of the fleet-wide hold. One per app, over the same
    /// `FleetQuiesce` the control API's `/v1/fleet/*` endpoints drive — a second
    /// instance would keep a second gate, and a fleet held through one of them
    /// would go on taking work through the other.
    @State private var fleetQuiesce: FleetQuiesceControl

    @State private var didBootstrap = false

    init() {
        // The login shell's PATH is captured once per launch; asking for it
        // here, off the main actor, means the first spawn — or the first
        // `/health` — does not wait on `~/.zprofile`.
        Task.detached(priority: .utility) { _ = ExecutableSearchPath.loginShellPath }
        let registry = ControlSessionRegistry()
        // The same store the autopilots write their run metrics into, so
        // `GET /v1/metrics` reports the runs the app actually measured.
        let metricStore = TaskMetricStore()
        // The queryable projection of the same logs. Nothing writes through it —
        // it catches itself up by replaying what the logs gained — so attaching
        // it adds a way to ask questions and no way to lose a measurement.
        let metricIndex = MetricIndex()
        let refill = CoordinatorQueueRefill()
        let scheduler = CoordinatorRunScheduler()
        _controlRegistry = State(initialValue: registry)
        _taskMetricStore = State(initialValue: metricStore)
        _metricIndex = State(initialValue: metricIndex)
        _queueRefill = State(initialValue: refill)
        _runScheduler = State(initialValue: scheduler)
        let server = KiteloopControlServer(
            registry: registry, metricStore: metricStore, metricIndex: metricIndex,
            // The same ledger the autopilots' pre-run checks write their refusals
            // into, so `GET /v1/grooming` reports what the app actually refused.
            groomingLedger: .shared,
            queueRefill: refill, runScheduler: scheduler,
            // Where run records outlive the app. Attached here and nowhere else:
            // a test server writing into `~/.kiteloop/control-runs.jsonl` would
            // put invented runs in the developer's own history.
            runRecords: .shared,
            // A token per paired phone, beside the control token every other client uses.
            deviceTokens: ControlDeviceTokens(url: ControlDeviceTokens.defaultURL),
            // What was driven remotely, readable afterwards: never a body or a token.
            accessLog: ControlAccessLog(url: ControlAccessLog.defaultURL))
        // The scheduler records its own runs through the server, so a night of
        // unattended work is readable from `GET /v1/runs`. Wired after the fact
        // because the server is built around the scheduler — and weakly on the
        // scheduler's side, so the pair is not a cycle.
        scheduler.attach(controlServer: server)
        _controlServer = State(initialValue: server)
        // The server owns the seam because the gate it keeps is read on the path
        // that starts runs; the app reaches the same one rather than building a
        // second. Off-by-default has nothing to do with it — the API being
        // switched off in Settings does not stop the server object existing, and
        // the operator's hold must work either way.
        _fleetQuiesce = State(initialValue: FleetQuiesceControl(fleet: server.fleet))
    }

    /// Where the recent-projects list lives: Application Support, or — under an
    /// isolated `KITELOOP_HOME` — inside that home. A QA copy read the user's
    /// own list, showed their projects on its start screen and checked each
    /// path, and one under ~/Documents or on a network volume raised a privacy
    /// prompt nobody was there to answer.
    static func recentsURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let support = environment[KiteloopHome.variable] == nil
            ? URL.applicationSupportDirectory
            : KiteloopHome.url(environment: environment).appending(path: "Library/Application Support")
        return support.appending(path: "Kiteloop/recent-projects.json")
    }

    private static let globalDir: URL = {
        let home = KiteloopHome.url
        return home.appending(path: ".kiteloop")
    }()

    /// The environment variable that switches session recording on. Absent,
    /// empty or set to anything other than `recordingSessionsOnValue` leaves
    /// the runtime unwrapped — the recorder is off in every shipped build,
    /// and on only when something in the process environment asks for it.
    static let recordingSessionsVariable = "KITELOOP_RECORD_SESSIONS"
    static let recordingSessionsOnValue = "1"

    /// Whether to wrap the real runtime in a RecordingAgentRuntime that captures
    /// session events to `~/.kiteloop/recordings` for building replay test fixtures.
    static func shouldRecordSessions(environment: [String: String]) -> Bool {
        environment[recordingSessionsVariable] == recordingSessionsOnValue
    }

    private var runtime: any AgentRuntime {
        // Debug only: a shipped build must not swap its agent runtime for a
        // canned one on the strength of an environment variable.
        #if DEBUG
        if UITestingSupport.isUITesting, !UITestingSupport.isIntegrationTesting {
            return UITestingSupport.makeMockRuntime()
        }
        #endif
        // Through the resolver rather than the bare initializer: the bare one
        // falls back to `CLIResolver.claude`/`node`, which never read the
        // configured `claudePath`/`nodePath`, so a path set in
        // global-config.json would decide nothing about what gets spawned.
        let cli = CLIResolver.resolve(globalConfig: globalConfigStore.config)
        let real = ClaudeCodeCLIRuntime(claudePath: cli.claude, nodePath: cli.node,
                                        environmentForSpawn: RunEnvironment.overlay(forWorkingDirectory:),
                                        globalMCPServers: globalConfigStore.config.mcpServers ?? [:])
        if Self.shouldRecordSessions(environment: ProcessInfo.processInfo.environment) {
            let dir = Self.globalDir.appending(path: "recordings")
            return RecordingAgentRuntime(wrapped: real, outputDirectory: dir)
        }
        return real
    }

    /// Starts the routines: who they reach is the control server's to say,
    /// what they may spend is the day's ledger's, and a project opening is an
    /// occasion to look again for one that was waiting on it.
    private func startRoutines() {
        let runner = routineRunner
        let ledger = dailySpendLedger
        let configStore = globalConfigStore
        controlServer.routines = runner
        runner.agent = { [weak controlServer] routine in
            controlServer?.routineAgent(for: routine)
                ?? .failure(Routine.Refusal(problems: ["Kiteloop is shutting down"]))
        }
        runner.budgetRefusal = { [weak controlServer] folder in
            controlServer?.routineBudgetRefusal(folder: folder, ledger: ledger,
                                                portfolioBudgetUSD: configStore.config.dailyBudgetUSD)
        }
        runner.charge = { cost, folder in
            ledger.charge(costUSD: cost, project: folder.path(percentEncoded: false))
        }
        controlRegistry.projectOpened = { [weak runner] in runner?.look() }
        runner.start()
    }

    var body: some Scene {
        WindowGroup(id: MainWindow.windowID) {
            MainWindow(
                projectStore: projectStore,
                statusLine: statusLine,
                runtimeFactory: { runtime },
                agentCatalogStore: agentCatalogStore,
                packageResolver: packageResolver,
                globalConfigStore: globalConfigStore,
                repoCloneService: repoCloneService,
                orgManifestLoader: orgManifestLoader,
                activeOrchestratorTracker: activeOrchestratorTracker,
                taskMetricStore: taskMetricStore,
                metricIndex: metricIndex,
                controlRegistry: controlRegistry,
                dailySpendLedger: dailySpendLedger,
                queueRefill: queueRefill,
                runScheduler: runScheduler,
                fleetQuiesce: fleetQuiesce
            )
            .environment(routineRunner)
            .task {
                // Ahead of the bootstrap guard: a quit has to be offered the
                // drain whether or not the rest of launch ran, and a quit with
                // nothing wired is today's quit — it interrupts.
                appDelegate.fleetQuiesce = fleetQuiesce
                // Ahead of the guard for the same reason, and wired whether or
                // not the API is switched on below: the server holds the runs it
                // began either way, and a record left open at quit is the one
                // the next launch has to call `interrupted`.
                appDelegate.finalizeRuns = { [weak controlServer] in
                    await controlServer?.finalizeRunsAtQuit()
                }
                guard !didBootstrap, !UITestingSupport.isTesting else { return }
                didBootstrap = true
                if let packageResolver {
                    await orgManifestLoader.loadIfNeeded(resolver: packageResolver)
                }
                HealthMonitor.shared.start(
                    subprocessCountProvider: { ClaudeCodeCLIRuntime.globalActiveProcessCount },
                    orchestratorProvider: { activeOrchestratorTracker.orchestrator }
                )
                let configStore = globalConfigStore
                PushRelay.shared.configure(devices: PushDeviceStore(url: PushDeviceStore.defaultURL),
                                           key: { configStore.config.pushKey })
                controlServer.quickReplies = { QuickReplies.effective(configStore.config) }
                // Grooming an item filed from the phone: the Groom button's one-shot.
                let groomer = BacklogAIEditor(runtimeFactory: { runtime }, globalConfigStore: configStore)
                controlServer.groomOneShot = { prompt, cwd, system, grant in
                    try await groomer.runOneShot(prompt: prompt, cwd: cwd, systemPrompt: system,
                                                 agentName: "Backlog Groomer", access: grant)
                }
                startRoutines()
                if globalConfigStore.config.controlServerEnabled == true {
                    controlServer.start(port: KiteloopControlServer.resolvedPort(globalConfigStore.config.controlServerPort))
                }
            }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                NewChatMenuButton()
            }
            CommandGroup(after: .appInfo) {
                CheckForUpdatesMenuButton(updater: softwareUpdater)
            }
            CommandGroup(after: .toolbar) {
                OpenDiagnosticsMenuButton()
            }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 600)

        Window("Diagnostics", id: "diagnostics") {
            DiagnosticsView(registry: controlRegistry)
        }
        .defaultSize(width: 900, height: 500)

        MenuBarExtra {
            MenuBarView(tracker: activeOrchestratorTracker)
        } label: {
            // The bar itself reads differently while something is waiting on a
            // person, so the fleet stalling is visible without the popover being
            // opened at all.
            Image(systemName: MenuBarAttention.labelSymbol(
                waiting: !activeOrchestratorTracker.waiting.isEmpty))
        }

        Settings {
            AppPreferencesView(
                globalConfigStore: globalConfigStore,
                agentCatalogStore: agentCatalogStore,
                controlServer: controlServer,
                softwareUpdater: softwareUpdater,
                packageResolver: packageResolver
            )
        }
    }
}
