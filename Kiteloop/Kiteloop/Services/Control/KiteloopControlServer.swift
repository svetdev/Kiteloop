import Foundation
import KiteloopCore
import os.log

private let controlLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "control-server")

/// The local control API: a loopback HTTP server that lets an external tool — a
/// Claude Code session, a script — start a backlog item, poll its progress, and
/// read the result. Off by default; guarded by a bearer token on 127.0.0.1.
///
/// v1 requires the target project to already be open in the app (its agents up),
/// and runs one item at a time per project. Monitoring is by polling `GET
/// /v1/runs/{id}`; SSE and headless project boot are later increments.
@MainActor
@Observable
final class KiteloopControlServer {

    struct RunInfo {
        let runId: String        // == workflow executionID, unless `startedHere` is false
        let projectID: String
        let itemId: String
        let title: String
        let startedAt: Date
        /// The cost readout last seen while this run was the one in flight —
        /// refreshed on every request that reaches a handler (see
        /// `snapshotLiveCosts()`), and left alone once the run is over.
        ///
        /// Kept because the governor's in-flight figures are cleared the moment
        /// the item ends: the ceiling the run was actually measured against is
        /// gone by the time its result is read, and re-deriving it would ask the
        /// prediction chain a question this very run has since changed the answer
        /// to (its own cost is now the chain's first rung).
        var cost: CostGovernor.Readout?
        /// The workflow execution this run turned out to be, when the run id is
        /// not it. A run this server started *is* its execution id; an autonomous
        /// one is recorded before a workflow exists, so its execution is filled in
        /// by `closeRun` and this is what its charge is addressed by.
        var executionID: String?
        /// Whether this run is addressed by the execution driving it, and so
        /// whether anything here can say how the run is going. True for a run this
        /// server started, and for one adopted from the Autopilot tab: both are
        /// keyed by the workflow's own id, and the ending of both is the
        /// autopilot's, read the same way. False for the autonomous scheduler's
        /// runs: it opens them here so they leave the same records, but it awaits
        /// the whole run itself and asks for the run to be closed — and until it
        /// does, nothing here could say how the run is going, because the minted
        /// `auto-…` id is not one the workflow engine knows.
        var startedHere = true

        /// The execution this run is reported as having been, or nil while there
        /// is nothing to report. A run driven under its own execution id *is* that
        /// execution, so the `runId` answers immediately; a scheduler-opened one
        /// only learns its execution at `closeRun`, and one whose start the pickup
        /// gates refused never gets one at all — reporting its minted `auto-…` id
        /// there would name a transcript directory that does not exist.
        var reportedExecutionID: String? { executionID ?? (startedHere ? runId : nil) }
    }

    /// The port the server falls back to when the user has never chosen one, or
    /// when the persisted value is unusable.
    ///
    /// `nonisolated` — like `resolvedPort`, `isValidPort` and `validPortRange`
    /// below it — because a spawned CLI's environment is built off the main
    /// actor (`ClaudeCodeCLIRuntime.provision`), and it needs this to compose
    /// `KITELOOP_CONTROL_URL` for an operator-tools grant.
    nonisolated static let defaultPort: UInt16 = 4517

    /// Ports the app is willing to bind. The floor is 1024 because a sandboxed,
    /// non-root app cannot bind a privileged port — offering one in Settings would
    /// only produce a server that silently fails to start.
    nonisolated static let validPortRange: ClosedRange<Int> = 1024...65535

    nonisolated static func isValidPort(_ port: Int) -> Bool { validPortRange.contains(port) }

    /// Turns a persisted `controlServerPort` into a port safe to bind. Out-of-range
    /// values fall back to `defaultPort` rather than trapping in `UInt16.init` —
    /// a hand-edited or stale `global-config.json` must not crash the app at launch.
    nonisolated static func resolvedPort(_ persisted: Int?) -> UInt16 {
        guard let persisted, isValidPort(persisted) else { return defaultPort }
        return UInt16(persisted)
    }

    private let registry: ControlSessionRegistry
    /// The fleet-wide hold — "stop taking new work everywhere, and tell me when the
    /// last run has finished". Owned here because the gate it keeps is read on the
    /// path that starts runs, and the autonomous scheduler reaches it through
    /// `isQuiesced` below.
    let fleet: FleetQuiesce
    private var http: HTTPServer?
    /// The one credential that authorizes the whole API. `var` because it can be
    /// rotated while the server runs — replacing it here is what makes a
    /// rotation take effect without a restart.
    private var token: String
    /// The file `token` is read from at launch and written back to on rotation.
    /// Instance state so a test can rotate against a temp file rather than the
    /// developer's real credential.
    private let tokenURL: URL
    /// The second credential the API accepts — authorized for everything the
    /// full token is **except** resolving a human gate (see `ControlRoute.isHumanGate`).
    /// Handed to an agent's environment when its "Operator tools" grant is on
    /// (`ClaudeCodeCLIRuntime.provision`), so a chat agent can do what the
    /// operator's own terminal session does without holding the credential that
    /// can approve its own team's work. Minted the same way as `token`, at
    /// `~/.kiteloop/operator-token`, and not rotatable from here — the file is
    /// simply re-read, so replacing it on disk is enough to change it.
    private let operatorToken: String
    private var runs: [String: RunInfo] = [:]
    /// How each ended run ended, keyed by run id — the autopilot's own result when
    /// there is one, otherwise the ending reconstructed from what the run left
    /// behind. A run is **open** exactly while it has no entry here, so this is
    /// what `running` and `activeRuns` are read from rather than the absence of
    /// evidence. `finalizeEndedRuns()` is the only thing that writes it.
    ///
    /// Nothing is restored at launch: `runs` starts empty after a restart, so no
    /// record can come back claiming to be running a run this process never began.
    /// What a previous process left behind is answered from `runRecords` instead,
    /// which cannot say `running` about anything.
    private var runEndings: [String: BacklogAutopilot.ItemResult] = [:]
    /// Run ids `closeRun`'s fallback closed as a `did-not-run` refusal — the
    /// pickup gates took the item before any work began, so nothing recorded a
    /// real ending. Consulted by both the live `/result` body and `persist`,
    /// so a driver polling mid-session and one reading `GET /v1/runs` after a
    /// restart report the same word for the same run rather than `blocked`,
    /// which a refusal that spent nothing never was.
    private var didNotRunIDs: Set<String> = []
    /// The durable half of a run record: what each run finally was, written where
    /// it survives the app and read back at launch, so a `runId` issued before a
    /// restart still answers instead of 404ing for work that may have merged.
    ///
    /// Optional because only the app attaches one — a test server keeps its runs
    /// in memory alone rather than writing into the developer's real history.
    private let runRecords: RunRecordStore?
    /// What `/health` reads beyond liveness — main-thread latency, resident
    /// memory, subprocess count. Defaulted to the live monitor's own reading;
    /// injected in tests so both the `ok` and `degraded` verdicts can be
    /// asserted without waiting on `HealthMonitor`'s real one-second timer.
    private let healthSnapshotProvider: () -> HealthMonitor.Snapshot
    /// The app-wide learning-engine store, so `GET /v1/metrics` can serve runs
    /// this process never started. Optional because the endpoint is the only
    /// thing that needs it — unattached, it answers 503 rather than an empty list.
    private let metricStore: TaskMetricStore?
    /// The SQLite projection of the same logs, so `GET /v1/metrics` can answer a
    /// `GROUP BY` over the whole history instead of a capped page of records.
    /// Optional and never authoritative: unattached, listing falls back to the
    /// in-memory log and only `?aggregate=` — which has nothing to fall back to —
    /// answers 503.
    private let metricIndex: MetricIndex?
    /// The app-wide grooming ledger, so `GET /v1/grooming` can report what was
    /// filed and what a pre-run check refused. Optional for the same reason the
    /// metric store is — unattached, the endpoint answers 503 rather than an
    /// empty list a caller would read as "nothing was refused".
    private let groomingLedger: GroomingLedger?
    /// The app's one queue-refill loop, so a driver can switch it on, choose its
    /// mode and set the day's grooming ceiling. Optional for the same reason the
    /// metric store is — unattached, the two refill endpoints answer 503 rather
    /// than reporting settings nothing is reading.
    private let injectedQueueRefill: CoordinatorQueueRefill?
    /// The one refill loop, whichever way it was attached — injected at init, or
    /// published onto the registry by the window. Read through here and never
    /// from the two sources directly: reading the injected one in `PUT` and the
    /// registry's in `GET` is how the two endpoints came to disagree about
    /// whether a loop existed at all, answering 200 and 503 for the same app.
    private var queueRefill: CoordinatorQueueRefill? {
        injectedQueueRefill ?? registry.queueRefill
    }
    /// The app's one autonomous run scheduler, so a driver can read what it has
    /// been starting overnight and — the reason it is reachable at all — switch
    /// it off without opening the app. Optional like the loop above: unattached,
    /// the two scheduling endpoints answer 503.
    private let runScheduler: CoordinatorRunScheduler?
    /// When this server was built. The app builds one at launch and keeps it
    /// across Settings toggles, so this is effectively app uptime — which is the
    /// number a driver wants, since a restart is what ends every run in flight
    /// and turns the ones it holds into historical records.
    private let startedAt: Date
    /// The repeating pass that closes ended runs while nobody is asking. Non-nil
    /// exactly while some tracked run is still open — see
    /// `updateFinalizationTicker()`, which is the only thing that sets it.
    private var finalizationTicker: Task<Void, Never>?

    /// How long a finished run's record may stay open before the ticker closes
    /// it. In the same band as the live cost figure, which `snapshotLiveCosts`
    /// notes trails by about as much: a record is durable state, and closing it
    /// within half a minute of the ending is soon enough for anything that reads
    /// the file afterwards.
    #if DEBUG
    /// A `var` under DEBUG only, so a test can watch a tick arrive without
    /// spending half a minute per case.
    static var finalizationInterval: TimeInterval = 30
    #else
    static let finalizationInterval: TimeInterval = 30
    #endif

    /// True only once the current listener has reported `.ready` — never set
    /// just because `HTTPServer.start()` returned without throwing, since the
    /// bind it performs is asynchronous and can still fail or later be
    /// cancelled by the network stack. See `handleListenerState`.
    private(set) var isRunning = false
    private(set) var activePort: UInt16?
    /// The port `start(port:)` was last asked to bind, for as long as the
    /// server is meant to be listening — cleared by `stop()`. What a late or
    /// stray listener callback is checked against, and what a `.failed`
    /// listener restarts on.
    private var desiredPort: UInt16?
    /// Consecutive `.failed` reports for `desiredPort` since the last `.ready`
    /// or `stop()` — what the backoff delay and the retry ceiling below are
    /// read against.
    private var consecutiveListenerFailures = 0
    /// The pending restart after a `.failed` listener, while backoff is still
    /// running its course. At most one is ever outstanding: `stop()` and a
    /// fresh `start(port:)` both cancel it.
    private var listenerRestartTask: Task<Void, Never>?
    /// Why the listener last failed, in one line — what Settings shows under
    /// "Not currently listening" and the give-up notice names beside the port.
    /// Empty while listening or stopped.
    private(set) var lastListenerFailure = ""
    /// Who holds the port the listener was refused, as `PortHolder` describes
    /// it — nil until that lookup answers, and when it found no one.
    private(set) var portHolder: String?
    /// The `PortHolder` lookup for the latest failure, superseded by the next.
    private var portHolderLookup: Task<Void, Never>?
    /// The inbox a give-up is filed in. A closure because the API is app-wide
    /// and an inbox belongs to a project: it is read at the moment of giving
    /// up, not when the server is built, before any project was open.
    private let inbox: @MainActor () -> NotificationStoring?
    /// The give-up notice still standing, and the inbox it went to — what a
    /// later give-up replaces and a listener that comes up resolves.
    private var listenerGaveUpNotice: (id: String, inbox: NotificationStoring)?
    /// The last inbox write about the give-up, so the next waits behind it: a
    /// resolve must not reach the inbox before the notice it resolves.
    private var listenerNoticeWork: Task<Void, Never>?

    /// How many times in a row a failed listener is restarted before giving up
    /// and only logging — bounds a port permanently held by another process to
    /// a fixed number of attempts instead of retrying forever.
    static let maxListenerRestarts = 5

    /// The roll-up key the give-up notice carries: one live row however many
    /// times the listener gives up.
    static let listenerGaveUpRollUpKey = "control-api-gave-up"

    /// The delay before the first restart attempt, doubled for each further
    /// consecutive failure and capped at 30s. `var` under DEBUG only, so a
    /// test can shrink it instead of waiting out real seconds — the same
    /// pattern `finalizationInterval` above uses.
    #if DEBUG
    static var listenerRestartBaseInterval: TimeInterval = 2
    #else
    static let listenerRestartBaseInterval: TimeInterval = 2
    #endif

    private static func listenerRestartDelay(afterFailures count: Int) -> TimeInterval {
        min(30, listenerRestartBaseInterval * pow(2, Double(count - 1)))
    }

    #if DEBUG
    /// Test-only window onto `consecutiveListenerFailures`, so a test can wait
    /// for a bind conflict to actually have been observed before asserting on
    /// `isRunning`, rather than guessing how long that takes.
    var debugConsecutiveListenerFailures: Int { consecutiveListenerFailures }
    #endif

    /// `token`, `tokenURL`, `operatorToken`, `operatorTokenURL` and `startedAt`
    /// are for tests only — production callers omit all five and get the
    /// tokens from `~/.kiteloop/control-token` and `~/.kiteloop/operator-token`,
    /// rotate `token` back into its own file, and start their uptime clock now.
    init(
        registry: ControlSessionRegistry,
        token: String? = nil,
        tokenURL: URL = KiteloopControlServer.defaultTokenURL,
        operatorToken: String? = nil,
        operatorTokenURL: URL = KiteloopControlServer.defaultOperatorTokenURL,
        metricStore: TaskMetricStore? = nil,
        metricIndex: MetricIndex? = nil,
        groomingLedger: GroomingLedger? = nil,
        queueRefill: CoordinatorQueueRefill? = nil,
        runScheduler: CoordinatorRunScheduler? = nil,
        runRecords: RunRecordStore? = nil,
        inbox: (@MainActor () -> NotificationStoring?)? = nil,
        healthSnapshotProvider: @escaping () -> HealthMonitor.Snapshot = HealthMonitor.shared.snapshot,
        deviceTokens: ControlDeviceTokens? = nil,
        accessLog: ControlAccessLog? = nil,
        startedAt: Date = Date()
    ) {
        self.registry = registry
        self.deviceTokens = deviceTokens
        self.accessLog = accessLog
        self.fleet = FleetQuiesce(registry: registry)
        self.tokenURL = tokenURL
        self.token = token ?? Self.loadOrCreateToken(at: tokenURL)
        self.operatorToken = operatorToken ?? Self.loadOrCreateToken(at: operatorTokenURL)
        self.metricStore = metricStore
        self.metricIndex = metricIndex
        self.groomingLedger = groomingLedger
        self.injectedQueueRefill = queueRefill
        self.runScheduler = runScheduler
        self.runRecords = runRecords
        self.healthSnapshotProvider = healthSnapshotProvider
        self.startedAt = startedAt
        // Unless told otherwise, the first open project's inbox — the tab a
        // person sees first, and where the bell is most likely looked at.
        self.inbox = inbox ?? { [registry] in
            registry.openProjects.first?.session.orchestrator.notificationStore
        }
        // Wired here rather than at `start(port:)`: closing a record has nothing
        // to do with whether the API is listening, and a server switched off in
        // Settings still holds the runs it began. Weak, since the registry
        // outlives the server and the server holds the registry.
        registry.finalizeRuns = { [weak self] in await self?.finalizeRunsBeforeProjectCloses() }
        // Same reasoning, same lifetime: a run started from the Autopilot tab has
        // to leave a record whether or not anyone switched the API on, since the
        // record is the only thing that can answer for it afterwards.
        registry.adoptRun = { [weak self] projectID, itemID, title, executionID, startedAt in
            self?.adoptRun(projectID: projectID, itemID: itemID, title: title,
                           executionID: executionID, startedAt: startedAt)
        }
    }

    /// Idempotent: restarts on the given port, applying a changed port if already
    /// running. Safe to call from a Settings toggle.
    ///
    /// `isRunning` does not flip here — `HTTPServer.start()` only constructs the
    /// listener and asks it to bind; the bind itself is asynchronous. It flips
    /// in `handleListenerState` once the listener actually reports `.ready`,
    /// which is also what schedules a bounded-backoff restart if it instead
    /// reports `.failed` while this is still the port asked for.
    func start(port: UInt16) {
        stop()
        desiredPort = port
        consecutiveListenerFailures = 0
        beginListening(port: port)
    }

    /// Tries the port again after the listener gave up — Settings' Retry. The
    /// failure count starts over, so a port that is still held gets the whole
    /// backoff again rather than one attempt. Does nothing once stopped.
    func retryListening() {
        guard let port = desiredPort else { return }
        listenerRestartTask?.cancel()
        listenerRestartTask = nil
        consecutiveListenerFailures = 0
        beginListening(port: port)
    }

    func stop() {
        desiredPort = nil
        listenerRestartTask?.cancel()
        listenerRestartTask = nil
        http?.stop()
        http = nil
        isRunning = false
        activePort = nil
        clearListenerFailure()
    }

    private func clearListenerFailure() {
        portHolderLookup?.cancel()
        portHolderLookup = nil
        lastListenerFailure = ""
        portHolder = nil
    }

    /// Looks up who holds `port`, off the main actor, and keeps the answer
    /// only while that port is still wanted and still not ours.
    private func lookUpPortHolder(port: UInt16) {
        portHolderLookup?.cancel()
        portHolderLookup = Task { @MainActor [weak self] in
            let holder = await Task.detached { PortHolder.describe(PortHolder.listeners(onPort: port)) }.value
            guard !Task.isCancelled, let self, self.desiredPort == port, !self.isRunning else { return }
            self.portHolder = holder
        }
    }

    private func beginListening(port: UInt16) {
        let server = HTTPServer(port: port) { [weak self] request in
            guard let self else { return .error("Server gone", status: 500) }
            return await self.handle(request)
        }
        server.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.handleListenerState(state, port: port)
            }
        }
        do {
            try server.start()
            http = server
            activePort = port
        } catch {
            controlLog.error("failed to start control API: \(String(describing: error), privacy: .public)")
            lastListenerFailure = String(describing: error)
            lookUpPortHolder(port: port)
            isRunning = false
            activePort = nil
            scheduleListenerRestart(afterFailureOn: port)
        }
    }

    /// Reacts to the listener this server currently owns changing state. A
    /// callback naming a port that is no longer `desiredPort` is a straggler
    /// from a listener `stop()` or a fresh `start(port:)` already superseded,
    /// and is ignored — otherwise a `.cancelled` from the listener `stop()`
    /// just tore down could race a later `start(port:)` and clear `isRunning`
    /// for the new one.
    private func handleListenerState(_ state: HTTPServer.ListenerState, port: UInt16) {
        guard desiredPort == port else { return }
        switch state {
        case .ready:
            isRunning = true
            activePort = port
            consecutiveListenerFailures = 0
            clearListenerFailure()
            resolveListenerGaveUpNotice()
            controlLog.info("control API started on 127.0.0.1:\(port, privacy: .public)")
        case .failed(let reason):
            isRunning = false
            lastListenerFailure = reason
            lookUpPortHolder(port: port)
            controlLog.error("control API listener on 127.0.0.1:\(port, privacy: .public) failed: \(reason, privacy: .public)")
            scheduleListenerRestart(afterFailureOn: port)
        case .cancelled:
            isRunning = false
        }
    }

    /// Restarts a listener that just failed, backing off further each
    /// consecutive time — up to `maxListenerRestarts`, past which the failure
    /// is left logged rather than retried forever.
    private func scheduleListenerRestart(afterFailureOn port: UInt16) {
        guard desiredPort == port else { return }
        consecutiveListenerFailures += 1
        guard consecutiveListenerFailures <= Self.maxListenerRestarts else {
            controlLog.error("control API on 127.0.0.1:\(port, privacy: .public) failed \(self.consecutiveListenerFailures, privacy: .public) times in a row; giving up")
            fileListenerGaveUpNotice(port: port)
            return
        }
        let delay = Self.listenerRestartDelay(afterFailures: consecutiveListenerFailures)
        listenerRestartTask?.cancel()
        listenerRestartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.desiredPort == port else { return }
            self.beginListening(port: port)
        }
    }

    /// Says in the inbox that the API stopped trying, naming the port and the
    /// failure. A notice from an earlier give-up is resolved first, even when it
    /// went to another project's inbox, so one row stands however often it
    /// recurs.
    private func fileListenerGaveUpNotice(port: UInt16) {
        guard let store = inbox() else { return }
        let previous = listenerGaveUpNotice
        let item = NotificationItem(
            agentID: "",
            type: .error,
            title: "Control API stopped listening on port \(port)",
            body: "127.0.0.1:\(port) failed \(consecutiveListenerFailures) times in a row — "
                + "\(lastListenerFailure)."
                + (portHolder.map { " Held by \($0)." } ?? "")
                + " Retry from Settings → Control API.",
            rollUpKey: Self.listenerGaveUpRollUpKey)
        listenerGaveUpNotice = (item.id, store)
        let earlier = listenerNoticeWork
        listenerNoticeWork = Task {
            await earlier?.value
            if let previous { await previous.inbox.markResolved(id: previous.id) }
            await store.add(item)
        }
    }

    /// Resolves the give-up notice once a listener is up again.
    private func resolveListenerGaveUpNotice() {
        guard let notice = listenerGaveUpNotice else { return }
        listenerGaveUpNotice = nil
        let earlier = listenerNoticeWork
        listenerNoticeWork = Task {
            await earlier?.value
            await notice.inbox.markResolved(id: notice.id)
        }
    }

    // MARK: - Routing

    /// The in-process transport: a request answered exactly as the socket
    /// answers it — same routing, same auth, same payload — with no socket.
    /// `start(port:)` hands every request off the wire to this same function.
    /// A test that needs the whole path takes the loopback socket through
    /// `ControlServerHarness`; one that needs an endpoint's behaviour calls
    /// this and spends no port, no probe and no retry.
    func handle(_ request: HTTPServer.Request) async -> HTTPServer.Response {
        let started = Date()
        let response = await route(request)
        if let accessLog {
            let credential = credentialName(request)
            let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
            let status = response.status
            Task {
                await accessLog.record(at: started, method: request.method, path: request.path,
                                       credential: credential, status: status, milliseconds: milliseconds)
            }
        }
        return response
    }

    /// Who a request came as, for the access log: a paired phone by its name,
    /// else which shared token, else none.
    private func credentialName(_ req: HTTPServer.Request) -> String {
        switch authScope(req) {
        case .full: return "control"
        case .operatorScoped: return "operator"
        case .paired: return pairedDevice(req)?.name ?? "phone"
        case .none: return "none"
        }
    }

    private func route(_ req: HTTPServer.Request) async -> HTTPServer.Response {
        let matched = ControlRouter.match(method: req.method, path: req.path)
        let scope = authScope(req)

        // Auth is checked before the route is resolved: `/health` is the one
        // unauthenticated probe, and an unmatched path 401s rather than leaking
        // which routes exist. Hence `== false` and not `!= true` — only a route
        // that explicitly opts out skips the token; an unmatched path (`nil`)
        // goes through the scope check like any other.
        guard matched?.requiresAuth == false || scope != .none else {
            return .error("Missing or invalid bearer token", status: 401)
        }
        guard let matched else {
            return .error("No route for \(req.method) \(req.path)", status: 404)
        }

        // The operator token authorizes everything else the API does — every
        // config write, every run, every read — but not this: resolving the
        // human gate stays a person's call, so an agent holding this token
        // cannot approve its own team's work. Checked ahead of the handler
        // rather than inside it, so no approve path can forget the guard.
        if scope == .operatorScoped, matched.isHumanGate {
            return .error(
                "the human gate takes the operator's own token (scope: approve)",
                status: 403
            )
        }

        // Close whatever has ended before any handler reads a run. Done here, once,
        // rather than at each ending: a handler that forgets would leave a record
        // reading `running` for the rest of the app's life, and `/health` counting
        // it. This is also what makes `GET /v1/runs` and `/health` answer from the
        // same set within a request.
        await finalizeEndedRuns()

        return await dispatch(matched, req)
    }

    /// Which area of the API answers this route. Every case of `ControlRoute` is
    /// named here and nowhere else at this level, so the switch is exhaustive and
    /// a route added without an area is a compile error rather than a 404 found
    /// in production. The areas are `ControlRoute`'s own groups: what a request
    /// is *about* — the team, the backlog, autopilot, the fleet, a run — is also
    /// what makes it change, so each area's arms move for one reason.
    private func dispatch(_ route: ControlRoute, _ req: HTTPServer.Request) async -> HTTPServer.Response {
        switch route {
        case .health, .openAPIDocument, .claimPairingCode, .listQuickReplies,
             .registerPushDevice, .registerLiveActivity:
            return await metaRoute(route, req)
        case .listProjects, .openProject, .reorderProjects, .askAboutProject,
             .workspaceChanges, .workspaceFile, .previewScreenshot,
             .hireAgent, .listAgents, .messageAgent, .agentTranscript, .agentEvents,
             .interruptAgent, .answerAgentPlan, .answerAgentQuestion,
             .answerAgentPermission, .answerAgentChoices, .setAgentMode, .listAgentTasks, .stopAgentTask,
             .listMemoryProposals, .approveMemoryProposal, .rejectMemoryProposal:
            return await teamRoute(route, req)
        case .listBacklog, .backlogItemDetail, .backlogItemDiff, .listTemplates,
             .approveBacklogItem, .landBacklogItem, .releaseBacklogItem, .refreshBacklogItem,
             .groomBacklogItem, .moveBacklogItem, .setBacklogItemLane, .stampTemplate, .fileBacklogItem,
             .listMetrics, .listEstimates, .listGrooming, .portfolioReport:
            return await backlogRoute(route, req)
        case .getAutopilot, .setAutopilot, .resetAutopilot, .pauseAutopilot, .resumeAutopilot:
            return await autopilotRoute(route, req)
        case .getCoordinatorRefill, .setCoordinatorRefill,
             .getCoordinatorScheduling, .setCoordinatorScheduling,
             .listProposals, .approveProposal, .dismissProposal:
            return coordinatorRoute(route, req)
        case .fleetStatus, .quiesceFleet, .resumeFleet, .usage:
            return await fleetRoute(route, req)
        case .startRun, .listRuns, .runStatus, .runResult, .runEvents, .runLog,
             .approveRun, .cancelRun, .steerRun:
            return await runsRoute(route, req)
        }
    }

    /// The two routes that describe the API rather than a project: the liveness
    /// probe and the machine-readable document a client generates types from.
    private func metaRoute(_ route: ControlRoute, _ req: HTTPServer.Request) async -> HTTPServer.Response {
        switch route {
        case .health: return health()
        case .openAPIDocument: return openAPIDocument()
        case .claimPairingCode: return claimPairingCode(body: req.body)
        case .listQuickReplies: return .json(["replies": quickReplies()])
        case .registerPushDevice: return await registerPushDevice(req)
        case .registerLiveActivity: return registerLiveActivity(body: req.body)
        default: return Self.notThisArea(route)
        }
    }

    /// The push token of a Live Activity the phone started for a turn, so the
    /// Mac can move it on while the phone sleeps: waiting on you, then done.
    private func registerLiveActivity(body: Data) -> HTTPServer.Response {
        let json = Self.jsonBody(body)
        guard let token = json["token"] as? String, !token.isEmpty, token.allSatisfy(\.isHexDigit),
              let environment = (json["environment"] as? String).flatMap(APNs.Environment.init(rawValue:)),
              let project = json["project"] as? String, let agent = json["agent"] as? String else {
            return .error("Body must include a hex \"token\", \"environment\", \"project\" and \"agent\"", status: 400)
        }
        PushRelay.shared.registerActivity(token: token, environment: environment, project: project, agent: agent)
        return .json(["registered": true])
    }

    /// A phone's push token, kept so the Mac can tell it when an item reaches
    /// the gate, an agent asks something or a turn it started ends. The same
    /// token again replaces its entry.
    private func registerPushDevice(_ req: HTTPServer.Request) async -> HTTPServer.Response {
        let json = Self.jsonBody(req.body)
        guard let token = json["token"] as? String, !token.isEmpty, token.allSatisfy(\.isHexDigit),
              let environment = (json["environment"] as? String).flatMap(APNs.Environment.init(rawValue:)) else {
            return .error("Body must include a hex \"token\" and \"environment\": sandbox or production", status: 400)
        }
        guard let devices = PushRelay.shared.devices else {
            return .error("Pushes are not set up on this Mac", status: 503)
        }
        let name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "iPhone"
        // A paired phone takes the name it reports, in place of "Paired …".
        if let device = pairedDevice(req) { deviceTokens?.rename(device.id, to: name) }
        await devices.register(PushDevice(token: token, environment: environment, name: name, registeredAt: .now))
        var reply: [String: Any] = ["registered": true]
        if let problem = PushRelay.shared.problem { reply["problem"] = problem }
        return .json(reply)
    }

    /// The team and what it works on: the open projects, the agents on them, and
    /// the memory those agents propose back.
    private func teamRoute(_ route: ControlRoute, _ req: HTTPServer.Request) async -> HTTPServer.Response {
        switch route {
        case .listProjects, .openProject, .reorderProjects, .askAboutProject,
             .workspaceChanges, .workspaceFile, .previewScreenshot:
            return await projectsRoute(route, req)
        case .hireAgent, .listAgents, .messageAgent, .agentTranscript, .agentEvents:
            return await agentsRoute(route, req)
        case .interruptAgent, .answerAgentPlan, .answerAgentQuestion:
            return agentSteeringRoute(route, req)
        case .answerAgentPermission, .answerAgentChoices, .setAgentMode, .listAgentTasks, .stopAgentTask:
            return await agentPromptRoute(route, req)
        case .listMemoryProposals:
            return await listMemoryProposals(project: req.query["project"])
        case .approveMemoryProposal:
            return await answerMemoryProposal(body: req.body, approve: true)
        case .rejectMemoryProposal:
            return await answerMemoryProposal(body: req.body, approve: false)
        default:
            return Self.notThisArea(route)
        }
    }

    /// The agents themselves: hiring one, listing them, sending one a message,
    /// and reading back what it said.
    private func agentsRoute(_ route: ControlRoute, _ req: HTTPServer.Request) async -> HTTPServer.Response {
        switch route {
        case .hireAgent: return hireAgent(body: req.body)
        case .listAgents: return listAgents(project: req.query["project"])
        case .messageAgent: return await messageAgent(body: req.body)
        case .agentTranscript: return agentTranscript(query: req.query)
        case .agentEvents: return agentEvents(query: req.query)
        default: return Self.notThisArea(route)
        }
    }

    /// What a session stops to ask, its mode, and the tasks it has running.
    private func agentPromptRoute(_ route: ControlRoute, _ req: HTTPServer.Request) async -> HTTPServer.Response {
        switch route {
        case .answerAgentPermission: return answerAgentPermission(body: req.body)
        case .answerAgentChoices: return answerAgentChoices(body: req.body)
        case .setAgentMode: return await setAgentMode(body: req.body)
        case .listAgentTasks: return listAgentTasks(query: req.query)
        case .stopAgentTask: return stopAgentTask(body: req.body)
        default: return Self.notThisArea(route)
        }
    }

    /// Steering an agent mid-conversation: stopping its turn, answering its
    /// plan card or the question it stopped to ask.
    private func agentSteeringRoute(_ route: ControlRoute, _ req: HTTPServer.Request) -> HTTPServer.Response {
        switch route {
        case .interruptAgent: return interruptAgent(body: req.body)
        case .answerAgentPlan: return answerAgentPlan(body: req.body)
        case .answerAgentQuestion: return answerAgentQuestion(body: req.body)
        default: return Self.notThisArea(route)
        }
    }

    /// The backlog, in the three ways it is touched: reading the queue, moving an
    /// item through it, and reading what the queue has already produced.
    private func backlogRoute(_ route: ControlRoute, _ req: HTTPServer.Request) async -> HTTPServer.Response {
        switch route {
        case .listBacklog, .backlogItemDetail, .backlogItemDiff, .listTemplates:
            return await backlogReadRoute(route, req)
        case .approveBacklogItem, .landBacklogItem, .releaseBacklogItem, .refreshBacklogItem,
             .groomBacklogItem, .moveBacklogItem, .setBacklogItemLane, .stampTemplate, .fileBacklogItem:
            return await backlogWriteRoute(route, req)
        case .listMetrics, .listEstimates, .listGrooming, .portfolioReport:
            return await backlogHistoryRoute(route, req)
        default:
            return Self.notThisArea(route)
        }
    }

    /// Reads over the queue as it stands: the items, one item's detail or diff,
    /// and the templates an item can be stamped from.
    private func backlogReadRoute(_ route: ControlRoute, _ req: HTTPServer.Request) async -> HTTPServer.Response {
        switch route {
        case .listBacklog: return await listBacklog(project: req.query["project"])
        case .backlogItemDetail: return backlogItemDetail(query: req.query)
        case .backlogItemDiff: return await backlogItemDiff(query: req.query)
        case .listTemplates: return listTemplates(project: req.query["project"])
        default: return Self.notThisArea(route)
        }
    }

    /// Writes that move an item through the queue — the human gate, releasing a
    /// held item, regrooming one, reordering, and filing new ones.
    private func backlogWriteRoute(_ route: ControlRoute, _ req: HTTPServer.Request) async -> HTTPServer.Response {
        switch route {
        case .approveBacklogItem, .landBacklogItem: return await backlogGateRoute(route, req)
        case .releaseBacklogItem: return releaseBacklogItem(body: req.body)
        case .refreshBacklogItem: return await refreshBacklogItem(body: req.body)
        case .groomBacklogItem: return groomBacklogItem(body: req.body)
        case .moveBacklogItem: return moveBacklogItem(body: req.body)
        case .setBacklogItemLane: return setBacklogItemLane(body: req.body)
        case .stampTemplate, .fileBacklogItem: return await backlogFilingRoute(route, req)
        default: return Self.notThisArea(route)
        }
    }

    /// The two ways new work is filed: a template's items, or one by hand.
    private func backlogFilingRoute(_ route: ControlRoute, _ req: HTTPServer.Request) async -> HTTPServer.Response {
        switch route {
        case .stampTemplate: return await stampTemplate(body: req.body)
        case .fileBacklogItem: return fileBacklogItem(body: req.body)
        default: return Self.notThisArea(route)
        }
    }

    /// The two verbs that put work in the base: resolving the gate, and
    /// landing a done item's branch the gate left behind.
    private func backlogGateRoute(_ route: ControlRoute, _ req: HTTPServer.Request) async -> HTTPServer.Response {
        switch route {
        case .approveBacklogItem: return await approveBacklogItem(body: req.body)
        case .landBacklogItem: return await landBacklogItem(body: req.body)
        default: return Self.notThisArea(route)
        }
    }

    /// What the queue has produced: the run metrics, the estimates and grooming
    /// records behind them, and the portfolio report over a window.
    private func backlogHistoryRoute(_ route: ControlRoute, _ req: HTTPServer.Request) async -> HTTPServer.Response {
        switch route {
        case .listMetrics:
            return await listMetrics(project: req.query["project"], limit: req.query["limit"],
                                     aggregate: req.query["aggregate"])
        case .listEstimates:
            return listEstimates(project: req.query["project"], limit: req.query["limit"])
        case .listGrooming:
            return listGrooming(project: req.query["project"], limit: req.query["limit"])
        case .portfolioReport:
            return portfolioReport(hours: req.query["hours"])
        default:
            return Self.notThisArea(route)
        }
    }

    /// One project's autopilot: its configuration, and whether its queue is
    /// picking work up at all.
    private func autopilotRoute(_ route: ControlRoute, _ req: HTTPServer.Request) async -> HTTPServer.Response {
        switch route {
        case .getAutopilot: return await getAutopilot(project: req.query["project"])
        case .setAutopilot: return setAutopilot(body: req.body)
        case .resetAutopilot: return resetAutopilot(body: req.body)
        case .pauseAutopilot: return pauseAutopilot(body: req.body)
        case .resumeAutopilot: return resumeAutopilot(body: req.body)
        default: return Self.notThisArea(route)
        }
    }

    /// The coordinator's settings — how the queue is refilled and when it runs —
    /// and the proposal routes that used to sit beside them.
    private func coordinatorRoute(_ route: ControlRoute, _ req: HTTPServer.Request) -> HTTPServer.Response {
        switch route {
        case .getCoordinatorRefill: return coordinatorRefill(limit: req.query["limit"])
        case .setCoordinatorRefill: return setCoordinatorRefill(body: req.body)
        case .getCoordinatorScheduling: return coordinatorScheduling(limit: req.query["limit"])
        case .setCoordinatorScheduling: return setCoordinatorScheduling(body: req.body)
        case .listProposals, .approveProposal, .dismissProposal: return Self.proposalsGone
        default: return Self.notThisArea(route)
        }
    }

    /// The fleet-wide quiesce: what is still in flight, holding new work back,
    /// and letting it through again.
    private func fleetRoute(_ route: ControlRoute, _ req: HTTPServer.Request) async -> HTTPServer.Response {
        switch route {
        case .fleetStatus: return await fleetStatus()
        case .quiesceFleet: return await quiesceFleet(body: req.body)
        case .resumeFleet: return await resumeFleet()
        case .usage: return usage()
        default: return Self.notThisArea(route)
        }
    }

    /// The window `GET /v1/usage` reports spend over: the day the shared
    /// daily budget covers.
    private static let usageHours = 24

    /// `GET /v1/usage`: how close the agents are to their rate limit, and
    /// where the last day's spend went.
    private func usage() -> HTTPServer.Response {
        let readings = registry.openProjects.flatMap { entry in
            entry.session.chatViewModels.values.compactMap { $0.agentActivity.rateLimit }
        }
        return .json([
            "rateLimit": UsageSummary.closest(readings).map(Self.rateLimitJSON) as Any? ?? NSNull(),
            "agentsReporting": readings.count,
            "spend": usageSpendJSON() as Any? ?? NSNull()
        ])
    }

    private static func rateLimitJSON(_ reading: AgentActivityEvent.RateLimitInfo) -> [String: Any] {
        [
            "status": reading.status,
            "window": reading.window ?? NSNull(),
            "resetsAt": reading.resetsAt.map { iso.string(from: $0) } ?? NSNull(),
            "utilization": reading.utilization ?? NSNull()
        ]
    }

    /// The last day's spend per project, off the same report `GET /v1/report`
    /// serves; nil on a server that keeps no metrics.
    private func usageSpendJSON() -> [String: Any]? {
        guard let metricStore, let groomingLedger else { return nil }
        let report = PortfolioReport.make(runs: metricStore.records, grooming: groomingLedger.records,
                                          period: .last(hours: Self.usageHours, endingAt: Date()))
        return [
            "hours": Self.usageHours,
            "totalUSD": report.total.spendUSD,
            "projects": report.rows.map { ["project": $0.projectName, "spendUSD": $0.spendUSD] },
            "omittedProjects": report.omittedProjects
        ]
    }

    /// Runs, split by what a caller is doing: watching one, or driving it.
    private func runsRoute(_ route: ControlRoute, _ req: HTTPServer.Request) async -> HTTPServer.Response {
        switch route {
        case .listRuns, .runStatus, .runResult, .runEvents, .runLog:
            return await runReadRoute(route, req)
        case .startRun, .approveRun, .cancelRun, .steerRun:
            return await runCommandRoute(route, req)
        default:
            return Self.notThisArea(route)
        }
    }

    /// Watching runs: the list, and one run's status, result, events or log.
    private func runReadRoute(_ route: ControlRoute, _ req: HTTPServer.Request) async -> HTTPServer.Response {
        switch route {
        case .listRuns:
            return listRuns(project: req.query["project"], limit: req.query["limit"])
        case .runStatus(let runID): return await runStatus(runId: runID)
        case .runResult(let runID): return await runResult(runId: runID)
        case .runEvents(let runID): return runEvents(runId: runID)
        case .runLog(let runID): return runLog(runId: runID, limit: req.query["limit"])
        default: return Self.notThisArea(route)
        }
    }

    /// Driving runs: starting one, clearing its human gate, cancelling it, and
    /// steering one that is still going.
    private func runCommandRoute(_ route: ControlRoute, _ req: HTTPServer.Request) async -> HTTPServer.Response {
        switch route {
        case .startRun: return await startRun(body: req.body)
        case .approveRun(let runID): return await approveRun(runId: runID, body: req.body)
        case .cancelRun(let runID): return await cancelRun(runId: runID)
        case .steerRun(let runID): return steerRun(runId: runID, body: req.body)
        default: return Self.notThisArea(route)
        }
    }

    /// The `default` arm every area handler needs and none of them can reach:
    /// `dispatch(_:_:)` is exhaustive over `ControlRoute` and sends each route to
    /// exactly one area, so this fires only if an area's own switch were to lose
    /// an arm the dispatch still points at it.
    private static func notThisArea(_ route: ControlRoute) -> HTTPServer.Response {
        .error("No handler for \(route)", status: 500)
    }

    /// The unauthenticated liveness probe: is the app up, which build, and how
    /// much of what a driver holds is still valid — a restart resets
    /// `uptimeSeconds` and turns every run that was in flight into an
    /// `interrupted` record.
    ///
    /// `status` is what tells a wedged app from a busy one: `"ok"` beside "ok" is
    /// indistinguishable from a working app, which is what a headless driver
    /// used to have to wait 20 minutes of no progress to rule out. It reads
    /// `"degraded"` at or above `HealthMonitor.hitchThresholdMs` of the latest
    /// main-thread latency reading — the same threshold the monitor itself logs
    /// a hitch at — and `"ok"` below it.
    ///
    /// `holds` is the other standing question a watcher has: **is anything not
    /// starting, and why?** An autonomous hold used to be visible only on the
    /// sidebar of a window nobody was in front of, which is how one project's
    /// three retries stopped the fleet for six hours on 2026-08-12 without
    /// anything saying so. Empty is the healthy state and the shipped one.
    private func health() -> HTTPServer.Response {
        let snapshot = healthSnapshotProvider()
        let degraded = snapshot.mainThreadLatencyMs >= HealthMonitor.hitchThresholdMs
        return .json([
            "status": degraded ? "degraded" : "ok",
            "version": Self.appVersion,
            "apiVersion": ControlRouter.apiVersion,
            "uptimeSeconds": max(0, Int(Date().timeIntervalSince(startedAt))),
            "projectsOpen": registry.entries.count,
            "activeRuns": activeRunCount,
            "mainThreadLatencyMs": snapshot.mainThreadLatencyMs,
            "hitchCount": snapshot.hitches.count,
            "processMemoryMB": snapshot.processMemoryMB as Any,
            "activeSubprocessCount": snapshot.activeSubprocessCount,
            "holds": (runScheduler?.holds.active ?? []).map(Self.holdJSON),
            "tools": registry.openProjects.map { Self.toolsJSON($0.session.toolReachability()) }
        ])
    }

    /// One open project's verify tools: where each resolved, or — with `path`
    /// null — the directories the app searched for it. **Which tools can this
    /// app reach for this project, and where?** used to be answerable only by
    /// a refused run: a `cargo` verify refused at grooming and a `lizard`
    /// invisible at the merge gate on 2026-09-03, both installed. `exports`
    /// is what every verify and spawn on the project's behalf runs with
    /// beyond `PATH` — the shared build output (`BuildEnvironment`).
    private static func toolsJSON(_ report: ToolReachability.ProjectReport) -> [String: Any] {
        [
            "project": report.project,
            "path": report.path,
            "tools": report.tools.map { row -> [String: Any] in
                var json: [String: Any] = ["name": row.name, "path": row.path as Any]
                if row.path == nil { json["searched"] = row.searched }
                return json
            },
            "exports": report.exports.map { ["name": $0.name, "value": $0.value] }
        ]
    }

    /// One autonomous hold: which project is not starting runs, and why — the
    /// hold's own reason, which names the evidence and what would end it.
    private static func holdJSON(_ hold: RunScheduling.ProjectHold) -> [String: Any] {
        [
            "project": hold.project,
            "path": hold.path,
            "reason": hold.reason,
            "failures": hold.failures.count,
            "items": hold.itemCount,
            // Whether it is the same-cause kind. It matters to a reader: an
            // ordinary hold ends when the project's queue changes, and this one
            // does not — it waits on the autopilot config, the global config or
            // a human.
            "systemic": hold.isSystemic
        ]
    }

    /// The API describing itself: an OpenAPI 3.1 document generated from
    /// `ControlRouter.table`, so a client generating types from it is reading the
    /// endpoints this build actually answers rather than a checked-in file that
    /// went stale. Stamped with the running app's version and the port this server
    /// is bound to, so `servers[0].url` is usable as it stands.
    private func openAPIDocument() -> HTTPServer.Response {
        .json(ControlAPISpec.document(version: Self.appVersion, port: activePort ?? Self.defaultPort))
    }

    /// The phones paired with a token each (Settings → Control API → Paired
    /// phones); nil for a server that keeps none, as tests build by default.
    let deviceTokens: ControlDeviceTokens?
    /// One line per request in `~/.kiteloop/logs/control-access.log`; nil for
    /// a server that keeps none, as tests build by default.
    private let accessLog: ControlAccessLog?

    var pairedPhones: [ControlDevice] { deviceTokens?.devices ?? [] }

    /// A one-time code for the pairing QR; nil when this server keeps no
    /// device tokens. Nothing is paired until a phone claims it.
    func offerPairingCode() -> String? {
        deviceTokens?.offer()
    }

    /// Takes a code off offer — the pairing sheet closing.
    func withdrawPairingCode(_ code: String) {
        deviceTokens?.withdraw(code: code)
        pairingClaims[code] = nil
    }

    /// The one-tap replies `GET /v1/quick-replies` serves. The app points it
    /// at Settings at launch; a server nobody configured offers the starters.
    var quickReplies: @MainActor () -> [String] = { QuickReplies.starters }

    /// The phone each claimed code paired, by the name it sent, so the sheet
    /// showing a code can say it has been used.
    private(set) var pairingClaims: [String: String] = [:]

    /// `POST /v1/pair`: a code on offer, traded once for the phone's own token.
    private func claimPairingCode(body: Data) -> HTTPServer.Response {
        let json = Self.jsonBody(body)
        guard let code = json["code"] as? String, !code.isEmpty else {
            return .error("Body must include the pairing \"code\"", status: 400)
        }
        guard let deviceTokens else { return .error("This Mac keeps no paired phones", status: 404) }
        let sent = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = sent.isEmpty ? "Paired \(Date.now.formatted(date: .abbreviated, time: .shortened))" : sent
        guard let (token, device) = deviceTokens.claim(code: code, name: name) else {
            return .error("That pairing code is not on offer — show a new one on the Mac", status: 403)
        }
        pairingClaims[code] = device.name
        return .json(["token": token, "device": device.id.uuidString])
    }

    func revokePhone(_ id: UUID) {
        deviceTokens?.revoke(id)
    }

    /// The paired phone a request's bearer token belongs to, if it is one.
    private func pairedDevice(_ req: HTTPServer.Request) -> ControlDevice? {
        guard let header = req.header("Authorization"), header.hasPrefix("Bearer ") else { return nil }
        return deviceTokens?.device(for: String(header.dropFirst("Bearer ".count)))
    }

    /// Which of the API's credentials, if any, this request carries.
    private enum AuthScope {
        /// The full control token — every endpoint.
        case full
        /// A paired phone's own token — every endpoint, as the full token.
        case paired
        /// The operator-scoped token — every endpoint except a human gate.
        case operatorScoped
        /// No valid credential.
        case none
    }

    private func authScope(_ req: HTTPServer.Request) -> AuthScope {
        guard let header = req.header("Authorization") else { return .none }
        // Exact, full-string comparison against both credentials; localhost-scoped
        // so timing isn't a real threat.
        if header == "Bearer \(token)" { return .full }
        if header == "Bearer \(operatorToken)" { return .operatorScoped }
        if pairedDevice(req) != nil { return .paired }
        return .none
    }

    // MARK: - Read endpoints

    /// Every open project, what it is configured for, what it is doing — and what
    /// it has left to do, so "what is the fleet up to?" is one call rather than
    /// one per project.
    ///
    /// `queue` is the second half of that question. The run state says what is in
    /// flight; without a depth alongside it, a project that has finished its work
    /// and one whose queue is nothing but ungroomed drafts both read as "idle",
    /// and finding out which cost a `GET /v1/backlog` per project.
    private func listProjects() async -> HTTPServer.Response {
        var projects: [[String: Any]] = []
        for entry in registry.openProjects {
            let name = entry.session.project.rootURL.lastPathComponent
            let queue = Self.queueJSON(Self.judgedBacklog(entry.session.backlogViewModel),
                                       refusedAtGate: Self.refusedAtGateCount(entry.session.backlogViewModel))
            let gateDetail = RunScheduling.gateFullDetail(
                project: name, awaitingApproval: queue["awaitingApproval"] as? Int ?? 0,
                approveReviewPassedRuns: entry.autopilot.approveReviewPassedRuns,
                policy: queueRefill?.policy ?? .default)
            projects.append([
                "id": entry.session.project.id,
                "name": name,
                "path": entry.session.project.rootURL.path(percentEncoded: false),
                "autopilotReady": entry.autopilot.workerAgentID != nil && entry.autopilot.reviewerAgentID != nil,
                "gate": Self.projectGateJSON(entry.session.backlogViewModel) as Any,
                "baseBranch": await Self.effectiveBaseBranch(entry) as Any,
                "unattendedPermissions": "auto",
                "paused": Self.isPaused(entry),
                "run": await Self.runState(entry.autopilot, clearingInconsistencyVia: "GET /v1/projects"),
                "queue": queue,
                // Null while the gate isn't full — the same reading `/health`'s
                // `holds` and `GET /v1/coordinator/scheduling`'s `lastDecision`
                // give any other hold, computed the same way the scheduler's own
                // eligibility pass computes it (`RunScheduling.gateFullDetail`),
                // so this can never disagree with why a tick actually held.
                "hold": gateDetail.map { ["kind": "gateFull", "reason": $0] } as Any
            ])
        }
        return .json(["projects": projects])
    }

    /// The branch this project's runs fork from and land on, resolved: the
    /// configured `baseBranch` when there is one, otherwise the branch the
    /// checkout is on right now — which is what a nil setting means. Null when
    /// neither answers: the root is not a git repository, or its `HEAD` is
    /// detached. `GET /v1/autopilot` reports the setting as written; this is
    /// the one place a driver can read what a run would actually use, so
    /// "run on `quality/rebased`" can be checked against the project it names
    /// instead of against a second registration of the same checkout.
    private static func effectiveBaseBranch(_ entry: ControlSessionRegistry.Entry) async -> String? {
        if let configured = entry.autopilot.baseBranch { return configured }
        let root = entry.session.project.rootURL
        guard WorktreeManager.isGitRepository(at: root) else { return nil }
        let name = await WorktreeManager(projectRoot: root).currentBranchName()
        return name.isEmpty || name == "HEAD" ? nil : name
    }

    /// Whether this project's queue is held — by the human's paused switch on
    /// the fleet board or by `BacklogAutopilot.pause()` (`POST
    /// /v1/autopilot/pause`) — the one condition `startRun` refuses over and
    /// `GET /v1/projects` reports as `paused`, and what `GET /v1/autopilot`
    /// answers with too. Pausing is one act now: either cause reads the same to
    /// every caller — and a pause taken over an item in flight keeps reading
    /// `true` after that item finishes, since the hold is the autopilot's
    /// `queueHeld` rather than the ending run's status.
    private static func isPaused(_ entry: ControlSessionRegistry.Entry) -> Bool {
        entry.session.project.loadConfig().paused == true
            || entry.autopilot.isHoldingQueue
    }

    /// How deep the project's queue is, by the statuses a driver acts on.
    ///
    /// `runnable` is the one that decides anything: `ready` counts items somebody
    /// *called* ready, and the gap between the two is exactly the ungroomed work
    /// autopilot would skip. Counted off the same Definition-of-Ready verdicts
    /// `GET /v1/backlog` reports per item, so the two endpoints cannot come to
    /// disagree about grooming — see `judgedBacklog`. It is the grooming gate
    /// alone: `GET /v1/backlog`'s `ready` also subtracts the items the retry
    /// ceiling has retired, which needs the run ledger this count does not read.
    ///
    /// Every field is always present. A project with no backlog, or one the
    /// parser could make nothing of, reports zeros: an omitted block reads as a
    /// build too old to count rather than as a queue with nothing in it.
    private static func queueJSON(_ judged: [JudgedItem], refusedAtGate: Int = 0) -> [String: Any] {
        var counts: [BacklogItemStatus: Int] = [:]
        for entry in judged { counts[entry.item.status, default: 0] += 1 }
        return [
            "ready": counts[.ready] ?? 0,
            "runnable": judged.filter { $0.verdict?.isReady == true }.count,
            "draft": counts[.draft] ?? 0,
            "active": counts[.active] ?? 0,
            "inReview": counts[.inReview] ?? 0,
            "awaitingApproval": counts[.awaitingApproval] ?? 0,
            "refusedAtGate": refusedAtGate,
            "blocked": counts[.blocked] ?? 0
        ]
    }

    /// Of the items at `awaiting-approval`, how many the merge gate already
    /// ran against and refused — the same `GateState` each item's own row
    /// reports. A driver counting its night used to read every one of these
    /// as a decision it was waiting on a person for.
    private static func refusedAtGateCount(_ backlogViewModel: BacklogViewModel) -> Int {
        (backlogViewModel.backlogFile?.sections.flatMap(\.items) ?? [])
            .count { backlogViewModel.gateState(for: $0)?.kind == .refused }
    }

    /// One backlog item with the Definition-of-Ready verdict on it, and the epic
    /// it sits under.
    private struct JudgedItem {
        let epic: String
        let item: BacklogItem
        /// Nil for anything that isn't `ready` — see `judgedBacklog`.
        let verdict: DefinitionOfReady.Verdict?
        /// The groomed detail the verdict was read from, kept rather than
        /// discarded so the retry ceiling can fingerprint the item's spec
        /// without parsing the same file off disk a second time. Nil for the
        /// same items `verdict` is, and for a `ready` item with no detail file.
        var detail: BacklogItemDetail?
    }

    /// The project's backlog flattened across epics in file order, each item
    /// carrying the gate's verdict on it.
    ///
    /// The single grooming path both `listBacklog` and `listProjects` read, so
    /// the per-item `ready` flag and the listing's `queue.runnable` count are the
    /// same answer rather than two derivations that can drift apart. The verdict
    /// is `DefinitionOfReady`'s own — the gate `BacklogAutopilot` filters its
    /// queue with — so a rule change there reaches both endpoints untouched.
    /// The retry ceiling, autopilot's *other* pickup gate, is applied on top of
    /// this by `listBacklog` alone: it is judged from the run ledger rather than
    /// from the backlog file, and only that handler holds one.
    ///
    /// Only `ready` items are judged. `loadDetail` parses a file off disk per
    /// item, and pickup readiness is a meaningless question for a `done`,
    /// `blocked` or `draft` one — inventing a verdict for it would be noise.
    private static func judgedBacklog(_ backlogViewModel: BacklogViewModel) -> [JudgedItem] {
        let sections = backlogViewModel.backlogFile?.sections ?? []
        // Resolved across every epic, since sequencing routinely crosses them.
        let dependencies = DefinitionOfReady.Dependencies(items: sections.flatMap(\.items))
        return sections.flatMap { section in
            section.items.map { item in
                guard item.status == .ready else {
                    return JudgedItem(epic: section.name, item: item, verdict: nil)
                }
                let detail = backlogViewModel.loadDetail(for: item)
                return JudgedItem(
                    epic: section.name, item: item,
                    verdict: DefinitionOfReady.evaluate(
                        item: item, detail: detail, dependencies: dependencies),
                    detail: detail)
            }
        }
    }

    /// The project's backlog, flattened across epics — and, for the items a run
    /// could actually be started on, whether autopilot would take them.
    ///
    /// An item triaged to `ready` but never groomed is indistinguishable from a
    /// runnable one by id/title/status alone, so a headless driver used to find
    /// out by posting a run and reading back the generic 422. `ready`/`notReady`
    /// answer that before anything is started, straight from
    /// `DefinitionOfReady` via `judgedBacklog` — the same gate `BacklogAutopilot`
    /// filters its queue with, and the same verdicts `GET /v1/projects` counts
    /// its `queue.runnable` off, so a rule change there shows up here without
    /// touching this handler and the two endpoints cannot come to disagree about
    /// what runnable means.
    ///
    /// Grooming is only half of what pickup asks, though, so `retired` reports
    /// the other half: `RetryCeiling`'s verdict on the item's recorded history.
    /// A groomed item whose last few attempts all produced nothing is refused at
    /// pickup exactly like an ungroomed one, and reporting it `"ready": true`
    /// left a headless driver posting runs autopilot silently declined — the
    /// same "find out by starting it" loop `ready`/`notReady` removed for
    /// grooming. Judged with the release and the spec fingerprint pickup judges
    /// it with (`BacklogAutopilot.retryCeilingVerdict`), so an item a human
    /// released, or one rewritten since its empty attempts, reads runnable here
    /// the moment it is runnable there.
    ///
    /// `strandedWork` answers the opposite end of the item's life: which `done`
    /// items never actually merged. See `StrandedWorkSweep` for why that costs a
    /// bounded number of git calls rather than one per done item, and why it
    /// reports rather than merges.
    private func listBacklog(project: String?) async -> HTTPServer.Response {
        guard let project else { return .error("Missing ?project=", status: 400) }
        guard let entry = registry.entry(forProject: project) else {
            return .error("Project not open in Kiteloop: \(project)", status: 409)
        }
        let backlogViewModel = entry.session.backlogViewModel
        let judged = Self.judgedBacklog(backlogViewModel)
        // The ledger the ceiling is counted from, read once for the whole
        // listing rather than per item. Nil without a metric store: nothing has
        // recorded an attempt this build can see, and counting an empty history
        // would answer "never retired" as if it had been asked.
        let projectPath = entry.session.project.rootURL.path(percentEncoded: false)
        let ceilingRecords = metricStore?.records
        let items = judged.map { judgedItem -> [String: Any] in
            let item = judgedItem.item
            var json: [String: Any] = [
                "id": item.id,
                "title": item.title,
                "epic": judgedItem.epic,
                "status": item.status.rawValue,
                "size": item.size?.rawValue as Any, "lane": item.lane.rawValue
            ]
            // Lineage, when the item records any: enough for a driver to
            // group children under the item they came out of without
            // re-reading BACKLOG.md itself.
            if let from = item.from { json["from"] = from }
            // Sequencing, as written on the line — reported for every item
            // rather than only the `ready` ones, because it is a fact about
            // the item and not a verdict on it.
            if !item.needs.isEmpty { json["needs"] = item.needs }
            // Whether this item's branch still merges onto the project's
            // current base — present only at the gate, where the question
            // means anything, and only once something has actually checked
            // (a live-tree project, or one whose gate item predates this
            // build, has nothing cached yet).
            json.merge(Self.gateFields(item: item, backlog: backlogViewModel)) { _, new in new }
            if let verdict = judgedItem.verdict {
                // The retry ceiling, on the same items the grooming gate judges
                // and no others: it is a verdict on attempts at picking the item
                // up, which is a question only a `ready` item is asked.
                let ceiling = ceilingRecords.map { records in
                    RetryCeiling.evaluate(
                        itemID: item.id, projectPath: projectPath, records: records,
                        releasedAt: groomingLedger?.latestRelease(itemID: item.id,
                                                                 projectPath: projectPath),
                        specFingerprint: RetryCeiling.specFingerprint(
                            item: item, detail: judgedItem.detail))
                }
                json["ready"] = verdict.isReady && !(ceiling?.isRetired ?? false)
                // Named separately from the grooming clauses, and after them: an
                // item can be both ungroomed and retired, and the two ask for
                // different work — one is a section to write, the other a
                // release or a rewrite.
                var reasons = verdict.reasons
                if let ceiling, ceiling.isRetired { reasons.append(ceiling.summary) }
                if !reasons.isEmpty { json["notReady"] = reasons }
                if let ceiling {
                    // `retired` only when it is, like `notReady` — but the count
                    // whenever it is known, so a driver can see a streak building
                    // towards the ceiling rather than only the moment it lands.
                    if ceiling.isRetired { json["retired"] = true }
                    json["noWorkAttempts"] = ceiling.noWorkAttempts
                }
            }
            return json
        }
        // The lines the parser refused, alongside the ones it accepted. Without
        // them a headless driver reads a backlog shorter than the file and takes
        // the difference for work that does not exist — the panel has shown this
        // as a banner since `BacklogParseIssue` landed. Always present, so an
        // empty array distinguishes a clean file from a build that never
        // reported them.
        let issues = backlogViewModel.parseIssues.map { issue -> [String: Any] in
            ["line": issue.line, "text": issue.text, "reason": issue.reason]
        }
        // Done items whose work never left a branch. Kiteloop has been able to
        // tell for one item at a time since `ItemDisagreements` landed, in a view
        // a person has to open — so the answer existed and nobody was given it,
        // and two items were eventually found by walking the branch list by hand.
        // Reported here because this is where an unattended driver already looks.
        //
        // `statusByItemID` and `inFlightItemID` are for the sweep's other pass —
        // a worktree dirty for an item nothing is coming back for — which needs
        // to tell a run in flight and a `blocked` worktree kept for inspection
        // (both normal) apart from every other stage (not).
        let strandedWork = await StrandedWorkSweep.read(
            projectRoot: entry.session.project.rootURL,
            doneItemIDs: judged.filter { $0.item.status == .done }.map(\.item.id),
            // Not `uniqueKeysWithValues`: a malformed backlog can parse two lines
            // to the same id (`issues` reports the line, but the item still
            // reaches here) — last one wins rather than crashing the listing.
            statusByItemID: Dictionary(judged.map { ($0.item.id, $0.item.status) }, uniquingKeysWith: { _, new in new }),
            inFlightItemID: await entry.autopilot.inFlightRun()?.itemID)
        return .json(["project": entry.session.project.rootURL.lastPathComponent,
                      "items": items, "issues": issues,
                      "strandedWork": Self.strandedWorkJSON(strandedWork)])
    }

    /// The sweep as the API reports it. Never an action — the finding is put in
    /// front of a person, and merging a branch this old is exactly the decision
    /// that needs one.
    private static func strandedWorkJSON(_ report: StrandedWorkReport) -> [String: Any] {
        var json: [String: Any] = [
            "count": report.count,
            // Always present, so "asked, and nothing is stranded" cannot be read
            // off a response that means "could not ask".
            "unreadable": report.unreadable,
            "doneItemsConsidered": report.doneItemsConsidered,
            "branchesExamined": report.branchesExamined,
            // The second pass: done items the branch listing did not name, whose
            // ref the sweep read to tell a branch tidied away after a merge from
            // one teardown dropped over unmerged work.
            "danglingCandidatesExamined": report.danglingCandidatesExamined,
            "items": report.stranded.map { item -> [String: Any] in
                var itemJSON: [String: Any] = [
                    "id": item.itemID, "branch": item.branch, "commitsAhead": item.commitsAhead,
                    "ledgerSays": item.ledgerSays, "gitSays": item.gitSays
                ]
                // Only the dirty-worktree finding carries these — the branch and
                // dangling-commit findings above are about a ref, not a directory.
                if let worktreePath = item.worktreePath { itemJSON["worktreePath"] = worktreePath }
                if let uncommittedFiles = item.uncommittedFiles {
                    itemJSON["uncommittedFiles"] = uncommittedFiles
                }
                return itemJSON
            }
        ]
        if report.unreadable { json["reason"] = StrandedWorkReport.unreadableReason }
        // Only when a budget actually bit. A sweep that stopped early must not
        // read like one that finished — either pass.
        if report.branchesNotExamined > 0 { json["branchesNotExamined"] = report.branchesNotExamined }
        if report.danglingCandidatesNotExamined > 0 {
            json["danglingCandidatesNotExamined"] = report.danglingCandidatesNotExamined
        }
        return json
    }

    /// Recent measured runs, newest first — the durable counterpart to
    /// `GET /v1/runs`, which only knows the runs this process started and forgets
    /// them on restart. One record is appended to `~/.kiteloop/task-metrics.jsonl`
    /// every time an item finishes, carrying what the SLO scorecard is scored on:
    /// duration, cost, rework loops, outcome and the advisory quality score.
    ///
    /// `?project=` narrows to one project (which must be open, as elsewhere);
    /// without it the records span every project the app has ever run.
    ///
    /// `?aggregate=` answers with a `GROUP BY` over the whole history instead of
    /// a page of records — see `aggregateMetrics`. The `limit` cap exists to stop
    /// a poller dragging a growing log through the socket every tick, and an
    /// aggregate returns a handful of groups however many runs went into them, so
    /// it is not capped at all.
    private func listMetrics(project: String?, limit: String?,
                             aggregate: String?) async -> HTTPServer.Response {
        guard let metricStore else {
            return .error("Metrics are unavailable — no metric store attached", status: 503)
        }
        guard let limit = Self.parseHistoryLimit(limit) else {
            return .error("\"limit\" must be an integer in \(Self.historyLimitRange)", status: 400)
        }
        var projectName: String?
        var projectID: String?
        if let project {
            guard let entry = registry.entry(forProject: project) else {
                return .error("Project not open in Kiteloop: \(project)", status: 409)
            }
            // Records store the raw root path; the registry keys on the canonical one.
            projectID = entry.session.project.id
            projectName = entry.session.project.rootURL.lastPathComponent
        }

        if let aggregate, !aggregate.isEmpty {
            return await aggregateMetrics(aggregate, projectID: projectID, projectName: projectName)
        }

        let page = await listedRuns(store: metricStore, projectID: projectID, limit: limit)
        var body: [String: Any] = [
            "count": page.records.count,
            "metrics": page.records.map(Self.metricJSON),
            // Whole-history, not limited to the records above: the rate is about
            // every approval this project ever made, not the last `limit` runs.
            "escapedDefects": Self.escapedDefectJSON(page.escapedDefects),
            // Whole-history for the same reason, over every run ever judged.
            "firstPassRate": Self.firstPassJSON(page.firstPass),
            // Over the records above and no further — unlike the two rates, this
            // is a distribution, and one taken over all history would answer for
            // a CLAUDE.md and a knowledge package that have since changed. Widen
            // or narrow the window with `?limit=`.
            "openingContextByRole": OpeningContextStats.byRole(page.records)
                .map(Self.openingContextStatsJSON)
        ]
        if let projectName { body["project"] = projectName }
        return .json(body)
    }

    /// The page of runs and the two whole-history quality rates behind it.
    ///
    /// Served from the SQLite projection when one is attached — an `ORDER BY …
    /// LIMIT` and a handful of `COUNT`s, rather than sorting and walking the
    /// whole history in memory. The in-memory log answers when it isn't, and when
    /// a query against the index fails: the index holds nothing the log doesn't,
    /// so losing it must cost an answer's speed and never the answer. It is all
    /// or nothing on purpose — a body half from the index and half from the log
    /// would be two answers about two different moments.
    private func listedRuns(
        store: TaskMetricStore, projectID: String?, limit: Int
    ) async -> (records: [TaskMetricRecord], escapedDefects: EscapedDefectRate, firstPass: FirstPassRate) {
        if let metricIndex,
           let indexed = try? await metricIndex.recentRuns(projectID: projectID, limit: limit),
           let escaped = try? await metricIndex.escapedDefectRate(projectID: projectID),
           let firstPass = try? await metricIndex.firstPassRate(projectID: projectID) {
            return (indexed, escaped, firstPass)
        }
        var records = store.records
        if let projectID {
            records = records.filter { KiteloopProject.canonicalPath($0.projectPath) == projectID }
        }
        // Sorted rather than trusting append order: the file is loaded as written,
        // and a poller wants the run that just finished at index 0.
        let recent = Array(records.sorted { $0.completedAt > $1.completedAt }.prefix(limit))
        return (recent,
                store.escapedDefectRate(projectPath: projectID),
                store.firstPassRate(projectPath: projectID))
    }

    /// `GET /v1/metrics?aggregate=size` and friends: one row per group over every
    /// run the index holds, so throughput, spend per size and cost per merged item
    /// are questions the API answers rather than ones a caller pulls records to
    /// compute. `aggregate=role` groups **turns** instead, which is the only level
    /// at which "what share of the night went to review" exists.
    ///
    /// Aggregating is the one thing the JSONL log cannot do without loading
    /// itself, so — unlike listing — this has no fallback and says so.
    private func aggregateMetrics(_ raw: String, projectID: String?,
                                  projectName: String?) async -> HTTPServer.Response {
        guard let grouping = MetricGrouping(rawValue: raw) else {
            return .error("\"aggregate\" must be one of \(Self.aggregateOptions)", status: 400)
        }
        guard let metricIndex else {
            return .error("Aggregates are unavailable — no metric index attached", status: 503)
        }
        do {
            var body: [String: Any] = ["aggregate": grouping.rawValue]
            if grouping.isTurnDimension {
                body["unit"] = "turns"
                body["groups"] = try await metricIndex
                    .turnAggregates(projectID: projectID, groupedBy: grouping)
                    .map(Self.turnAggregateJSON)
            } else {
                body["unit"] = "runs"
                body["groups"] = try await metricIndex
                    .runAggregates(projectID: projectID, groupedBy: grouping)
                    .map(Self.runAggregateJSON)
            }
            body["escapedDefects"] = Self.escapedDefectJSON(
                try await metricIndex.escapedDefectRate(projectID: projectID))
            body["firstPassRate"] = Self.firstPassJSON(
                try await metricIndex.firstPassRate(projectID: projectID))
            if let projectName { body["project"] = projectName }
            return .json(body)
        } catch {
            return .error("Metric index query failed: \(error)", status: 500)
        }
    }

    /// The dimensions `?aggregate=` accepts, for the 400 that rejects the rest.
    private static var aggregateOptions: String {
        MetricGrouping.allCases.map(\.rawValue).sorted().joined(separator: ", ")
    }

    private static func runAggregateJSON(_ group: RunAggregate) -> [String: Any] {
        [
            "key": group.key,
            "runs": group.runs,
            "costUSD": group.costUSD,
            "avgCostUSD": group.avgCostUSD as Any,
            // The cost re-derived from token counters, over the runs that had
            // them — `null` when none did, which is not the same as $0.
            "derivedCostUSD": group.derivedCostUSD as Any,
            "durationSec": Int(group.durationSeconds),
            "avgDurationSec": group.avgDurationSeconds as Any,
            "reviewerRetries": group.reviewerRetries,
            "avgReviewerRetries": group.avgReviewerRetries as Any,
            "merged": group.merged,
            "producedWork": group.producedWork,
            // Spend over the runs that left work behind — what "cost per item"
            // means. `null` when the group produced none.
            "costPerProducedRunUSD": group.costPerProducedRunUSD as Any,
            "tokens": Self.tokenJSON(group.usage) as Any,
            // The denominator behind `tokens`, which is not `runs` whenever some
            // of the group predates token capture.
            "runsWithUsage": group.runsWithUsage
        ]
    }

    private static func turnAggregateJSON(_ group: TurnAggregate) -> [String: Any] {
        [
            "key": group.key,
            "turns": group.turns,
            "costUSD": group.costUSD,
            "derivedCostUSD": group.derivedCostUSD as Any,
            "durationSec": Int(group.durationSeconds),
            "tokens": Self.tokenJSON(group.usage) as Any,
            "turnsWithUsage": group.turnsWithUsage
        ]
    }

    /// `null` rather than four zeros when nothing in the group recorded usage —
    /// a group that was never measured must not read as one that consumed nothing.
    private static func tokenJSON(_ usage: TokenUsage?) -> [String: Any]? {
        guard let usage else { return nil }
        return [
            "input": usage.inputTokens,
            "output": usage.outputTokens,
            "cacheWrite": usage.cacheCreationTokens,
            "cacheRead": usage.cacheReadTokens,
            "cacheHitRate": usage.cacheHitRate as Any
        ]
    }

    /// Success metric #3b: the share of approved items reopened within 7 days.
    /// `rate` is `null` until something has been approved — 0/0 is "not measured
    /// yet", which a caller must not read as a perfect 0%.
    private static func escapedDefectJSON(_ rate: EscapedDefectRate) -> [String: Any] {
        [
            "windowDays": rate.windowDays,
            "approvals": rate.approvals,
            "reopened": rate.reopened,
            "lateReopened": rate.lateReopened,
            "rate": rate.rate as Any
        ]
    }

    /// Success metric #3a: the share of judged runs review passed on the first
    /// worker attempt. `rate` is `null` until something has been judged — 0/0 is
    /// "not measured yet", which a caller must not read as "nothing passes".
    private static func firstPassJSON(_ rate: FirstPassRate) -> [String: Any] {
        [
            "judged": rate.judged,
            "firstPass": rate.firstPass,
            "rate": rate.rate as Any
        ]
    }

    /// How much history one call may pull, shared by `/v1/metrics` and
    /// `/v1/estimates`. Capped so a driver polling in a loop can't drag a whole
    /// JSONL history through the socket on every tick.
    private static let historyLimitRange: ClosedRange<Int> = 1...200

    /// Tests a project id against a `?project=` that may name a project nobody has
    /// open — the case `registry.entry(forProject:)` alone can't answer, and the
    /// one `GET /v1/runs` has to serve rather than refuse.
    ///
    /// An open project resolves through the registry, so every spelling it already
    /// accepts (canonical path, raw path, folder name) keeps working. A closed one
    /// is matched on the two things a record still carries: the canonical path, and
    /// the folder name derived from it. An absent or empty `project` matches
    /// everything.
    private func projectMatcher(_ project: String?) -> (String) -> Bool {
        guard let project, !project.isEmpty else { return { _ in true } }
        if let entry = registry.entry(forProject: project) {
            let id = entry.session.project.id
            return { $0 == id }
        }
        let canonical = KiteloopProject.canonicalPath(project)
        return { $0 == canonical || URL(fileURLWithPath: $0).lastPathComponent == project }
    }

    /// `nil` = the caller sent a `limit` that isn't a number in range (→ 400);
    /// an absent or empty one is the default, not an error.
    private static func parseHistoryLimit(_ raw: String?) -> Int? {
        guard let raw, !raw.isEmpty else { return 20 }
        guard let value = Int(raw), historyLimitRange.contains(value) else { return nil }
        return value
    }

    private static func metricJSON(_ record: TaskMetricRecord) -> [String: Any] {
        [
            // The workflow execution id — the same handle `GET /v1/runs` reports as
            // `runId`, so a run can be followed from its events into its metrics.
            "runId": record.executionID as Any,
            "item": record.itemID,
            "title": record.title,
            "project": record.projectName,
            "epic": record.epic as Any,
            "size": record.declaredSize as Any,
            "startedAt": iso.string(from: record.startedAt),
            "completedAt": iso.string(from: record.completedAt),
            "durationSec": Int(record.durationSeconds),
            "costUSD": record.costUSD,
            // What the run was forecast to cost, and whether it went past the
            // ceiling that forecast set. Reported together because neither
            // answers on its own: an overrun without the prediction it overran
            // says nothing about how far the estimate was out, and the item cap
            // is advisory, so an overrun is a measurement rather than a failure.
            // Both are `null` for a record written before they were captured.
            "predictedCostUSD": record.predictedCostUSD as Any,
            "overItemCap": record.overItemCap as Any,
            "reviewerRetries": record.reviewerRetries,
            "outcome": record.outcome,
            "worker": record.workerAgent as Any,
            "reviewer": record.reviewerAgent as Any,
            "qualityScore": record.qualityScore as Any,
            "judgeDimensions": record.judgeDimensions as Any,
            // Why there's no score, when the judge was asked and didn't answer.
            // A caller averaging `qualityScore` over a night needs to tell a
            // judge that died from work that scored badly; without this the two
            // are the same null.
            "judgeUnavailable": record.judgeUnavailableReason as Any,
            // Whether the diff the judge scored was cut short before it reached
            // the judge. `null` when the judge was never asked; `true`/`false`
            // otherwise, so a caller can filter a truncated score out of an
            // average rather than blend it in with the ones taken over the
            // whole diff.
            "qualityScoreDiffTruncated": record.qualityScoreDiffTruncated as Any,
            // What each role was sent before it had done anything. Absent —
            // rather than zero — on a run that recorded no opening call.
            "openingContext": record.openingContext.map { byRole in
                byRole.mapValues(Self.openingContextJSON)
            } as Any
        ]
    }

    private static func openingContextJSON(_ context: OpeningContext) -> [String: Any] {
        [
            // How big it is, and what it cost to send. Both, because they differ
            // by an order of magnitude between a cold session and a warm one.
            "promptTokens": context.promptTokens,
            "billedTokens": context.billedTokens,
            "inputTokens": context.inputTokens,
            "cacheWriteTokens": context.cacheCreationTokens,
            "cacheReadTokens": context.cacheReadTokens
        ]
    }

    private static func openingContextStatsJSON(_ stats: OpeningContextStats) -> [String: Any] {
        [
            "role": stats.role,
            // Runs that measured one — not runs returned. History written before
            // the capture existed carries none, so the two differ for a while.
            "runs": stats.runs,
            "promptTokens": ["p50": stats.prompt.p50, "p90": stats.prompt.p90],
            "billedTokens": ["p50": stats.billed.p50, "p90": stats.billed.p90]
        ]
    }

    /// The current estimate for each scoped item, newest first — the forecast side
    /// of `GET /v1/metrics`. Scoping an item again appends rather than replaces, so
    /// only the newest estimate per item is reported: that is the one the run was
    /// actually planned against, and the one to score the actual against.
    ///
    /// `?project=` narrows to one project (which must be open, as elsewhere);
    /// without it the estimates span every project the app has ever scoped.
    private func listEstimates(project: String?, limit: String?) -> HTTPServer.Response {
        guard let metricStore else {
            return .error("Estimates are unavailable — no metric store attached", status: 503)
        }
        guard let limit = Self.parseHistoryLimit(limit) else {
            return .error("\"limit\" must be an integer in \(Self.historyLimitRange)", status: 400)
        }
        var projectPath: String?
        var projectName: String?
        if let project {
            guard let entry = registry.entry(forProject: project) else {
                return .error("Project not open in Kiteloop: \(project)", status: 409)
            }
            projectPath = entry.session.project.id
            projectName = entry.session.project.rootURL.lastPathComponent
        }
        let latest = metricStore.latestEstimatesPerItem(projectPath: projectPath).prefix(limit)
        var body: [String: Any] = ["count": latest.count, "estimates": latest.map(Self.estimateJSON)]
        if let projectName { body["project"] = projectName }
        return .json(body)
    }

    private static func estimateJSON(_ estimate: TaskEstimate) -> [String: Any] {
        [
            "item": estimate.itemID,
            // Estimates carry only a path; report the folder name so the field
            // matches what `/v1/metrics` and `/v1/backlog` call a project.
            "project": URL(fileURLWithPath: estimate.projectPath).lastPathComponent,
            "createdAt": iso.string(from: estimate.createdAt),
            "size": estimate.estimatedSize,
            "predictedDurationSec": Int(estimate.predictedDurationSeconds),
            // Null when history was too thin to ground a cost — an unknown, not a free run.
            "predictedCostUSD": estimate.predictedCostUSD as Any,
            "predictedRetries": estimate.predictedRetries as Any,
            "confidence": estimate.confidence,
            "source": estimate.source,
            "rationale": estimate.rationale
        ]
    }

    /// Recent grooming records, newest first — what was filed, and what a pre-run
    /// check refused at pickup, with the clause that failed.
    ///
    /// This is the half of a night `GET /v1/metrics` cannot show: a run record
    /// only exists for an item that ran, so a queue that drained because four
    /// items were refused for a missing `verify:` and a queue that drained because
    /// the work is done look identical from the metrics alone. Read from
    /// `~/.kiteloop/grooming.jsonl`, so it survives restarts and spans every
    /// project unless narrowed with `?project=`.
    private func listGrooming(project: String?, limit: String?) -> HTTPServer.Response {
        guard let groomingLedger else {
            return .error("Grooming records are unavailable — no grooming ledger attached", status: 503)
        }
        guard let limit = Self.parseHistoryLimit(limit) else {
            return .error("\"limit\" must be an integer in \(Self.historyLimitRange)", status: 400)
        }
        var projectID: String?
        var projectName: String?
        if let project {
            guard let entry = registry.entry(forProject: project) else {
                return .error("Project not open in Kiteloop: \(project)", status: 409)
            }
            // Records store the raw root path; the registry keys on the canonical one.
            projectID = entry.session.project.id
            projectName = entry.session.project.rootURL.lastPathComponent
        }
        var records = groomingLedger.records
        if let projectID {
            records = records.filter { KiteloopProject.canonicalPath($0.projectPath) == projectID }
        }
        // The ledger is append-only and appended in time order, so reversing it is
        // "newest first" — the ordering every other listing answers in.
        let recent = records.reversed().prefix(limit)
        var body: [String: Any] = ["count": recent.count, "grooming": recent.map(Self.groomingJSON)]
        if let projectName { body["project"] = projectName }
        return .json(body)
    }

    private static func groomingJSON(_ record: GroomingRecord) -> [String: Any] {
        [
            "at": iso.string(from: record.at),
            "item": record.itemID,
            "project": record.projectName,
            "event": record.event.rawValue,
            // Both null for a filing: only a refusal names a check and a clause.
            "check": record.check as Any,
            "reason": record.reason as Any
        ]
    }

    // MARK: - Portfolio report

    /// How long a window one call may report on — an hour at the least, a month at
    /// the most. The report walks both ledgers in memory, and a window longer than
    /// the history they hold reports the same thing as one that spans it.
    private static let reportHoursRange: ClosedRange<Int> = 1...720

    /// `nil` = the caller sent an `hours` that isn't a number in range (→ 400); an
    /// absent or empty one is a day, which is the question the report answers.
    private static func parseReportHours(_ raw: String?) -> Int? {
        guard let raw, !raw.isEmpty else { return 24 }
        guard let value = Int(raw), reportHoursRange.contains(value) else { return nil }
        return value
    }

    /// What a period of unattended work produced across every project: merged ÷
    /// filed, why the rejections were rejected, and what it cost — the same
    /// `PortfolioReport` the coordinator panel renders.
    ///
    /// Aggregated here rather than left to the caller because the rate has a rule
    /// that a re-derivation would have to repeat: nothing files items in a period
    /// where the coordinator did no grooming, so a period with runs but no filings
    /// falls back to merged ÷ **run**. Each rate carries its `basis`, so the
    /// fallback is never read as the headline.
    ///
    /// Both ledgers are required. The runs say what merged and the grooming ledger
    /// says what was filed, so with either missing the numerator and denominator
    /// would come from different questions — 503 naming the missing one, like the
    /// two endpoints that serve the raw records.
    private func portfolioReport(hours: String?) -> HTTPServer.Response {
        guard let metricStore else {
            return .error("Metrics are unavailable — no metric store attached", status: 503)
        }
        guard let groomingLedger else {
            return .error("Grooming records are unavailable — no grooming ledger attached", status: 503)
        }
        guard let hours = Self.parseReportHours(hours) else {
            return .error("\"hours\" must be an integer in \(Self.reportHoursRange)", status: 400)
        }

        let period = PortfolioReport.Period.last(hours: hours, endingAt: Date())
        let report = PortfolioReport.make(runs: metricStore.records,
                                          grooming: groomingLedger.records,
                                          period: period)
        let periodJSON: [String: Any] = [
            "hours": hours,
            "label": period.label,
            "start": Self.iso.string(from: period.start),
            "end": Self.iso.string(from: period.end)
        ]
        let body: [String: Any] = [
            "period": periodJSON,
            "summary": report.summaryLine,
            "empty": report.isEmpty,
            "rows": report.rows.map(Self.reportRowJSON),
            // Every project in the period, including the ones `rows` left out.
            "total": Self.reportRowJSON(report.total),
            "omittedProjects": report.omittedProjects
        ]
        return .json(body)
    }

    /// One project's period — and, in the same shape, the portfolio total, so a
    /// driver reads the summary line and a project line with the same code.
    private static func reportRowJSON(_ row: PortfolioReport.Row) -> [String: Any] {
        let mergeRate: [String: Any] = [
            "merged": row.mergeRate.merged,
            "of": row.mergeRate.of,
            // Which question the rate answers: `filed` judges the grooming, `run`
            // is the fallback when nothing was filed.
            "basis": row.mergeRate.basis.rawValue,
            // null with nothing to divide by — 0/0 is "not measured", not 0%.
            "fraction": row.mergeRate.fraction as Any
        ]
        let causes: [[String: Any]] = row.causes.map { cause in
            ["label": cause.label, "count": cause.count, "example": cause.example as Any]
        }
        return [
            "project": row.projectName,
            "filed": row.filed,
            "ready": row.ready,
            "draft": row.draft,
            "run": row.run,
            "merged": row.merged,
            "rejected": row.rejected,
            "awaitingApproval": row.awaitingApproval,
            "skippedByCheck": row.skippedByCheck,
            "spendUSD": row.spendUSD,
            // Period time with no item running. A project that ran nothing is idle
            // for the whole period.
            "idleSeconds": Int(row.idle.rounded()),
            "quiet": row.isQuiet,
            "mergeRate": mergeRate,
            "causes": causes,
            "text": row.text
        ]
    }

    private func getAutopilot(project: String?) async -> HTTPServer.Response {
        guard let project else { return .error("Missing ?project=", status: 400) }
        guard let entry = registry.entry(forProject: project) else {
            return .error("Project not open in Kiteloop: \(project)", status: 409)
        }
        var body = Self.autopilotConfig(entry)
        // Configuration plus what it is doing with it. Only on `GET`: `PUT` and
        // `reset` answer with what they wrote, and a run state in a write
        // response is a value the write never set.
        body["run"] = await Self.runState(entry.autopilot)
        await Self.clearReportedInconsistency(body["run"] as? [String: Any], autopilot: entry.autopilot,
                                              via: "GET /v1/autopilot")
        // (`GET /v1/projects` does the same through `runState(_:clearingInconsistencyVia:)`.)
        // The figure `budgetUSD` is measured against — the whole session's
        // spend, every run of it, including the item in flight. Reported for the
        // same reason the cap is: a driver deciding whether to start another item
        // needs the accumulated number, and it is not derivable from any run's own
        // cost now that a session outlives a run.
        body["sessionSpendUSD"] = entry.autopilot.costReadout.sessionSpendUSD
        // Whether the project is held, from the one reading `GET /v1/projects`
        // and `POST /v1/runs` take (`isPaused`). On the read only, for the same
        // reason `run` is: a write never sets it. A pause taken over an item in
        // flight reports `true` between items as well as during one — the hold
        // outlives the run it interrupted.
        body["paused"] = Self.isPaused(entry)
        return .json(body)
    }

    /// What a project's autopilot is running, as JSON — the same block on
    /// `GET /v1/autopilot` and on every entry of `GET /v1/projects`, from the one
    /// call the busy guard makes.
    ///
    /// Encoded here rather than in `BacklogAutopilot` so the service keeps its own
    /// vocabulary, but there is no second derivation: everything below is read off
    /// `RunState`, and `state` is its phase verbatim.
    /// A read that found the autopilot claiming a run with none behind it
    /// clears the claim — after reporting it, so the read says what it found
    /// and the next one finds the slot free. Until 2026-09-20 only a run
    /// request or reopening the project cleared it, and a project driven
    /// unattended does neither: one held an item for a day at `review`,
    /// its watchdog gone with the run loop, while every read of it said so.
    private static func clearReportedInconsistency(_ run: [String: Any]?, autopilot: BacklogAutopilot,
                                                   via: String) async {
        guard run?["state"] as? String == "inconsistent" else { return }
        await autopilot.reconcileStatus(reason: "reported inconsistent to \(via)")
    }

    /// `runState`, and the claim it reports as inconsistent cleared after
    /// the reading — see `clearReportedInconsistency`.
    private static func runState(_ autopilot: BacklogAutopilot, clearingInconsistencyVia via: String) async -> [String: Any] {
        let run = await runState(autopilot)
        await clearReportedInconsistency(run, autopilot: autopilot, via: via)
        return run
    }

    private static func runState(_ autopilot: BacklogAutopilot) async -> [String: Any] {
        let state = await autopilot.runState()
        // `?? nil` flattens what the `map` nests: a `String??` bridges to JSON as
        // neither a value nor null.
        let startedAt = state.inFlight?.startedAt.map { iso.string(from: $0) } ?? nil
        let rail = PortfolioSnapshot.phaseRail(
            currentRunPhase: autopilot.currentRunPhase, attempt: autopilot.currentRunAttempt,
            lastActivityAt: autopilot.lastActivityAt, stallTimeoutMinutes: autopilot.stallTimeoutMinutes)
        return [
            "state": state.phase.rawValue,
            "running": state.isRunning,
            "item": state.inFlight?.itemID as Any,
            "itemTitle": state.inFlight?.itemTitle as Any,
            "runId": state.inFlight?.executionID as Any,
            "startedAt": startedAt as Any,
            "status": state.statusLabel,
            "heldItems": state.heldItems,
            "detail": state.detail as Any,
            "phaseRail": rail.map(Self.phaseRailJSON) as Any
        ]
    }

    /// Where inside the worker → verify → review → merge → gate pipeline a run
    /// is right now, as JSON — the same `PortfolioSnapshot.RunState.PhaseRail`
    /// the fleet board's state cell and the Autopilot tab's in-flight row draw.
    private static func phaseRailJSON(_ rail: PortfolioSnapshot.RunState.PhaseRail) -> [String: Any] {
        [
            "currentStep": rail.current.rawValue,
            "stepsDone": rail.stepsDone.map(\.rawValue),
            "attempt": rail.attempt,
            "lastOutputAgeSeconds": rail.lastOutputAge,
            "warnAtSeconds": rail.warnAtSeconds
        ]
    }

    /// One key of the autopilot configuration reply, and where its value comes
    /// from.
    private struct AutopilotConfigField: Sendable {
        let name: String
        /// Isolated, because everything it reads is: the payload is built on the
        /// main actor like the rest of this class. `@Sendable` so the table
        /// itself is a value the document's tests can read without it.
        let value: @MainActor @Sendable (ControlSessionRegistry.Entry) -> Any
    }

    /// A table rather than a dictionary literal for the reason the refill policy
    /// is one: the names below are what the OpenAPI document is checked against,
    /// so a key added here and nowhere else fails that check instead of being
    /// served by an endpoint whose schema never mentions it.
    nonisolated private static let autopilotConfigFields: [AutopilotConfigField] = [
        AutopilotConfigField(name: "project") { $0.session.project.rootURL.lastPathComponent },
        AutopilotConfigField(name: "worker") { $0.autopilot.workerAgentID as Any },
        AutopilotConfigField(name: "reviewer") { $0.autopilot.reviewerAgentID as Any },
        // How far this project may go on its own — one dial over
        // `autonomousWorkEnabled` and `approvalGate`.
        AutopilotConfigField(name: "autonomy") { $0.autopilot.autonomy.rawValue },
        // What happens to a review-passed run: `propose` waits for a person,
        // `land` approves and merges it.
        AutopilotConfigField(name: "approvalGate") { $0.autopilot.approvalGate.rawValue },
        AutopilotConfigField(name: "maxRetries") { $0.autopilot.maxRetries },
        // Read-only, and derived: the worker node's clock is this project's own
        // p95 worker phase plus half again, the gate's the same over its own
        // phase, each counting only that phase's runs (`RunTimeouts`). Both are
        // still reported, because a caller
        // watching a run needs to know what it is being timed against; a `PUT`
        // naming either is tolerated and answered with the derived value.
        AutopilotConfigField(name: "stallTimeoutMinutes") { $0.autopilot.stallTimeoutMinutes },
        // The project's one budget — a daily ceiling that also bounds a
        // sitting; nil defers to the portfolio's own ceiling
        // (`GET /v1/coordinator/scheduling`). Replaces `perItemCostCapUSD`,
        // `sessionCostCapUSD`, `costCapMargin` and `dailyBudgetUSD`: the
        // per-item ceiling is no longer a setting at all — see
        // `CostGovernor.effectiveItemCap(for:)`.
        AutopilotConfigField(name: "budgetUSD") { $0.autopilot.budgetUSD as Any },
        AutopilotConfigField(name: "autoMergeOnApproval") { $0.autopilot.autoMergeOnApproval },
        AutopilotConfigField(name: "autoMergeVerifyTimeoutMinutes") { $0.autopilot.autoMergeVerifyTimeoutMinutes },
        // Where each derived clock came from — "derived" once this project has
        // enough runs carrying that phase's duration, "default" until then.
        // Without it the two numbers are indistinguishable from settings, and a
        // caller cannot tell a measured 20 from an unmeasured one. One answer
        // per clock, because the two are measured separately: a project whose
        // runs stop at the approval gate has a measured worker deadline beside
        // a default gate one.
        AutopilotConfigField(name: "runTimeoutSource") {
            ["worker": $0.autopilot.runTimeouts.worker.source.rawValue,
             "gate": $0.autopilot.runTimeouts.gate.source.rawValue]
        },
        // The worker's turn budget, derived the same way from the turn counts
        // this project's runs recorded, and where it came from.
        AutopilotConfigField(name: "workerMaxTurns") { $0.autopilot.workerMaxTurns },
        AutopilotConfigField(name: "workerMaxTurnsSource") { $0.autopilot.runTimeouts.workerTurns.source.rawValue },
        // The per-item cost cap this project's runs imply — their p95 cost plus
        // half again, null until five carry a cost (each item's prediction
        // plus the same headroom then) — and where it came from.
        AutopilotConfigField(name: "itemCostCapUSD") { $0.autopilot.runTimeouts.itemCost.usd as Any },
        AutopilotConfigField(name: "itemCostCapSource") { $0.autopilot.runTimeouts.itemCost.source.rawValue },
        AutopilotConfigField(name: "worktreeSetupCommand") { $0.autopilot.worktreeSetupCommand as Any },
        // What the gate and a fresh worktree actually run, and where each came
        // from — "configured", or the file or rule the repository implied it
        // from when nothing was set (`RepoConventions`). The setup setting
        // above stays as written so a read matches the last write; the gate's
        // is the verify map's, with no setting of its own.
        AutopilotConfigField(name: "effectiveAutoMergeVerifyCommand") { $0.autopilot.effectiveMergeVerify.command as Any },
        AutopilotConfigField(name: "autoMergeVerifyCommandSource") { $0.autopilot.effectiveMergeVerify.source },
        AutopilotConfigField(name: "effectiveWorktreeSetupCommand") { $0.autopilot.effectiveWorktreeSetup.command as Any },
        AutopilotConfigField(name: "worktreeSetupCommandSource") { $0.autopilot.effectiveWorktreeSetup.source },
        // The branch runs fork from and land on. Null is the checkout's own
        // `HEAD` — `GET /v1/projects` resolves that to a name; this payload
        // reports the setting as written, so a read matches the last write.
        AutopilotConfigField(name: "baseBranch") { $0.autopilot.baseBranch as Any },
        AutopilotConfigField(name: "openPullRequest") { $0.autopilot.openPullRequest },
        // Deprecated — read off `approvalGate`. `GET` still reports it; a `PUT`
        // naming it still works, mapped the same way loading an old config
        // file does.
        AutopilotConfigField(name: "approveReviewPassedRuns") { $0.autopilot.approveReviewPassedRuns },
        AutopilotConfigField(name: "autonomousWorkEnabled") { $0.autopilot.autonomousWorkEnabled }
    ]

    /// Every key the configuration reply carries, for whoever declares the
    /// endpoint. There is no `coordinator` here: the per-project persona picker
    /// retired, and a `PUT` tolerates the field without the reply ever answering
    /// with it.
    nonisolated static let autopilotConfigFieldNames = autopilotConfigFields.map(\.name)

    /// The full autopilot configuration for a project — the shared shape returned by
    /// both `GET` and `PUT /v1/autopilot`, so a read always matches the last write.
    private static func autopilotConfig(_ entry: ControlSessionRegistry.Entry) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: autopilotConfigFields.map { ($0.name, $0.value(entry)) })
    }

    // MARK: - Project + team setup

    private func openProject(body: Data) async -> HTTPServer.Response {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let path = json["path"] as? String else {
            return .error("Body must be JSON: { \"path\": \"…\" }", status: 400)
        }
        guard let opener = registry.openProject else {
            return .error("Project opening is unavailable — the app window isn't running", status: 503)
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let outcome = await opener(url)
        guard outcome != .failed, let entry = registry.entry(forProject: url.path(percentEncoded: false)) else {
            return .error("Could not open a project at \(path)", status: 400)
        }
        // 201 only when a session was actually created. An already-open project
        // is re-read from disk and answered 200 `reloaded` — a driver that just
        // groomed the backlog outside the app needs to be able to tell the two
        // apart, and "201 Created" for a call that created nothing is what let a
        // stale in-memory backlog look like a fresh one.
        let reloaded = outcome == .reloaded
        return .json([
            "id": entry.session.project.id,
            "name": entry.session.project.rootURL.lastPathComponent,
            "autopilotReady": entry.autopilot.workerAgentID != nil && entry.autopilot.reviewerAgentID != nil,
            "alreadyOpen": reloaded,
            "reloaded": reloaded
        ], status: reloaded ? 200 : 201)
    }

    /// The `/v1/projects…` family, dispatched from one arm of `route(_:)`.
    private func projectsRoute(_ route: ControlRoute, _ req: HTTPServer.Request) async -> HTTPServer.Response {
        switch route {
        case .listProjects: return await listProjects()
        case .openProject: return await openProject(body: req.body)
        case .reorderProjects: return await reorderProjects(body: req.body)
        case .askAboutProject: return await askAboutProject(body: req.body)
        case .workspaceChanges, .workspaceFile, .previewScreenshot: return await workspaceRoute(route, req)
        default: return Self.notThisArea(route)
        }
    }

    // MARK: - The project's working tree, read from the phone

    /// What an agent has changed, a file it names, and what the web preview
    /// shows — read-only, so the phone can check work without the Mac.
    private func workspaceRoute(_ route: ControlRoute, _ req: HTTPServer.Request) async -> HTTPServer.Response {
        guard let project = req.query["project"] else { return .error("Missing ?project=", status: 400) }
        guard let entry = registry.entry(forProject: project) else {
            return .error("Project not open in Kiteloop: \(project)", status: 409)
        }
        switch route {
        case .workspaceChanges: return await workspaceChanges(entry)
        case .workspaceFile: return await workspaceFile(entry, path: req.query["path"] ?? "")
        case .previewScreenshot: return await previewScreenshot(entry)
        default: return Self.notThisArea(route)
        }
    }

    private func workspaceChanges(_ entry: ControlSessionRegistry.Entry) async -> HTTPServer.Response {
        let root = entry.session.project.rootURL.path(percentEncoded: false)
        let result = await Task.detached(priority: .userInitiated) { WorkspaceReader.changes(root: root) }.value
        switch result {
        case .notARepository: return .error("The project is not a git repository, so there is no diff to read", status: 409)
        case .timedOut: return .error("git timed out reading the working tree", status: 504)
        case .changes(let files, let patch, let truncated):
            return .json(["files": files.map { ["status": $0.status, "path": $0.path] },
                          "patch": patch, "truncated": truncated])
        }
    }

    private func workspaceFile(_ entry: ControlSessionRegistry.Entry, path: String) async -> HTTPServer.Response {
        let root = entry.session.project.rootURL
        let read = await Task.detached(priority: .userInitiated) { WorkspaceReader.read(root: root, relative: path) }.value
        switch read {
        case .text(let text): return .json(["path": path, "kind": "file", "text": text])
        case .directory(let entries):
            return .json(["path": path, "kind": "directory",
                          "entries": entries.map { ["name": $0.name, "directory": $0.isDirectory] }])
        case .outside: return .error("\(path) is outside the project", status: 403)
        case .ignored: return .error("\(path) is ignored by git, so it stays on the Mac", status: 403)
        case .missing: return .error("No file \(path) in the project", status: 404)
        case .tooLarge(let bytes): return .error("\(path) is \(bytes) bytes; files over \(WorkspaceReader.fileCap) are not sent", status: 413)
        case .binary: return .error("\(path) is not text", status: 415)
        }
    }

    /// The web preview of a window showing this project, as a PNG.
    private func previewScreenshot(_ entry: ControlSessionRegistry.Entry) async -> HTTPServer.Response {
        guard let preview = entry.session.chatViewModels.values.lazy.compactMap(\.webPreview).first,
              let png = await preview.snapshotPNG() else {
            return .error("No web preview is open for this project — open one in the Mac's preview pane", status: 409)
        }
        return HTTPServer.Response(status: 200, headers: ["Content-Type": "image/png"], body: png)
    }

    /// Move one open project's tab before another, or to the end — the move a
    /// tab drop makes in the window, through the closure the window installed,
    /// so the phone's drag and the Mac's share one saved order. Answers the
    /// order `GET /v1/projects` now lists.
    private func reorderProjects(body: Data) async -> HTTPServer.Response {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let project = json["project"] as? String else {
            return .error("Body must be JSON: { \"project\": \"…\", \"before\": \"…\" | null }", status: 400)
        }
        guard let moving = registry.entry(forProject: project) else {
            return .error("No open project named \(project)", status: 409)
        }
        var beforeID: String?
        if let before = json["before"] as? String {
            guard let target = registry.entry(forProject: before) else {
                return .error("No open project named \(before)", status: 409)
            }
            beforeID = target.session.project.id
        }
        guard let reorder = registry.reorderProject else {
            return .error("Project reordering is unavailable — the app window isn't running", status: 503)
        }
        await reorder(moving.session.project.id, beforeID)
        return .json(["projects": registry.openProjects.map { $0.session.project.rootURL.lastPathComponent }])
    }

    /// Ask the Planner a question about one open project's **source**.
    ///
    /// The read endpoints above answer from what the app already holds — a
    /// queue's depth, an item's status, what a run cost — and they are the cheap
    /// default. This is the expensive exception, for the questions none of them
    /// can reach: whether a file is still there, whether a symbol exists, what a
    /// test actually asserts. It spends a model call with tools, so it is asked
    /// for by name and never taken.
    ///
    /// Read-only, scoped to the one project named, and charged to the portfolio's
    /// daily ceiling — see `CoordinatorQueueRefill.answerFromSource`, which owns
    /// every one of those guarantees. This handler validates the body and
    /// translates the outcome into a status; it grants nothing itself.
    private func askAboutProject(body: Data) async -> HTTPServer.Response {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let project = json["project"] as? String,
              let question = (json["question"] as? String) ?? (json["q"] as? String),
              !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .error("Body must include \"project\" and a non-empty \"question\"", status: 400)
        }
        guard let queueRefill else {
            return .error("Cannot read a project's source — no Planner is attached to do the reading",
                          status: 503)
        }
        let outcome = await queueRefill.answerFromSource(project: project, question: question)
        switch outcome {
        case .answered(let name, let answer, let costUSD):
            return .json([
                "project": name,
                // The stated form, so a capped answer says so in the text a
                // caller prints as well as in the flag beside it — a driver that
                // reads only `answer` still learns it was cut.
                "answer": answer.stated,
                "capped": answer.wasCapped,
                "costUSD": costUSD
            ])
        case .unknownProject(let reason):
            return .error(reason, status: 404)
        case .budgetExhausted(let reason):
            return .error(reason, status: 429)
        case .unavailable(let reason):
            return .error(reason, status: 503)
        case .noAnswer(let reason):
            return .error(reason, status: 502)
        }
    }

    /// What a body said about a nullable daily ceiling. A ceiling is the one
    /// number where "I couldn't read that, so I'll treat it as unbounded" is the
    /// worst possible reading, so junk is a case here rather than a nil that
    /// looks like an intentional clear.
    ///
    /// The middle case is `ceiling`, not `set`: `lizard`'s Swift reader takes a
    /// bare `set` token for a property setter and swallows braces until the next
    /// `{`, which made `case .set(let usd)` measure this handler — and the one
    /// on `PUT /v1/coordinator/scheduling` — as running to the end of the file,
    /// hiding every function after it from the complexity gate.
    private enum BudgetField {
        case cleared
        case ceiling(Double)
        case invalid
    }

    /// `null` clears the ceiling; a positive number sets it; anything else — a
    /// string, a zero, a negative — is a 400. Shared by the project ceiling on
    /// `PUT /v1/autopilot` and the portfolio one on
    /// `PUT /v1/coordinator/scheduling`, so the two say the same thing.
    private static func parseNullableBudget(_ raw: Any) -> BudgetField {
        if raw is NSNull { return .cleared }
        // `as? Double` bridges a JSON `true` to 1.0, which would set a $1
        // ceiling from an obvious mistake. Asked of the underlying CFBoolean
        // rather than with `is Bool`: JSONSerialization hands back NSNumber for
        // both, and `NSNumber(1) is Bool` is *true*, so the simpler test would
        // reject a perfectly legitimate $1 budget.
        if let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return .invalid
        }
        guard let usd = raw as? Double, usd > 0 else { return .invalid }
        return .ceiling(usd)
    }

    private static func invalidBudget(_ key: String = "dailyBudgetUSD") -> HTTPServer.Response {
        .error("\"\(key)\" must be a positive number or null", status: 400)
    }

    /// What a body said about a boolean field: absent, a real boolean, or junk
    /// (carrying the key it came under, so the message names what the caller
    /// actually sent rather than the field the alias resolves to).
    private enum BoolField {
        case absent
        case value(Bool)
        case invalid(String)
    }

    /// The only reading of a JSON boolean this server trusts.
    ///
    /// `JSONSerialization` decodes a JSON boolean *and* a JSON number as
    /// `NSNumber`, and `NSNumber as? Bool` succeeds for both — `1` bridges to
    /// `true`, `0` to `false`. So a guard written as `raw as? Bool` reads like a
    /// validator while accepting `{"resetBreaker": 1}` and clearing the circuit
    /// breaker, with a 200 and no complaint. The underlying CoreFoundation type
    /// tells them apart: only a JSON `true`/`false` is a CFBoolean. (Same trick
    /// as `parseNullableBudget`, pointed the other way.)
    private static func parseBool(_ raw: Any) -> Bool? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// Reads one optional boolean field, and its alias if it has one. `key` wins
    /// when a body sends both.
    private static func boolField(_ json: [String: Any], _ key: String,
                                  alias: String? = nil) -> BoolField {
        for name in [key, alias].compactMap({ $0 }) {
            guard let raw = json[name] else { continue }
            guard let value = parseBool(raw) else { return .invalid(name) }
            return .value(value)
        }
        return .absent
    }

    private static func invalidBool(_ key: String) -> HTTPServer.Response {
        .error("\"\(key)\" must be true or false", status: 400)
    }

    /// What a `PUT /v1/autopilot` body said about one agent slot, once its id or
    /// name has been looked up. A failed lookup isn't a case here — it's `nil`
    /// from the resolver, which the handler turns into a 400.
    private enum AgentAssignment {
        case unchanged           // key absent from the body
        case cleared             // explicit null/"" — reviewer only
        case assigned(String)    // resolved agent id
    }

    /// Every behaviour flag `setAutopilot` reads, in one place for the same
    /// reason the config keys are: whoever declares the endpoint reads this,
    /// so a flag added to the loop below is a flag the document has to declare.
    nonisolated static let autopilotFlagFieldNames = [
        "autoMergeOnApproval",
        "openPullRequest", "approveReviewPassedRuns", "autonomousWorkEnabled"
    ]

    /// What a `PUT` body said about the behaviour flags. Read in one pass
    /// before anything is written: a JSON number is not a boolean (see
    /// `parseBool`), and a body with one bad flag leaves the config exactly as
    /// it was rather than half-applied.
    private enum AutopilotFlags {
        case invalid(String)     // the first flag that wasn't a boolean
        case read([String: Bool])
    }

    private static func readAutopilotFlags(_ json: [String: Any]) -> AutopilotFlags {
        var flags: [String: Bool] = [:]
        for key in autopilotFlagFieldNames {
            switch boolField(json, key) {
            case .absent: continue
            case .invalid(let key): return .invalid(key)
            case .value(let value): flags[key] = value
            }
        }
        return .read(flags)
    }

    private func setAutopilot(body: Data) -> HTTPServer.Response {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let project = json["project"] as? String else {
            return .error("Body must include \"project\"", status: 400)
        }
        guard let entry = registry.entry(forProject: project) else {
            return .error("Project not open in Kiteloop: \(project)", status: 409)
        }
        let flags: [String: Bool]
        switch Self.readAutopilotFlags(json) {
        case .invalid(let key): return Self.invalidBool(key)
        case .read(let read): flags = read
        }
        if let refusal = assignAutopilotAgents(json, entry: entry) { return refusal }
        if let refusal = Self.applyAutopilotSettings(json, flags: flags, to: entry.autopilot) {
            return refusal
        }
        return .json(Self.autopilotConfig(entry))
    }

    /// Every agent slot is addressed by **id or name** — a driver that just
    /// hired "Builder" shouldn't have to carry its UUID around — and is
    /// resolved to an id before anything is written, so a body naming one
    /// known and one unknown agent leaves the pair as it was instead of
    /// half-assigned. Answers with the 400 to send, or `nil` when both slots
    /// are fine.
    private func assignAutopilotAgents(_ json: [String: Any],
                                       entry: ControlSessionRegistry.Entry) -> HTTPServer.Response? {
        let agents = entry.session.orchestrator.agents
        /// `clearable` is for a slot whose empty value is a working setting:
        /// null or "" for the reviewer means no separate reviewer — the run
        /// goes from the worker straight to the gates. The worker has no such
        /// meaning, so an empty value is a 400 for it.
        func resolve(_ key: String, clearable: Bool = false) -> AgentAssignment? {
            guard json.keys.contains(key) else { return .unchanged }
            let value = json[key]
            if value is NSNull || (value as? String)?.isEmpty == true {
                return clearable ? .cleared : nil
            }
            guard let value = value as? String,
                  let agent = agents.first(where: { $0.id == value || $0.name == value }) else { return nil }
            return .assigned(agent.id)
        }
        guard let worker = resolve("worker") else {
            return .error("No agent matching \"worker\" in this project", status: 400)
        }
        guard let reviewer = resolve("reviewer", clearable: true) else {
            return .error("No agent matching \"reviewer\" in this project", status: 400)
        }
        // "coordinator" is tolerated and ignored: the per-project persona
        // picker retired (the-run-supervisor-retires) and old callers keep
        // working. Documented as deprecated in control-api.md.
        if case .assigned(let id) = worker { entry.autopilot.workerAgentID = id }
        switch reviewer {
        case .assigned(let id): entry.autopilot.reviewerAgentID = id
        case .cleared: entry.autopilot.reviewerAgentID = nil
        case .unchanged: break
        }
        return nil
    }

    /// Everything a `PUT` body sets beyond the agent slots, applied in the
    /// order the two refusals fall in: a bad ceiling stops the write there, a
    /// bad `autonomy` stops it later, and whatever was applied before the
    /// refusal stays applied. Answers with the refusal, or `nil` when the whole
    /// body landed.
    private static func applyAutopilotSettings(_ json: [String: Any],
                                               flags: [String: Bool],
                                               to autopilot: BacklogAutopilot) -> HTTPServer.Response? {
        applyAutopilotRunFlags(json, to: autopilot)
        if let refusal = applyAutopilotBudget(json, to: autopilot) { return refusal }
        applyAutopilotLandingFlags(json, flags: flags, to: autopilot)
        if let refusal = applyReviewGate(json, flags: flags, to: autopilot) { return refusal }
        // The dial, read last: it wins when a body sends it beside
        // `approvalGate` or `autonomousWorkEnabled`.
        if let raw = json["autonomy"] as? String {
            guard let autonomy = BacklogAutopilot.Autonomy(rawValue: raw) else {
                return .error("\"autonomy\" must be \"off\", \"propose\" or \"land\"", status: 400)
            }
            autopilot.autonomy = autonomy
        }
        // `protectedPaths` is tolerated and ignored: it is no longer a setting,
        // and the repository's own guards are where path rules live.
        return nil
    }

    /// How a run is set up, written before the ceiling is read — so a body
    /// carrying a bad ceiling keeps these, exactly as it did when this was one
    /// long handler.
    ///
    /// `useWorktree` is tolerated and ignored the same way: isolation is a fact
    /// about the checkout (ADR-0001), so a git project always isolates.
    ///
    /// `stallTimeoutMinutes` and `autoMergeVerifyTimeoutMinutes` are tolerated
    /// and ignored, the way `coordinator` is: neither is a setting any more —
    /// both are derived from this project's own phase durations (`RunTimeouts`)
    /// — and the reply answers with the derived value, so an old caller sending
    /// one is told what it will actually run under rather than handed a 400.
    /// `autoMergeVerifyCommand` is ignored the same way: the merge gate runs
    /// the verify map's rules, and a rule matching every path is the setting.
    private static func applyAutopilotRunFlags(_ json: [String: Any], to autopilot: BacklogAutopilot) {
        if let rounds = json["maxRetries"] as? Int { autopilot.maxRetries = rounds }
    }

    /// The project's one budget. Validated rather than coerced: a budget that
    /// silently reads a typo as "no ceiling" is the failure the ceiling exists
    /// to prevent. Same rule and wording as the refill loop's ceiling — null
    /// clears it, anything non-positive is a 400. Replaces `perItemCostCapUSD`,
    /// `sessionCostCapUSD` and `costCapMargin`, which a body naming is tolerated
    /// and ignored — the per-item ceiling is no longer a setting at all.
    private static func applyAutopilotBudget(_ json: [String: Any],
                                             to autopilot: BacklogAutopilot) -> HTTPServer.Response? {
        guard let raw = json["budgetUSD"] else { return nil }
        switch parseNullableBudget(raw) {
        case .invalid: return invalidBudget("budgetUSD")
        case .cleared: autopilot.budgetUSD = nil
        case .ceiling(let usd): autopilot.budgetUSD = usd
        }
        return nil
    }

    /// What happens to a run once it comes back — written after the ceiling and
    /// before `autonomy`, which is the order their refusals fall in.
    private static func applyAutopilotLandingFlags(_ json: [String: Any], flags: [String: Bool],
                                                   to autopilot: BacklogAutopilot) {
        for key in clearableStringFields where json.keys.contains(key) {
            applyClearableString(key, from: json, to: autopilot)
        }
        if let openPR = flags["openPullRequest"] { autopilot.openPullRequest = openPR }
        if let autonomous = flags["autonomousWorkEnabled"] { autopilot.autonomousWorkEnabled = autonomous }
    }

    /// What happens to a review-passed run. `approvalGate` sets it; the two
    /// switches it replaced are read for one release and mapped the way an old
    /// config file is (`ApprovalGate.fromLegacy`) — `land` only when both end up
    /// on, a switch the body leaves out keeping the value the gate gives it now.
    /// `approvalGate`, read after them, wins when a body sends both.
    private static func applyReviewGate(_ json: [String: Any], flags: [String: Bool],
                                        to autopilot: BacklogAutopilot) -> HTTPServer.Response? {
        let approve = flags["approveReviewPassedRuns"]
        let merge = flags["autoMergeOnApproval"]
        if approve != nil || merge != nil {
            autopilot.approvalGate = .fromLegacy(approveReviewPassedRuns: approve ?? autopilot.approveReviewPassedRuns,
                                               autoMergeOnApproval: merge ?? autopilot.autoMergeOnApproval)
        }
        guard let raw = json["approvalGate"] as? String else { return nil }
        guard let gate = BacklogAutopilot.ApprovalGate(rawValue: raw) else {
            return .error("\"approvalGate\" must be \"propose\" or \"land\"", status: 400)
        }
        autopilot.approvalGate = gate
        return nil
    }

    /// Put the project's caps, cost margin and behaviour flags back to their
    /// built-in defaults — the way out of a session where a driver tuned the knobs
    /// and can no longer tell what was changed. The worker/reviewer assignment
    /// survives, so autopilot stays runnable. Responds with the full config, same
    /// shape as `GET`/`PUT`.
    /// The optional strings a `PUT` may set or clear: a value sets one, `null`
    /// clears it, and an absent key leaves it alone like every other field.
    /// `baseBranch` also reads `""` as cleared — its setter trims and turns an
    /// empty name into nil — because a driver that built the body from a text
    /// field sends `""` where one built from JSON sends `null`, and neither
    /// means "run on a branch called nothing". Null puts the project back on
    /// the checkout's own `HEAD`, which is the default.
    nonisolated private static let clearableStringFields = [
        "worktreeSetupCommand", "baseBranch"
    ]

    private static func applyClearableString(_ key: String, from json: [String: Any], to autopilot: BacklogAutopilot) {
        let value = json[key] as? String
        switch key {
        case "baseBranch": autopilot.baseBranch = value
        default: autopilot.worktreeSetupCommand = value
        }
    }

    private func resetAutopilot(body: Data) -> HTTPServer.Response {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let project = json["project"] as? String else {
            return .error("Body must include \"project\"", status: 400)
        }
        guard let entry = registry.entry(forProject: project) else {
            return .error("Project not open in Kiteloop: \(project)", status: 409)
        }
        // Mid-run the caps are actively enforced against the running item; clearing
        // them out from under it would silently unbound a run in flight.
        // And say what this verb is: an operator reaching for it to clear a
        // stuck run wiped a project's autonomy, budget and verify command on
        // 2026-09-19 and the run survived — the name invites exactly that.
        guard entry.autopilot.status == .idle else {
            return .error("Autopilot is running for this project — reset changes the configuration, not the run; "
                          + "end the run with POST /v1/runs/{runId}/cancel first, or wait for it to finish", status: 409)
        }
        entry.autopilot.resetConfigToDefaults()
        return .json(Self.autopilotConfig(entry))
    }

    /// Hold the queue after the item in flight finishes — the headless equivalent of
    /// the Autopilot tab's pause button, and the missing half of a driver's control
    /// loop: until now an external caller could start a run but only stop it from the
    /// UI. Pausing does not interrupt the current item; it lands at the next item
    /// boundary, so the run in flight still reaches its gate.
    private func pauseAutopilot(body: Data) -> HTTPServer.Response {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let project = json["project"] as? String else {
            return .error("Body must include \"project\"", status: 400)
        }
        guard let entry = registry.entry(forProject: project) else {
            return .error("Project not open in Kiteloop: \(project)", status: 409)
        }
        guard entry.autopilot.status != .idle else {
            return .error("Autopilot is not running for this project", status: 409)
        }
        // Already paused is a no-op rather than a 409: a driver retrying after a
        // dropped connection must not have to distinguish "I paused it" from
        // "my first request got through".
        if !entry.autopilot.isHoldingQueue { entry.autopilot.pause() }
        return .json(["project": entry.session.project.rootURL.lastPathComponent, "autopilot": "paused"])
    }

    /// Pick the project back up, whichever way it was held. Pausing is one act —
    /// `isPaused` above reads the human's paused switch on the fleet board the
    /// same as `BacklogAutopilot.pause()` — so lifting it has to be one call too;
    /// otherwise a parked project has no remedy at all, and `startRun`'s own
    /// refusal, which names this endpoint, would be naming a call that fails.
    ///
    /// The autopilot's half is read as `isHoldingQueue` rather than off its
    /// `status`: a pause taken while an item was in flight outlives that item
    /// now (`BacklogAutopilot.queueHeld`), and a project held with its queue
    /// already finished still has to be resumable.
    ///
    /// A project paused only by that switch has no queue to pick back up, so it
    /// answers 200 once the flag is cleared. A project
    /// whose autopilot is paused (with or without the fleet board's pause alongside it)
    /// still answers 202 immediately, same as before: the remaining items run in
    /// the background — poll `GET /v1/runs/{runId}` (or start a run and watch its
    /// events) for the live status. `resumed` says which hold this call lifted.
    private func resumeAutopilot(body: Data) -> HTTPServer.Response {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let project = json["project"] as? String else {
            return .error("Body must include \"project\"", status: 400)
        }
        guard let entry = registry.entry(forProject: project) else {
            return .error("Project not open in Kiteloop: \(project)", status: 409)
        }
        let autopilot = entry.autopilot
        let isAutopilotPaused = autopilot.isHoldingQueue
        let isProjectPaused = entry.session.project.isPaused
        guard isAutopilotPaused || isProjectPaused else {
            return .error(
                "Autopilot is not paused for this project (status: \(Self.statusLabel(autopilot.status)))",
                status: 409
            )
        }
        if isProjectPaused {
            do {
                try entry.session.project.setPaused(false, goal: entry.session.project.goal)
            } catch {
                return .error(error.localizedDescription, status: 422)
            }
        }
        let name = entry.session.project.rootURL.lastPathComponent
        guard isAutopilotPaused else {
            return .json(["project": name, "autopilot": "idle", "resumed": "paused"], status: 200)
        }
        Task { await autopilot.resume() }
        return .json(
            ["project": name, "autopilot": "resuming", "resumed": isProjectPaused ? "both" : "autopilot"],
            status: 202
        )
    }

    // MARK: - Fleet quiesce

    /// Where the fleet is, in one answer — the poll `GET /v1/projects` was being
    /// used for, reduced to the two booleans a restart actually turns on.
    ///
    /// Safe to call at any time; it starts and stops nothing, and reports
    /// `quiesced: false` for a fleet nobody has held.
    private func fleetStatus() async -> HTTPServer.Response {
        .json(Self.fleetJSON(await fleet.reading()))
    }

    /// Stop the fleet taking new work, hold every queue that is advancing, and —
    /// when asked to — wait for the last in-flight run to finish before answering.
    ///
    /// `waitSeconds` is the whole point of the endpoint. Without it a caller is
    /// back to polling, which is what took 120–520 seconds by hand and twice let
    /// the idle window close: the drivers start the next item within seconds of one
    /// ending. Here the gate is closed *first*, so the fleet can only drain, and
    /// the wait is bounded so a stuck run cannot park the connection forever.
    ///
    /// A wait that times out is a 200, not an error: `drained: false` with a count
    /// of what is still finishing is a true answer, and the caller decides whether
    /// to wait again. The only reply that could cost anything is one claiming
    /// drained when it isn't — that is the restart that strands an item.
    private func quiesceFleet(body: Data) async -> HTTPServer.Response {
        // A bare POST is the common case, so an empty body is valid — only a body
        // that is present and unreadable is a mistake worth naming.
        var waitSeconds: Double = 0
        if !body.isEmpty {
            guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
                return .error("Body must be a JSON object", status: 400)
            }
            if let raw = json["waitSeconds"] {
                guard let seconds = (raw as? NSNumber)?.doubleValue,
                      seconds >= 0, seconds <= Self.maxQuiesceWaitSeconds else {
                    return .error(
                        "\"waitSeconds\" must be a number in 0…\(Int(Self.maxQuiesceWaitSeconds))",
                        status: 400
                    )
                }
                waitSeconds = seconds
            }
        }

        var reading = await fleet.quiesce()
        if waitSeconds > 0, !reading.drained {
            _ = await fleet.awaitDrained(timeout: waitSeconds)
            // Re-read rather than trusting the boolean: the reading is what the
            // caller acts on, and it has to be the state as of the answer.
            reading = await fleet.reading()
        }
        return .json(Self.fleetJSON(reading))
    }

    /// Reopen the gate and pick back up exactly the queues the quiesce held.
    ///
    /// Always 200, including when there was nothing to resume — which is what a
    /// caller gets after the restart the quiesce was for, since the ledger lives in
    /// memory and the autopilots come back idle. That is not a failure and must not
    /// read as one; `resumed` being empty says it plainly.
    private func resumeFleet() async -> HTTPServer.Response {
        let outcome = await fleet.resume()
        var body = Self.fleetJSON(await fleet.reading())
        body["resumed"] = outcome.resumed
        body["skipped"] = outcome.skipped.map { ["project": $0.project, "reason": $0.reason] }
        return .json(body)
    }

    /// The fleet reading as JSON — the same shape from all three endpoints, so a
    /// caller can poll `GET` and read the `POST` reply with one parser.
    private static func fleetJSON(_ reading: FleetQuiesce.Reading) -> [String: Any] {
        [
            "quiesced": reading.quiesced,
            "drained": reading.drained,
            "running": reading.running,
            "summary": reading.summary,
            "projects": reading.projects.map { project in
                [
                    "id": project.id,
                    "name": project.name,
                    "status": project.status,
                    "state": project.state,
                    "running": project.running,
                    "item": project.item as Any,
                    "heldItems": project.heldItems,
                    "heldByQuiesce": project.heldByQuiesce,
                    "action": project.action?.rawValue as Any
                ]
            }
        ]
    }

    /// The ceiling on `waitSeconds`. Ten minutes covers the observed drain by a wide
    /// margin — the hand-run waits were 120–520 seconds against a 5.3-minute median
    /// run — while keeping a wedged run from parking a connection indefinitely.
    static let maxQuiesceWaitSeconds: Double = 600

    // MARK: - Memory

    /// A project's pending memory proposals — an agent's own `propose_memory`
    /// call, or a fact the librarian pass wants merged, deleted or archived.
    /// Before this, `MemoryManager.pendingProposals()` had exactly one reader,
    /// the Memory tab's view model, so a proposal filed during an unattended run
    /// sat invisible until someone opened a window. Read-only: nothing here
    /// approves, rejects or writes anything — the same accessor
    /// `ProjectSession` wires the Memory tab to.
    private func listMemoryProposals(project: String?) async -> HTTPServer.Response {
        guard let project else { return .error("Missing ?project=", status: 400) }
        guard let entry = registry.entry(forProject: project) else {
            return .error("Project not open in Kiteloop: \(project)", status: 409)
        }
        let proposals = await entry.session.orchestrator.memoryManager.pendingProposals()
        return .json([
            "project": entry.session.project.rootURL.lastPathComponent,
            "count": proposals.count,
            "proposals": proposals.map(Self.memoryProposalJSON)
        ])
    }

    /// Answers one pending memory proposal — the button on the Memory tab's card,
    /// pressed remotely. `MemoryManager.approve(proposalID:)` had exactly one
    /// non-test caller before this, so on a machine driven through the control API
    /// a proposal could be filed and never answered, and the index could never
    /// accumulate a fact.
    ///
    /// Membership is checked here rather than left to `MemoryManager`, which
    /// returns silently for an id it does not hold: over an API that reads as a
    /// write that happened. The check is against the *pending* set, so answering
    /// the same id twice is a 404 rather than a second write.
    ///
    /// A refusal stays a refusal. `approve` writes the fact before it marks the
    /// proposal approved, and rethrows ``MemoryWriteError/rejected(reason:)``
    /// having changed nothing — the cap was reached, or the fact is already
    /// covered — so the answer is 422 carrying that reason and the proposal is
    /// still pending, which is what `MemoryViewModel.lastWriteError` says in the
    /// UI. Nothing here approves anything on its own: this is an operator
    /// pressing the button from somewhere else.
    private func answerMemoryProposal(body: Data, approve: Bool) async -> HTTPServer.Response {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let project = json["project"] as? String,
              let id = json["id"] as? String else {
            return .error("Body must include \"project\" and \"id\"", status: 400)
        }
        guard let entry = registry.entry(forProject: project) else {
            return .error("Project not open in Kiteloop: \(project)", status: 409)
        }
        let memory = entry.session.orchestrator.memoryManager
        guard let proposal = await memory.pendingProposals().first(where: { $0.id == id }) else {
            return .error("No pending memory proposal '\(id)' in this project", status: 404)
        }
        do {
            if approve {
                try await memory.approve(proposalID: id)
            } else {
                try await memory.reject(proposalID: id)
            }
        } catch {
            return .error(error.localizedDescription, status: 422)
        }
        return .json([
            "project": entry.session.project.rootURL.lastPathComponent,
            "id": id,
            "agent": proposal.agentID,
            "operation": Self.memoryOperationTag(proposal.operation),
            "status": approve ? MemoryProposal.Status.approved.rawValue : MemoryProposal.Status.rejected.rawValue
        ])
    }

    /// One proposal, as the API reports it. `operation` is the machine-readable
    /// tag (`add`/`merge`/`delete`/`archive`); `topics` carries the fact names a
    /// merge, delete or archive acts on and is omitted for `add`, which acts on
    /// none.
    private static func memoryProposalJSON(_ proposal: MemoryProposal) -> [String: Any] {
        var json: [String: Any] = [
            "id": proposal.id,
            "agent": proposal.agentID,
            "status": proposal.status.rawValue,
            "source": proposal.source.rawValue,
            "operation": Self.memoryOperationTag(proposal.operation),
            "content": proposal.proposedContent,
            "rationale": proposal.rationale as Any,
            "evidence": proposal.evidence as Any,
            "timestamp": iso.string(from: proposal.timestamp)
        ]
        if !proposal.operation.topics.isEmpty { json["topics"] = proposal.operation.topics }
        return json
    }

    private static func memoryOperationTag(_ operation: MemoryProposal.Operation) -> String {
        switch operation {
        case .add: return "add"
        case .merge: return "merge"
        case .delete: return "delete"
        case .archive: return "archive"
        }
    }

    /// Set any field. Each is optional and an omitted one is left alone; the
    /// defaults (off, uncapped) are what a caller gets by never sending
    /// anything, and only an explicit `enabled: true` starts the loop.
    ///
    /// `mode` — advisory mode's retired knob — is tolerated and ignored, so a
    /// driver still sending it keeps working; it is documented as deprecated.
    private func setCoordinatorRefill(body: Data) -> HTTPServer.Response {
        guard let queueRefill else { return Self.refillUnavailable }
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return .error("Body must be a JSON object", status: 400)
        }
        // The ceiling is nullable, so an explicit null is how a caller clears it —
        // distinct from omitting the field, which leaves it as it was.
        if let raw = json["dailyBudgetUSD"] {
            // Deprecated alias since the ceilings merged: this writes the one
            // shared daily number (the portfolio's), same as the scheduling
            // PUT. Kept for contract stability; docs point callers there.
            if raw is NSNull {
                queueRefill.setBudgetLimits(capUSD: .some(nil))
                queueRefill.globalConfigStoreForBudgetAlias?.setDailyBudgetUSD(nil)
            } else if let capUSD = raw as? Double, capUSD > 0 {
                queueRefill.setBudgetLimits(capUSD: capUSD)
                queueRefill.globalConfigStoreForBudgetAlias?.setDailyBudgetUSD(capUSD)
            } else {
                return .error("\"dailyBudgetUSD\" must be a positive number or null", status: 400)
            }
        }
        // How many grooming passes the day allows. Nothing could set this before,
        // so a portfolio that groomed twelve times went quiet for the rest of the
        // day with its cost ceiling untouched — on 2026-08-10 the passes ran out
        // at $0.00 of $125 and every queue drained behind it. Raising it needed a
        // rebuild, which is the wrong shape for a ceiling an operator tunes.
        if let raw = json["maxPasses"] {
            guard let passes = raw as? Int, passes > 0 else {
                return .error("\"maxPasses\" must be a positive integer", status: 400)
            }
            queueRefill.setBudgetLimits(maxPasses: .some(passes))
        }
        // How fast an emptied queue gets refilled — the pacing knob, and the last
        // refill setting that needed a rebuild. On 2026-08-11 two projects sat
        // idle with empty queues having spent 2 of 60 passes and $2.46 of $125:
        // neither ceiling was binding, the constant interval was. Assigning it
        // restarts the timer, so the next pass comes on the new cadence.
        if let raw = json["checkIntervalSeconds"] {
            guard let seconds = raw as? Int,
                  Self.refillIntervalRange.contains(TimeInterval(seconds)) else {
                return .error(Self.badRefillInterval, status: 400)
            }
            queueRefill.checkInterval = TimeInterval(seconds)
        }
        // The selection policy — how empty is empty, how full is full enough, and
        // how much of the fleet one pass serves. It was reported by GET and
        // writable nowhere, so the only lever an operator had over a starving
        // fleet was the interval, which speeds up every project's turn equally
        // and costs a pass each time, including for projects that needed nothing.
        // Read into one copy and assigned once, so a body that gets one field
        // wrong leaves the whole policy as it found it.
        var policy = queueRefill.policy
        for field in Self.refillPolicyFields {
            guard let raw = json[field.name] else { continue }
            guard let value = raw as? Int, field.range.contains(value) else {
                return .error(Self.badRefillPolicyField(field), status: 400)
            }
            policy[keyPath: field.field] = value
        }
        queueRefill.policy = policy
        // Applied last, so switching on starts the loop against the ceiling
        // sent with it rather than the previous one.
        switch Self.boolField(json, "enabled") {
        case .absent: break
        case .invalid(let key): return Self.invalidBool(key)
        case .value(let enabled):
            // Arming is gated on the ceiling it will spend against — read after
            // the budget writes above, so one call can set both. Already-armed
            // state is not re-judged (`AutonomyArming`); the same words show on
            // the panel's toggle.
            if enabled, !queueRefill.enabled,
               let refusal = AutonomyArming.armGrooming(dailyBudgetUSD: queueRefill.sharedDailyCeilingUSD) {
                return .error(refusal.message, status: 422)
            }
            queueRefill.enabled = enabled
        }
        return .json(Self.refillPayload(queueRefill))
    }

    private static var refillUnavailable: HTTPServer.Response {
        .error("Queue refill is unavailable — no refill loop attached", status: 503)
    }

    private static let refillIntervalRange = CoordinatorQueueRefill.Defaults.checkIntervalRange

    /// Names the range, so a rejected value tells the caller what would be taken
    /// instead of only that this wasn't. A fraction, a negative and a zero all
    /// land here: none of them is an integer in the range.
    private static var badRefillInterval: String {
        "\"checkIntervalSeconds\" must be an integer in "
            + "\(Int(refillIntervalRange.lowerBound))…\(Int(refillIntervalRange.upperBound))"
    }

    /// One writable field of `QueueRefill.Policy`: its name on the wire, what it
    /// may be set to, and where it lands. A table rather than four near-identical
    /// blocks, so the reply, the validation and the document are all read off the
    /// same list and cannot describe different endpoints.
    private struct RefillPolicyField: Sendable {
        let name: String
        let range: ClosedRange<Int>
        /// Where the value lands. A key path rather than a closure so the table
        /// is a value the document's tests can read without the main actor.
        let field: any WritableKeyPath<QueueRefill.Policy, Int> & Sendable
    }

    /// The upper bounds are a sanity ceiling rather than a considered depth: a
    /// driver should not be able to ask one pass for a thousand specs, or to
    /// fan a pass out across a fleet it cannot finish before the deadline ends
    /// it. `threshold` starts at zero — "only refill a queue that is completely
    /// empty" is a policy someone may want; the rest start at one, since a target
    /// of nothing, a pass that files nothing and a pass that serves no project
    /// are all ways of switching the loop off without saying so.
    nonisolated private static let refillPolicyFields: [RefillPolicyField] = [
        RefillPolicyField(name: "threshold", range: 0...50, field: \.threshold),
        RefillPolicyField(name: "targetDepth", range: 1...50, field: \.targetDepth),
        RefillPolicyField(name: "maxItemsPerPass", range: 1...50, field: \.maxItemsPerPass),
        RefillPolicyField(name: "maxProjectsPerPass", range: 1...50, field: \.maxProjectsPerPass)
    ]

    /// Every writable policy field's name, for whoever declares the endpoint.
    nonisolated static let refillPolicyFieldNames = refillPolicyFields.map(\.name)

    /// Names the range the way `badRefillInterval` does, so a rejected value says
    /// what would have been taken instead of only that this wasn't.
    nonisolated private static func badRefillPolicyField(_ field: RefillPolicyField) -> String {
        "\"\(field.name)\" must be an integer in "
            + "\(field.range.lowerBound)…\(field.range.upperBound)"
    }

    /// Both ceilings, not just the money one. `maxPasses` was the only writable
    /// field this reply left out, so an operator who raised it got a 200 that
    /// looked exactly like a 200 for a body the endpoint had ignored — and the
    /// ceiling that stops grooming first is the one worth being able to read back.
    private static func refillPayload(_ refill: CoordinatorQueueRefill) -> [String: Any] {
        [
            "enabled": refill.enabled,
            // The shared ceiling — one number bounds grooming and running
            // alike; "groomingSpentTodayUSD" is this loop's own draw from it.
            "dailyBudgetUSD": refill.sharedDailyCeilingUSD ?? NSNull(),
            "groomingSpentTodayUSD": refill.budget.spentUSD,
            "maxPasses": refill.budget.maxPasses ?? NSNull(),
            "checkIntervalSeconds": Int(refill.checkInterval),
            // Sanitized, like GET's: a caller that set a target below the
            // threshold has to read back the policy a pass will actually apply,
            // not the one it sent.
            "policy": policyPayload(refill.policy.sanitized)
        ]
    }

    /// The selection policy, in the one shape both `GET` and `PUT` answer with.
    private static func policyPayload(_ policy: QueueRefill.Policy) -> [String: Any] {
        [
            "threshold": policy.threshold,
            "targetDepth": policy.targetDepth,
            "maxItemsPerPass": policy.maxItemsPerPass,
            "maxProjectsPerPass": policy.maxProjectsPerPass
        ]
    }

    /// What the portfolio-level queue-refill loop has been doing: its current
    /// settings, the day's budget, and the most recent passes newest first.
    ///
    /// This is the answer to the failure it was built for — a loop that ran for
    /// minutes filing nothing, with every input verifiably fine, and no way to
    /// tell whether it held, drafted nothing, or fell over in the model call.
    /// A hold is reported like any other pass, with the reason it held.
    ///
    /// The history is in memory and bounded (`maxPassHistory`), so it starts empty
    /// after a restart and only reaches back so far; the durable record of what
    /// was groomed is the ledger and the portfolio report.
    private func coordinatorRefill(limit: String?) -> HTTPServer.Response {
        guard let refill = queueRefill else { return Self.refillUnavailable }
        guard let limit = Self.parseHistoryLimit(limit) else {
            return .error("\"limit\" must be an integer in \(Self.historyLimitRange)", status: 400)
        }
        let budget = refill.budget
        // Sanitized, because that's the policy a pass actually applies —
        // reporting the raw one would explain a decision it didn't make.
        let policy = refill.policy.sanitized
        let recent = refill.passHistory.suffix(limit).reversed()
        let inFlight = refill.inFlightPass
        return .json([
            "enabled": refill.enabled,
            "passInFlight": refill.isPassing,
            // Since when, and how long a pass may run before it is ended. The
            // bare flag was the whole answer once, and on 2026-08-12 it read
            // `true` for 2h22m beside a healthy budget and a healthy pass count:
            // nothing in this reply said the loop had stopped, because nothing
            // in it could be compared against anything.
            "passInFlightSince": inFlight.map { Self.iso.string(from: $0.startedAt) } as Any,
            "passStage": inFlight?.stage.rawValue as Any,
            "passStalled": refill.stallNotice() != nil,
            "passDeadlineSeconds": Int(refill.passDeadline),
            "checkIntervalSeconds": Int(refill.checkInterval),
            "policy": Self.policyPayload(policy),
            "budget": [
                "spentUSD": budget.spentUSD,
                "capUSD": budget.capUSD as Any,
                "passesUsed": budget.passes,
                "maxPasses": budget.maxPasses as Any,
                // Beside the passes rather than inside them: `passStalled`
                // above answers "right now" and goes back to false as soon as
                // the deadline ends a stuck pass, so this is the standing
                // reading — how much of today's grooming was scheduled, spent
                // a pass and filed nothing. Always present, `0` included.
                "abandonedPasses": budget.abandonedPasses,
                // The local calendar day these counters describe, not the
                // instant `budget.day` happens to store — `Budget.rolled`
                // zeroes at local midnight, so the date must agree with that.
                "day": DayKey.string(for: budget.day),
                "exhausted": budget.isExhausted,
                // Null while there's budget left — the same phrasing a refusal
                // would record.
                "exhaustionReason": budget.exhaustionReason as Any
            ],
            "historyLimit": CoordinatorQueueRefill.maxPassHistory,
            "count": recent.count,
            "passes": recent.map(Self.refillPassJSON)
        ])
    }

    /// One pass. `outcome` is the tag to switch on; `detail` is the same line the
    /// log and the Activity feed carry. The count fields are present only for the
    /// outcome that has them, so a `filed` pass is never confused with a `held` one
    /// reporting zeroes.
    private static func refillPassJSON(_ record: CoordinatorQueueRefill.PassRecord) -> [String: Any] {
        var json: [String: Any] = [
            "at": iso.string(from: record.at),
            "outcome": record.outcome.kind,
            "detail": record.summary,
            "project": record.project as Any
        ]
        if let hold = record.outcome.hold {
            json["hold"] = hold.kind
            json["reason"] = hold.reason
        }
        switch record.outcome {
        case .filed(_, let ready, let drafts, let refused):
            json["ready"] = ready
            json["drafts"] = drafts
            // Always, including zero: a reader comparing what a pass groomed
            // with what it filed needs the third number to be present rather
            // than inferred from its absence.
            json["refused"] = refused
        case .triaged(_, let tally):
            json["retry"] = tally.retry
            json["regroom"] = tally.regroom
            json["escalate"] = tally.escalate
        case .abandoned(_, let stage, let ranFor, let why):
            // A pass that was ended rather than finished. `stage` is the
            // diagnostic — an unattended night that lost a pass needs to know
            // which call it was in, not only that it lost one.
            json["stage"] = stage.rawValue
            json["ranForSeconds"] = Int(ranFor.rounded())
            json["abandonedBecause"] = why.rawValue
        case .disabled, .held, .noDrafts:
            break
        }
        return json
    }

    // MARK: - Autonomous run scheduling

    /// What the scheduler is doing and what it has started: the kill switch,
    /// the day's ceiling, the breaker, and the recent starts newest first.
    ///
    /// This is how a night is read back — every autonomous start says which
    /// project and item it chose, why it chose them, what the budget was at the
    /// time and how the run ended. The list is bounded (`maxStartHistory`) but
    /// not lost to a restart: it is read back at launch from
    /// `~/.kiteloop/coordinator-starts.jsonl`, with a start whose process died
    /// mid-run reported as `interrupted`.
    private func coordinatorScheduling(limit: String?) -> HTTPServer.Response {
        guard let runScheduler else { return Self.schedulingUnavailable }
        guard let limit = Self.parseHistoryLimit(limit) else {
            return .error("\"limit\" must be an integer in \(Self.historyLimitRange)", status: 400)
        }
        let budget = runScheduler.dailyBudget
        let recent = runScheduler.startHistory.suffix(limit).reversed()
        let active = runScheduler.holds.active
        // Null rather than "" when nothing is held: the field says whether there
        // is a reason, and an empty string is a reason nobody wrote down.
        let heldReason: String? = active.isEmpty
            ? nil : active.map(\.reason).joined(separator: "; ")
        let json: [String: Any] = [
            "enabled": runScheduler.enabled,
            "checkIntervalSeconds": Int(runScheduler.checkInterval),
            "startInFlight": runScheduler.isStarting,
            "startsInFlight": runScheduler.startsInFlight.count,
            "maxConcurrentRuns": runScheduler.maxConcurrentRuns,
            // Still keyed `breaker`, because `resetBreaker` is still the lever
            // that clears it and a reader has to be able to find the two
            // together. What it reports is no longer a fleet-wide latch: `holds`
            // is one entry per project that is withholding starts, and `open`
            // is simply whether there are any.
            "breaker": [
                "open": !active.isEmpty,
                "reason": heldReason as Any,
                "holds": active.map(Self.holdJSON)
            ],
            "budget": [
                "budgetUSD": budget.budgetUSD as Any,
                "spentTodayUSD": budget.spentUSD,
                "remainingUSD": budget.remainingUSD as Any,
                "exhausted": budget.isExhausted
            ],
            "lastDecision": runScheduler.lastDecision.map {
                ["kind": $0.kind, "detail": $0.summary]
            } as Any,
            "historyLimit": CoordinatorRunScheduler.maxStartHistory,
            "count": recent.count,
            "starts": recent.map(Self.startJSON)
        ]
        return .json(json)
    }

    /// The kill switch, the portfolio's daily ceiling, and the way to clear
    /// every autonomous hold. Every field is optional; sending none reports the
    /// state unchanged, and only an explicit `enabled: true` ever starts runs.
    /// The two booleans a scheduling write may carry, each absent, present or
    /// malformed — one refusal names the first malformed one.
    private static func schedulingSwitches(_ json: [String: Any])
        -> (reset: Bool?, enabled: Bool?, refusal: HTTPServer.Response?) {
        var reset: Bool?
        switch boolField(json, "resetBreaker") {
        case .absent: reset = nil
        case .invalid(let key): return (nil, nil, invalidBool(key))
        case .value(let value): reset = value
        }
        switch boolField(json, "enabled") {
        case .absent: return (reset, nil, nil)
        case .invalid(let key): return (nil, nil, invalidBool(key))
        case .value(let value): return (reset, value, nil)
        }
    }

    private func setCoordinatorScheduling(body: Data) -> HTTPServer.Response {
        guard let runScheduler else { return Self.schedulingUnavailable }
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return .error("Body must be a JSON object", status: 400)
        }
        // Both switches are read before either is applied: clearing the holds
        // on the way to refusing the rest of the body would be the one write a
        // caller most wants back.
        let switches = Self.schedulingSwitches(json)
        if let refusal = switches.refusal { return refusal }
        let reset = switches.reset
        let enabled = switches.enabled
        if let refusal = Self.applySchedulingLimits(json, to: runScheduler) { return refusal }
        if reset == true { runScheduler.resetBreaker() }
        // Last, so switching on starts against holds this call may just have
        // cleared. (Flipping the switch clears them too — turning it back on is
        // a human saying they've seen the failures.)
        if let enabled, let refusal = Self.applySchedulingSwitch(enabled, to: runScheduler) { return refusal }
        return coordinatorScheduling(limit: nil)
    }

    /// Arming is gated on the ceiling it will spend against — read after the
    /// budget write, so one call can set both; already-armed state is not
    /// re-judged. Answers with the refusal, or `nil` when the switch landed.
    private static func applySchedulingSwitch(_ enabled: Bool,
                                              to runScheduler: CoordinatorRunScheduler) -> HTTPServer.Response? {
        if enabled, !runScheduler.enabled,
           let refusal = AutonomyArming.armScheduling(dailyBudgetUSD: runScheduler.portfolioDailyBudgetUSD) {
            return .error(refusal.message, status: 422)
        }
        runScheduler.enabled = enabled
        return nil
    }

    /// The portfolio ceiling and the concurrency cap a scheduling write may
    /// carry, applied in that order: a bad ceiling stops the write there, a bad
    /// cap stops it after the ceiling landed. Answers with the refusal, or `nil`
    /// when both landed.
    ///
    /// The portfolio ceiling, which until now had no route at all: raising it
    /// meant stopping the app and hand-editing global-config.json. Written
    /// before the switch, so one call can raise the budget and switch back on.
    private static func applySchedulingLimits(_ json: [String: Any],
                                              to runScheduler: CoordinatorRunScheduler) -> HTTPServer.Response? {
        if let raw = json["dailyBudgetUSD"] {
            switch parseNullableBudget(raw) {
            case .invalid: return invalidBudget()
            case .cleared: runScheduler.portfolioDailyBudgetUSD = nil
            case .ceiling(let usd): runScheduler.portfolioDailyBudgetUSD = usd
            }
        }
        if let raw = json["maxConcurrentRuns"] {
            guard let count = raw as? Int, CoordinatorRunScheduler.concurrentRunsRange.contains(count) else {
                return .error("\"maxConcurrentRuns\" must be an integer in \(CoordinatorRunScheduler.concurrentRunsRange)", status: 400)
            }
            runScheduler.maxConcurrentRuns = count
        }
        return nil
    }

    private static var schedulingUnavailable: HTTPServer.Response {
        .error("Run scheduling is unavailable — no scheduler attached", status: 503)
    }

    /// One autonomous start. `why` is the choice, not a restatement of the
    /// outcome: a night that picked the wrong project reads as a bad reason
    /// rather than as a mystery.
    private static func startJSON(_ record: CoordinatorRunScheduler.StartRecord) -> [String: Any] {
        [
            "at": iso.string(from: record.at),
            "project": record.project,
            "item": record.itemID,
            "title": record.itemTitle,
            "why": record.why,
            "budget": record.budgetText,
            "outcome": record.outcome,
            "finishedAt": record.finishedAt.map(iso.string(from:)) as Any
        ]
    }

    // MARK: - Coordinator proposals (retired)

    /// Advisory mode retired, and its inbox with it: grooming either files
    /// (switch on, within the gates and the shared ceiling) or doesn't (switch
    /// off), so there is nothing to list, approve or dismiss. The three routes
    /// stay registered to answer **410 Gone** with this note — a named,
    /// permanent ending — rather than vanishing into a 404 a driver would read
    /// as its own typo.
    static let proposalsRetiredNote = "Advisory mode retired: the proposals inbox is gone. "
        + "Grooming files gated drafts directly while it is on — read what passes filed "
        + "via GET /v1/coordinator/refill."

    private static var proposalsGone: HTTPServer.Response {
        .error(proposalsRetiredNote, status: 410)
    }

    private func hireAgent(body: Data) -> HTTPServer.Response {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let project = json["project"] as? String,
              let name = (json["name"] as? String), !name.isEmpty else {
            return .error("Body must include \"project\" and \"name\"", status: 400)
        }
        guard let entry = registry.entry(forProject: project) else {
            return .error("Project not open in Kiteloop: \(project)", status: 409)
        }
        let config = entry.session.project.loadConfig()
        // No model: the project's, else the app's Default Model, else the built-in.
        let model = (json["model"] as? String) ?? SettingInheritance.resolve(
            builtIn: ModelCatalog.defaultModelID,
            app: SettingInheritance.present(entry.session.appDefaultModel),
            project: SettingInheritance.present(config.model)).value
        let permissionMode = (json["permissionMode"] as? String)
            ?? Agent.initialPermissionMode(projectConfig: config)
        let systemPrompt = json["systemPrompt"] as? String
        let avatar = json["avatar"] as? String
        let tools = json["tools"] as? [String]
        // Default: don't steal the user's current view/selection. Opt in with select:true.
        let select: Bool
        switch Self.boolField(json, "select") {
        case .absent: select = false
        case .invalid(let key): return Self.invalidBool(key)
        case .value(let value): select = value
        }

        let agentID = entry.session.addAgent(
            name: name,
            model: model,
            permissionMode: permissionMode,
            avatar: avatar,
            systemPrompt: systemPrompt,
            tools: tools,
            select: select
        )
        return .json(["agentId": agentID, "name": name, "model": model], status: 201)
    }

    // MARK: - Run lifecycle

    /// Every run this server knows of, newest first: the ones this process
    /// started, plus what earlier processes wrote down. `historical` tells them
    /// apart — where a row was answered from, not whether its run has ended: a
    /// run that ended in this session says how it ended too.
    ///
    /// `?project=` narrows to one project and `?limit=` bounds the history, as on
    /// the other listings — without them a driver watching one project pays for
    /// months of every project's history on every poll.
    ///
    /// Two things differ from `listGrooming`, deliberately. A run record outlives
    /// its project being open, so a project that is **not** open is answered from
    /// the records rather than refused with a 409 — the run happened, and closing a
    /// tab doesn't unhappen it. And `limit` bounds only the historical rows: what
    /// this process is tracking is what a driver polls for, so the default can
    /// never hide a live run behind a page of finished ones.
    private func listRuns(project: String?, limit: String?) -> HTTPServer.Response {
        guard let limit = Self.parseHistoryLimit(limit) else {
            return .error("\"limit\" must be an integer in \(Self.historyLimitRange)", status: 400)
        }
        let matches = projectMatcher(project)

        var listed = runs.values.filter { matches($0.projectID) }.map { run -> (Date, [String: Any]) in
            let entry = registry.entries[run.projectID]
            let projectURL = entry?.session.project.rootURL ?? URL(fileURLWithPath: run.projectID)
            var listing: [String: Any] = [
                "runId": run.runId,
                "item": run.itemId,
                "title": run.title,
                "project": projectURL.lastPathComponent,
                "startedAt": Self.iso.string(from: run.startedAt),
                // A closed project can't be inspected, so its runs read "unknown".
                "state": entry.map { runState(run: run, entry: $0) } ?? "unknown",
                "historical": false
            ]
            // The workflow this run is, when that is known — what its transcript
            // directory and its metric record are keyed by, and the only way to
            // join an `auto-…` run to either.
            if let execution = run.reportedExecutionID { listing["executionId"] = execution }
            // What it has spent, and against what — the meter a headless
            // driver has to pace itself by, since the only other place the
            // figure appears is the Autopilot panel nobody is watching.
            listing.merge(costFields(run: run, entry: entry)) { _, new in new }
            // How it ended, once it has — read off the record `finalizeEndedRuns`
            // wrote before this handler ran rather than re-derived here, so a run
            // reads the same whether or not the process that ran it is still up.
            // A run still working has no ending recorded and reaches none of it.
            if runEndings[run.runId] != nil, let ended = runRecords?.record(runId: run.runId) {
                listing.merge(Self.endingFields(ended)) { _, new in new }
            }
            return (run.startedAt, listing)
        }

        // Records for runs this process is tracking are the stale copy of what is
        // above them — skip those, list the rest. `newestFirst` is already the
        // order `limit` pages, so the cap keeps the newest history rather than an
        // arbitrary slice of it.
        let history = (runRecords?.newestFirst ?? [])
            .filter { runs[$0.runId] == nil && matches($0.projectID) }
            .prefix(limit)
        for record in history {
            var listing: [String: Any] = [
                "runId": record.runId,
                "item": record.itemID,
                "title": record.title,
                "project": record.projectName,
                "startedAt": Self.iso.string(from: record.startedAt),
                "state": Self.historicalState(record),
                "historical": true
            ]
            if let execution = record.executionID { listing["executionId"] = execution }
            listing.merge(Self.recordCostFields(record)) { _, new in new }
            listing.merge(Self.endingFields(record)) { _, new in new }
            listed.append((record.startedAt, listing))
        }

        return .json(["runs": listed.sorted { $0.0 > $1.0 }.map(\.1)])
    }

    /// How a run ended, read off its durable record: when it ended, the outcome,
    /// why it ended that way (`outcome` alone puts a reviewer rejection, a cost
    /// overrun and a run nothing recorded an ending for in one column), how long
    /// it took and how the judge scored it. The one emitter of the five — both
    /// halves of `GET /v1/runs`, and a historical `/result` — so a run reads the
    /// same however it is asked for. Absent, never null, when the record holds
    /// none.
    private static func endingFields(_ record: PersistedRunRecord) -> [String: Any] {
        var fields: [String: Any] = [:]
        fields.merge(endedAtField(record)) { _, new in new }
        if let outcome = reportedOutcome(record) { fields["outcome"] = outcome }
        if let reason = record.reason { fields["reason"] = reason }
        if let duration = record.durationSec { fields["durationSec"] = duration }
        if let score = record.qualityScore {
            fields["qualityScore"] = score
            if let dims = record.judgeDimensions { fields["judgeDimensions"] = dims }
        } else if let unavailable = record.judgeUnavailable {
            fields["judgeUnavailable"] = unavailable
        }
        return fields
    }

    /// When the run reached its ending, read off its durable record wherever a
    /// readout reports an ending at all — the listing, a live `/result` and
    /// `/status`, and their historical counterparts — so one run reports the
    /// same instant however it is asked for, and a night read back the next
    /// morning lays against the app's logs without a restart first. Not
    /// derivable from `durationSec`: that measures the item, not the wall clock
    /// between `startedAt` and the close.
    ///
    /// Absent, not null, on a run that never reached an ending — an interrupted
    /// one by construction has no end time, and inventing one would put a number
    /// on a run nobody watched finish. Absent too when there is no record to
    /// read, which is the same answer for the same reason.
    private static func endedAtField(_ record: PersistedRunRecord?) -> [String: Any] {
        guard let endedAt = record?.endedAt else { return [:] }
        return ["endedAt": iso.string(from: endedAt)]
    }

    /// The one place a run is recorded, so `GET /v1/runs` and the per-run
    /// endpoints always see the same set.
    ///
    /// Also opens the run's durable record. That opening line is not a second
    /// finalization — it carries no ending — but it is the only thing that can
    /// tell a run the app died under from one this install never heard of: at the
    /// next launch an unclosed record reads `interrupted`, and an id with no
    /// record at all still 404s.
    /// First writer wins, so a run is opened once however many surfaces notice it.
    /// The one id two of them can both reach is a workflow execution: `POST
    /// /v1/runs` learns it by polling for it, and `adoptRun` is handed it the
    /// moment it exists, and which of the two arrives first is a matter of
    /// scheduling. Tracking it twice would append a second opening line and reset
    /// what the first had already recorded about the run.
    func track(_ info: RunInfo) {
        guard runs[info.runId] == nil else { return }
        runs[info.runId] = info
        runRecords?.upsert(PersistedRunRecord(
            runId: info.runId, projectID: info.projectID,
            itemID: info.itemId, title: info.title, startedAt: info.startedAt))
        // The opening line is what makes an unclosed record read `interrupted` at
        // the next launch, so this is where the thing that closes it starts: an
        // unattended night sees no request at all, and until this ran on a timer
        // every finished item's record held only the line written here.
        updateFinalizationTicker()
    }

    // MARK: - Runs this server didn't start

    /// Opens a run for the autonomous scheduler, which calls
    /// `BacklogAutopilot.start` directly and so reaches none of the tracking above.
    /// Returns the id the run is addressable by on every run surface.
    ///
    /// Recorded here rather than written by the scheduler so that a run record has
    /// one author: the ending is written by `closeRun` through the same
    /// `persist(run:entry:result:)` a control-API run ends through, and an
    /// unattended night reads back on the same terms as a driven one.
    ///
    /// The id is minted rather than the workflow's: the record is opened as the run
    /// begins, and no execution exists yet to name it after. Prefixed so a driver
    /// reading `GET /v1/runs` can see at a glance that nobody asked for this one.
    func openRun(projectID: String, itemID: String, title: String, startedAt: Date) -> String {
        let runId = "auto-\(UUID().uuidString.lowercased())"
        track(RunInfo(runId: runId, projectID: projectID, itemId: itemID, title: title,
                      startedAt: startedAt, startedHere: false))
        return runId
    }

    /// Records a run the Autopilot tab's Start button began, which reaches neither
    /// of the paths above: it calls `BacklogAutopilot.start` directly, so the run
    /// was in no `runs` entry, got no line in `control-runs.jsonl`, never appeared
    /// in `GET /v1/runs`, and could not afterwards be asked how it ended. Durable
    /// history that depends on which surface pressed start is history with holes
    /// in it, and nothing in it says which runs are missing.
    ///
    /// Adopted rather than opened: the workflow already exists by the time anyone
    /// can call this, so the run is addressable by its execution id like a
    /// control-API run. Whether that execution is a run of its own or a second
    /// name for one already open — the scheduler's, or the one `POST /v1/runs`
    /// started — is `adopt(_:)`'s question; either way, one run, one record.
    ///
    /// The ending needs no writer of its own. `finalizeEndedRuns()` closes any
    /// tracked run once the autopilot has a result for its item, and `MainWindow`
    /// asks for a pass as the run finishes so the record is closed then rather
    /// than at whatever request happens to arrive next.
    func adoptRun(projectID: String, itemID: String, title: String, executionID: String, startedAt: Date) {
        // A project the registry doesn't hold can never be inspected to close the
        // run, so opening a record for it would only mint an `interrupted` line at
        // the next launch.
        guard registry.entries[projectID] != nil else { return }
        adopt(RunInfo(runId: executionID, projectID: projectID, itemId: itemID,
                      title: title, startedAt: startedAt))
    }

    /// Closes a run `openRun` opened, now that the scheduler has seen it end.
    ///
    /// The ending itself still comes from `finalizeEndedRuns()` — the autopilot's
    /// own result, persisted the way every other ending is — rather than from
    /// whatever the caller believes happened. What this adds is the *timing*: an
    /// unattended night may see no HTTP request at all, and a record left open
    /// until one arrives reads `interrupted` at the next launch for a run that
    /// finished perfectly well.
    ///
    /// `execution` is the workflow execution the run turned out to be, when it got
    /// one. The item's charge is addressed by it, so a start refused before any
    /// workflow existed is reported with no cost rather than with an earlier
    /// attempt's.
    ///
    /// - Parameter didNotRunReason: the gate's own words, from a caller that has
    ///   already established that nothing ran — a pickup-gate refusal, almost
    ///   always. Given one, no finalization pass runs first: a refused start
    ///   returns before the autopilot clears its results, so that pass would
    ///   match the previous attempt's `ItemResult` by item id and close this
    ///   record with the earlier run's outcome, duration, branch and PR. Nil
    ///   leaves the pass its ending to find; either way the fallback below ends
    ///   the run `did-not-run`, never `blocked`: a refusal got stuck at nothing.
    func closeRun(_ runId: String, execution: String? = nil, didNotRunReason: String? = nil) async {
        if let execution { runs[runId]?.executionID = execution }
        // Skipped where the caller has said nothing ran, so no earlier attempt
        // at the same item can have its result taken for this run's.
        if didNotRunReason == nil { await finalizeEndedRuns() }
        noteExecutionID(of: runId)
        // Nothing recorded a result for it. Closed here rather than left open,
        // which would come back as `interrupted` — a claim about the app dying.
        guard let run = runs[runId], runEndings[runId] == nil,
              let entry = registry.entries[run.projectID] else { return }
        closeAsDidNotRun(run, entry: entry, reason: didNotRunReason)
    }

    /// The did-not-run ending itself, written without a finalization pass first:
    /// a refused start has no execution for that pass to inspect, and an idle
    /// autopilot reads to it as "nothing is driving this" — `cancelled`, which
    /// is a claim about a run that never existed.
    private func closeAsDidNotRun(_ run: RunInfo, entry: ControlSessionRegistry.Entry, reason: String?) {
        didNotRunIDs.insert(run.runId)
        let ending = BacklogAutopilot.ItemResult(
            id: run.itemId, title: run.title,
            outcome: .blocked(reason ?? "run ended without a recorded result"),
            duration: Date().timeIntervalSince(run.startedAt))
        runEndings[run.runId] = ending
        persist(run: run, entry: entry, result: ending)
    }

    /// How long a run request waits out a run still in flight before refusing.
    /// Long enough for the previous run's tail (the advisory quality judge is an
    /// LLM call), short enough that a driver isn't left holding a socket.
    #if DEBUG
    /// A `var` under DEBUG only, so a test can exercise the refusal without
    /// spending half a minute on it.
    static var busyWaitMilliseconds = 30_000
    #else
    static let busyWaitMilliseconds = 30_000
    #endif

    /// The previous run keeps the autopilot busy for a few seconds after its
    /// result reads "finished" — the advisory quality judge (an LLM call) and
    /// agent teardown run before the loop returns — so this waits that tail out
    /// rather than 409ing back-to-back requests (e.g. a marathon).
    ///
    /// Read from `inFlightRun()`, never from `status`: a status left non-idle by
    /// a run that never began (a cost cap firing before the first item) is not a
    /// run, and refusing every item against it left projects stuck until the app
    /// was restarted. When there really is one, the refusal names it — "still
    /// busy" with no run id is unfalsifiable from the outside.
    private func waitOutTail(_ autopilot: BacklogAutopilot) async -> BacklogAutopilot.InFlightRun? {
        var waitedMs = 0
        var inFlight = await autopilot.inFlightRun()
        while inFlight != nil, waitedMs < Self.busyWaitMilliseconds {
            try? await Task.sleep(nanoseconds: 500_000_000)
            waitedMs += 500
            inFlight = await autopilot.inFlightRun()
        }
        return inFlight
    }

    private func startRun(body: Data) async -> HTTPServer.Response {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let project = json["project"] as? String,
              let itemId = (json["item"] as? String) ?? (json["itemId"] as? String) else {
            return .error("Body must be JSON: { \"project\": \"…\", \"item\": \"…\" }", status: 400)
        }
        // The fleet gate, before anything else this could do. A driver on its
        // usual cadence would otherwise start a fresh run into a fleet that was
        // being drained for a restart, which is exactly how the hand-run idle
        // window kept closing. Refused as 409 (retry later), never 422: the item
        // is fine, the moment is not.
        if fleet.isQuiesced {
            return .error(
                "The fleet is quiesced for a restart — no new runs are being accepted. "
                + "POST /v1/fleet/resume to lift the hold, or GET /v1/fleet/quiesce to see it.",
                status: 409
            )
        }
        guard let entry = registry.entry(forProject: project) else {
            return .error("Project not open in Kiteloop: \(project)", status: 409)
        }
        // The project's own hold, named the same way the fleet-wide one just was
        // above. Pausing is one act now — the fleet board's switch and a held
        // autopilot queue both read the same here — so a driver's usual cadence
        // cannot start a fresh run into a project it, or a person, just paused.
        if Self.isPaused(entry) {
            return .error(
                "This project is paused — no new runs are being accepted. "
                + "POST /v1/autopilot/resume to lift the hold, or GET /v1/projects to see it.",
                status: 409
            )
        }
        let autopilot = entry.autopilot
        let items = entry.session.backlogViewModel.backlogFile?.sections.flatMap(\.items) ?? []
        guard let item = items.first(where: { $0.id == itemId }) else {
            return .error("No backlog item '\(itemId)' in this project", status: 404)
        }
        // What blocks this run is another run, not a flag — see `waitOutTail`.
        if let inFlight = await waitOutTail(autopilot) {
            return .error("Autopilot is still busy for this project — \(inFlight.summary)", status: 409)
        }
        // Nothing is running, so nothing may claim to be: a run request is one of
        // the two places a stale claim is put right (the other is opening the
        // project), and leaving it would keep the Autopilot tab's Start disabled.
        await autopilot.reconcileStatus(reason: "run requested")
        guard autopilot.workerAgentID != nil, autopilot.reviewerAgentID != nil else {
            return .error("Configure worker and reviewer agents in the Autopilot screen first", status: 409)
        }

        // Stamped before the queue moves, not after the execution id arrives a few
        // seconds later: `GET /v1/runs/{id}/log` slices the autopilot's log by this
        // instant, and the opening lines ("Executing: …", the cost-cap line) are
        // written in that gap.
        let startedAt = Date()
        let priorExec = autopilot.currentExecutionID
        let priorAttempt = autopilot.lastStartOutcome?.attempt ?? 0
        autopilot.selectedItemIDs = [itemId]
        Task { await autopilot.start() }

        switch await awaitStart(autopilot: autopilot, priorExecutionID: priorExec,
                                priorAttempt: priorAttempt,
                                timeoutMilliseconds: Self.startPollMilliseconds) {
        case .started(let runId):
            track(RunInfo(runId: runId, projectID: entry.session.project.id, itemId: itemId, title: item.title, startedAt: startedAt))
            return .json(["runId": runId, "item": itemId, "title": item.title, "status": "running"], status: 202)

        case .refused(let outcome):
            return .error("Run did not start: \(outcome.detail)", status: Self.httpStatus(for: outcome))

        case .pending:
            // Nothing refused this. The workflow is spinning up and has not named
            // itself yet, and the one thing this must not do is call that a
            // failure: a driver reads 422 as permanent and drops the item for
            // good — twice on 2026-08-10, once for an item that was executing as
            // it read the refusal. 202 with no id says what is true, and points
            // at the two places the id turns up once it exists.
            watchPendingStart(entry: entry, autopilot: autopilot, item: item,
                              priorExecutionID: priorExec, priorAttempt: priorAttempt, startedAt: startedAt)
            return Self.startingReply(item: item)
        }
    }

    /// The undecided answer: 202, no id, and where the id — or a late refusal —
    /// will turn up.
    private static func startingReply(item: BacklogItem) -> HTTPServer.Response {
        .json([
            "item": item.id,
            "title": item.title,
            "status": "starting",
            "detail": "The run was accepted and is spinning up; its id was not available within "
                    + "\(startPollMilliseconds) ms. Read it from GET /v1/autopilot?project= "
                    + "(run.runId) or GET /v1/projects, or post this item again — while it is in "
                    + "flight the 409 names the run rather than starting it twice. A pickup gate "
                    + "that refuses it after this reply closes a did-not-run record in "
                    + "GET /v1/runs?project= with the gate's reason, and writes it to the item's Notes."
        ], status: 202)
    }

    /// Keeps watching a start this request answered `starting` for, until the
    /// autopilot decides it, so a refusal that lands after the reply is not lost.
    ///
    /// The undecided 202 was right — a false 422 had dropped executing items —
    /// but what followed it was silence: on 2026-09-03 the grounding check refused
    /// an item after the window had closed, the refusal went to the metrics ledger
    /// as a pickup refusal and nowhere a driver reads, and the reason only
    /// appeared when the item was posted a second time. A started run needs
    /// nothing from here (`adoptRun` opens it the moment the execution exists);
    /// a refused one gets the record and the note it would have had inside the
    /// window, and a watch that runs out of its own window records nothing.
    private func watchPendingStart(entry: ControlSessionRegistry.Entry, autopilot: BacklogAutopilot,
                                   item: BacklogItem, priorExecutionID: String?, priorAttempt: Int,
                                   startedAt: Date) {
        Task { [weak self] in
            guard let self else { return }
            let resolution = await self.awaitStart(autopilot: autopilot, priorExecutionID: priorExecutionID,
                                                   priorAttempt: priorAttempt,
                                                   timeoutMilliseconds: Self.pendingWatchMilliseconds)
            guard case .refused(let outcome) = resolution else { return }
            self.recordRefusedStart(entry: entry, item: item, outcome: outcome, startedAt: startedAt)
        }
    }

    /// A pickup refusal as a run that did not run: one closed record, so
    /// `GET /v1/runs` and `/result` answer for it, and one Notes line, so the
    /// item itself says why nothing happened. The id carries the shape because
    /// no execution ever existed to name it.
    private func recordRefusedStart(entry: ControlSessionRegistry.Entry, item: BacklogItem,
                                    outcome: BacklogAutopilot.StartOutcome, startedAt: Date) {
        let run = RunInfo(runId: "did-not-run-" + UUID().uuidString.lowercased(),
                          projectID: entry.session.project.id, itemId: item.id,
                          title: item.title, startedAt: startedAt)
        track(run)
        closeAsDidNotRun(run, entry: entry, reason: outcome.detail)
        entry.session.backlogViewModel.appendNote(itemID: item.id, "run did not start: \(outcome.detail)")
    }

    /// How long a `starting` reply's watch keeps waiting for the autopilot to
    /// decide. Longer than the reply's own window because the pickup gates that
    /// decide late do real work first — the grounding index reads every source
    /// file in the tree — and a watch that gives up before them is the silence
    /// this exists to end.
    #if DEBUG
    static var pendingWatchMilliseconds = 120_000
    #else
    static let pendingWatchMilliseconds = 120_000
    #endif

    /// How long `POST /v1/runs` waits for a starting run to name itself before it
    /// answers `starting` instead of an id.
    ///
    /// Spin-up is agent sessions, possibly a worktree, then the workflow — usually
    /// well inside this, occasionally not. What matters is that running out of it
    /// is not an answer about whether the run started, only about whether this
    /// request could name it yet.
    #if DEBUG
    /// A `var` under DEBUG only, so a test can reach the slow-spin-up path without
    /// waiting the production window out.
    static var startPollMilliseconds = 4_000
    #else
    static let startPollMilliseconds = 4_000
    #endif

    /// How often `awaitStart` looks.
    private static let startPollStepMilliseconds = 100

    /// What a start this server asked for turned out to be.
    enum StartResolution: Equatable {
        /// The workflow spun up; this is the id it is addressable by.
        case started(runID: String)
        /// A gate refused it, in that gate's own words.
        case refused(BacklogAutopilot.StartOutcome)
        /// Undecided: nothing refused it and no execution has appeared yet. Not a
        /// refusal, and must never be reported as one.
        case pending
    }

    /// Watches a start already asked for until a spinning-up run can be told
    /// apart from a refused one.
    ///
    /// Polls rather than awaiting `start()`, which does not return until the whole
    /// queue is done — waiting on it would mean answering the HTTP request when
    /// the run was over. The refusal is read from `lastStartOutcome`, whose
    /// `attempt` must be past `priorAttempt`: an earlier run's refusal is not an
    /// answer about this request.
    func awaitStart(
        autopilot: BacklogAutopilot,
        priorExecutionID: String?,
        priorAttempt: Int,
        timeoutMilliseconds: Int
    ) async -> StartResolution {
        var waited = 0
        while true {
            if let id = autopilot.currentExecutionID, id != priorExecutionID {
                return .started(runID: id)
            }
            if let outcome = autopilot.lastStartOutcome, outcome.attempt > priorAttempt,
               !outcome.isAccepted {
                return .refused(outcome)
            }
            // An accepted outcome is not an answer yet — the id is still coming —
            // so the wait runs on either way until the window closes.
            guard waited < timeoutMilliseconds else { return .pending }
            try? await Task.sleep(nanoseconds: UInt64(Self.startPollStepMilliseconds) * 1_000_000)
            waited += Self.startPollStepMilliseconds
        }
    }

    /// What a refused start is worth as HTTP.
    ///
    /// 422 stays what it has always meant here: the pickup gates refusing *this
    /// item* — ungroomed, not ready, retired, not grounded, wrong status — which
    /// stays true until somebody re-grooms it. A driver reads 422 as permanent
    /// and drops the item from its rotation, which is right for those and wrong
    /// for everything else. A spent daily budget, a project without agent
    /// sessions, a run already in flight: all conditions of the moment, and the
    /// caller should come back rather than write the item off.
    static func httpStatus(for outcome: BacklogAutopilot.StartOutcome) -> Int {
        switch outcome.refusal {
        case .noRunnableItems: return 422
        default: return 409
        }
    }

    private func runStatus(runId: String) async -> HTTPServer.Response {
        guard let run = runs[runId], let entry = registry.entries[run.projectID] else {
            guard let record = runRecords?.record(runId: runId) else {
                return .error("Unknown run: \(runId)", status: 404)
            }
            // Nothing is polling any more, so there is nothing live to report:
            // the same closing readout `/result` gives, with an empty event list.
            // Bus history isn't durable and this endpoint has never claimed to
            // hold more than the last 20 events.
            var body = historicalBody(record)
            body["events"] = [[String: Any]]()
            if let entry = registry.entries[record.projectID] {
                body["autopilot"] = Self.statusLabel(entry.autopilot.status)
            }
            return .json(body)
        }
        let exec = await entry.session.orchestrator.workflowEngine.execution(id: runId)
        let backlogStatus = itemStatus(entry: entry, itemId: run.itemId)
        let events = await entry.session.orchestrator.eventBus.recentEvents()
            .filter { $0.payload["executionID"] == runId }
            .suffix(20)
            .map { event -> [String: Any] in
                ["ts": Self.iso.string(from: event.timestamp), "type": event.type.rawValue, "source": event.source]
            }

        var body: [String: Any] = [
            "runId": runId,
            "item": run.itemId,
            "title": run.title,
            "startedAt": Self.iso.string(from: run.startedAt),
            "autopilot": Self.statusLabel(entry.autopilot.status),
            "itemStatus": backlogStatus,
            "events": Array(events),
            "historical": false
        ]
        // Absent, not null, on a run that never got an execution — see `liveRunFields`.
        if let execution = run.reportedExecutionID { body["executionId"] = execution }
        // And when the run this endpoint is being polled about has already ended,
        // the instant it did — a poll loop sitting here reads it off the record
        // the run was closed with rather than waiting for a restart to be told.
        // A run still working has an open record and reaches none of it.
        body.merge(Self.endedAtField(runRecords?.record(runId: runId))) { _, new in new }
        if let exec {
            body["currentNode"] = exec.currentNode
            body["executionStatus"] = exec.status.rawValue
        }
        if let question = approvalQuestion(entry: entry, runId: runId) { body["approvalQuestion"] = question }
        return .json(body)
    }

    private func runResult(runId: String) async -> HTTPServer.Response {
        guard let run = runs[runId], let entry = registry.entries[run.projectID] else {
            guard let record = runRecords?.record(runId: runId) else {
                return .error("Unknown run: \(runId)", status: 404)
            }
            // 200, not 202: there is nothing left to wait for. A poll loop sitting
            // on this endpoint across a restart has to be released, not parked
            // forever on a run no process is driving.
            return .json(historicalBody(record))
        }
        let backlogStatus = itemStatus(entry: entry, itemId: run.itemId)

        // The ending the record was closed with, not the autopilot's live results:
        // those are cleared at the start of the next run, and a finished run has to
        // keep answering for itself after that.
        if let result = runEndings[runId] {
            return .json(finishedRunBody(run: run, entry: entry, result: result, backlogStatus: backlogStatus))
        }

        // Still open → working, or paused at the human approval gate.
        var body: [String: Any] = [
            "runId": runId,
            "item": run.itemId,
            "title": run.title,
            "startedAt": Self.iso.string(from: run.startedAt),
            "state": runState(run: run, entry: entry),
            "itemStatus": backlogStatus,
            "historical": false
        ]
        // Spend so far, and the execution it is: the 202 is what a poll loop
        // sits on, so this is where both are read from most.
        body.merge(liveRunFields(run: run, entry: entry)) { _, new in new }
        if let question = approvalQuestion(entry: entry, runId: runId) { body["approvalQuestion"] = question }
        return .json(body, status: 202)
    }

    /// The 200 for a run this process finished and is still tracking. Deliberately
    /// the same shape as `historicalBody`, plus what only a live run can say — the
    /// two are what a driver polling across a restart reads in turn.
    private func finishedRunBody(run: RunInfo, entry: ControlSessionRegistry.Entry,
                                 result: BacklogAutopilot.ItemResult, backlogStatus: String) -> [String: Any] {
        var body: [String: Any] = [
            "runId": run.runId,
            "item": run.itemId,
            "title": run.title,
            // What `durationSec` is measured from, and the only thing that
            // places the run in time — a driver holding a runId would
            // otherwise have to list every run to tell last night's from
            // last month's.
            "startedAt": Self.iso.string(from: run.startedAt),
            "state": "finished",
            "outcome": didNotRunIDs.contains(run.runId) ? "did_not_run" : Self.outcomeLabel(result.outcome),
            "durationSec": Int(result.duration),
            "itemStatus": backlogStatus,
            "historical": false
        ]
        // The other end of the bracket, taken off the record this run was closed
        // with rather than from the clock now — the same instant the readout
        // after a restart reports, from the same place. See `endedAtField`.
        body.merge(Self.endedAtField(runRecords?.record(runId: run.runId))) { _, new in new }
        if case .blocked(let reason) = result.outcome { body["reason"] = reason }
        // What the run finally cost, against the ceiling it was measured
        // against, and which execution it turned out to be — the same fields
        // `GET /v1/runs` carries, so a driver can compare the forecast it
        // paced itself by with the bill, and reach the transcript.
        body.merge(liveRunFields(run: run, entry: entry)) { _, new in new }
        if let branch = result.branch { body["branch"] = branch }
        // Only when the run approved the item itself. Absent is the ordinary
        // case and means nobody has approved it *here* — a driver polling a
        // `done` run would otherwise have no way to tell the setting's
        // acceptance from a person's.
        if let approval = result.approval { body["approval"] = approval.rawValue }
        body.merge(Self.mergeFields(merged: result.merged, commit: result.mergeCommit)) { _, new in new }
        // Only when one was opened. A run that skipped the PR says why in
        // the item's Notes, which is where a reason belongs — a `null` here
        // would tell a driver nothing it could act on.
        if let pr = result.pullRequestURL { body["pullRequestUrl"] = pr }
        body.merge(metricFields(run: run, entry: entry)) { _, new in new }
        return body
    }

    /// A run's coarse lifecycle state: a closed record is `finished`; an open one
    /// is either paused at a human gate or still working.
    private func runState(run: RunInfo, entry: ControlSessionRegistry.Entry) -> String {
        if runEndings[run.runId] != nil { return "finished" }
        let awaiting = approvalQuestion(entry: entry, runId: run.runId) != nil
            || itemStatus(entry: entry, itemId: run.itemId) == BacklogItemStatus.awaitingApproval.rawValue
        return awaiting ? "awaiting_approval" : "running"
    }

    /// Tracked runs still open — working or paused at the human gate. Runs whose
    /// project has since been closed read `unknown` in `GET /v1/runs` and are not
    /// counted here: nothing is driving them any more.
    private var activeRunCount: Int {
        runs.values.filter { registry.entries[$0.projectID] != nil && runEndings[$0.runId] == nil }.count
    }

    /// Closes every tracked run that has ended, and is the only thing that does.
    /// Called once per request, before any handler reads a run — and, while
    /// anything it holds is still open, every `finalizationInterval` whether or
    /// not a request ever arrives.
    ///
    /// The question it asks of each open run is "is anything still driving this?",
    /// which is what makes it whole: a run left behind by an ending nobody thought
    /// to handle — cancelled, stalled, timed out, or an app-side session that died
    /// under it — closes here just the same, because the answer is no.
    ///
    /// Closing keeps the outcome, so `GET /v1/runs/{id}/result` still answers for a
    /// finished run long after the autopilot has cleared its own in-memory results
    /// for the next one. That clearing is why deriving `finished` from those results
    /// wasn't enough: runs that had merged days earlier read `running` again.
    private func finalizeEndedRuns() async {
        snapshotLiveCosts()
        for (runId, run) in runs {
            // A closed project can't be inspected. Its runs read `unknown` and are
            // counted as neither open nor finished, as they were before.
            guard let entry = registry.entries[run.projectID] else { continue }
            // The autopilot's own result is the best ending there is. While the run
            // still owns the autopilot this is re-read rather than frozen: the
            // quality judge attaches its score seconds after the item lands.
            if let result = endingResult(run: run, entry: entry),
               runEndings[runId] == nil || isWorking(entry: entry, runId: runId) {
                runEndings[runId] = result
                persist(run: run, entry: entry, result: result)
                continue
            }
            guard runEndings[runId] == nil else { continue }
            if let ending = await endingWithoutResult(run: run, entry: entry) {
                runEndings[runId] = ending
                persist(run: run, entry: entry, result: ending)
            }
        }
        sweepEndedRuns()
        // Whatever this pass just closed, the ticker only has work while some run
        // is still open — so the pass that empties the set is also what stops it.
        updateFinalizationTicker()
    }

    /// How many ended runs stay in memory once they have closed — the live half's
    /// bound, and the in-memory counterpart of the durable half's
    /// `RunRecordStore.retentionLimit`.
    ///
    /// It needs one because `GET /v1/runs` deliberately lists every run this
    /// process is tracking regardless of `limit`, so that a default page of
    /// finished work can never hide a live run: without a bound here, an app left
    /// up for a week — the way this one is meant to be left — answers every poll
    /// with every run it has ever tracked, and the same map is walked in full on
    /// every finalization pass besides. Smaller than the durable limit because
    /// this half is the one nothing pages and everything re-emits: a night is a
    /// few dozen runs, so 50 keeps whatever a driver is still plausibly polling
    /// about live, and older work is listed from its record instead — the same
    /// rows, carrying `historical`.
    static let endedRunRetentionLimit = 50

    /// Drops the ended runs this process no longer needs to hold, keeping the
    /// `endedRunRetentionLimit` most recently started of them. Called where the
    /// finalization pass ends, because that pass is the only thing that makes a
    /// run ended.
    ///
    /// Only a run `runRecords` holds a record for is swept: that record is what
    /// answers for it afterwards — `historicalBody` for `/result`, the listing's
    /// history half for `GET /v1/runs` — so a run without one would lose its only
    /// copy. An open run is never swept however much finished work sits behind
    /// it in the map: reporting exactly those is what the live half is for.
    private func sweepEndedRuns() {
        let ended = runs.values.filter {
            runEndings[$0.runId] != nil && runRecords?.record(runId: $0.runId) != nil
        }
        guard ended.count > Self.endedRunRetentionLimit else { return }
        let sorted = ended.sorted { $0.startedAt > $1.startedAt }
        for run in sorted.dropFirst(Self.endedRunRetentionLimit) {
            runs[run.runId] = nil
            runEndings[run.runId] = nil
            didNotRunIDs.remove(run.runId)
        }
    }

    /// The autopilot result that is *this* run's ending.
    ///
    /// Addressed by execution id, the way `costFields` addresses the charge: an
    /// item that runs twice in one session (rejected, returned to `ready`, run
    /// again) leaves two entries in one result list, both keyed by the item id,
    /// and matching on that alone closed whichever record was still open with the
    /// later run's outcome, duration, branch and PR URL. A record closes when a
    /// request arrives or when the ticker's pass comes round, so the window where
    /// the first record is still open when the second run lands is narrow on an
    /// unattended night rather than the whole night — and still a window.
    ///
    /// The item-id match survives as a fallback for results carrying no execution
    /// id — those already in memory when this shipped, and the error path that
    /// never got one — so nothing is stranded open. A result stamped with a
    /// *different* execution is that run's ending and is passed over.
    private func endingResult(
        run: RunInfo, entry: ControlSessionRegistry.Entry
    ) -> BacklogAutopilot.ItemResult? {
        let results = entry.autopilot.results
        // Nothing identifies this run yet — a scheduler-opened one before
        // `closeRun` reports its execution. The item id is all there is, as it
        // always was.
        guard let execution = run.reportedExecutionID else {
            return results.last(where: { $0.id == run.itemId })
        }
        return results.last(where: { $0.executionID == execution })
            ?? results.last(where: { $0.id == run.itemId && $0.executionID == nil })
    }

    /// The last finalization pass a closing project gets, called by
    /// `ControlSessionRegistry.unregister` before the entry goes.
    ///
    /// A run does not need the app to die to be stranded — closing its tab was
    /// enough. `finalizeEndedRuns()` can only close a run whose project it can
    /// still inspect, so after the entry is dropped that run's record stays open
    /// for ever and the next launch reads it as `interrupted`: the store's word
    /// for "the app died under it", said about work that may have merged and
    /// opened a PR.
    ///
    /// It is the ordinary pass, not a special ending: a run that genuinely had
    /// not ended is left open here, because it really is being interrupted.
    func finalizeRunsBeforeProjectCloses() async {
        await finalizeEndedRuns()
    }

    /// The pass the ticker runs, and the one anything else can ask for without
    /// making a request. Same body as every other trigger: a run that has ended
    /// is closed with the ending it reached, and one still going is left open.
    func finalizeOpenRuns() async {
        await finalizeEndedRuns()
    }

    /// Whether the repeating pass is currently scheduled. Nothing in the app reads
    /// it — it is how a test can see that the ticker stops once the last record
    /// has closed, rather than waiting out a timer that would prove nothing either
    /// way.
    var isFinalizationTickerRunning: Bool { finalizationTicker != nil }

    /// Starts or stops the repeating pass, from the one question that decides it:
    /// is any tracked run still open?
    ///
    /// Called where a run is opened and at the end of every finalization pass, so
    /// the ticker exists exactly while there is something for it to close. It is
    /// deliberately not tied to `start(port:)`/`stop()` — for the reason the
    /// `registry.finalizeRuns` wiring in `init` already gives, a server switched
    /// off in Settings still holds the runs it began, and those records still
    /// have to close.
    private func updateFinalizationTicker() {
        guard activeRunCount > 0 else {
            finalizationTicker?.cancel()
            finalizationTicker = nil
            return
        }
        guard finalizationTicker == nil else { return }
        finalizationTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.finalizationInterval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                // Which cancels this very task once the last open run has closed,
                // so the loop ends here rather than on the next iteration's check.
                await self.finalizeOpenRuns()
            }
        }
    }

    /// The last finalization pass of all, called by `AppDelegate` as an orderly
    /// quit is answered.
    ///
    /// The ticker closes what has ended within a `finalizationInterval` of its
    /// ending, so what is left here is the interval itself: an item that lands in
    /// the seconds before the app is quit, whose pass never comes. The quit is the
    /// last moment anything can still inspect the project the run belongs to, so
    /// it is the last chance to say how the run actually ended — and the next
    /// launch would otherwise read a run that merged, and may have opened a PR, as
    /// `interrupted`.
    ///
    /// The ordinary pass, not a special ending, on the same terms as
    /// `finalizeRunsBeforeProjectCloses()`: a run that genuinely had not ended is
    /// left open, because it really is being interrupted. Crash and force quit
    /// reach nothing here at all, and are correctly left to that reading.
    func finalizeRunsAtQuit() async {
        await finalizeEndedRuns()
    }

    /// Writes the ending down, where it outlives the app. Called from
    /// `finalizeEndedRuns` and nowhere else, so every exit path that route
    /// already covers — cancelled, stalled, timed out, finished, or a session
    /// that died under the run — is persisted on the same terms, and there is
    /// exactly one writer of a terminal record.
    ///
    /// Re-derived rather than frozen while the run still owns its autopilot: the
    /// quality judge attaches its score seconds after the item lands. The store
    /// drops a record identical to the one it holds, so a poll loop over a
    /// settled run writes nothing.
    private func persist(run: RunInfo, entry: ControlSessionRegistry.Entry, result: BacklogAutopilot.ItemResult) {
        guard let runRecords else { return }
        var record = runRecords.record(runId: run.runId)
            ?? PersistedRunRecord(runId: run.runId, projectID: run.projectID,
                                  itemID: run.itemId, title: run.title, startedAt: run.startedAt)
        // First close wins: a later pass adds the judge's verdict, it does not
        // re-date the ending.
        record.endedAt = record.endedAt ?? Date()
        // `closeRun`'s fallback marks its own runs: the item never reached an
        // ending of its own, so `.blocked` — the only vocabulary a synthetic
        // `ItemResult` here can carry — would misreport a refusal that spent
        // nothing as a run that got stuck.
        record.outcome = didNotRunIDs.contains(run.runId) ? .didNotRun : Self.persistedOutcome(result.outcome)
        record.durationSec = Int(result.duration)
        record.itemStatus = itemStatus(entry: entry, itemId: run.itemId)
        if case .blocked(let reason) = result.outcome { record.reason = reason }
        record.branch = result.branch
        record.pullRequestURL = result.pullRequestURL
        // Who cleared the gate, when the run cleared it itself. This is the only
        // copy that survives a restart, and "done" without it cannot be told
        // from work a person accepted.
        record.approval = result.approval?.rawValue
        record.merged = result.merged
        record.mergeCommit = result.mergeCommit
        // Same first-close-wins treatment as `endedAt`, so a later judge pass
        // cannot rewrite which execution the run was. A record still holding nil
        // is not "won" — the id simply wasn't known yet, and a scheduler-opened
        // run only learns it at `closeRun`.
        record.executionID = record.executionID ?? run.reportedExecutionID

        let cost = costFields(run: run, entry: entry)
        record.costUSD = cost["costUSD"] as? Double
        record.costCapUSD = cost["costCapUSD"] as? Double
        record.predictionSource = cost["predictionSource"] as? String

        if let metric = Self.metric(of: run, entry: entry) {
            record.qualityScore = metric.qualityScore
            record.judgeDimensions = metric.qualityScore != nil ? metric.judgeDimensions : nil
            record.judgeUnavailable = metric.qualityScore == nil ? metric.judgeUnavailableReason : nil
            Self.copyVerdict(metric.verify, onto: &record)
        }
        runRecords.upsert(record)
    }

    /// Writes down which workflow execution a run turned out to be, for the one
    /// case `persist` cannot reach: a scheduler-opened run whose record was
    /// already closed by a poll landing in the gap between its result and
    /// `closeRun`. The execution id arrives after that closing, and `persist`
    /// deliberately does not re-derive a record it has finished with.
    ///
    /// Not an ending, so it does not go through `persist` and cannot invent one:
    /// it fills a field that was empty and writes nothing otherwise.
    private func noteExecutionID(of runId: String) {
        guard let runRecords, let execution = runs[runId]?.reportedExecutionID,
              var record = runRecords.record(runId: runId), record.executionID == nil else { return }
        record.executionID = execution
        runRecords.upsert(record)
    }

    // MARK: - Runs this process is not running

    /// The readout for a run answered from its durable record rather than from
    /// anything live — finished before the app restarted, interrupted by one, or
    /// belonging to a project that has since been closed.
    ///
    /// Deliberately the same shape as the live `/result` body, minus what only a
    /// live run can say. `historical` is the flag a driver branches on.
    private func historicalBody(_ record: PersistedRunRecord) -> [String: Any] {
        var body: [String: Any] = [
            "runId": record.runId,
            "item": record.itemID,
            "title": record.title,
            // The record's own start, in the spelling `GET /v1/runs` uses. A
            // durable record read back after a restart reports `durationSec`
            // with nothing to anchor it to otherwise.
            "startedAt": Self.iso.string(from: record.startedAt),
            "state": Self.historicalState(record),
            "itemStatus": historicalItemStatus(record),
            "historical": true
        ]
        // Absent, not null, on a record written before the field existed and on a
        // run that never got an execution — the same rule the cost fields follow,
        // for the same reason: an invented id would point at a transcript that
        // isn't there.
        if let execution = record.executionID { body["executionId"] = execution }
        body.merge(Self.endingFields(record)) { _, new in new }
        if let branch = record.branch { body["branch"] = branch }
        if let pr = record.pullRequestURL { body["pullRequestUrl"] = pr }
        // The same rule as the live reading above: present only when the run
        // itself approved the item, so a night read back the next morning still
        // says which of its `done` runs nobody looked at.
        if let approval = record.approval { body["approval"] = approval }
        body.merge(Self.mergeFields(merged: record.merged, commit: record.mergeCommit)) { _, new in new }
        body.merge(Self.recordCostFields(record)) { _, new in new }
        body.merge(Self.verifyFields(record)) { _, new in new }
        return body
    }

    /// The backlog is the live truth about where the item stands, and it outlives
    /// the run — so when the project is open, read it there and fall back to what
    /// the record froze only when the item (or the project) can't be read.
    private func historicalItemStatus(_ record: PersistedRunRecord) -> String {
        if let entry = registry.entries[record.projectID] {
            let live = itemStatus(entry: entry, itemId: record.itemID)
            if live != "unknown" { return live }
        }
        return record.itemStatus ?? "unknown"
    }

    /// `interrupted` for a run the app stopped under, `finished` for one that
    /// reached an ending, and `unknown` for a run still open in a record this
    /// process wrote — its project was closed out from under it, which is what
    /// `GET /v1/runs` has always called such a run.
    private static func historicalState(_ record: PersistedRunRecord) -> String {
        switch record.outcome {
        case .interrupted: return "interrupted"
        case .some: return "finished"
        case nil: return "unknown"
        }
    }

    /// The outcome to report, which an interrupted run does not have: it was cut
    /// off before reaching one, and `state` already says so. Calling the
    /// interruption an outcome would put it in the same column as `blocked` for a
    /// driver counting how its queue went.
    private static func reportedOutcome(_ record: PersistedRunRecord) -> String? {
        guard let outcome = record.outcome, reportableOutcomes.contains(outcome.rawValue) else { return nil }
        return outcome.rawValue
    }

    /// Every value `reportedOutcome` can return, for whoever declares the
    /// schemas — the run outcomes minus `interrupted`, which is withheld above.
    /// A schema listing fewer describes a body a driver can be handed and
    /// cannot validate; `did_not_run` was missing from three of them.
    nonisolated static let reportableOutcomes: [String] =
        PersistedRunRecord.Outcome.allCases.filter { $0 != .interrupted }.map(\.rawValue)

    /// The refusal for an endpoint that only means something for a live run. A
    /// run that is merely over is a **409** naming its state, not a 404: the id
    /// is real, and telling a driver its run never existed is how a restart used
    /// to read. An id with no record at all is still unknown.
    private func notLive(_ runId: String, _ because: String) -> HTTPServer.Response {
        guard let record = runRecords?.record(runId: runId) else {
            return .error("Unknown run: \(runId)", status: 404)
        }
        return .error("Run \(runId) is \(Self.historicalState(record)) and not live — \(because)", status: 409)
    }

    /// How a run ended when the autopilot recorded no result for it — cancelled
    /// from under it, or a run whose session died mid-workflow. `nil` while the run
    /// is still genuinely open.
    private func endingWithoutResult(
        run: RunInfo,
        entry: ControlSessionRegistry.Entry
    ) async -> BacklogAutopilot.ItemResult? {
        // Still the autopilot's current work? Then it is executing, whatever the
        // item and the execution say: an item is marked `blocked` or `done` well
        // before the run around it has finished tearing down and recording itself.
        guard !isWorking(entry: entry, runId: run.runId) else { return nil }

        func ending(_ outcome: BacklogAutopilot.ItemResult.Outcome) -> BacklogAutopilot.ItemResult {
            BacklogAutopilot.ItemResult(
                id: run.itemId,
                title: run.title,
                outcome: outcome,
                duration: Date().timeIntervalSince(run.startedAt)
            )
        }

        // The item is the app's own record of whether work is still happening —
        // autopilot moves it out of the working stages on every ending, including
        // the ones that record no result. An item that can't be read (deleted, or a
        // backlog that never loaded) is not evidence either way, so it says nothing.
        let status = itemFor(entry: entry, itemId: run.itemId)?.status
        switch status {
        case .done: return ending(.done)
        case .blocked: return ending(.blocked("run ended with the item blocked"))
        case .ready, .draft: return ending(.cancelled)
        case .active, .inReview, .awaitingApproval, nil: break
        }

        // The item still reads as work in progress, so ask the workflow. A settled
        // execution is over even when the item hasn't caught up — the cancel case,
        // where the workflow is cancelled up front and autopilot only unwinds the
        // item a poll or two later.
        guard let exec = await entry.session.orchestrator.workflowEngine.execution(id: run.runId),
              exec.status.isTerminal else { return nil }
        switch exec.status {
        case .cancelled: return ending(.cancelled)
        case .timedOut: return ending(.blocked("workflow timed out"))
        case .failed: return ending(.blocked("workflow failed"))
        default:
            // Completed, but nothing recorded the item: the run around the
            // workflow didn't survive to write its result. Report where the item
            // stands rather than assuming the work was accepted.
            return status == .awaitingApproval
                ? ending(.awaitingApproval)
                : ending(.blocked("run ended without a recorded result"))
        }
    }

    /// Whether the autopilot is still holding this run — it is the execution in
    /// flight and the queue hasn't gone idle. A paused queue counts: it can resume.
    private func isWorking(entry: ControlSessionRegistry.Entry, runId: String) -> Bool {
        // A run this server didn't start is driven from outside it, and its id is
        // not an execution id — there is nothing here to ask how it is going. It is
        // working until its opener closes it, which is what stops the finalization
        // pass guessing an ending from an item the run is in the middle of: the
        // status moves to `done` or `blocked` well before the run around it has
        // torn down, opened its PR and recorded its result.
        if let run = runs[runId], !run.startedHere { return runEndings[runId] == nil }
        return entry.autopilot.currentExecutionID == runId && entry.autopilot.status != .idle
    }

    // MARK: - What a run is costing

    /// Copies the governor's live cost figures onto every run that currently owns
    /// its project's autopilot. Called once per request, alongside
    /// `finalizeEndedRuns`, so both run surfaces report the same readout the
    /// Autopilot panel is showing at that moment.
    ///
    /// Only while there is something in flight to record: the governor clears an
    /// item's figures as the run unwinds around it (teardown, the PR, the quality
    /// judge all happen after), and a request landing in that window would
    /// otherwise wipe the ceiling the run was actually measured against.
    private func snapshotLiveCosts() {
        for (runId, run) in runs {
            guard let entry = registry.entries[run.projectID],
                  isWorking(entry: entry, runId: runId) else { continue }
            let live = entry.autopilot.costReadout
            guard live.itemCapUSD != nil || live.itemSpendUSD > 0 else { continue }
            runs[runId]?.cost = live
        }
    }

    /// What a run is costing, for the two surfaces that report it: spend so far,
    /// the ceiling that spend is measured against, and the rung of the prediction
    /// chain that set the ceiling.
    ///
    /// Every field is **absent rather than zero** when it can't be established. A
    /// run nothing could be attributed to did not cost $0 — nobody could tell what
    /// it cost, and a driver deciding whether tonight's queue is affordable reads
    /// those two very differently.
    private func costFields(run: RunInfo, entry: ControlSessionRegistry.Entry?) -> [String: Any] {
        // The record this run wrote is the last word on what it spent: the
        // in-flight figure trails the live turn by up to one watchdog sample
        // (~16s), and the item is charged after the final one. Addressed by
        // execution id, so an earlier attempt at the same item is never mistaken
        // for this run's spend — for an autonomous run that is the execution its
        // opener reported, since its own id was minted before one existed.
        let recorded = entry?.autopilot.metric(executionID: run.executionID ?? run.runId)

        var fields: [String: Any] = [:]
        if let spent = recorded?.costUSD ?? run.cost?.itemSpendUSD, spent > 0 {
            fields["costUSD"] = spent
        }
        if let cap = run.cost?.itemCapUSD {
            fields["costCapUSD"] = cap
        }
        if let source = recorded?.predictionSource ?? run.cost?.itemPredictionSource?.rawValue {
            fields["predictionSource"] = source
        }
        return fields
    }

    // MARK: - Live monitoring (SSE)

    private func runEvents(runId: String) -> HTTPServer.Response {
        guard let run = runs[runId], let entry = registry.entries[run.projectID] else {
            return notLive(runId, "the event bus it was streamed from is gone; read GET /v1/runs/\(runId)/result")
        }
        let bus = entry.session.orchestrator.eventBus
        // A run can go minutes between events, so ping every 15s: clients (and any
        // proxy in between) see traffic instead of assuming a dead stream.
        return .sse(keepAlive: 15) { writer in
            // Backfill this run's history first; if it already ended, close.
            var sawTerminal = false
            for event in await bus.recentEvents() where event.payload["executionID"] == runId {
                writer.send(Self.eventJSON(event))
                if Self.isTerminal(event.type) { sawTerminal = true }
            }
            if sawTerminal { return }

            let consumerID = "__control_sse_\(runId)_\(UUID().uuidString)__"
            let stream = await bus.subscribe(agentID: consumerID, types: Set(KiteloopEvent.EventType.allCases))
            // A run can be quiet for minutes, so this parks here between events.
            // A client that hangs up cancels this task, which ends the iteration
            // and drops the subscription below — otherwise the bus would keep
            // fanning every event out to a stream nobody is reading.
            for await event in stream {
                if writer.isClosed { break }
                guard event.payload["executionID"] == runId else { continue }
                writer.send(Self.eventJSON(event))
                if Self.isTerminal(event.type) { break }
            }
            await bus.unsubscribe(agentID: consumerID)
        }
    }

    // MARK: - Which run an adoption turns out to be

    /// Records an adopted run — unless it is a run already open under another
    /// name, which claims `info.runId` as its execution instead of being tracked
    /// a second time under it.
    ///
    /// Three surfaces can notice one run start, and two of them arrive holding
    /// the workflow's execution id; `track` dedupes those two against each other,
    /// because the id they hold is the same. The third cannot be caught that way.
    /// The autonomous scheduler opens its run through `openRun` before any
    /// workflow exists, under a minted `auto-…` id, and the adoption hook — which
    /// cannot tell who pressed start — arrives with the execution moments later.
    /// Tracking that was a second `RunInfo` and a second record for one run: `GET
    /// /v1/runs` listing an unattended night twice, /health counting it twice, and
    /// both records finalized from a single `ItemResult`.
    ///
    /// Claiming is also the only way an `auto-…` record learns its execution at
    /// all. `closeRun` is handed nil — `currentExecutionID` is cleared per item
    /// before the scheduler reads it — so the field `PersistedRunRecord` documents
    /// as what ties an unattended night's record to its transcript and its metric
    /// was written empty every time. `reportedExecutionID` reads the claimed id
    /// first, so the record closes carrying it, and the run's charge is
    /// addressable while it is still in flight rather than only once it has ended.
    private func adopt(_ info: RunInfo) {
        guard let opened = schedulerRunAwaitingExecution(projectID: info.projectID,
                                                         itemID: info.itemId) else {
            track(info)
            return
        }
        runs[opened]?.executionID = info.runId
    }

    /// The run `openRun` opened for this item and that is still waiting to learn
    /// its execution, if there is one — the only run an adoption can turn out to
    /// be rather than begin.
    ///
    /// Deliberately narrow. `startedHere` false is exactly the scheduler's minted
    /// runs; no ending means the run is still in flight; no `executionID` means it
    /// has not already claimed one, so a second run of the same item cannot take
    /// the first's name. The oldest match wins, so the answer does not depend on
    /// how `runs` happens to enumerate.
    private func schedulerRunAwaitingExecution(projectID: String, itemID: String) -> String? {
        runs.values
            .filter { $0.projectID == projectID && $0.itemId == itemID
                && !$0.startedHere && $0.executionID == nil && runEndings[$0.runId] == nil }
            .min { $0.startedAt < $1.startedAt }?
            .runId
    }

    // MARK: - What a durable record answers with

    /// What a run's record says it spent, and against what — the durable half of
    /// `costFields`. The one emitter for both readouts answered off a record, so
    /// the listing and a historical `/result` cannot come to disagree. Absent,
    /// never null, when the record holds none.
    /// Whether the run's own merge landed, as the wire says it: `merged`
    /// present only when a merge was attempted — true with the commit it
    /// became, false for one refused — and absent when this run attempted
    /// none, which is not the same as unmerged. A live reading and a
    /// historical one say it the same way.
    nonisolated static func mergeFields(merged: Bool?, commit: String?) -> [String: Any] {
        guard let merged else { return [:] }
        var fields: [String: Any] = ["merged": merged]
        if let commit { fields["mergeCommit"] = commit }
        return fields
    }

    private static func recordCostFields(_ record: PersistedRunRecord) -> [String: Any] {
        var fields: [String: Any] = [:]
        if let cost = record.costUSD { fields["costUSD"] = cost }
        if let cap = record.costCapUSD { fields["costCapUSD"] = cap }
        if let source = record.predictionSource { fields["predictionSource"] = source }
        return fields
    }

    /// Writes the run's verify verdict onto its durable record — all five facts
    /// the verdict carries, or none, so the record cannot end up holding a
    /// command with no status or a status with nothing saying whether the
    /// deadline is what produced it.
    ///
    /// Flat fields rather than the verdict itself: `RunVerifyVerdict` is
    /// app-side and `PersistedRunRecord` is in the package.
    private static func copyVerdict(_ verdict: RunVerifyVerdict?, onto record: inout PersistedRunRecord) {
        record.verifyExitStatus = verdict?.exitStatus
        record.verifyCommand = verdict?.command
        record.verifyOutputTail = verdict?.outputTail
        record.verifyTimedOut = verdict?.timedOut
        record.verifyDirectory = verdict?.directory
    }

    /// The verify verdict a run's record kept, in the same keys the live
    /// `metricFields` emits — so a run reads the same whether the metric row is
    /// still reachable or only the record survives.
    ///
    /// The first three all or none, and absent rather than null: a `0` exit
    /// status would read as a verify that passed, and no verdict was taken is
    /// not that. A record written before these fields existed holds none, which
    /// is the third case the documentation names.
    ///
    /// `verifyTimedOut` and `verifyDirectory` are emitted beside them rather
    /// than gating them: they are the newer pair, so a record that kept a
    /// verdict before they existed has the three and not these two, and holding
    /// the three back over that would lose a verdict that was measured.
    private static func verifyFields(_ record: PersistedRunRecord) -> [String: Any] {
        guard let exitStatus = record.verifyExitStatus,
              let command = record.verifyCommand,
              let tail = record.verifyOutputTail else { return [:] }
        var fields: [String: Any] = [
            "verifyExitStatus": Int(exitStatus), "verifyCommand": command, "verifyOutputTail": tail
        ]
        if let timedOut = record.verifyTimedOut { fields["verifyTimedOut"] = timedOut }
        if let directory = record.verifyDirectory { fields["verifyDirectory"] = directory }
        return fields
    }

    // MARK: - What a finished result reads off the metric row

    /// The metric row **this run** wrote, addressed by execution id the way
    /// `costFields` addresses the charge.
    ///
    /// Deliberately not `latestMetric(itemID:)`: an item that runs twice in one
    /// session — rejected, returned to `ready`, run again — leaves two rows
    /// under the same item id, and matching on that alone filled the first
    /// run's result body and its durable record from the second run's row. A
    /// driver reading the earlier run then saw a score and a verify verdict
    /// measured on a tree that run never produced.
    ///
    /// Nil when no execution can be established — a scheduler-opened run before
    /// `closeRun` reports its execution, or one the pickup gates refused. Saying
    /// nothing is the answer there: the fields are documented as absent when the
    /// fact was not measured, and another run's row is not this run's reading.
    private static func metric(
        of run: RunInfo, entry: ControlSessionRegistry.Entry
    ) -> TaskMetricRecord? {
        guard let execution = run.reportedExecutionID else { return nil }
        return entry.autopilot.metric(executionID: execution)
    }

    /// What the run's metric row adds to a finished result: the advisory quality
    /// score (or why there is none) and the verify verdict the app measured
    /// before the reviewer read the diff.
    ///
    /// Every key is absent when the fact behind it was never measured — a
    /// `null` would tell a driver nothing it could act on, and a `0` exit
    /// status would read as a verify that passed. Empty when this run wrote no
    /// metric row `metric(of:entry:)` can address.
    private func metricFields(run: RunInfo, entry: ControlSessionRegistry.Entry) -> [String: Any] {
        guard let metric = Self.metric(of: run, entry: entry) else { return [:] }
        var fields: [String: Any] = [:]
        if let verify = metric.verify {
            fields["verifyExitStatus"] = Int(verify.exitStatus)
            fields["verifyCommand"] = verify.command
            fields["verifyOutputTail"] = verify.outputTail
            // The two that make the status readable: a negative exit status is a
            // command that returned none, and only `verifyTimedOut` says whether
            // the deadline is what took it — a killed command judged nothing
            // about the tree `verifyDirectory` names.
            fields["verifyTimedOut"] = verify.timedOut
            fields["verifyDirectory"] = verify.directory
        }
        if let score = metric.qualityScore {
            fields["qualityScore"] = score
            if let dims = metric.judgeDimensions { fields["judgeDimensions"] = dims }
        } else if let reason = metric.judgeUnavailableReason {
            // No score *and* why not: a driver polling this endpoint would
            // otherwise read a dead judge as an unremarkable unscored run.
            fields["judgeUnavailable"] = reason
        }
        return fields
    }

    /// What a live `/result` body says about the run itself rather than about its
    /// ending: the meter `costFields` reads, plus the workflow execution the run
    /// turned out to be.
    ///
    /// The execution id is here and not only in `historicalBody` because it is
    /// what a run's transcript directory and its metric row are keyed by, and a
    /// driver holding a runId polls this endpoint, not the listing — waiting for
    /// a restart to learn which execution last night's `auto-…` run was is no
    /// answer at all. Absent, never null, on a run that never got an execution.
    private func liveRunFields(run: RunInfo, entry: ControlSessionRegistry.Entry?) -> [String: Any] {
        var fields = costFields(run: run, entry: entry)
        if let execution = run.reportedExecutionID { fields["executionId"] = execution }
        return fields
    }

    // MARK: - Run log

    /// The autopilot's own narration for this run — the lines the Autopilot tab
    /// prints ("Executing: …", "→ Reviewer (attempt 2)", "Blocked: … — review did
    /// not pass"), for a caller that has no tab. `events` (SSE, or the last 20 on
    /// `GET /v1/runs/{id}`) says what the machine did; this says why a run ended
    /// the way it did, which is what a driver needs when a result comes back
    /// `blocked` and the reason alone doesn't explain it.
    ///
    /// The autopilot keeps one project-wide, rolling log rather than a log per
    /// run, so a run's share is the slice from when it started until the next run
    /// in the same project began (one run at a time per project, so the slice is
    /// exact). Two things can leave it incomplete, and both set `truncated`: the
    /// rolling buffer having already evicted the run's earlier lines, and `limit`
    /// asking for fewer than the slice holds.
    private func runLog(runId: String, limit: String?) -> HTTPServer.Response {
        guard let run = runs[runId], let entry = registry.entries[run.projectID] else {
            return notLive(runId, "autopilot's log buffer holds only the current process's lines")
        }
        guard let limit = Self.parseLogLimit(limit) else {
            return .error("\"limit\" must be an integer in \(Self.logLimitRange)", status: 400)
        }
        let log = entry.autopilot.log
        // The next run this server started for the same project closes the window;
        // without one it stays open, so a live run's newest lines are included.
        let nextStart = runs.values
            .filter { $0.projectID == run.projectID && $0.startedAt > run.startedAt }
            .map(\.startedAt)
            .min()
        let window = log.filter { entry in
            entry.timestamp >= run.startedAt && nextStart.map { entry.timestamp < $0 } ?? true
        }
        // A full buffer whose oldest surviving line postdates the run means lines
        // from the window are already gone — the count alone can't show that.
        let evicted = log.count >= BacklogAutopilot.logCapacity
            && (log.first.map { $0.timestamp > run.startedAt } ?? false)
        let lines = window.suffix(limit)
        return .json([
            "runId": runId,
            "item": run.itemId,
            "title": run.title,
            "project": entry.session.project.rootURL.lastPathComponent,
            "count": lines.count,
            "truncated": evicted || lines.count < window.count,
            "lines": lines.map { ["ts": Self.iso.string(from: $0.timestamp), "message": $0.message] }
        ])
    }

    /// The log buffer holds 50 lines, so that is also the most one call can ask
    /// for. Unlike `/v1/metrics` the default is everything: a log truncated by a
    /// default nobody chose is a log that hides the line you were looking for.
    private static let logLimitRange: ClosedRange<Int> = 1...BacklogAutopilot.logCapacity

    /// `nil` = the caller sent a `limit` that isn't a number in range (→ 400);
    /// an absent or empty one means the whole window.
    private static func parseLogLimit(_ raw: String?) -> Int? {
        guard let raw, !raw.isEmpty else { return BacklogAutopilot.logCapacity }
        guard let value = Int(raw), logLimitRange.contains(value) else { return nil }
        return value
    }

    // MARK: - Cancellation

    /// Abandon a run that is still in flight — the missing counterpart to
    /// `POST /v1/runs`: until now a driver could start a run headlessly but had to
    /// reach for the Autopilot tab's stop button to get out of one gone wrong.
    ///
    /// Three things happen, in order: the agent holding the current node is
    /// interrupted (cancelling the execution alone leaves its CLI subprocess
    /// streaming — and billing — against a workflow nobody is waiting on), the
    /// execution is cancelled, and the project's queue is stopped so autopilot
    /// doesn't march straight on to the next item. The agent is interrupted rather
    /// than stopped so its session survives and the next run can start without a
    /// human reopening the chat.
    ///
    /// Answers **202**: autopilot notices the cancellation on its next poll (~2s),
    /// and only then puts the item back to `ready` and records the `cancelled`
    /// result. Poll `GET /v1/runs/{runId}/result` for the unwound state.
    private func cancelRun(runId: String) async -> HTTPServer.Response {
        guard let run = runs[runId], let entry = registry.entries[run.projectID] else {
            return notLive(runId, "there is nothing left to cancel")
        }
        // A finished run has nothing left to cancel — its item has already landed
        // (done, blocked, or waiting at its human gate, which is `approve`'s job).
        guard runState(run: run, entry: entry) != "finished" else {
            return .error("Run \(runId) has already finished", status: 409)
        }
        let autopilot = entry.autopilot
        let orchestrator = entry.session.orchestrator
        if let agentID = await activeAgent(entry: entry, runId: runId) {
            orchestrator.interrupt(agentID: agentID)
        }
        await orchestrator.cancelWorkflow(executionID: runId)
        // Only halt the queue when this run is the one in flight: a stale runId must
        // not stop the item that has since taken its place.
        if autopilot.currentExecutionID == runId { autopilot.stop() }
        return .json([
            "runId": runId,
            "item": run.itemId,
            "title": run.title,
            "state": "cancelling",
            "autopilot": Self.statusLabel(autopilot.status)
        ], status: 202)
    }

    /// The agent actually holding this run's turn — worker or reviewer, depending on
    /// the node the execution sits on. `nil` once it reaches a terminal node (nothing
    /// is streaming) or if the execution is already gone.
    private func activeAgent(entry: ControlSessionRegistry.Entry, runId: String) async -> String? {
        guard let exec = await entry.session.orchestrator.workflowEngine.execution(id: runId) else { return nil }
        switch exec.currentNode {
        case "worker": return entry.autopilot.workerAgentID
        case "reviewer": return entry.autopilot.reviewerAgentID
        default: return nil
        }
    }

    // MARK: - Steering

    /// Hands the live run's worker a short note, delivered at its next turn
    /// boundary — the third option beside cancelling and waiting, which until now
    /// only the Autopilot tab's note field could reach.
    ///
    /// Everything the tab's control does is `BacklogAutopilot.steerWorker`, so
    /// that is what this calls: the sanitizing, the gate on there being a worker
    /// to reach, and the recording — run log, phase log and the item's `## Notes`
    /// — are the same for a note typed in the app and one posted here, and a
    /// second implementation of any of them would be a second set of rules to
    /// keep in step.
    ///
    /// Refusals are 409 rather than 400: the body was fine, the run was not in a
    /// state that could take it, and both of the states that refuse — the
    /// reviewer holding the run, the run being over — are things the caller can
    /// see change.
    private func steerRun(runId: String, body: Data) -> HTTPServer.Response {
        guard let run = runs[runId], let entry = registry.entries[run.projectID] else {
            return notLive(runId, "a note can only be handed to a worker that is still running")
        }
        // The autopilot steers whatever it is executing, so a run that is no
        // longer the one in flight has to be refused here rather than there:
        // one project runs one item at a time, and a stale runId would otherwise
        // hand the note to whichever item has since taken its place.
        guard isWorking(entry: entry, runId: runId) else {
            return .error("Run \(runId) is no longer the run in flight for its project"
                          + " — it has no worker to hand a note to", status: 409)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let note = json["note"] as? String else {
            return .error("Body must include \"note\"", status: 400)
        }
        switch entry.autopilot.steerWorker(note) {
        case .sent(let delivered):
            return .json([
                "runId": runId,
                "item": run.itemId,
                "title": run.title,
                "state": "sent",
                // What was queued, not what was posted: an overlong note is
                // truncated rather than refused, and a caller that pasted 1,500
                // characters would otherwise have no way to tell.
                "note": delivered
            ])
        case .refused(let reason):
            return .error(reason, status: 409)
        }
    }

    // MARK: - Approval

    private func approveRun(runId: String, body: Data) async -> HTTPServer.Response {
        guard let run = runs[runId], let entry = registry.entries[run.projectID] else {
            // A gate the run left behind is still resolvable — but through the
            // item, not the run: this endpoint resolves whichever gate the *run*
            // is holding, and a run no process is driving holds none. The item id
            // is in the record, so name it.
            let item = runRecords?.record(runId: runId)?.itemID
            return notLive(runId, item.map {
                "resolve the item's gate with POST /v1/backlog/approve for item '\($0)'"
            } ?? "there is no gate left to resolve")
        }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        // An omitted verdict means yes, which is exactly why junk cannot fall
        // through to the default: `{"approve": "no"}` would approve the run its
        // sender meant to reject.
        let approved: Bool
        switch Self.boolField(json, "approve", alias: "approved") {
        case .absent: approved = true
        case .invalid(let key): return Self.invalidBool(key)
        case .value(let value): approved = value
        }
        let note = json["note"] as? String
        let orchestrator = entry.session.orchestrator

        // A mid-workflow human-approval node takes priority.
        if orchestrator.pendingWorkflowApprovals.contains(where: { $0.executionID == runId }) {
            orchestrator.resolveWorkflowApproval(executionID: runId, approved: approved, reason: note)
            return .json(["runId": runId, "gate": "workflow", "resolved": approved ? "approved" : "rejected"])
        }
        // Otherwise the backlog-item gate: autopilot finished, item awaiting sign-off.
        if let item = itemFor(entry: entry, itemId: run.itemId), item.status == .awaitingApproval {
            return await approveItem(entry: entry, itemId: run.itemId, approve: approved, reason: note, runId: runId)
        }
        return .error("Run \(runId) has no pending approval (workflow node or backlog item)", status: 409)
    }

    private func approveBacklogItem(body: Data) async -> HTTPServer.Response {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let project = json["project"] as? String,
              let itemId = (json["item"] as? String) ?? (json["itemId"] as? String) else {
            return .error("Body must include \"project\" and \"item\"", status: 400)
        }
        guard let entry = registry.entry(forProject: project) else {
            return .error("Project not open in Kiteloop: \(project)", status: 409)
        }
        let approve: Bool
        switch Self.boolField(json, "approve", alias: "approved") {
        case .absent: approve = true
        case .invalid(let key): return Self.invalidBool(key)
        case .value(let value): approve = value
        }
        let reason = json["reason"] as? String
        return await approveItem(entry: entry, itemId: itemId, approve: approve, reason: reason)
    }

    /// Merges a `done` item's branch that never landed — the merge half of an
    /// approval, taken later. An item reads `done` with its work still on a
    /// branch when the gate cleared with `autoMergeOnApproval` off (thirty of
    /// them on 2026-09-18, under a half-set dial), and until now nothing could
    /// land it: `approve` refuses a done item, and the sweep only reports.
    /// The same gate as an approval's merge — clean merge, green verify of
    /// the merged tree, on the configured base — and the item's status does
    /// not change: it was done; what changes is that the work is in main.
    private func landBacklogItem(body: Data) async -> HTTPServer.Response {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let project = json["project"] as? String,
              let itemId = (json["item"] as? String) ?? (json["itemId"] as? String) else {
            return .error("Body must include \"project\" and \"item\"", status: 400)
        }
        guard let entry = registry.entry(forProject: project) else {
            return .error("Project not open in Kiteloop: \(project)", status: 409)
        }
        guard let item = itemFor(entry: entry, itemId: itemId) else {
            return .error("No backlog item '\(itemId)' in this project", status: 404)
        }
        guard item.status == .done else {
            return .error("Item '\(itemId)' is not done (status: \(item.status.rawValue)) — "
                          + "an item at its gate lands through POST /v1/backlog/approve", status: 409)
        }
        return await landDoneItem(entry: entry, item: item)
    }

    private func landDoneItem(entry: ControlSessionRegistry.Entry, item: BacklogItem) async -> HTTPServer.Response {
        let plan = Self.mergeVerify(autopilot: entry.autopilot, item: item)
        var payload: [String: Any] = ["item": item.id, "branch": WorktreeSession.branchName(for: item.id),
                                      "status": BacklogItemStatus.done.rawValue]
        let outcome = await entry.session.backlogViewModel.landDoneItem(
            itemID: item.id, verify: plan,
            projectRoot: entry.session.project.rootURL,
            base: entry.autopilot.baseBranch, setupCommand: entry.autopilot.effectiveWorktreeSetup.command,
            timeout: TimeInterval(entry.autopilot.autoMergeVerifyTimeoutMinutes) * 60)
        switch outcome {
        case .landed(let commit):
            payload["merged"] = true
            if let commit { payload["commit"] = commit }
            payload["verify"] = plan.labels
            return .json(payload)
        case .nothingToLand(let why):
            payload["merged"] = false
            payload["reason"] = why
            return .json(payload, status: 409)
        case .refused(let why, let verifyOutput):
            payload["merged"] = false
            payload["reason"] = why
            if let verifyOutput, !verifyOutput.isEmpty { payload["verifyOutput"] = verifyOutput }
            return .json(payload, status: 409)
        }
    }

    /// Promote a groomed `draft` to `ready`, send a `ready` item back to
    /// `draft`, or lift a `blocked` item to either — the transition the app had
    /// no headless equivalent for.
    ///
    /// It was the one busy move with no verb: 92 drafts sat in this repo's
    /// backlog, most already carrying What/How/Validation, a `verify:` and a
    /// size, and the only way to advance one was the app's own list. A driver
    /// grooming a night's work had to edit `BACKLOG.md` on the shared branch by
    /// hand and rely on the file watcher.
    ///
    /// Deliberately only from `draft`, `ready` or `blocked`, and only to `ready`
    /// or `draft`. Every other transition belongs to something that already
    /// owns it — a run moves an item to `active`, a review to
    /// `awaiting-approval`, an approval to `done` — and a general status setter
    /// here would be a way to stamp any of those from outside the machinery
    /// that earns them.
    ///
    /// A promotion — `draft` to `ready` — is refused (422) when the item fails
    /// the Definition-of-Ready, with the clauses named, unless the body says
    /// `force: true`. It used to promote anything and leave the refusal to the
    /// next pickup: on 2026-09-12 five items were promoted that way, three were
    /// selected within seconds and refused for "no groomed detail file", and
    /// the queue read as work. Lifting a `blocked` item is not a promotion —
    /// the item was ready once — and `draft` is always allowed.
    private func groomBacklogItem(body: Data) -> HTTPServer.Response {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let project = json["project"] as? String,
              let itemId = (json["item"] as? String) ?? (json["itemId"] as? String) else {
            return .error("Body must include \"project\" and \"item\"", status: 400)
        }
        // `ready` is the default because promoting is what this is for; `draft`
        // is how a promotion is taken back.
        let wanted = (json["status"] as? String) ?? BacklogItemStatus.ready.rawValue
        guard let target = BacklogItemStatus(rawValue: wanted),
              target == .ready || target == .draft else {
            return .error("\"status\" must be \"ready\" or \"draft\"", status: 400)
        }
        guard let entry = registry.entry(forProject: project) else {
            return .error("Project not open in Kiteloop: \(project)", status: 409)
        }
        guard let item = itemFor(entry: entry, itemId: itemId) else {
            return .error("No backlog item '\(itemId)' in this project", status: 404)
        }
        // Only from the other side of the same pair, or out of `blocked`. An
        // item that is running, in review, at a gate or done is somewhere this
        // verb has no business moving it from, and saying so beats silently
        // reopening it. `blocked` is the exception because nothing else lifted
        // it: a block was cleared by hand-editing the backlog file, which lost
        // the reason — the view model keeps it as a Notes line.
        guard item.status == .draft || item.status == .ready || item.status == .blocked else {
            return .error("Item is '\(item.status.rawValue)' — groom moves between draft and ready, and lifts blocked",
                          status: 409)
        }
        if item.status == .draft, target == .ready, json["force"] as? Bool != true,
           let refusal = Self.promotionRefusal(item: item, backlogViewModel: entry.session.backlogViewModel) {
            return refusal
        }
        return Self.groom(item, to: target, in: entry.session.backlogViewModel)
    }

    /// The move itself, and its answer. Out of `blocked` goes through
    /// `unblock`, which keeps the reason as a Notes line.
    private static func groom(_ item: BacklogItem, to target: BacklogItemStatus,
                              in backlogViewModel: BacklogViewModel) -> HTTPServer.Response {
        if item.status == .blocked {
            backlogViewModel.unblock(itemID: item.id, to: target)
        } else if item.status == .ready, target == .draft {
            // Written down, like the pickup gates' own demotions: three items
            // promoted on 2026-09-19 were back at draft by the 20th and nothing
            // on the item said who moved them.
            backlogViewModel.sendBackToDraft(itemID: item.id, reason: "over the control API (POST /v1/backlog/groom)")
        } else {
            backlogViewModel.updateItemStatus(itemID: item.id, newStatus: target)
        }
        return .json([
            "item": item.id,
            "was": item.status.rawValue,
            "status": target.rawValue,
            "changed": item.status != target,
        ])
    }

    /// The 422 a promotion answers when the item is not groomed: the same
    /// `DefinitionOfReady` verdict pickup would refuse it with, so the caller
    /// reads the clauses now rather than from a run that never started. Nil
    /// when the item is ready.
    ///
    /// The `needs:` clause is left unjudged. A dependency not yet done says
    /// *when* the item may run, not whether it is groomed, and pickup already
    /// holds it back until then; judging it here refused promoting the second
    /// half of a split until the first half had landed.
    private static func promotionRefusal(item: BacklogItem, backlogViewModel: BacklogViewModel) -> HTTPServer.Response? {
        let verdict = DefinitionOfReady.evaluate(
            item: item, detail: backlogViewModel.loadDetail(for: item), dependencies: nil)
        guard !verdict.isReady else { return nil }
        return .json([
            "error": "Item is not ready — \(verdict.summary); pass \"force\": true to promote it anyway",
            "item": item.id,
            "status": item.status.rawValue,
            "notReady": verdict.reasons,
        ], status: 422)
    }

    /// Agent id or name, case-insensitively — both are what the UI shows, and
    /// a phone typing either should land on the same agent.
    private static func agent(in entry: ControlSessionRegistry.Entry, idOrName: String) -> Agent? {
        let key = idOrName.lowercased()
        return entry.session.orchestrator.agents.first {
            $0.id.lowercased() == key || $0.name.lowercased() == key
        }
    }

    private func listAgents(project: String?) -> HTTPServer.Response {
        guard let project else { return .error("Missing ?project=", status: 400) }
        guard let entry = registry.entry(forProject: project) else {
            return .error("Project not open in Kiteloop: \(project)", status: 409)
        }
        let agents = entry.session.orchestrator.agents.map { agent -> [String: Any] in
            ["id": agent.id, "name": agent.name, "model": agent.model, "state": agent.state.rawValue,
             "mode": agent.permissionMode]
        }
        return .json(["agents": agents])
    }

    private func messageAgent(body: Data) async -> HTTPServer.Response {
        let json = Self.jsonBody(body)
        let content: AgentMessageContent
        switch AgentMessageContent.parse(json) {
        case .failure(let refusal): return .error(refusal.reason, status: refusal.status)
        case .success(let parsed): content = parsed
        }
        let target = agentTarget(json)
        guard case .found(let entry, let agent) = target else { return target.refusal }
        let wait: Bool
        switch Self.boolField(json, "wait") {
        case .absent: wait = false
        case .invalid(let key): return Self.invalidBool(key)
        case .value(let value): wait = value
        }
        return await deliver(content, to: agent.id, in: entry, wait: wait)
    }

    /// Without `wait`, answered as soon as the message is in: the reply comes
    /// over GET /v1/agents/events, from `after` on, rather than holding the
    /// request open for a turn that can outlast any client's timeout. With it,
    /// answered when the turn ends, with the reply.
    /// The images go in with the text, as files dropped on the Mac's input do.
    private func deliver(_ content: AgentMessageContent, to agentID: String, in entry: ControlSessionRegistry.Entry,
                         wait: Bool) async -> HTTPServer.Response {
        let vm = entry.session.chatViewModel(for: agentID)
        // Mid-turn, send() queues rather than interleaving — answer that
        // honestly instead of blocking this request on someone else's turn.
        let wasStreaming = vm.isStreaming
        let countBefore = vm.messages.count
        guard wait else {
            var reply: [String: Any] = ["agent": agentID, "queued": wasStreaming, "started": !wasStreaming]
            if let last = vm.messages.last { reply["after"] = last.id.uuidString }
            let projectName = entry.session.project.rootURL.lastPathComponent
            let agentName = Self.agent(in: entry, idOrName: agentID)?.name ?? agentID
            Task {
                vm.pendingAttachments += content.attachments
                vm.inputText = content.text
                await vm.send()
                guard !wasStreaming else { return }
                Self.announceTurnEnd(project: projectName, agentID: agentID, agentName: agentName,
                                     reply: Self.lastAgentReply(in: vm.messages, since: countBefore),
                                     waiting: vm.waitingStatus)
            }
            return .json(reply)
        }
        vm.pendingAttachments += content.attachments
        vm.inputText = content.text
        await vm.send()
        if wasStreaming { return .json(["agent": agentID, "queued": true]) }
        return .json(["agent": agentID, "queued": false,
                      "reply": Self.lastAgentReply(in: vm.messages, since: countBefore)])
    }

    /// A turn the phone started has stopped. Waiting on a question or a plan,
    /// its Live Activity says so and the notice that raised pushes itself;
    /// finished, the activity ends and the phone gets a push of its own.
    private static func announceTurnEnd(project: String, agentID: String, agentName: String,
                                        reply: String, waiting: String?) {
        let relay = PushRelay.shared
        if let waiting {
            relay.updateActivity(project: project, agent: agentID, working: false, status: waiting, line: reply, ends: false)
            return
        }
        relay.updateActivity(project: project, agent: agentID, working: false, status: "Done", line: reply, ends: true)
        relay.turnFinished(project: project, agentID: agentID, agentName: agentName, reply: reply)
    }

    /// The end of a turn the phone resumed by answering a plan or a question.
    private static func announceResumedTurnEnd(_ vm: some AgentChatSource, project: String, agent: Agent,
                                               since countBefore: Int) {
        announceTurnEnd(project: project, agentID: agent.id, agentName: agent.name,
                        reply: lastAgentReply(in: vm.messages, since: countBefore), waiting: vm.waitingStatus)
    }

    /// The reply: the last agent text since the caller's message went in.
    private static func lastAgentReply(in messages: [Message], since countBefore: Int) -> String {
        messages.suffix(from: min(countBefore, messages.count))
            .reversed()
            .compactMap { msg -> String? in
                guard case .agent = msg.sender, case .text(let text) = msg.content else { return nil }
                return text
            }
            .first ?? ""
    }

    private func agentTranscript(query: [String: String]) -> HTTPServer.Response {
        guard let project = query["project"] else { return .error("Missing ?project=", status: 400) }
        guard let agentRef = query["agent"] else { return .error("Missing ?agent=", status: 400) }
        guard let entry = registry.entry(forProject: project) else {
            return .error("Project not open in Kiteloop: \(project)", status: 409)
        }
        guard let agent = Self.agent(in: entry, idOrName: agentRef) else {
            return .error("No agent '\(agentRef)' in this project", status: 404)
        }
        let limit = query["limit"].flatMap(Int.init) ?? Self.transcriptWindow
        let messages = AgentTranscript.tail(of: entry.session.chatViewModels[agent.id]?.messages ?? [], limit: limit)
        return .json(["agent": agent.id, "messages": messages])
    }

    // MARK: - Steering an agent from the phone

    /// The open project and the agent a request body names, or the answer
    /// that says which is missing.
    private enum AgentTarget {
        case found(ControlSessionRegistry.Entry, Agent)
        case refused(HTTPServer.Response)

        /// The refusal, for a caller that has already matched `.found` away.
        var refusal: HTTPServer.Response {
            guard case .refused(let response) = self else { return .error("Agent resolved", status: 500) }
            return response
        }
    }

    private func agentTarget(_ json: [String: Any]) -> AgentTarget {
        guard let project = json["project"] as? String, let agentRef = json["agent"] as? String else {
            return .refused(.error("Body must include \"project\" and \"agent\"", status: 400))
        }
        guard let entry = registry.entry(forProject: project) else {
            return .refused(.error("Project not open in Kiteloop: \(project)", status: 409))
        }
        guard let agent = Self.agent(in: entry, idOrName: agentRef) else {
            return .refused(.error("No agent '\(agentRef)' in this project", status: 404))
        }
        return .found(entry, agent)
    }

    private static func jsonBody(_ body: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }

    /// Stops the agent's turn, as the Mac's Stop button does. Messages you had
    /// queued during the turn go back into the Mac's input box, and the answer
    /// carries them as `returned` so the phone can put them in its draft.
    private func interruptAgent(body: Data) -> HTTPServer.Response {
        let target = agentTarget(Self.jsonBody(body))
        guard case .found(let entry, let agent) = target else { return target.refusal }
        let vm = entry.session.chatViewModel(for: agent.id)
        guard vm.isStreaming else { return .json(["agent": agent.id, "interrupted": false]) }
        let returned = vm.queuedTypedMessages.joined(separator: "\n\n")
        vm.interrupt()
        return .json(["agent": agent.id, "interrupted": true, "returned": returned])
    }

    /// Answers a plan card the way its buttons do: build in Auto or Accept
    /// Edits, or keep planning with what should change.
    private func answerAgentPlan(body: Data) -> HTTPServer.Response {
        let json = Self.jsonBody(body)
        let target = agentTarget(json)
        guard case .found(let entry, let agent) = target else { return target.refusal }
        guard let messageID = (json["message"] as? String).flatMap(UUID.init(uuidString:)),
              let answer = (json["answer"] as? String).flatMap(Message.PlanProposal.Answer.init(rawValue:)) else {
            return .error("Body must include \"message\" (a plan's id) and \"answer\": approveAuto, approveAcceptEdits or keepPlanning", status: 400)
        }
        let vm = entry.session.chatViewModel(for: agent.id)
        guard Self.isOpenPlan(messageID, in: vm.messages) else {
            return .error("No open plan \(messageID.uuidString) in this chat — answered already, or not a plan", status: 409)
        }
        // Approving starts the build turn when the agent is idle; this request
        // does not wait it out — the stream shows the card answered and the turn.
        let feedback = json["feedback"] as? String
        let project = entry.session.project.rootURL.lastPathComponent
        let countBefore = vm.messages.count
        Task {
            await vm.answerPlan(messageID: messageID, with: answer, feedback: feedback)
            Self.announceResumedTurnEnd(vm, project: project, agent: agent, since: countBefore)
        }
        return .json(["agent": agent.id, "message": messageID.uuidString, "answer": answer.rawValue])
    }

    private static func isOpenPlan(_ id: UUID, in messages: [Message]) -> Bool {
        guard let message = messages.first(where: { $0.id == id }), case .plan(let plan) = message.content else { return false }
        return plan.answer == nil
    }

    /// Answers the question the agent stopped to ask — only the one it is
    /// waiting on now, as the Mac's bubble does.
    private func answerAgentQuestion(body: Data) -> HTTPServer.Response {
        let json = Self.jsonBody(body)
        let target = agentTarget(json)
        guard case .found(let entry, let agent) = target else { return target.refusal }
        guard let request = json["request"] as? String, let answer = json["answer"] as? String,
              !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .error("Body must include \"request\" and a non-empty \"answer\"", status: 400)
        }
        let vm = entry.session.chatViewModel(for: agent.id)
        guard vm.pendingHumanToolCallID == request else {
            return .error("The agent is not waiting on question \(request) — answered already, or moved past", status: 409)
        }
        // The answer resumes the turn; this request does not wait it out.
        let project = entry.session.project.rootURL.lastPathComponent
        let countBefore = vm.messages.count
        Task {
            await vm.respondToHuman(requestID: request, answer: answer)
            Self.announceResumedTurnEnd(vm, project: project, agent: agent, since: countBefore)
        }
        return .json(["agent": agent.id, "request": request])
    }

    /// Answers a permission card as its buttons do.
    private func answerAgentPermission(body: Data) -> HTTPServer.Response {
        let json = Self.jsonBody(body)
        let target = agentTarget(json)
        guard case .found(let entry, let agent) = target else { return target.refusal }
        guard let request = json["request"] as? String, let answer = json["answer"] as? String,
              ["allow", "always", "deny"].contains(answer) else {
            return .error("Body must include \"request\" and \"answer\": allow, always or deny", status: 400)
        }
        let remembering = answer == "always" ? json["always"] as? Int ?? 0 : nil
        let vm = entry.session.chatViewModel(for: agent.id)
        guard vm.answerPermission(requestID: request, allow: answer != "deny", remembering: remembering) else {
            return .error("No open permission card \(request) to answer that way — answered already, taken back, "
                + "or it offers nothing at that position", status: 409)
        }
        return .json(["agent": agent.id, "request": request, "answer": answer])
    }

    /// Answers the model's own questions, one answer each.
    private func answerAgentChoices(body: Data) -> HTTPServer.Response {
        let json = Self.jsonBody(body)
        let target = agentTarget(json)
        guard case .found(let entry, let agent) = target else { return target.refusal }
        guard let request = json["request"] as? String, let answers = json["answers"] as? [String] else {
            return .error("Body must include \"request\" and \"answers\", one per question", status: 400)
        }
        guard entry.session.chatViewModel(for: agent.id).answerChoices(requestID: request, answers: answers) else {
            return .error("No open questions card \(request) those answers fit — answered already, taken back, "
                + "or they do not number its questions or one is blank", status: 409)
        }
        return .json(["agent": agent.id, "request": request])
    }

    /// Moves the agent to a permission mode, as `/mode` does in its chat.
    private func setAgentMode(body: Data) async -> HTTPServer.Response {
        let json = Self.jsonBody(body)
        let target = agentTarget(json)
        guard case .found(let entry, let agent) = target else { return target.refusal }
        guard let mode = json["mode"] as? String,
              await entry.session.chatViewModel(for: agent.id).setPermissionMode(named: mode) else {
            return .error("Body must include \"mode\": auto, acceptEdits, plan, default, dontAsk or bypassPermissions", status: 400)
        }
        let stored = entry.session.orchestrator.agents.first { $0.id == agent.id }?.permissionMode ?? mode
        return .json(["agent": agent.id, "mode": stored])
    }

    /// The subagents and background shells the agent's session has running.
    private func listAgentTasks(query: [String: String]) -> HTTPServer.Response {
        let target = agentTarget(query)
        guard case .found(let entry, let agent) = target else { return target.refusal }
        let tasks = (entry.session.chatViewModels[agent.id]?.runningTasks ?? []).map { task -> [String: Any] in
            var row: [String: Any] = ["id": task.taskID, "kind": Self.taskKindName(task.kind), "description": task.description]
            if let subagent = task.subagentType { row["subagent"] = subagent }
            return row
        }
        return .json(["agent": agent.id, "tasks": tasks])
    }

    private static func taskKindName(_ kind: AgentTaskKind) -> String {
        switch kind {
        case .subagent: "subagent"
        case .backgroundShell: "shell"
        case .other(let name): name
        }
    }

    /// Stops one running task and leaves the session going.
    private func stopAgentTask(body: Data) -> HTTPServer.Response {
        let json = Self.jsonBody(body)
        let target = agentTarget(json)
        guard case .found(let entry, let agent) = target else { return target.refusal }
        guard let task = json["task"] as? String else {
            return .error("Body must include \"task\"", status: 400)
        }
        guard entry.session.chatViewModel(for: agent.id).stopTask(task) else {
            return .error("No running task \(task) in this agent's session", status: 409)
        }
        return .json(["agent": agent.id, "task": task])
    }

    /// How many of the newest messages a transcript read answers and an event
    /// stream watches, unless the caller says otherwise.
    static let transcriptWindow = 50

    /// The agent's chat as it happens: every new or changed message from
    /// `after` on, and the agent starting and ending turns. The stream watches
    /// the same window a transcript read answers.
    private func agentEvents(query: [String: String]) -> HTTPServer.Response {
        guard let project = query["project"] else { return .error("Missing ?project=", status: 400) }
        guard let agentRef = query["agent"] else { return .error("Missing ?agent=", status: 400) }
        guard let entry = registry.entry(forProject: project) else {
            return .error("Project not open in Kiteloop: \(project)", status: 409)
        }
        guard let agent = Self.agent(in: entry, idOrName: agentRef) else {
            return .error("No agent '\(agentRef)' in this project", status: 404)
        }
        let vm = entry.session.chatViewModel(for: agent.id)
        let after = query["after"].flatMap(UUID.init(uuidString:))
        let limit = query["limit"].flatMap(Int.init) ?? Self.transcriptWindow
        let agentID = agent.id
        return .sse(keepAlive: 15) { writer in
            await AgentChatStream.run(vm, agentID: agentID, after: after, limit: limit, writer: writer)
        }
    }

    private func backlogItemDetail(query: [String: String]) -> HTTPServer.Response {
        guard let project = query["project"] else { return .error("Missing ?project=", status: 400) }
        guard let itemId = query["item"] else { return .error("Missing ?item=", status: 400) }
        guard let entry = registry.entry(forProject: project) else {
            return .error("Project not open in Kiteloop: \(project)", status: 409)
        }
        guard let item = itemFor(entry: entry, itemId: itemId) else {
            return .error("No backlog item '\(itemId)' in this project", status: 404)
        }
        var json: [String: Any] = ["id": item.id, "title": item.title, "status": item.status.rawValue]
        if let size = item.size { json["size"] = size.rawValue }
        if let epic = Self.judgedBacklog(entry.session.backlogViewModel)
            .first(where: { $0.item.id == item.id })?.epic { json["epic"] = epic }
        if let detail = entry.session.backlogViewModel.loadDetail(for: item) {
            json.merge(Self.groomedSections(of: detail)) { current, _ in current }
        }
        return .json(json)
    }

    /// The groomed detail file's sections, keyed as the endpoint reports them.
    /// Absent sections stay absent — the phone renders what exists.
    private static func groomedSections(of detail: BacklogItemDetail) -> [String: Any] {
        var json: [String: Any] = ["verify": detail.verifyCommands.map(\.cmd).joined(separator: "\n")]
        if let what = detail.what { json["what"] = what }
        if let approach = detail.approach { json["approach"] = approach }
        if !detail.acceptanceCriteria.isEmpty { json["acceptanceCriteria"] = detail.acceptanceCriteria }
        if !detail.outOfScope.isEmpty { json["outOfScope"] = detail.outOfScope }
        if let notes = detail.notes { json["notes"] = notes }
        if let why = detail.why { json["why"] = why }
        return json
    }

    /// The diff a human at the gate is approving: the item's autopilot branch
    /// against the project's current HEAD. Three-dot, so only the branch's own
    /// work shows — commits that landed on HEAD since the fork don't.
    ///
    /// The three gits run inside `Task.detached`, off the main actor: this
    /// handler answers the control API's HTTP socket, and `SubprocessOutput`'s
    /// own documentation says its calls block until git exits. `runDiffGit`
    /// hands back plain data rather than a `Response` — the latter carries an
    /// SSE stream closure that isn't `Sendable`, so it is built back here, on
    /// the actor the socket already runs on.
    private func backlogItemDiff(query: [String: String]) async -> HTTPServer.Response {
        guard let project = query["project"] else { return .error("Missing ?project=", status: 400) }
        guard let itemId = query["item"] else { return .error("Missing ?item=", status: 400) }
        guard let entry = registry.entry(forProject: project) else {
            return .error("Project not open in Kiteloop: \(project)", status: 409)
        }
        guard itemFor(entry: entry, itemId: itemId) != nil else {
            return .error("No backlog item '\(itemId)' in this project", status: 404)
        }
        let root = entry.session.project.rootURL.path(percentEncoded: false)
        let branch = WorktreeSession.branchName(for: itemId)
        let result = await Task.detached(priority: .userInitiated) {
            Self.runDiffGit(branch: branch, root: root)
        }.value
        guard !result.timedOut else {
            return .error("git timed out reading the diff for '\(branch)'", status: 504)
        }
        guard result.branchExists else {
            return .error("No branch '\(branch)' — the item ran in the live tree, or its branch is already merged and gone", status: 404)
        }
        return .json(Self.diffBody(itemId: itemId, branch: branch, stat: result.stat, patch: result.patch))
    }

    /// Each of the three gits the gate diff needs is killed rather than
    /// waited on past this — a hung `git diff` must not hold the human at the
    /// gate, or the control API behind it, forever.
    private nonisolated static let diffGitTimeout: TimeInterval = 30

    private static let diffPatchCap = 200_000

    /// What the three gits `backlogItemDiff` needs answered, off the main
    /// actor. Plain data only — no `HTTPServer.Response` — so it crosses back
    /// out of `Task.detached` without needing to be `Sendable` itself.
    private struct DiffGitResult: Sendable {
        var branchExists = false
        var timedOut = false
        var stat = ""
        var patch = ""
    }

    /// Runs the verify/stat/diff sequence with a deadline on each git, killing
    /// (with its descendants) whichever one outlives `diffGitTimeout` instead
    /// of waiting on it. `discardStandardError` because each answer is parsed
    /// as the diff itself, not read as a log.
    ///
    /// `nonisolated`: without it this inherits the enclosing class's
    /// `@MainActor`, and calling it from inside `Task.detached` would either
    /// fail to compile or hop straight back onto the main actor to run it —
    /// defeating the reason this exists.
    private nonisolated static func runDiffGit(branch: String, root: String) -> DiffGitResult {
        func git(_ arguments: [String]) -> (status: Int32, output: String, timedOut: Bool) {
            SubprocessOutput.runWithDeadline(
                executable: "/usr/bin/git",
                arguments: arguments,
                timeout: diffGitTimeout,
                discardStandardError: true
            )
        }
        let verify = git(["-C", root, "rev-parse", "--verify", "--quiet", branch])
        guard !verify.timedOut else { return DiffGitResult(timedOut: true) }
        guard verify.status == 0 else { return DiffGitResult() }
        let stat = git(["-C", root, "diff", "--stat", "HEAD...\(branch)"])
        guard !stat.timedOut else { return DiffGitResult(branchExists: true, timedOut: true) }
        let patch = git(["-C", root, "diff", "HEAD...\(branch)"])
        guard !patch.timedOut else {
            return DiffGitResult(branchExists: true, timedOut: true, stat: stat.output)
        }
        return DiffGitResult(branchExists: true, stat: stat.output, patch: patch.output)
    }

    private static func diffBody(itemId: String, branch: String, stat: String, patch: String) -> [String: Any] {
        var patch = patch
        let truncated = patch.count > diffPatchCap
        if truncated { patch = String(patch.prefix(diffPatchCap)) }
        return ["item": itemId, "branch": branch, "stat": stat, "patch": patch, "truncated": truncated]
    }

    private func moveBacklogItem(body: Data) -> HTTPServer.Response {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let project = json["project"] as? String,
              let itemId = (json["item"] as? String) ?? (json["itemId"] as? String) else {
            return .error("Body must include \"project\" and \"item\"", status: 400)
        }
        let before = json["before"] as? String
        guard let entry = registry.entry(forProject: project) else {
            return .error("Project not open in Kiteloop: \(project)", status: 409)
        }
        guard let item = itemFor(entry: entry, itemId: itemId) else {
            return .error("No backlog item '\(itemId)' in this project", status: 404)
        }
        // Reordering a finished item is meaningless, and moving one would only
        // rewrite history's order; everything still in play may be prioritised.
        guard item.status != .done else {
            return .error("Item is done — order only matters for work still in play", status: 409)
        }
        if let before, itemFor(entry: entry, itemId: before) == nil {
            return .error("No backlog item '\(before)' to move in front of", status: 404)
        }
        entry.session.backlogViewModel.moveItem(itemID: itemId, before: before)
        return .json([
            "item": itemId,
            "before": before as Any,
            "moved": true,
        ])
    }

    /// Puts an item in the `now` or `later` lane. Unlike a move, the item keeps
    /// its place in its epic: only the `lane:now` mark on its line changes.
    private func setBacklogItemLane(body: Data) -> HTTPServer.Response {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let project = json["project"] as? String,
              let itemId = (json["item"] as? String) ?? (json["itemId"] as? String),
              let laneName = json["lane"] as? String else {
            return .error("Body must include \"project\", \"item\" and \"lane\"", status: 400)
        }
        guard let lane = BacklogLane(rawValue: laneName) else {
            return .error("\"lane\" must be \"now\" or \"later\", not \"\(laneName)\"", status: 400)
        }
        guard let entry = registry.entry(forProject: project) else {
            return .error("Project not open in Kiteloop: \(project)", status: 409)
        }
        guard let item = itemFor(entry: entry, itemId: itemId) else {
            return .error("No backlog item '\(itemId)' in this project", status: 404)
        }
        guard item.status != .done else {
            return .error("Item is done — the lane only matters for work still in play", status: 409)
        }
        if item.lane != lane {
            entry.session.backlogViewModel.updateItemLane(itemID: itemId, lane: lane)
        }
        return .json([
            "item": itemId,
            "was": item.lane.rawValue,
            "lane": lane.rawValue,
            "changed": item.lane != lane,
        ])
    }

    /// Lifts the retry ceiling's refusal on an item, on a human's say-so.
    ///
    /// The other half of `RetryCeiling` — without it, an item retired for
    /// producing nothing three times could never run again, because a retired
    /// item cannot run and only a run could clear the count. Re-grooming the item
    /// releases it by itself (its attempts were made against different wording);
    /// this is for the item a human wants re-attempted exactly as it stands.
    ///
    /// Deliberately not gated on the item being retired. Releasing a runnable
    /// item is a no-op the response reports as such (`wasRetired: false`), and a
    /// 409 there would mean a driver has to reproduce the ceiling's arithmetic to
    /// know whether it's allowed to ask.
    private func releaseBacklogItem(body: Data) -> HTTPServer.Response {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let project = json["project"] as? String,
              let itemId = (json["item"] as? String) ?? (json["itemId"] as? String) else {
            return .error("Body must include \"project\" and \"item\"", status: 400)
        }
        guard let entry = registry.entry(forProject: project) else {
            return .error("Project not open in Kiteloop: \(project)", status: 409)
        }
        guard let groomingLedger else {
            return .error("Cannot release — no grooming ledger attached to record it", status: 503)
        }
        guard itemFor(entry: entry, itemId: itemId) != nil else {
            return .error("No backlog item '\(itemId)' in this project", status: 404)
        }
        let outcome = RetryCeilingRelease.apply(
            itemID: itemId,
            projectPath: entry.session.project.rootURL.path(percentEncoded: false),
            projectName: entry.session.project.rootURL.lastPathComponent,
            source: "control API", reason: json["reason"] as? String,
            ledger: groomingLedger, backlog: entry.session.backlogViewModel,
            records: metricStore?.records ?? [])
        return .json([
            "item": itemId,
            "released": Self.iso.string(from: outcome.at),
            "wasRetired": outcome.wasRetired,
            "noWorkAttemptsBefore": outcome.noWorkAttemptsBefore,
            "noWorkAttempts": outcome.noWorkAttemptsAfter,
            "ceiling": RetryCeiling.limit,
        ])
    }

    /// Rebases a stale item at the gate by hand — the same bounded round the
    /// autopilot runs on its own once the project goes idle. 409 covers every
    /// reason there was nothing to do (not at the gate, no branch, already
    /// fresh, or already retired); a round that ran is 200 whether it
    /// succeeded, failed, or retired the item on its third failure — the
    /// request was answered, and `result` says what happened.
    private func refreshBacklogItem(body: Data) async -> HTTPServer.Response {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let project = json["project"] as? String,
              let itemId = (json["item"] as? String) ?? (json["itemId"] as? String) else {
            return .error("Body must include \"project\" and \"item\"", status: 400)
        }
        guard let entry = registry.entry(forProject: project) else {
            return .error("Project not open in Kiteloop: \(project)", status: 409)
        }
        guard itemFor(entry: entry, itemId: itemId) != nil else {
            return .error("No backlog item '\(itemId)' in this project", status: 404)
        }
        switch await entry.autopilot.refreshGateItem(itemID: itemId) {
        case .refreshed:
            return .json(["item": itemId, "result": "refreshed"])
        case .retired:
            return .json([
                "item": itemId, "result": "retired",
                "detail": "three refresh rounds failed in a row — the item stays at the gate, stale",
            ])
        case .failed(let detail):
            return .json(["item": itemId, "result": "failed", "detail": detail])
        case .nothingToRefresh(let detail):
            return .error(detail, status: 409)
        }
    }

    // MARK: - Backlog templates

    /// The recurring processes this project has written down, and what each one
    /// has to be told before it can be stamped.
    ///
    /// A template that doesn't parse is listed with its `error` rather than
    /// omitted: a missing name reads as "no such template" and sends whoever
    /// wrote it looking in the wrong directory. `directories` comes with the list
    /// for the same reason an empty one is otherwise unreadable — it says where
    /// the app looked.
    private func listTemplates(project: String?) -> HTTPServer.Response {
        guard let project else { return .error("Missing ?project=", status: 400) }
        guard let entry = registry.entry(forProject: project) else {
            return .error("Project not open in Kiteloop: \(project)", status: 409)
        }
        let backlog = entry.session.backlogViewModel
        let root = entry.session.project.rootURL
        let fileBacked = BacklogTemplateStore.list(backlogURL: backlog.backlogURL, projectRoot: root)
        var seen = Set(fileBacked.map(\.name))
        var templates = fileBacked.map(templateJSON)
        templates += groomingKindTemplates(skippingNamesIn: &seen)
        return .json([
            "directories": BacklogTemplateStore.directories(backlogURL: backlog.backlogURL,
                                                            projectRoot: root)
                .map { $0.path(percentEncoded: false) },
            "templates": templates
        ])
    }

    private func templateJSON(_ entry: BacklogTemplateStore.Entry) -> [String: Any] {
        var out: [String: Any] = [
            "name": entry.name,
            "path": entry.url.path(percentEncoded: false)
        ]
        if let error = entry.error { out["error"] = error }
        guard let template = entry.template else { return out }
        out["description"] = template.description as Any
        out["epic"] = template.epic as Any
        out["items"] = template.items.count
        out["variables"] = variablesJSON(template.variables)
        return out
    }

    /// The three grooming-kind skeletons (`BacklogTemplate.ItemKind`) — Swift
    /// constants, not files under `templates/` — surfaced the same way a
    /// file-backed template is, so hand grooming can find them without the repo
    /// carrying a `templates/bug.md` etc. A file-backed template of the same
    /// name shadows its skeleton, the same rule that already lets a
    /// project-local template shadow a repo one. Has no `path`; carries `kind`
    /// instead so a caller can tell the two apart.
    private func groomingKindTemplates(skippingNamesIn seen: inout Set<String>) -> [[String: Any]] {
        BacklogTemplate.ItemKind.allCases.compactMap { kind -> [String: Any]? in
            guard seen.insert(kind.rawValue).inserted else { return nil }
            let skeleton = kind.skeleton
            return [
                "name": kind.rawValue,
                "kind": true,
                "description": skeleton.description as Any,
                "items": skeleton.items.count,
                "variables": variablesJSON(skeleton.variables)
            ]
        }
    }

    private func variablesJSON(_ variables: [BacklogTemplate.Variable]) -> [[String: Any]] {
        variables.map { variable -> [String: Any] in
            [
                "name": variable.name,
                "description": variable.description as Any,
                "required": variable.required,
                "pattern": variable.pattern as Any
            ]
        }
    }

    /// A step in `stampTemplate` that can either continue with `Value` or
    /// refuse with its own response — the same shape as `BoolField`,
    /// generalised since this endpoint gained more than one such step.
    /// `Result` doesn't fit: its `Failure` must conform to `Error`, and
    /// `HTTPServer.Response` is a plain struct, not one.
    private enum StampStep<Value> {
        case value(Value)
        case failure(HTTPServer.Response)
    }

    /// The `variables` object, read as JSON scalars; a number is what
    /// `{"version": 2}` would send, and reading it as "2" is friendlier than a
    /// 400 for a type the template's own pattern is about to judge anyway.
    private static func stampVariables(from json: [String: Any]) -> StampStep<[String: String]> {
        var values: [String: String] = [:]
        for (key, value) in (json["variables"] as? [String: Any]) ?? [:] {
            switch value {
            case let text as String: values[key] = text
            case let number as NSNumber: values[key] = number.stringValue
            default:
                return .failure(.error("Variable \"\(key)\" must be a string", status: 400))
            }
        }
        return .value(values)
    }

    /// The `kind` field, resolved — `nil` when the request left it out, which
    /// runs today's plain gate unchanged.
    private static func stampKind(from json: [String: Any]) -> StampStep<BacklogTemplate.ItemKind?> {
        guard let kindField = json["kind"] as? String else { return .value(nil) }
        guard let resolved = BacklogTemplate.ItemKind(rawValue: kindField) else {
            let known = BacklogTemplate.ItemKind.allCases.map(\.rawValue).joined(separator: ", ")
            return .failure(.error("kind must be one of: \(known)", status: 400))
        }
        return .value(resolved)
    }

    /// Loads the named template and stamps it — the two steps that can each
    /// refuse with their own status, folded into one so the caller reads past
    /// both in a single switch.
    private static func loadAndStamp(
        named name: String, values: [String: String], existingIDs: Set<String>,
        backlogURL: URL?, projectRoot: URL
    ) -> StampStep<(BacklogTemplate, [BacklogTemplate.Drafted])> {
        guard let found = BacklogTemplateStore.load(named: name, backlogURL: backlogURL,
                                                    projectRoot: projectRoot) else {
            return .failure(.error("No template \"\(name)\" in this project", status: 404))
        }
        guard let template = found.template else {
            return .failure(.error(found.error ?? "template \(name) could not be read", status: 422))
        }
        do {
            return .value((template, try template.stamp(values: values, existingIDs: existingIDs)))
        } catch let error as BacklogTemplateError {
            return .failure(.error(error.message, status: 422))
        } catch {
            return .failure(.error(error.localizedDescription, status: 422))
        }
    }

    private static func gatedItemJSON(_ item: BacklogTemplate.GatedItem) -> [String: Any] {
        [
            "id": item.draft.id,
            "title": item.draft.title,
            "status": item.status.rawValue,
            "size": item.draft.size,
            "verify": item.draft.verify,
            "needs": item.draft.needs,
            "gates": item.notes,
            "detail": item.draft.detailMarkdown(notes: item.notes)
        ]
    }

    /// Stamp a template into real items — previewed by default, filed with
    /// `"apply": true`.
    ///
    /// The refusals are the point. A variable that fails its constraint, or an id
    /// already in the backlog, refuses the **whole** stamp with 422 and writes
    /// nothing: half a release checklist is worse than none, because the missing
    /// half is invisible. The collision refusal is also what stops the same
    /// release being filed twice — a stamp is idempotent by refusing, not by
    /// overwriting.
    private func stampTemplate(body: Data) async -> HTTPServer.Response {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let project = json["project"] as? String,
              let name = (json["template"] as? String), !name.isEmpty else {
            return .error("Body must include \"project\" and \"template\"", status: 400)
        }
        guard let entry = registry.entry(forProject: project) else {
            return .error("Project not open in Kiteloop: \(project)", status: 409)
        }
        let values: [String: String]
        switch Self.stampVariables(from: json) {
        case .value(let resolved): values = resolved
        case .failure(let response): return response
        }
        let apply: Bool
        switch Self.boolField(json, "apply") {
        case .absent: apply = false
        case .invalid(let key): return Self.invalidBool(key)
        case .value(let value): apply = value
        }
        // Absent: today's gate, unchanged. Given: this kind's own clause is
        // checked too, on top of the same two gates every stamp already faces —
        // the steering lever `BacklogTemplate.ItemKind` exists for, reached from
        // a hand-groomed stamp rather than only the coordinator's own drafting.
        let kind: BacklogTemplate.ItemKind?
        switch Self.stampKind(from: json) {
        case .value(let resolved): kind = resolved
        case .failure(let response): return response
        }

        let backlog = entry.session.backlogViewModel
        let root = entry.session.project.rootURL
        let existingIDs = Set((backlog.backlogFile?.sections.flatMap(\.items) ?? []).map(\.id))
        let template: BacklogTemplate
        let stamped: [BacklogTemplate.Drafted]
        switch Self.loadAndStamp(named: name, values: values, existingIDs: existingIDs,
                                 backlogURL: backlog.backlogURL, projectRoot: root) {
        case .value(let result): (template, stamped) = result
        case .failure(let response): return response
        }

        // The same index the coordinator's drafts are grounded against, built off
        // the main actor — it walks the repo, and the orchestrator must not block.
        let (vault, base) = (backlog.vaultURL, entry.autopilot.baseBranch)
        let sources = await Task.detached {
            GroundingCheck.Sources.repository(root: root, vault: vault, baseBranch: base)
        }.value
        let gated = kind?.gate(stamped, sources: sources) ?? BacklogTemplate.gate(stamped, sources: sources)
        let epic = template.section(in: backlog.backlogFile)

        var payload: [String: Any] = [
            "template": template.name,
            "epic": epic,
            "applied": apply,
            "items": gated.map(Self.gatedItemJSON)
        ]
        guard apply else { return .json(payload) }

        let failures = BacklogAIEditor.apply(BacklogTemplate.ops(for: gated, epic: epic), to: backlog)
        guard failures.isEmpty else {
            return .error("Stamped \(gated.count - failures.count) of \(gated.count) items: "
                          + failures.joined(separator: "; "), status: 500)
        }
        payload["filed"] = gated.map { $0.draft.id }
        return .json(payload, status: 201)
    }

    /// The model call a grooming pass makes — prompt, project root, system
    /// prompt and what it may read. The app points it at the Backlog Groomer's
    /// one-shot at launch; on a server nobody gave one, `POST /v1/backlog/items`
    /// files without grooming and says so.
    typealias GroomOneShot = @MainActor (_ prompt: String, _ cwd: URL, _ systemPrompt: String,
                                         _ grant: RepoRead.Grant) async throws -> String
    var groomOneShot: GroomOneShot?

    /// What `POST /v1/backlog/items` was asked to file.
    private struct ItemFiling {
        let project: String
        let title: String
        let note: String?
        let epic: String
        let groom: Bool
    }

    /// `POST /v1/backlog/items`: one new item at `draft`, answered at once and
    /// groomed afterwards when asked.
    private func fileBacklogItem(body: Data) -> HTTPServer.Response {
        let filing: ItemFiling
        switch Self.itemFiling(Self.jsonBody(body)) {
        case .value(let read): filing = read
        case .failure(let response): return response
        }
        guard let entry = registry.entry(forProject: filing.project) else {
            return .error("Project not open in Kiteloop: \(filing.project)", status: 409)
        }
        let backlog = entry.session.backlogViewModel
        let id = backlog.itemID(forTitle: filing.title)
        let outcome = Self.file(filing, id: id, in: backlog)
        guard outcome.didFile else { return Self.filingRefusal(outcome, id: id) }
        return .json(["item": id, "epic": filing.epic, "status": BacklogItemStatus.draft.rawValue,
                      "grooming": filing.groom ? startGrooming(id, in: entry) : "not asked"], status: 201)
    }

    private static func itemFiling(_ json: [String: Any]) -> StampStep<ItemFiling> {
        let title = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let project = json["project"] as? String, !title.isEmpty else {
            return .failure(.error("Body must include \"project\" and a non-empty \"title\"", status: 400))
        }
        guard !title.contains(DefinitionOfReady.fieldSeparator) else {
            return .failure(.error("A title can't contain “\(DefinitionOfReady.fieldSeparator)”, the backlog line's field separator",
                                   status: 400))
        }
        let groom: Bool
        switch boolField(json, "groom") {
        case .absent: groom = false
        case .invalid(let key): return .failure(invalidBool(key))
        case .value(let value): groom = value
        }
        return .value(ItemFiling(project: project, title: title, note: nonEmptyText(json["note"]),
                                 epic: nonEmptyText(json["epic"]) ?? "Inbox", groom: groom))
    }

    private static func nonEmptyText(_ raw: Any?) -> String? {
        let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    /// The line, and with a note the detail file whose What it is.
    private static func file(_ filing: ItemFiling, id: String, in backlog: BacklogViewModel) -> BacklogViewModel.FilingOutcome {
        guard let note = filing.note else {
            return backlog.addItem(sectionName: filing.epic, id: id, title: filing.title, verify: nil, status: .draft)
        }
        return backlog.fileGroomedItem(sectionName: filing.epic, id: id, title: filing.title, size: nil, verify: nil,
                                       status: .draft, detailMarkdown: "## What\n\n\(note)\n")
    }

    private static func filingRefusal(_ outcome: BacklogViewModel.FilingOutcome, id: String) -> HTTPServer.Response {
        let reason = "Couldn't file \(id): \(outcome.refusalReason ?? "the backlog refused it")"
        switch outcome {
        case .emptyTitle, .holdsFieldSeparator: return .error(reason, status: 400)
        case .noBacklogOpen, .duplicateID: return .error(reason, status: 409)
        default: return .error(reason, status: 500)
        }
    }

    /// Starts the grooming pass behind the answer; says whether it could.
    private func startGrooming(_ id: String, in entry: ControlSessionRegistry.Entry) -> String {
        guard let groomOneShot else { return "unavailable — this Mac has no model runner for grooming" }
        Task { await groomFiledItem(id, in: entry, oneShot: groomOneShot) }
        return "started"
    }

    /// The Mac's Groom pass over a just-filed item, written without its
    /// preview: the item stays at `draft`, so promoting it is still a
    /// person's step. A pass that fails says why in the item's Notes.
    private func groomFiledItem(_ id: String, in entry: ControlSessionRegistry.Entry, oneShot: @escaping GroomOneShot) async {
        let backlog = entry.session.backlogViewModel
        guard let item = backlog.item(withID: id), let file = backlog.backlogFile else { return }
        let root = entry.session.project.rootURL
        let vault = backlog.vaultURL
        let grant = RepoRead.Grant(projectName: root.lastPathComponent, projectPath: root.path(percentEncoded: false))
        let system = BacklogGroomer.personaPrompt + "\n\n" + RepoRead.contract(for: grant)
        let base = entry.autopilot.baseBranch
        let sources = await Task.detached {
            GroundingCheck.Sources.repository(root: root, vault: vault, baseBranch: base)
        }.value
        do {
            let proposal = try await BacklogGroomer.propose(
                item: item, detail: backlog.loadDetail(for: item), backlog: file, sources: sources,
                runOneShot: { prompt in try await oneShot(prompt, root, system, grant) })
            if let refusal = backlog.writeGrooming(proposal) {
                _ = backlog.appendNote(itemID: id, "Grooming filed from the phone was not written — \(refusal)")
            }
        } catch {
            controlLog.error("Grooming \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            _ = backlog.appendNote(itemID: id, "Grooming filed from the phone failed — \(error.localizedDescription)")
        }
    }

    /// Resolves a backlog item's human gate: approve → merge the item's branch
    /// (when the project auto-merges) and then `done`; reject → back to `ready`
    /// with feedback. Only valid from `awaiting-approval`.
    ///
    /// Approving used to stamp `done` and stop there. The run-based path merges;
    /// this one silently did not, so an item read as delivered while its commits
    /// sat on a branch `main` had never seen — and this is the only path that
    /// survives a restart, because run records don't. On 2026-08-09 five items
    /// were approved this way and had to be merged by hand, with the backlog
    /// claiming `done` the whole time. `done` here now means the work landed.
    private func approveItem(entry: ControlSessionRegistry.Entry, itemId: String, approve: Bool, reason: String?, runId: String? = nil) async -> HTTPServer.Response {
        guard let item = itemFor(entry: entry, itemId: itemId) else {
            return .error("No backlog item '\(itemId)' in this project", status: 404)
        }
        guard item.status == .awaitingApproval else {
            return .error("Item '\(itemId)' is not awaiting approval (status: \(item.status.rawValue))", status: 409)
        }
        let backlog = entry.session.backlogViewModel
        var payload: [String: Any] = ["item": itemId]
        if let runId { payload["runId"] = runId }
        guard approve else {
            await backlog.rejectAtGate(itemID: itemId, reason: reason ?? "", projectRoot: entry.session.project.rootURL)
            payload["resolved"] = "rejected"
            payload["status"] = BacklogItemStatus.ready.rawValue
            return .json(payload)
        }

        payload["branch"] = WorktreeSession.branchName(for: itemId)

        // Already known to be stale from a sibling's merge — answered here,
        // before a merge or verify runs, rather than only once the fast-forward
        // itself refuses minutes later. See `staleGateRefusal` for when the
        // cache is trusted and when it is not.
        if let refusal = await Self.staleGateRefusal(
            itemId: itemId, freshness: backlog.freshnessByItemID, projectRoot: entry.session.project.rootURL
        ) {
            payload.merge(refusal) { _, new in new }
            return .json(payload, status: 409)
        }

        let plan = Self.mergeVerify(autopilot: entry.autopilot, item: item)
        let outcome = await backlog.resolveGate(
            itemID: itemId, approve: true,
            autoMerge: entry.autopilot.autoMergeOnApproval,
            verify: plan,
            projectRoot: entry.session.project.rootURL, isolationExpected: entry.autopilot.useWorktree,
            base: entry.autopilot.baseBranch, setupCommand: entry.autopilot.effectiveWorktreeSetup.command,
            timeout: TimeInterval(entry.autopilot.autoMergeVerifyTimeoutMinutes) * 60,
            closure: .approvedViaAPI)

        switch outcome {
        case .workNotOnBranch(let why):
            // The same shape as a refused merge, and for the same reason: the
            // item is still at the gate and nothing shipped. A driver that reads
            // only `resolved` must not see this as delivery.
            payload["merged"] = false
            payload["resolved"] = "not approved"
            payload["status"] = BacklogItemStatus.awaitingApproval.rawValue
            payload["reason"] = why
            return .json(payload, status: 409)
        case .mergeFailed(let why, let verifyOutput):
            // The work has not landed, so the item does not become `done` —
            // reporting delivery over an unmerged branch is the defect this
            // guard exists to stop. Left at the gate for a human.
            payload["merged"] = false
            payload["resolved"] = "not approved"
            payload["status"] = BacklogItemStatus.awaitingApproval.rawValue
            payload["reason"] = why
            // The refusal rolled the merged tree back, so a caller that only
            // gets `reason` cannot see what failed — the evidence is already
            // gone from the repository by the time it reads this.
            if let verifyOutput, !verifyOutput.isEmpty { payload["verifyOutput"] = verifyOutput }
            return .json(payload, status: 409)
        case .approvedWithoutMerge(let note):
            payload["merged"] = false
            payload["mergeSkipped"] = note
        case .approvedAndMerged:
            payload["merged"] = true
            // What the merge was actually gated on. A caller that approves
            // headlessly never sees the run log, and "merged: true" alone does
            // not say whether anything relevant to the diff ran.
            payload["verify"] = plan.labels
        case .rejected:
            break   // unreachable: `approve` is true on this path
        }
        payload["resolved"] = "approved"
        payload["status"] = BacklogItemStatus.done.rawValue
        return .json(payload)
    }

    /// The payload for a 409 the cache alone can answer, or `nil` when the
    /// merge attempt below has to settle it: `freshnessByItemID` is refreshed
    /// whenever an item reaches the gate and after every merge into the base
    /// since, so an item the cache never got a verdict for (a live-tree
    /// project, or one that reached the gate before this build) falls through
    /// exactly as before — and so does a cached conflict whose branch has
    /// since moved (a gate refresh round rebases it without updating this
    /// cache), checked here against the branch's live tip.
    private static func staleGateRefusal(
        itemId: String, freshness: [String: WorktreeManager.BranchFreshness], projectRoot: URL
    ) async -> [String: Any]? {
        guard let freshness = freshness[itemId], !freshness.clean else { return nil }
        let manager = WorktreeManager(projectRoot: projectRoot)
        guard await manager.branchTip(for: itemId) == freshness.branchTip else { return nil }
        return [
            "merged": false,
            "resolved": "not approved",
            "status": BacklogItemStatus.awaitingApproval.rawValue,
            "reason": WorktreeManager.conflictRefusal(paths: freshness.conflicts)
        ]
    }

    /// The gate-side fields of one backlog item — `freshness` and `gate` —
    /// present only for an item at the approval gate, empty otherwise.
    private static func gateFields(item: BacklogItem, backlog: BacklogViewModel) -> [String: Any] {
        var fields: [String: Any] = [:]
        if let freshness = freshnessJSON(item: item, cache: backlog.freshnessByItemID) { fields["freshness"] = freshness }
        if let gate = backlog.gateState(for: item) { fields["gate"] = gateJSON(gate) }
        return fields
    }

    /// The `gate` object for an item at the approval gate: verifying, waiting
    /// on a person, or refused with the reason — the three states one status
    /// used to hide.
    private static func gateJSON(_ gate: GateState) -> [String: Any] {
        var json: [String: Any] = ["state": gate.kind.rawValue]
        if let since = gate.since { json["since"] = iso.string(from: since) }
        if let reason = gate.reason { json["reason"] = reason }
        return json
    }

    /// The `gate` object for a project in `GET /v1/projects`: the item whose
    /// merge gate is verifying right now, whoever asked for it — a run's own
    /// gate or an approval's — so a phone can tell "verifying" from "waiting
    /// on you" without reading every item.
    private static func projectGateJSON(_ backlog: BacklogViewModel) -> [String: Any]? {
        guard let earliest = backlog.gateActivity.min(by: { $0.value < $1.value }) else { return nil }
        return ["item": earliest.key, "since": iso.string(from: earliest.value), "state": GateState.Kind.verifying.rawValue]
    }

    /// The `freshness` object for one backlog item's `GET /v1/backlog` entry —
    /// nil for anything but a gate item something has actually checked (a
    /// live-tree project, or a gate item that predates this build, has
    /// nothing cached).
    private static func freshnessJSON(
        item: BacklogItem, cache: [String: WorktreeManager.BranchFreshness]
    ) -> [String: Any]? {
        guard item.status == .awaitingApproval, let freshness = cache[item.id] else { return nil }
        return [
            "clean": freshness.clean,
            "conflicts": freshness.conflicts,
            "checkedAt": iso.string(from: freshness.checkedAt)
        ]
    }

    /// What must pass on the merged tree: the item's own `verify:` *and* the
    /// project's merge-verify command — the same plan the run-based path builds,
    /// so approving through the API can't clear a lower bar.
    private static func mergeVerify(autopilot: BacklogAutopilot, item: BacklogItem) -> MergeVerifyPlan {
        MergeVerifyPlan.resolve(projectCommand: autopilot.effectiveMergeVerify.command,
                                itemVerify: item.verify)
    }

    private func itemFor(entry: ControlSessionRegistry.Entry, itemId: String) -> BacklogItem? {
        entry.session.backlogViewModel.backlogFile?
            .sections.flatMap(\.items)
            .first { $0.id == itemId }
    }

    // MARK: - Helpers

    private func approvalQuestion(entry: ControlSessionRegistry.Entry, runId: String) -> String? {
        entry.session.orchestrator.pendingWorkflowApprovals.first { $0.executionID == runId }?.question
    }

    private static func isTerminal(_ type: KiteloopEvent.EventType) -> Bool {
        type == .workflowCompleted || type == .workflowFailed || type == .workflowCancelled
    }

    private static func eventJSON(_ event: KiteloopEvent) -> String {
        let obj: [String: Any] = [
            "ts": iso.string(from: event.timestamp),
            "type": event.type.rawValue,
            "source": event.source,
            "payload": event.payload
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    private func itemStatus(entry: ControlSessionRegistry.Entry, itemId: String) -> String {
        entry.session.backlogViewModel.backlogFile?
            .sections.flatMap(\.items)
            .first { $0.id == itemId }?
            .status.rawValue ?? "unknown"
    }

    private static func statusLabel(_ status: BacklogAutopilot.Status) -> String {
        status.label
    }

    /// The wire label for an outcome. Routed through `persistedOutcome` so the
    /// live response and the record on disk cannot come to disagree about what a
    /// `blocked` run is called.
    private static func outcomeLabel(_ outcome: BacklogAutopilot.ItemResult.Outcome) -> String {
        persistedOutcome(outcome).rawValue
    }

    private static func persistedOutcome(_ outcome: BacklogAutopilot.ItemResult.Outcome) -> PersistedRunRecord.Outcome {
        switch outcome {
        case .done: return .done
        // The wire vocabulary answers "where did the item end up", and a claim
        // run ends it at the approval gate — which is what a driver has to act
        // on, and what `itemStatus` beside it says too. The distinction the
        // claim makes is about the *ledger*, not about the gate: it is
        // `TaskMetricRecord.alreadyImplementedOutcome` that keeps the run out of
        // the retry ceiling, and the claim itself is in the item's Notes. So no
        // new wire value is minted for it.
        case .awaitingApproval, .alreadyImplemented: return .awaitingApproval
        // A refuted premise *does* get its own wire value: the item is at the
        // gate too, but a driver counting its night has to tell an item that
        // was built from one found not to need building — the whole reason
        // the ending exists (2026-09-03).
        case .investigation: return .investigation
        case .usageLimitParked: return .usageLimitParked
        case .blocked: return .blocked
        case .cancelled: return .cancelled
        }
    }

    private static let iso = ISO8601DateFormatter()

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    // MARK: - Token

    /// Where the bearer token lives in a real install: `~/.kiteloop/control-token`.
    ///
    /// `nonisolated`, like `defaultOperatorTokenURL` and `loadOrCreateToken`
    /// below it: `ClaudeCodeCLIRuntime.provision` reads the operator token off
    /// the main actor when building a spawned CLI's environment, and this is the
    /// same path that resolution runs.
    nonisolated static var defaultTokenURL: URL {
        KiteloopHome.url.appending(path: ".kiteloop/control-token")
    }

    /// Where the operator-scoped token lives: `~/.kiteloop/operator-token`,
    /// beside the full one.
    nonisolated static var defaultOperatorTokenURL: URL {
        KiteloopHome.url.appending(path: ".kiteloop/operator-token")
    }

    /// The token file's contents, trimmed, or nil when the file cannot be read
    /// or holds bytes that are not UTF-8. Read strictly, unlike other text
    /// files: a token decoded lossily would be a wrong credential.
    nonisolated static func readExactToken(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Bearer token at `url` (0600), created on first use. Used for both
    /// `~/.kiteloop/control-token` and `~/.kiteloop/operator-token` — the two
    /// files are minted and read back identically, only their contents differ
    /// in what they authorize.
    ///
    /// Internal rather than private so a test can drive the creation path — and
    /// the unwritable-directory path — without standing up a server.
    nonisolated static func loadOrCreateToken(at url: URL) -> String {
        if let existing = readExactToken(at: url), !existing.isEmpty { return existing }
        let token = mintToken()
        do {
            // 0600 explicitly rather than write-then-chmod, for the same reason
            // `regenerateToken()` does it: the file this renames into place is
            // created with the mode already set, so the token is never briefly
            // readable by anyone else. `AtomicFileWriter` creates the containing
            // directory, so first launch needs no mkdir of its own.
            try AtomicFileWriter.write(Data(token.utf8), to: url, mode: 0o600)
        } catch {
            // Nothing else can be done here — the server has no other credential
            // to start with and the caller cannot proceed without one — so hand
            // back the minted token anyway. Saying so is the point: a token that
            // never reached disk is one the user cannot read, and this used to
            // fail silently.
            controlLog.error("""
                control token could not be written to \
                \(url.path(percentEncoded: false), privacy: .public): \
                \(String(describing: error), privacy: .public)
                """)
        }
        return token
    }

    /// Replaces the bearer token with a freshly minted one — in the file the user
    /// reads it from *and* in this running server, so the old token stops
    /// authenticating the moment this returns and the new one works with no
    /// restart. Every client holding the old token breaks immediately, including a
    /// driver mid-run; that is the point of a rotation, and the caller is expected
    /// to have said so before getting here.
    ///
    /// Returns the new token, or `nil` if the file could not be written — in which
    /// case nothing has changed and the old token still works. The file is the
    /// only place the token can be read from, so a rotation that landed in memory
    /// alone would leave a credential nobody could look up.
    @discardableResult
    func regenerateToken() -> String? {
        let fresh = Self.mintToken()
        do {
            // 0600 explicitly rather than write-then-chmod: the temp file this
            // renames into place is created with the mode already set, so the
            // secret is never briefly world-readable.
            try AtomicFileWriter.write(Data(fresh.utf8), to: tokenURL, mode: 0o600)
        } catch {
            controlLog.error("control token rotation failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        token = fresh
        controlLog.info("control token rotated; existing clients must re-read the token file")
        return fresh
    }

    private nonisolated static func mintToken() -> String {
        UUID().uuidString + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }
}
