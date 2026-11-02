import Foundation
import KiteloopCore
import os.log

private let schedulerLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "run-scheduler")

/// The loop that **starts** runs: the Coordinator as an operator rather than a
/// groomer.
///
/// `CoordinatorQueueRefill` keeps the queues fed and then waits for a human to
/// press Run. This is the other half — when a project has runnable work and
/// nothing in flight, it calls `BacklogAutopilot.start(initiator: .autonomous)`.
/// That seam and `DailyBudget` were built for exactly this caller: the budget
/// refuses an autonomous start on an exhausted day and still lets a person start
/// one.
///
/// Four properties are load-bearing, and none of them is a bound invented here:
///
/// * **Off by default.** Only a stored `true` ever switches it on, so upgrading
///   the app cannot start running work overnight. Its switch is *separate* from
///   the refill switch — filing work and running it are different levels of
///   trust.
/// * **The kill switch means it.** Switching off tears the timer down and is
///   re-read immediately before the start call, so a tick already in flight
///   doesn't get one last run in. What it deliberately does **not** do is kill a
///   run already executing: abandoning an item mid-flight strands it, and
///   stopping that run is the Autopilot's own Stop button.
/// * **Every existing bound applies** — paused projects, the daily budget, one
///   run at a time per project and the pickup gates are all called
///   (`RunScheduling.decide`), never restated.
/// * **Repeated failure stops it — where the failures were.** Failed autonomous
///   runs accumulate into a `RunScheduling.ProjectHold` scoped to the project
///   whose queue they were about, and that hold ends the moment the queue it
///   describes is no longer the queue. Nothing aggregates across projects, and
///   nothing latches: what this replaced was a fleet-global counter that stopped
///   every project on one project's three retries and stayed stopped until
///   somebody relaunched the app.
///
/// Every start is recorded three ways: an entry in `startHistory`, a
/// `Coordinator` event in the project's console, and a line in
/// `~/.kiteloop/coordinator-starts.jsonl` that survives the app — and is read
/// back into `startHistory` at launch, so a restart doesn't erase the night from
/// the account of it the app serves. With the control
/// server attached it is recorded a fourth: as a run record, so `GET /v1/runs`
/// answers for the work an unattended night did instead of showing nothing.
@MainActor
@Observable
final class CoordinatorRunScheduler {

    // MARK: - What one start looked like

    /// One autonomous start, from the decision to the outcome. Written when the
    /// run begins — so a crash mid-run still leaves the start on record — and
    /// completed when it ends.
    struct StartRecord: Sendable, Equatable, Identifiable {
        let at: Date
        let project: String
        let itemID: String
        let itemTitle: String
        /// Why this project and item were chosen.
        let why: String
        /// The day's budget as it stood at the start ("$3.20 of $20.00").
        let budgetText: String
        /// `running` until the run ends, then `done`, `awaiting-approval`,
        /// `blocked`, `cancelled` — or `did-not-run` when the start was refused
        /// downstream (an item the pickup gates rejected, say). A start read back
        /// from the log with no finish beside it is `interrupted`: the process
        /// that was running it is gone.
        var outcome: String
        var finishedAt: Date?

        var id: String { "\(at.timeIntervalSince1970)-\(project)-\(itemID)" }

        static let running = "running"
        static let didNotRun = "did-not-run"
        /// The statement `PersistedRunRecord.Outcome.interrupted` makes, for the
        /// same reason: this run was in flight when the app went away, and
        /// reporting it as still `running` would be a claim about a process that
        /// no longer exists.
        static let interrupted = "interrupted"

        var summary: String {
            "\(project)/\(itemID) \(outcome) — \(why) · budget \(budgetText)"
        }
    }

    /// What a finished run said about the item, as a hold reads it.
    struct Outcome: Sendable, Equatable {
        /// `done`, `awaiting-approval`, `blocked`, `cancelled`, `did-not-run`.
        let name: String
        /// The blocked reason, when there was one.
        let detail: String?
        /// Whether the run got somewhere. `awaiting-approval` counts: the worker
        /// and the reviewer both did their job and the item is waiting on a
        /// person, which is a success of the run, not a failure of it.
        let succeeded: Bool

        var phrase: String { detail.map { "\(name): \($0)" } ?? name }
    }

    /// How many starts are remembered in memory, and how many of the JSONL's are
    /// read back at launch. Enough to read back a night at the default interval;
    /// the durable record is the JSONL, which keeps more than this on purpose —
    /// what the app serves is a window onto a longer history.
    static let maxStartHistory = 50

    /// How much of the durable log survives, so launch cost stays flat and the
    /// file stays readable. Both bounds apply, and they are the two
    /// `RunRecordStore` keeps for the same reason: a busy portfolio hits the
    /// count first, an idle one the age. The log is compacted to them when it is
    /// read, which is once per launch.
    static let retentionLimit = 500
    static let retentionAge: TimeInterval = 30 * 24 * 60 * 60

    // MARK: - Settings

    /// The kill switch. Off until a human turns it on, and assigning persists
    /// the choice, clears every hold (turning it back on is the human saying
    /// they've seen the failures) and starts or tears down the timer.
    var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            if !isLoadingConfig { globalConfigStore?.setCoordinatorScheduling(enabled: enabled) }
            holds.clear()
            gateRefusals.clear()
            syncTimer()
            schedulerLog.info("Autonomous scheduling \(self.enabled ? "on" : "off", privacy: .public)")
        }
    }

    /// How often the loop looks. A look is a snapshot, not a model call, so it
    /// is cheap; it is deliberately shorter than the refill interval because a
    /// project that just went idle is one this should notice.
    var checkInterval: TimeInterval = 5 * 60

    // MARK: - State

    /// What each project's own failed runs are still evidence for. Re-read at
    /// the top of every tick against the queue as it stands, so a hold is a live
    /// reading rather than a latch somebody has to remember to clear.
    ///
    /// In memory and nowhere else, deliberately: "an app relaunch clears it" is
    /// one of the ways a same-cause hold is supposed to end, and persisting
    /// these would take that away.
    private(set) var holds = RunScheduling.Holds()
    /// Which currently-ready items the pickup gates have already refused, as
    /// they were written when refused — re-read at the top of every tick the
    /// same way `holds` is, and, like `holds`, kept in memory only: an app
    /// relaunch is one of the ways a refusal is allowed to be re-asked.
    private(set) var gateRefusals = RunScheduling.GateRefusals()
    private(set) var lastDecision: RunScheduling.Decision?

    /// When the loop last looked, so a surface can say when it will look again.
    ///
    /// Nil until the first tick — which is the state a freshly launched app sits
    /// in for up to `checkInterval`, and the one worth saying out loud: an armed
    /// scheduler that has not ticked yet is indistinguishable from a broken one
    /// if nothing on screen mentions it.
    private(set) var lastTickAt: Date?
    /// Newest last, capped at `maxStartHistory`. Seeded at launch from the
    /// durable log, so it is empty only when nothing has ever run.
    private(set) var startHistory: [StartRecord] = []
    /// The projects whose autonomous run this scheduler is awaiting right now,
    /// by path. A tick reserves a project's slot here before it starts the run
    /// and releases it when the run returns, so concurrent looks never hand
    /// one project two runs and the fleet never exceeds `maxConcurrentRuns`.
    private(set) var startsInFlight: Set<String> = []
    /// True from the moment a start is committed to until the run ends.
    var isStarting: Bool { !startsInFlight.isEmpty }
    /// How many runs the fleet may have in flight at once, across projects —
    /// each project still runs one at a time. One is how the fleet always ran;
    /// raising it lets a second project's look proceed while the first's run
    /// is still being awaited. Persisted in the global config.
    var maxConcurrentRuns: Int = 1 {
        didSet {
            let clamped = min(max(maxConcurrentRuns, Self.concurrentRunsRange.lowerBound), Self.concurrentRunsRange.upperBound)
            if clamped != maxConcurrentRuns { maxConcurrentRuns = clamped; return }
            guard maxConcurrentRuns != oldValue else { return }
            if !isLoadingConfig { globalConfigStore?.setMaxConcurrentRuns(maxConcurrentRuns) }
        }
    }
    static let concurrentRunsRange = 1...8
    /// True for the whole of a tick, start or no start — the guard that keeps
    /// two occasions to look from becoming two looks.
    ///
    /// `isStarting` already covers the window a run is in flight, and on the
    /// main actor a tick reaches it without suspending. That is a property of
    /// where the suspension points happen to fall today, though, and the loop
    /// now has more than one caller: the timer, and the moment a finished run
    /// announces. This makes "never overlaps itself" something the type holds
    /// rather than something the schedule does.
    private var isTicking = false
    /// How many lines of the durable log the decoder refused at launch. Logged as
    /// well, but exposed so a caller — and a test — can see it without reading
    /// os_log.
    private(set) var undecodableLineCount = 0

    /// Those lines themselves, held verbatim so `rewrite` can put them back.
    /// `append` writes a line at a time, so a kill mid-append leaves a truncated
    /// one — which is exactly the run somebody came back to ask about.
    private var undecodableLines: [String] = []

    /// Whether the periodic check is live. A switched-off loop has no timer at
    /// all rather than one that wakes only to refuse.
    var isTimerRunning: Bool { timer != nil }

    /// Whether anything is wired to it. Unwired it holds with `.unwired`, which
    /// is a different claim from "off".
    var isConfigured: Bool { registry != nil && globalConfigStore != nil }

    /// Today's portfolio-wide budget: the ceiling joined with what every project
    /// has spent since local midnight. The same pair `BacklogAutopilot.dailyBudget`
    /// reads, so the gate here and the gate in `start` agree.
    var dailyBudget: DailyBudget {
        DailyBudget(budgetUSD: portfolioDailyBudgetUSD,
                    spentUSD: spendLedger?.spentTodayUSD ?? 0)
    }

    /// The portfolio-wide ceiling itself, readable and writable — the only thing
    /// in the app that offers a write to it besides the Coordinator panel, and
    /// what `PUT /v1/coordinator/scheduling` sets. It stays in
    /// `~/.kiteloop/global-config.json`: a per-project reset must never be able
    /// to clear the number that bounds the whole bill.
    var portfolioDailyBudgetUSD: Double? {
        get { globalConfigStore?.config.dailyBudgetUSD }
        set { globalConfigStore?.setDailyBudgetUSD(newValue) }
    }

    /// What arming would enroll, for the switch's confirm surface: each project
    /// that has opted into autonomous work and is autopilot-ready, with the
    /// first few runnable titles it would draw from — the queue order as it
    /// stands, not a promise. Empty means arming starts nothing until a
    /// project opts in, which the surface says rather than hides.
    struct ArmingPreview: Sendable, Equatable {
        struct Project: Sendable, Equatable, Identifiable {
            let name: String
            let nextItems: [String]
            /// Every `ready` item in the project, not only the ones named.
            let readyCount: Int
            /// How many of those could start right now — `QueueHealth.startable`.
            /// Nil when the queue was never measured, never a guessed 0.
            let startable: Int?
            var id: String { name }
        }
        let projects: [Project]

        /// One opted-in project as the confirm surface shows it.
        static func project(_ project: PortfolioSnapshot.Project, itemLimit: Int) -> Project {
            Project(name: project.name,
                    nextItems: project.readyItems.items.prefix(itemLimit).map(\.title),
                    readyCount: project.count(.ready),
                    startable: project.startable)
        }
    }

    func armingPreview(itemLimit: Int = 3) -> ArmingPreview {
        guard let registry, let globalConfigStore else { return ArmingPreview(projects: []) }
        let portfolio = PortfolioSnapshot.capture(registry: registry,
                                                 portfolioGoal: globalConfigStore.portfolioGoal)
        let projects = portfolio.selectableProjects
            .filter { $0.autopilotReady && $0.autonomousWorkEnabled }
            .map { ArmingPreview.project($0, itemLimit: itemLimit) }
        return ArmingPreview(projects: projects)
    }

    /// Each open project's **own** daily ceiling against its own share of today,
    /// keyed by project path for `RunScheduling.decide`. A project without a
    /// ceiling of its own is simply absent — the portfolio's is what governs it,
    /// and an entry with a nil budget would say the same thing more slowly.
    var projectDailyBudgets: [String: DailyBudget] {
        guard let registry else { return [:] }
        var budgets: [String: DailyBudget] = [:]
        for entry in registry.openProjects {
            guard let budgetUSD = entry.autopilot.dailyBudgetUSD else { continue }
            let root = entry.session.project.rootURL
            let path = root.path(percentEncoded: false)
            budgets[path] = DailyBudget(budgetUSD: budgetUSD,
                                        spentUSD: spendLedger?.spentTodayUSD(inProject: path) ?? 0,
                                        scope: .project(root.lastPathComponent))
        }
        return budgets
    }

    private weak var registry: ControlSessionRegistry?
    private weak var globalConfigStore: GlobalConfigStore?
    private weak var spendLedger: DailySpendLedger?
    /// The control API's server, so a run this loop starts leaves the same record
    /// a run started over HTTP does. Weak for the reason
    /// `ControlSessionRegistry.queueRefill` is: the server already holds this
    /// scheduler, and a strong reference back would be a cycle.
    ///
    /// Unwired, nothing here changes — no record is opened, and `startHistory`
    /// plus the JSONL are the whole account of the night, exactly as before.
    private weak var controlServer: KiteloopControlServer?

    /// When each project was last seen with nothing running — the tiebreak, kept
    /// by `QueueRefill.trackIdle` exactly as the refill loop keeps it.
    private var idleSince: [String: Date] = [:]
    private let logURL: URL
    private var timer: Task<Void, Never>?
    private var isStarted = false
    private var isLoadingConfig = false

    /// `now` is for tests only, so the age bound can be exercised without waiting
    /// a month — the same reason `RunRecordStore.init(url:now:)` takes one.
    init(logURL: URL = CoordinatorRunScheduler.defaultLogURL(), now: Date = Date()) {
        self.logURL = logURL
        let loaded = Self.loadHistory(from: logURL, now: now)
        startHistory = Array(loaded.records.suffix(Self.maxStartHistory))
        undecodableLines = loaded.undecodable
        undecodableLineCount = loaded.undecodable.count
        if !startHistory.isEmpty {
            schedulerLog.info("Read back \(self.startHistory.count, privacy: .public) autonomous start(s) from the log")
        }
        if undecodableLineCount > 0 {
            schedulerLog.error("\(self.undecodableLineCount, privacy: .public) line(s) in the autonomous start log could not be decoded — keeping them verbatim")
        }
        // Only when the load actually dropped or collapsed something: a log
        // already inside both bounds is left exactly as it was found.
        if loaded.needsRewrite { Self.rewrite(loaded.records, undecodable: undecodableLines, to: logURL) }
    }

    /// The durable record of what ran unattended, beside the coordinator's other
    /// logs.
    static func defaultLogURL(home: URL = KiteloopHome.url) -> URL {
        home.appending(path: ".kiteloop").appending(path: "coordinator-starts.jsonl")
    }

    /// Wire the portfolio it watches and the day's spend it is bounded by —
    /// then take the switch from what was saved. Unwired, every tick holds;
    /// nothing here fails open.
    func configure(registry: ControlSessionRegistry,
                   globalConfigStore: GlobalConfigStore,
                   spendLedger: DailySpendLedger? = nil) {
        self.registry = registry
        self.globalConfigStore = globalConfigStore
        self.spendLedger = spendLedger
        isLoadingConfig = true
        enabled = globalConfigStore.coordinatorSchedulingEnabled
        maxConcurrentRuns = globalConfigStore.maxConcurrentRuns
        isLoadingConfig = false
    }

    /// Wire the control server an autonomous run should leave its record in.
    /// Separate from `configure` because that server is built *around* this
    /// scheduler and so cannot be handed to it before it exists.
    func attach(controlServer: KiteloopControlServer) {
        self.controlServer = controlServer
    }

    // MARK: - Triggers

    /// Start the periodic check. Idempotent, and a no-op while the switch is
    /// off.
    func start() {
        isStarted = true
        syncTimer()
    }

    func stop() {
        isStarted = false
        syncTimer()
    }

    /// A run just finished — the moment a project is most likely to be free with
    /// runnable work still waiting. `BacklogAutopilot.onRunFinished` announces
    /// it, and this is the loop taking it up rather than waiting out the clock.
    ///
    /// The timer stays, and stays the backstop for everything a finished run
    /// does not announce: a gate clearing, the budget rolling at local midnight,
    /// an item edited into `ready`, a project's consent switched on. This makes
    /// the clock the slower of two paths rather than the only one — a run that
    /// ended with two items runnable used to leave the fleet idle for up to
    /// `checkInterval`, measured on 2026-08-21 as a full five minutes.
    ///
    /// An occasion to look, and nothing more. The tick it raises is the tick the
    /// timer would have taken — the switch, the holds, the budget, one run at a
    /// time, all of them read by the tick itself. In particular this fires from
    /// *inside* the run a tick may still be awaiting, since the autopilot
    /// announces the finish before `start` returns; such a look meets the
    /// in-flight guard and starts nothing.
    ///
    /// Returns the tick's task, so a caller that needs to know the look happened
    /// can await it. The app's own call discards it: the whole point is not
    /// making the finishing run wait for it.
    @discardableResult
    func runFinished() -> Task<Void, Never> {
        Task { [weak self] in await self?.runTick() }
    }

    /// Clear every hold — the human half of "stop on repeated failure", and the
    /// override a same-cause hold is otherwise waiting on.
    ///
    /// Still spelled `resetBreaker` because that is the name on the wire
    /// (`PUT /v1/coordinator/scheduling`) and on the sidebar control that now
    /// calls it; renaming the lever would break every driver holding it.
    func resetBreaker() {
        holds.clear()
        gateRefusals.clear()
    }

    private func syncTimer() {
        guard isStarted, enabled else {
            timer?.cancel()
            timer = nil
            return
        }
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.checkInterval else { return }
                // Look first, sleep after. The sleep used to come first, so a
                // freshly armed scheduler sat a whole interval before its first
                // look — the state the `lastDecision` comment calls out as
                // reading "exactly like a broken one".
                guard !Task.isCancelled else { return }
                let looked = await self?.tick()
                guard !Task.isCancelled else { return }
                // A tick that started a run has already waited out that run —
                // the tick awaits it — so the queue it is looking at is fresh
                // and may hold more. Sleeping here would spend `interval` doing
                // nothing after every completed item. Only a tick that found
                // nothing to start waits for the clock, which is the one case
                // where the clock is what changes the answer.
                //
                // `taken` is what keeps that from spinning: a tick refused
                // because another was already in flight looked at nothing, and
                // its answer is the other tick's. Read as this one's, a `.start`
                // there would skip the sleep and go straight round again, for as
                // long as the run the other tick is awaiting takes.
                if let looked, looked.taken, case .start = looked.decision { continue }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    // MARK: - The tick

    /// One look: snapshot the portfolio, decide, and start a run if everything
    /// allows it. Returns what it decided — the in-flight tick's answer when
    /// this call collided with one, which is what a caller asking "what is it
    /// doing" wants either way.
    @discardableResult
    func runTick(now: Date = Date()) async -> RunScheduling.Decision {
        await tick(now: now).decision
    }

    /// The same look, with whether this caller was the one that took it.
    ///
    /// A tick never overlaps another — the one in flight refuses this call — but
    /// a run being awaited is not a look, and `maxConcurrentRuns` of those may be
    /// in flight at once. At the default of one the tick awaits the whole run it
    /// started, so the portfolio does hold a single autonomous run at a time;
    /// above one the run is handed to a task of its own (`startBeside`) and this
    /// tick returns, so a look may proceed beside it up to the ceiling. A look
    /// refused costs nothing: the tick it collided with is looking at the same
    /// portfolio, and the loop takes another as soon as a run frees its slot.
    ///
    /// `taken` is for the timer, which reads a `.start` as a reason not to
    /// sleep. Only the caller that actually looked may be read that way — see
    /// the loop.
    ///
    /// Internal rather than `private` only so `CoordinatorRunSchedulerTests`
    /// can assert `taken` directly — `runTick` discards it, and that flag is
    /// exactly what the timer's loop reads to decide whether to skip its
    /// sleep, so it has to be reachable on its own.
    func tick(now: Date = Date()) async -> (decision: RunScheduling.Decision, taken: Bool) {
        // A look is exclusive — two snapshots at once could hand one project
        // two runs — but a run being awaited is not: up to `maxConcurrentRuns`
        // of them may be in flight, and a look may proceed beside them.
        guard !isTicking, startsInFlight.count < maxConcurrentRuns else {
            return (lastDecision ?? .hold(.disabled), false)
        }
        isTicking = true
        defer { isTicking = false }
        return (await look(now: now), true)
    }

    /// The look itself, once this caller holds the tick.
    private func look(now: Date) async -> RunScheduling.Decision {
        // Recorded even for a tick that holds: the question the footer answers is
        // "when will it look again", and a look that decided to do nothing is
        // still a look.
        lastTickAt = now
        guard enabled else { return note(.hold(.disabled), at: now) }
        guard let registry, let globalConfigStore else { return note(.hold(.unwired), at: now) }

        let portfolio = PortfolioSnapshot.capture(registry: registry,
                                                  portfolioGoal: globalConfigStore.portfolioGoal)
        idleSince = QueueRefill.trackIdle(idleSince, portfolio: portfolio, now: now)
        refreshHolds(portfolio: portfolio)
        gateRefusals.retain(paths: Set(portfolio.projects.map(\.path)))

        let decision = RunScheduling.decide(portfolio: portfolio, enabled: enabled,
                                            budget: dailyBudget, holds: holds,
                                            refusedItems: standingRefusals(portfolio: portfolio),
                                            idleSince: idleSince,
                                            projectBudgets: projectDailyBudgets,
                                            queueRefillPolicy: registry.queueRefill?.policy ?? .default,
                                            startingPaths: startsInFlight,
                                            now: now)
        switch decision {
        case .hold:
            return note(decision, at: now)
        case .start(let target):
            note(decision, at: now)
            // The slot is reserved before the look lock is released, so the
            // next look — timer or a finished run's — sees this project as
            // taken and may start another project beside it.
            startsInFlight.insert(target.path)
            isTicking = false
            if maxConcurrentRuns > 1 {
                // Several at once: the run is awaited by a task of its own, so
                // this look — and the timer behind it — comes straight back to
                // look again and start another project beside it. The slot is
                // released when that run returns, and releasing it is itself an
                // occasion to look — see `startBeside`.
                startBeside(target, registry: registry, now: now)
                return lastDecision ?? decision
            }
            // One at a time: the tick awaits the run, as it always did, so a
            // caller reading this tick's answer reads the run's end too.
            defer { startsInFlight.remove(target.path) }
            await performStart(target, registry: registry, now: now)
            // The decision this tick *ended* on, not the one it set out with.
            // `performStart` bails on its own guards — no registry entry, the
            // autopilot not idle, the switch re-read late — and notes a hold when
            // it does. Returning `.start` regardless is what let the loop read
            // "a run happened" from a tick where none did, and skip its sleep for
            // as long as that stayed true: the app spun at 99% CPU for fifteen
            // minutes on 2026-08-21 with the fleet quiesced. `taken` does not
            // cover this — that guards a tick refused for colliding with
            // another, which is a different way to look at nothing.
            return lastDecision ?? decision
        }
    }

    /// Run one start in a task of its own, and look again when its slot frees.
    ///
    /// The slot is what occasions that look. With every slot taken the timer's
    /// loop has gone to sleep — its tick was refused for want of capacity — so
    /// until this run returns nothing is going to look, and a fleet draining a
    /// slot would idle out `checkInterval` with runnable work waiting. The
    /// serial path has no such hole: there the tick awaits the run, so the
    /// loop reaches its `continue` the moment the run ends.
    /// `BacklogAutopilot.onRunFinished` does not close it either — that fires
    /// from *inside* `performStart`, while this run still holds its slot, and
    /// meets the in-flight guard.
    ///
    /// An occasion to look and nothing more, exactly as `runFinished()` is:
    /// the switch, the holds, the budget, the quiesce and `RunScheduling.decide`
    /// are all read by the tick itself and none of them is restated here. One
    /// look, never a loop — a look that finds nothing simply holds, and the
    /// timer stays the backstop for whatever changes later.
    ///
    /// Unstructured on purpose, and not the timer's child: cancelling the timer
    /// must not reach into a live run. The finishing run does not wait on the
    /// look it occasions — `performStart` has already returned by then.
    private func startBeside(_ target: RunScheduling.Target,
                             registry: ControlSessionRegistry,
                             now: Date) {
        Task { @MainActor [weak self] in
            await self?.performStart(target, registry: registry, now: now)
            self?.startsInFlight.remove(target.path)
            await self?.runTick()
        }
    }

    /// Commit to the start, run it, and record what it came to.
    private func performStart(_ target: RunScheduling.Target,
                              registry: ControlSessionRegistry,
                              now: Date) async {
        guard let entry = registry.entry(forProject: target.project) else {
            note(.hold(.noEligibleProject), at: now)
            return
        }
        let autopilot = entry.autopilot
        // The snapshot was taken a few statements ago; the authority on whether
        // this project is free is the autopilot itself.
        guard autopilot.status == .idle else {
            note(.hold(.allBusy), at: now)
            return
        }
        // The switch, read as late as it can be. Turning scheduling off while a
        // tick was mid-flight must stop this run, not merely the next one.
        guard enabled else {
            note(.hold(.disabled), at: now)
            return
        }
        // The fleet hold, read just as late and for the same reason. A quiesce
        // taken while this tick was in flight has to stop this run: the operator is
        // draining for a restart, and a run started now is the item that gets
        // stranded. A paused project is already skipped by the idle guard above —
        // this covers the idle ones, which is every project once the fleet drains.
        if controlServer?.fleet.isQuiesced == true {
            note(.hold(.quiesced), at: now)
            return
        }

        let budgetText = dailyBudget.text
        var record = StartRecord(at: now, project: target.project, itemID: target.itemID,
                                 itemTitle: target.itemTitle, why: target.reason,
                                 budgetText: budgetText, outcome: StartRecord.running,
                                 finishedAt: nil)
        remember(record)
        append(record, event: "start")
        publish(entry: entry, payload: [
            "kind": "autonomous-start",
            "project": target.project,
            "item": target.itemID,
            "title": target.itemTitle,
            "why": target.reason,
            "budget": budgetText
        ])
        schedulerLog.info("Autonomous start \(record.summary, privacy: .public)")
        // The run's durable record, opened on the same terms a control-API run's
        // is. `GET /v1/runs` and `/v1/runs/{id}/result` are where a night is read
        // back from, and until now they had nothing to say about a run nobody
        // asked for over HTTP.
        let runID = controlServer?.openRun(projectID: entry.session.project.id,
                                          itemID: target.itemID,
                                          title: target.itemTitle,
                                          startedAt: now)

        autopilot.selectedItemIDs = [target.itemID]
        // What the autopilot carried before the start, because the execution id is
        // never cleared: an id that hasn't changed belongs to an earlier run, and
        // charging this record with it would report another attempt's spend.
        let priorExecution = autopilot.currentExecutionID
        // Unstructured on purpose: the timer task can be cancelled by the kill
        // switch at any moment, and cancellation reaching into a live run would
        // abandon the item mid-flight. This task is not the timer's child, so
        // the switch stops the *next* run rather than corrupting this one.
        await Task { @MainActor in await autopilot.start(initiator: .autonomous) }.value
        let execution = autopilot.currentExecutionID == priorExecution
            ? nil : autopilot.currentExecutionID

        let outcome = Self.outcome(itemID: target.itemID, results: autopilot.results,
                                   lastStartOutcome: autopilot.lastStartOutcome)
        fold(outcome, of: target)
        // A gate refusal about the item itself — never a busy slot or a spent
        // cap, which carry no detail here — is remembered against the item as
        // it read just now, so the next tick skips it without asking
        // `DefinitionOfReady` or `GroundingCheck` the same question again.
        if outcome.name == StartRecord.didNotRun, let reason = outcome.detail {
            let backlog = entry.session.backlogViewModel
            if let item = backlog.backlogFile?.sections.flatMap(\.items).first(where: { $0.id == target.itemID }) {
                let fingerprint = RunScheduling.itemFingerprint(item: item, detail: backlog.loadDetail(for: item))
                gateRefusals.record(itemID: target.itemID, path: target.path,
                                    fingerprint: fingerprint, reason: reason)
            }
        }
        record.outcome = outcome.name
        record.finishedAt = Date()
        complete(record)
        append(record, event: "finish")
        // Closed now rather than whenever the next HTTP request happens to arrive:
        // an unattended night may see none, and a record left open reads
        // `interrupted` at the next launch for a run that ended perfectly well.
        if let runID {
            await controlServer?.closeRun(runID, execution: execution,
                                          didNotRunReason: outcome.name == StartRecord.didNotRun
                                              ? (outcome.detail ?? "run ended without a recorded result") : nil)
        }

        var payload: [String: String] = [
            "kind": "autonomous-finish",
            "project": target.project,
            "item": target.itemID,
            "outcome": outcome.name,
            "failures": String(holds.recorded(atPath: target.path)?.failures.count ?? 0)
        ]
        if let detail = outcome.detail { payload["detail"] = detail }
        publish(entry: entry, payload: payload)

        // Loud where it happened. A hold is scoped to one project now, so it is
        // said in that project's console rather than announced to the fleet —
        // and `/health` carries the same reason for whoever is not looking at a
        // window at 3am.
        if let hold = holds.hold(atPath: target.path) {
            schedulerLog.error("\(hold.reason, privacy: .public)")
            publish(entry: entry, payload: [
                "kind": "autonomous-stopped",
                "project": target.project,
                "reason": hold.reason
            ])
        }
    }

    /// Fold one finished run into that project's hold — the whole of "stop on
    /// repeated failure" as it applies to a single run.
    ///
    /// Three things decide what happens here, and each is a correction of what
    /// the fleet-global counter did:
    ///
    /// * **A gate refusal is not folded at all.** `did-not-run` means the item
    ///   was never picked up — grounding, status, an unmet `needs:`, a busy slot
    ///   — so it spent nothing and says nothing about whether runs here fail.
    ///   The counter this replaces tripped on three such $0 refusals on
    ///   2026-08-13 and stopped every project in the fleet.
    /// * **A failure is evidence about one queue**, so it is recorded with that
    ///   queue as it stands right now, and against that project alone.
    /// * **A run that got somewhere ends the matter** for its project, and only
    ///   for its project.
    func fold(_ outcome: Outcome, of target: RunScheduling.Target) {
        guard outcome.name != StartRecord.didNotRun else { return }
        guard !outcome.succeeded else {
            holds.clear(path: target.path)
            return
        }
        let entry = registry?.entry(forProject: target.project)
        holds.record(
            RunScheduling.ProjectHold.Failure(
                itemID: target.itemID,
                // The item's name is deliberately *not* in here: two different
                // items failing the same way is the systemic case, and it is
                // detected by comparing these strings.
                text: outcome.phrase,
                evidence: entry.map { Self.queueEvidence(of: $0) } ?? RunScheduling.QueueEvidence(),
                environment: Self.environment(of: entry, global: globalConfigStore)),
            project: target.project, path: target.path)
    }

    // MARK: - Evidence

    /// Re-read the queue behind every hold and drop whatever it no longer
    /// supports.
    ///
    /// This is the whole of "a hold expires when its evidence goes stale".
    /// There is no timer and no clock: the reading is taken when the loop was
    /// going to look anyway, and only for a project that actually has something
    /// recorded against it — a portfolio with no holds costs nothing here.
    private func refreshHolds(portfolio: PortfolioSnapshot) {
        // A project that has been closed is not being started from either way.
        holds.retain(paths: Set(portfolio.projects.map(\.path)))
        for project in portfolio.projects {
            guard holds.recorded(atPath: project.path) != nil,
                  let entry = registry?.entry(forProject: project.name) else { continue }
            holds.expire(path: project.path,
                         against: Self.queueEvidence(of: entry),
                         environment: Self.environment(of: entry, global: globalConfigStore))
        }
    }

    /// Every currently-ready item whose gate refusal still stands, as
    /// `RunScheduling.decide` needs it — a set of `refusalKey`s to skip
    /// without asking the gate again.
    ///
    /// Only a fingerprint compare, never the gate itself: `DefinitionOfReady`
    /// and `GroundingCheck` are not re-run here, which is the whole point —
    /// the overnight loop this replaced spent a full grounding pass, walking
    /// the repository, re-deriving the same "no" every five minutes.
    private func standingRefusals(portfolio: PortfolioSnapshot) -> Set<String> {
        guard let registry else { return [] }
        var keys: Set<String> = []
        for project in portfolio.projects {
            guard let entry = registry.entry(forProject: project.name) else { continue }
            let backlog = entry.session.backlogViewModel
            let items = backlog.backlogFile?.sections.flatMap(\.items) ?? []
            for sample in project.readyItems.items {
                guard let item = items.first(where: { $0.id == sample.id }) else { continue }
                let fingerprint = RunScheduling.itemFingerprint(item: item, detail: backlog.loadDetail(for: item))
                guard gateRefusals.stands(itemID: item.id, path: project.path, fingerprint: fingerprint) else {
                    continue
                }
                keys.insert(RunScheduling.refusalKey(path: project.path, itemID: item.id))
            }
        }
        return keys
    }

    /// One project's queue as a hold reads it — every `ready` item, what it asks
    /// for, and whether autopilot would take it.
    ///
    /// Read from the backlog itself rather than from the portfolio snapshot: the
    /// snapshot's ready list is a capped *sample*, and a hold judged on a sample
    /// would expire, or fail to, on which items happened to fit in it.
    private static func queueEvidence(of entry: ControlSessionRegistry.Entry)
        -> RunScheduling.QueueEvidence {
        let backlog = entry.session.backlogViewModel
        let autopilot = entry.autopilot
        return RunScheduling.evidence(
            items: backlog.backlogFile?.sections.flatMap(\.items) ?? [],
            detail: { backlog.loadDetail(for: $0) },
            isRetired: { autopilot.retryCeilingVerdict(item: $0, detail: $1).isRetired })
    }

    /// Everything one project's runs depended on that is **not** its queue.
    ///
    /// This is what a same-cause hold is measured against. Two different items
    /// failing identically is not a statement about either item, so no backlog
    /// edit clears it; what clears it is the pair and the caps those runs used
    /// (the project's autopilot config), the backend their agents resolve
    /// through (the global config), a human clearing it by hand — and an app
    /// relaunch, which is free, because holds live in memory and nowhere else.
    ///
    /// A project the registry can't produce contributes a distinct value rather
    /// than an empty one, so an unreadable project never compares equal to a
    /// readable one and a hold can't outlive a session that has gone.
    private static func environment(of entry: ControlSessionRegistry.Entry?,
                                    global: GlobalConfigStore?) -> String {
        guard let entry else { return "unwired" }
        return "\(entry.autopilot.configFingerprint)\u{1}\(global?.configFingerprint ?? "-")"
    }

    /// What the autopilot's results say about the item this loop started.
    ///
    /// No result at all is a failure, and an important one: it is what a start
    /// refused downstream looks like — the pickup gates rejected the item, or
    /// there was no agent session — and a night of those is exactly what the
    /// breaker exists to stop.
    ///
    /// - Parameter lastStartOutcome: the gate's own verdict on this attempt.
    ///   Asked first, and where it carries a refusal the results are not
    ///   consulted at all: `recordStartOutcome` runs on every path out of
    ///   `start`, so a refusal here describes the start that just returned,
    ///   while `results` can still hold an earlier attempt's `ItemResult` for
    ///   this same item — a refused start returns before `resetRunState`
    ///   clears the list. Reading that one as this start's counted an old
    ///   failure a second time toward the breaker, or reset the streak with an
    ///   old success. Only a `.noRunnableItems` refusal is a statement about
    ///   *this item* — a busy slot or a spent session cap is a condition of the
    ///   moment, and carries no detail here on purpose, so nothing downstream
    ///   mistakes it for a per-item verdict worth remembering.
    nonisolated static func outcome(itemID: String,
                                    results: [BacklogAutopilot.ItemResult],
                                    lastStartOutcome: BacklogAutopilot.StartOutcome? = nil) -> Outcome {
        guard lastStartOutcome?.refusal == nil,
              let result = results.first(where: { $0.id == itemID }) else {
            let detail = lastStartOutcome?.refusal == .noRunnableItems ? lastStartOutcome?.detail : nil
            return Outcome(name: StartRecord.didNotRun, detail: detail, succeeded: false)
        }
        var detail: String?
        if case .blocked(let reason) = result.outcome { detail = reason }
        let succeeded: Bool
        switch result.outcome {
        // A run that changed nothing and said, with evidence, that the item was
        // already built succeeded at what it was asked to do — it read the code
        // and answered — and the item is parked for a human. The breaker counts
        // failures so a night of them stops the loop, and this is not one: an
        // agent following CLAUDE.md's own instruction must not trip it.
        // An investigation likewise did what was asked: it checked the premise
        // and answered. A refuted premise is a finding, not a failed run.
        case .done, .awaitingApproval, .alreadyImplemented, .investigation: succeeded = true
        case .blocked, .cancelled: succeeded = false
        }
        return Outcome(name: PortfolioSnapshot.outcomeName(result.outcome),
                       detail: detail, succeeded: succeeded)
    }

    // MARK: - Recording

    /// Remember the decision, log it, and say so where it happened.
    ///
    /// A hold is information: "off", "budget spent", "everything is busy" and
    /// "the breaker tripped" are four different reasons for a quiet night, and a
    /// loop that reported them all as silence would be untrustworthy. `.disabled`
    /// is the exception — the timer is torn down when the switch is off, so it
    /// only arises from a caller asking, and recording it would say nothing the
    /// switch doesn't already.
    @discardableResult
    private func note(_ decision: RunScheduling.Decision, at now: Date) -> RunScheduling.Decision {
        lastDecision = decision
        guard decision.hold != .disabled else { return decision }
        schedulerLog.info("Run scheduling: \(decision.summary, privacy: .public)")
        var payload: [String: String] = [
            "kind": "autonomous-scheduling",
            "decision": decision.kind,
            "detail": decision.summary
        ]
        publish(project: decision.target?.project, payload: payload)
        return decision
    }

    private func remember(_ record: StartRecord) {
        startHistory.append(record)
        if startHistory.count > Self.maxStartHistory {
            startHistory.removeFirst(startHistory.count - Self.maxStartHistory)
        }
    }

    /// Fill in the outcome on the record this run opened, leaving it where it is
    /// in the history rather than appending a second row for the same run.
    private func complete(_ record: StartRecord) {
        guard let index = startHistory.firstIndex(where: { $0.id == record.id }) else {
            remember(record)
            return
        }
        startHistory[index] = record
    }

    private struct LogLine: Codable {
        let at: Date
        /// `start` or `finish`.
        let event: String
        let project: String
        let item: String
        let title: String
        let why: String
        let budget: String
        let outcome: String
    }

    /// Append one line of the durable record. Best-effort: a night's work must
    /// not fail because a log couldn't be written.
    private func append(_ record: StartRecord, event: String) {
        guard let text = Self.encode(record, event: event) else { return }

        // Through `AtomicFileWriter.append`, which makes the directory when it is
        // missing and starts a new line first when the log doesn't end in one. A
        // plain seek-to-end writes this line onto the remnant of one a kill cut
        // short, and the pair decodes as neither — so a run's start or its finish
        // goes missing from the only account of what ran unattended, and a start
        // whose finish was lost reads as `interrupted` for a run that ended fine.
        try? AtomicFileWriter.append(Data(text.utf8), to: logURL)
    }

    /// One line of the log, newline included — the single place its shape is
    /// decided, so a line written at launch by `rewrite` is the line `append`
    /// would have written for the same record.
    ///
    /// A `start` carries the moment the run began and the outcome a start has,
    /// which is `running`; the outcome a run reached belongs on its `finish`.
    private static func encode(_ record: StartRecord, event: String) -> String? {
        let isFinish = event == "finish"
        let line = LogLine(at: isFinish ? (record.finishedAt ?? record.at) : record.at,
                           event: event,
                           project: record.project, item: record.itemID,
                           title: record.itemTitle, why: record.why,
                           budget: record.budgetText,
                           outcome: isFinish ? record.outcome : StartRecord.running)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(line),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text + "\n"
    }

    /// Write the kept history back over the log — what bounds the file rather
    /// than only what is read from it. Returns whether the write landed.
    ///
    /// A record with a finish is two lines again, as it was written. A record
    /// **without** one is written back as a start alone: that is what makes it
    /// load as `interrupted` next time, and adding a finish to it would be a
    /// claim about a run nobody watched end.
    ///
    /// The lines nobody could decode go back at the end, verbatim — the same
    /// choice `RunRecordStore.rewrite` makes for `control-runs.jsonl`, and for
    /// the same reason. Compaction is what would otherwise erase them, on the
    /// very launch that failed to read them, and this is the one file that says
    /// what ran unattended: an unreadable line is still somebody's history, and
    /// deleting it is the one thing that can't be undone.
    ///
    /// Through `AtomicFileWriter.write` rather than `Data.write(options:
    /// .atomic)`, which renames a temp file into place without ever flushing
    /// it: on a panic the rename can reach disk while the contents are still in
    /// the page cache, and what survives is a zero-length start log — the same
    /// risk `RunRecordStore.rewrite` guards against for `control-runs.jsonl`.
    @discardableResult
    static func rewrite(_ records: [StartRecord],
                        undecodable: [String],
                        to url: URL) -> Bool {
        var body = ""
        for record in records {
            guard let start = encode(record, event: "start") else { continue }
            body += start
            guard record.finishedAt != nil, let finish = encode(record, event: "finish") else { continue }
            body += finish
        }
        body += undecodable.map { $0 + "\n" }.joined()
        do {
            try AtomicFileWriter.write(Data(body.utf8), to: url)
            schedulerLog.info("Compacted the autonomous start log to \(records.count, privacy: .public) run(s)")
            return true
        } catch {
            schedulerLog.error("Failed to compact the autonomous start log at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Fold the durable log back into the history the app serves, so what ran
    /// unattended outlives the app that ran it. Without this the log was written
    /// faithfully and never read, and after any restart the coordinator's own
    /// account of the night was empty — which reads as "nothing ran".
    ///
    /// A run is two lines: the `start` carries the `at` its record is identified
    /// by, and the `finish` carries `finishedAt` in the same field. They are
    /// paired by project and item in file order — a finish closes the most recent
    /// still-open start for that pair — because the log has no run id to pair on.
    /// A start with no finish belonged to a process that is gone, and loads as
    /// `interrupted`. A line that doesn't decode costs neither the runs around it
    /// nor itself: it is set aside, counted, and handed back so `init` can write
    /// it out again.
    ///
    /// Split on the newline byte rather than read as one string of the whole
    /// file, which is all-or-nothing: one cut-off character loaded no history and
    /// no refused lines, so the next rewrite erased every start on disk. A line
    /// that is not UTF-8 is held lossily, the way `NotificationStore` holds one.
    ///
    /// Both retention bounds are applied here, and `needsRewrite` reports whether
    /// anything was dropped or collapsed — a run older than `retentionAge`, a run
    /// beyond the newest `retentionLimit`, a finish with no start, an event that
    /// is neither. When it was, `init` writes the kept records back over the
    /// file, so the trim is real rather than only in memory. Whether there were
    /// refused lines says nothing about that: they are already in the file, and a
    /// rewrite only puts them back.
    private static func loadHistory(from url: URL, now: Date)
        -> (records: [StartRecord], undecodable: [String], needsRewrite: Bool) {
        guard let content = try? Data(contentsOf: url) else { return ([], [], false) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var records: [StartRecord] = []
        var undecodable: [String] = []
        var lines = 0
        /// Positions of the still-unclosed starts for each project+item, oldest
        /// first, so a finish takes the newest of them.
        var open: [String: [Int]] = [:]
        for line in content.split(separator: UInt8(ascii: "\n")) {
            guard String(data: line, encoding: .utf8) != nil,
                  let entry = try? decoder.decode(LogLine.self, from: line) else {
                undecodable.append(String(decoding: line, as: UTF8.self))
                continue
            }
            lines += 1
            let key = "\(entry.project)\u{0}\(entry.item)"
            switch entry.event {
            case "start":
                records.append(StartRecord(at: entry.at, project: entry.project, itemID: entry.item,
                                           itemTitle: entry.title, why: entry.why,
                                           budgetText: entry.budget,
                                           outcome: StartRecord.interrupted, finishedAt: nil))
                open[key, default: []].append(records.count - 1)
            case "finish":
                // A finish whose start isn't in the log — trimmed, or never
                // written — has no record to complete and is dropped rather than
                // invented into one without an `at`.
                guard let position = open[key]?.popLast() else { continue }
                records[position].outcome = entry.outcome
                records[position].finishedAt = entry.at
            default:
                continue
            }
        }

        // A run is dated by its start: an old run that finished yesterday is
        // still an old run, and the pairing above is what the age applies to.
        let cutoff = now.addingTimeInterval(-retentionAge)
        let kept = Array(records.filter { $0.at >= cutoff }.suffix(retentionLimit))
        // What the kept records would occupy: two lines for a finished run, one
        // for an interrupted one. Anything else among the lines that *did* decode
        // is history that was dropped, or a line that decoded into nothing.
        let occupies = kept.reduce(0) { $0 + ($1.finishedAt == nil ? 1 : 2) }
        return (kept, undecodable, occupies != lines)
    }

    private func publish(entry: ControlSessionRegistry.Entry, payload: [String: String]) {
        entry.session.orchestrator.publishEvent(
            KiteloopEvent(source: "Coordinator", type: .custom, payload: payload))
    }

    private func publish(project: String?, payload: [String: String]) {
        guard let orchestrator = project.flatMap({ registry?.entry(forProject: $0)?.session.orchestrator })
            ?? registry?.openProjects.first?.session.orchestrator else { return }
        orchestrator.publishEvent(KiteloopEvent(source: "Coordinator", type: .custom, payload: payload))
    }
}

extension CoordinatorRunScheduler {
    /// Pretend these projects' runs are being awaited — what a tick sees while
    /// another tick is inside a run.
    func stageStartsInFlightForTesting(_ paths: Set<String>) { startsInFlight = paths }
}
