import Foundation
import KiteloopCore
import os.log

private let refillLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "queue-refill")

/// The loop that keeps the machine fed: when a project's runnable queue runs dry,
/// draft more work for the project that most deserves it — and stop once it's
/// full again.
///
/// This is the observe-and-write half of the refill loop. `QueueRefill` decides
/// *whether* and *where*; this decides nothing on its own. It watches the
/// portfolio, asks `QueueRefill.decide`, has the coordinator draft candidates by
/// reading the repo those candidates concern, puts each one through the same two
/// gates a human-groomed item faces — `DefinitionOfReady` and `GroundingCheck` —
/// and files what survives.
///
/// Three properties are load-bearing and each is enforced somewhere it cannot be
/// reasoned around:
///
/// * **A paused project is never chosen.** Not by this class: by
///   `PortfolioSnapshot.selectableProjects`, which drops paused projects before a
///   choice exists.
/// * **An exhausted budget stops the pass**, before a model is called. Not a
///   smaller pass, not a cheaper draft — no pass, and a recorded refusal.
/// * **A gap is filled once.** `QueueRefill.Ledger` persists what was filed for
///   which project, so an item a human rejected is not re-invented next pass.
///
/// The switch is the whole choice: on files, within the gates and the shared
/// daily ceiling; off doesn't. The trust boundary is the machinery that runs on
/// every pass — `DefinitionOfReady` and `GroundingCheck` judge each draft, and
/// filed work is inert until a fleet with consent and budget picks it up.
@MainActor
@Observable
final class CoordinatorQueueRefill {

    /// One gate's refusal, as the ledger records it: which check said no, and
    /// what its verdict said.
    ///
    /// Kept beside `notes` rather than parsed back out of them. The notes are
    /// prose for whoever opens the item's file; this is the pair
    /// `GroomingLedger.recordCheckFailure` needs, so the report can attribute a
    /// parked draft to `definition-of-ready` or `grounding-check` instead of
    /// only counting it.
    struct Refusal: Sendable, Equatable, Codable {
        /// A `GroomingRecord.Check` constant — the file's contract, which the
        /// report groups on.
        let check: String
        /// The verdict's own summary, verbatim.
        let reason: String
    }

    /// A drafted item and the verdicts it earned, before anything is written —
    /// the shape a pass files from.
    ///
    /// The name survives the advisory-mode retirement (it used to also be what
    /// waited in the review inbox); today it is the gated draft on its way to
    /// the backlog, gate notes and all.
    struct Proposal: Sendable, Equatable, Identifiable, Codable {
        let project: String
        let draft: QueueRefill.Draft
        /// `ready` when both gates passed, `draft` when either didn't.
        let status: BacklogItemStatus
        /// What the gates said. Empty on a clean item.
        let notes: [String]
        /// The same refusals, in the shape the grooming ledger records. Empty
        /// exactly when `notes` is.
        let refusals: [Refusal]

        var id: String { "\(project)/\(draft.id)" }
        var passedGates: Bool { status == .ready }
    }

    /// A pass that has started and not yet ended: which project it chose, when
    /// it began, and where it had got to.
    ///
    /// The stage is the diagnostic half, and it is not decoration. Clearing a
    /// wedged flag on a timer and calling it fixed leaves the next wedge exactly
    /// as mysterious as the first: on 2026-08-12 a pass sat in flight for 2h22m,
    /// stopping grooming for the whole fleet, and nothing anywhere said which
    /// call it was in.
    struct InFlightPass: Sendable, Equatable, Identifiable {
        /// How far a pass got, in the order a pass goes through them.
        enum Stage: String, Sendable, Codable {
            /// Reading the blocked pile, before any drafting.
            case triaging
            /// In the drafter's model call — the one that hung.
            case drafting
            /// Running Definition-of-Ready and the grounding check.
            case gating
            /// Writing what survived.
            case filing

            /// The stage as the tail of a sentence: "…, still waiting on the
            /// drafter".
            var phrase: String {
                switch self {
                case .triaging: return "triaging the blocked pile"
                case .drafting: return "waiting on the drafter"
                case .gating: return "gating the drafts"
                case .filing: return "filing the drafts"
                }
            }
        }

        /// The project being groomed for right now. A pass may serve several in
        /// turn, so this moves with it — what a stalled pass has to say is which
        /// project it is stuck on, not which one it opened with.
        var project: String
        let startedAt: Date
        /// Which pass this is. A pass ended at its deadline may still come back
        /// hours later, and it must not then release the flag a *newer* pass
        /// took, relabel that pass's stage, or file its own stale drafts.
        let token: Int
        var stage: Stage = .triaging

        var id: Int { token }

        /// How long it has been running. Clamped, so a clock that stepped
        /// backwards reads as a pass that has just started rather than as one
        /// that finished before it began.
        func age(at now: Date) -> TimeInterval { max(0, now.timeIntervalSince(startedAt)) }

        func isOverdue(deadline: TimeInterval, at now: Date) -> Bool {
            age(at: now) >= deadline
        }
    }

    /// Why a pass was ended without finishing.
    enum Abandonment: String, Sendable, Codable {
        /// It outlived `passDeadline`.
        case deadline
        /// The loop was switched off while it was running.
        case switchedOff

        var reason: String {
            switch self {
            case .deadline: return "it outlived its deadline"
            case .switchedOff: return "the loop was switched off"
            }
        }
    }

    /// What one pass did, for the log and the UI.
    ///
    /// `Codable` whole rather than as its `kind` tag, because the ledger it is
    /// written to (`PassLedger`) is what `passHistory` is rebuilt from at
    /// launch, and every reader of that history — the Planner card, the
    /// `/v1/coordinator/refill` reply — reads the associated values: which
    /// hold, which stage a pass was abandoned in, how many items were filed. A
    /// tag alone would read back as a pass that did nothing anyone can name.
    enum PassOutcome: Sendable, Equatable, Codable {
        case disabled
        case held(QueueRefill.Hold)
        /// The pass never finished: it outlived its deadline, or the loop was
        /// switched off under it. Not a hold — a hold is a pass that looked and
        /// decided not to groom, and this one decided nothing at all.
        case abandoned(project: String, stage: InFlightPass.Stage,
                       ranFor: TimeInterval, why: Abandonment)
        /// The drafter returned nothing usable.
        case noDrafts(project: String)
        /// The blocked pile had work to recover, so the pass spent itself on
        /// that instead of drafting.
        case triaged(project: String, tally: BlockedTriage.Tally)
        /// The pass wrote what it drafted. `refused` counts the drafts the
        /// backlog wouldn't take — an id already there, or a detail file that
        /// wouldn't write. Without it a refused draft appeared in neither
        /// `ready` nor `drafts` and the pass simply reported a smaller number
        /// than it had groomed, with nothing saying why.
        case filed(project: String, ready: Int, drafts: Int, refused: Int)

        var summary: String {
            switch self {
            case .disabled: return "queue refill is off"
            case .held(let hold): return "held — \(hold.reason)"
            case .abandoned(let project, let stage, let ranFor, let why):
                return "\(project): pass ended after \(PortfolioReport.duration(ranFor))"
                    + " — \(why.reason), still \(stage.phrase)"
            case .noDrafts(let project): return "\(project): drafter returned nothing usable"
            case .triaged(let project, let tally):
                return "\(project): triaged the blocked pile — \(tally.summary)"
            case .filed(let project, let ready, let drafts, let refused):
                // Only when there were any: a clean pass says what it filed,
                // and "refused 0" on every line would bury the one that didn't.
                return "\(project): filed \(ready) ready, \(drafts) draft(s)"
                    + (refused > 0 ? ", refused \(refused)" : "")
            }
        }

        /// The case as a stable tag, so a record of the pass can be read without
        /// parsing `summary`.
        var kind: String {
            switch self {
            case .disabled: return "disabled"
            case .held: return "held"
            case .abandoned: return "abandoned"
            case .noDrafts: return "noDrafts"
            case .triaged: return "triaged"
            case .filed: return "filed"
            }
        }

        /// The project the pass chose, when it got as far as choosing one.
        var project: String? {
            switch self {
            case .disabled, .held: return nil
            case .abandoned(let project, _, _, _): return project
            case .noDrafts(let project): return project
            case .triaged(let project, _): return project
            case .filed(let project, _, _, _): return project
            }
        }

        /// The hold, when the pass held. Nil is the answer to "did something stop
        /// this pass" for every other outcome.
        var hold: QueueRefill.Hold? {
            if case .held(let hold) = self { return hold }
            return nil
        }
    }

    /// What one pass did **for one project**, as it happened. Kept in a bounded
    /// ring so a loop that has been running all day can still be asked what it
    /// has been doing — the durable record is the portfolio report, not this.
    ///
    /// A pass that serves several projects leaves one record each, at the same
    /// instant: "filed 3 for kiteloop" and "drafter returned nothing for beta"
    /// are separate answers and a single row could only carry one of them. The
    /// project is part of the identity for that reason — two rows sharing a
    /// timestamp and an outcome are still two different projects' passes.
    struct PassRecord: Sendable, Equatable, Identifiable {
        let at: Date
        let outcome: PassOutcome

        var id: String { "\(at.timeIntervalSince1970)-\(outcome.project ?? "-")-\(outcome.kind)" }
        var project: String? { outcome.project }
        var summary: String { outcome.summary }
    }

    // MARK: - Settings

    /// Off until switched on. An always-running loop that files backlog items is
    /// not something to inherit by upgrading, so nothing but a stored `true`
    /// ever turns it on.
    ///
    /// Assigning persists the choice and starts or tears down the timer. Off
    /// means **no timer** rather than a timer that wakes every quarter hour to
    /// refuse — a dormant loop should cost nothing.
    var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            if !isLoadingConfig { globalConfigStore?.setCoordinatorRefill(enabled: enabled) }
            // Off means off, including whatever pass is still running. This is
            // also the recovery an operator reaches for first, and on
            // 2026-08-12 it was the one that didn't work: writing `false` then
            // `true` through the refill endpoint returned cleanly both times
            // and left the flag exactly as set as it found it, so the only way
            // back to grooming was restarting the app.
            if !enabled, let running = inFlightPass {
                abandon(running, why: .switchedOff, at: Date())
            }
            syncTimer()
        }
    }
    var policy = QueueRefill.Policy.default
    /// How often the timer looks. A project sitting idle with a full queue needs
    /// nothing, so a check is cheap — it costs a snapshot, not a model call.
    ///
    /// Settable, because it is the knob that decides how fast an emptied queue
    /// refills and it used to need a rebuild: on 2026-08-11 two projects sat idle
    /// with empty queues while 2 of 60 passes and $2.46 of $125 had been used —
    /// neither ceiling binding, a constant throttling the throughput instead.
    ///
    /// **Deliberately not persisted**, unlike the two ceilings: `capUSD` is
    /// portfolio state and `Budget.maxPasses` is saved as
    /// `coordinatorMaxPassesPerDay`, so both survive a launch, and pacing
    /// chosen for a session of unattended work does not. A restart is back to
    /// `Defaults.checkInterval`.
    ///
    /// Assigning restarts the timer rather than letting the current sleep run
    /// out — shortening the interval and then waiting the old one out is
    /// indistinguishable from the setting being ignored.
    var checkInterval: TimeInterval = Defaults.checkInterval {
        didSet {
            guard checkInterval != oldValue else { return }
            restartTimer()
        }
    }

    /// How long one pass may run before it is treated as stuck and ended.
    ///
    /// A pass that has run longer than this is stuck by definition: the work is
    /// one model call and a handful of file writes, and a pass still going when
    /// the next one is due has stopped being a pass and become a wedge. The
    /// default is the default interval, which is the natural upper bound to
    /// reason from — it is deliberately *not* tied to `checkInterval`, so
    /// pacing the loop at a minute doesn't start declaring healthy passes stuck.
    ///
    /// **Deliberately not persisted**, the same way `checkInterval` isn't: it
    /// paces one session of unattended work.
    var passDeadline: TimeInterval = Defaults.passDeadline

    enum Defaults {
        /// A quarter of an hour: the right cadence for a deep queue, and cheap
        /// because a check that finds nothing to do costs a snapshot.
        static let checkInterval: TimeInterval = 15 * 60
        /// The same quarter of an hour, as a ceiling rather than a cadence — see
        /// `passDeadline`.
        static let passDeadline: TimeInterval = 15 * 60
        /// What `checkInterval` may be set to — a minute at the fast end, so a
        /// driver can't turn the loop into a spin, and a day at the slow end,
        /// which is as good as armed-but-dormant.
        static let checkIntervalRange: ClosedRange<TimeInterval> = 60...86_400
    }

    // MARK: - State

    /// The pool grooming charges and is bounded by — the same ledger the run
    /// scheduler consults. Optional and weak like the scheduler's: an unwired
    /// loop meters itself.
    private weak var spendLedger: DailySpendLedger?

    /// The one ceiling that bounds this loop: the portfolio's daily number when
    /// it exists (the store is live, so a write through either PUT shows here
    /// immediately), else the legacy grooming-only figure.
    var sharedDailyCeilingUSD: Double? {
        globalConfigStore?.config.dailyBudgetUSD ?? budget.capUSD
    }

    /// The store, exposed narrowly so the deprecated budget alias in
    /// `PUT /v1/coordinator/refill` writes the shared number.
    var globalConfigStoreForBudgetAlias: GlobalConfigStore? { globalConfigStore }

    /// The day's figures. **Derived**, not accumulated: every number in it but
    /// the two ceilings comes from `passLedger`, recomputed whenever an entry is
    /// written and rebuilt at launch. Assigning it is how `@Observable` readers
    /// — the Planner card, the sidebar footer — hear about it.
    ///
    /// The ceilings are the exception and stay settings: `capUSD` is portfolio
    /// state the config store holds, `maxPasses` is persisted as
    /// `coordinatorMaxPassesPerDay`; only the cadence is not persisted.
    private(set) var budget: QueueRefill.Budget
    private(set) var ledger: QueueRefill.Ledger
    /// Where the day's passes, spend and abandonments are written down, so none
    /// of them is forgotten by a relaunch. See `PassLedger`.
    private(set) var passLedger: PassLedger
    /// The blocked pile's half of the same loop. Owned here rather than beside
    /// it because the two share a budget, and because the order
    /// between them is the whole point: recovering finished work is cheaper than
    /// drafting more, so a pass triages before it grooms.
    let blockedTriage: CoordinatorBlockedTriage
    private(set) var lastOutcome: PassOutcome?
    /// The pass running right now, or nil.
    ///
    /// It replaced a bare `isPassing` flag, and the difference is the whole
    /// item: a flag can only say that grooming is blocked, never since when, on
    /// what, or how far it got — so a pass that ended abnormally left the loop
    /// wedged and every reader of its state reporting perfect health.
    private(set) var inFlightPass: InFlightPass?
    /// Whether a pass is running — unchanged for every reader that only ever
    /// asked that much.
    var isPassing: Bool { inFlightPass != nil }
    /// Bumped once per pass; see `InFlightPass.token`.
    private var passToken = 0
    /// The in-flight pass's work, so an ending decided from outside it — the
    /// loop being switched off, the reaper — can try to stop it too.
    private var passWork: Task<Void, Never>?
    /// Today's passes, oldest first, capped at `maxPassHistory`. Rebuilt from
    /// `passLedger` at launch, so it shows the day rather than the process — a
    /// card reading `0 of 12 passes` after a restart was not idle, it had
    /// forgotten.
    private(set) var passHistory: [PassRecord] = []
    /// Where a filing that landed is written down. Distinct from
    /// `QueueRefill.Ledger` above, which remembers *gaps* so one isn't filled
    /// twice: this is the grooming half of what `PortfolioReport` reports, whose
    /// headline is merged ÷ **filed**. Settable for tests, the way
    /// `BacklogAutopilot.groomingLedger` is; the app shares one ledger.
    var groomingLedger: GroomingLedger = .shared

    /// How many passes are remembered. Diagnostics, not an audit log: enough to
    /// answer "what has this loop been doing" over a working day at the default
    /// interval, and bounded so an app left running for a week doesn't grow a
    /// list nothing ever reads the far end of.
    ///
    /// `nonisolated` because `PassLedger` applies it too — the history is read
    /// back off the ledger, and the bound has to be the same one on both sides
    /// or a relaunch would change how much of the day the panel shows.
    nonisolated static let maxPassHistory = 50

    /// When each project was last seen with nothing running — the tiebreak.
    private var idleSince: [String: Date] = [:]

    private let ledgerURL: URL
    private let passLedgerURL: URL
    /// The JSONL ledger `TaskMetricStore.appendApprovalEvent` writes — read for
    /// the escaped-defect signal `SignalSources.gather` folds in beside the
    /// model's own drafts. Overridable for the same reason `passLedgerURL` is:
    /// a test's loop must read its own temp file, never the developer's real
    /// `~/.kiteloop/task-approvals.jsonl`.
    private let approvalsLedgerURL: URL
    private var timer: Task<Void, Never>?
    /// Whether the app has asked the loop to run at all — `start()` on, `stop()`
    /// off. The timer exists only while this and `enabled` are both true.
    private var isStarted = false
    /// True while stored settings are being applied, so loading what was saved
    /// doesn't immediately save it back.
    private var isLoadingConfig = false

    /// Whether the periodic check is live. A switched-off loop has no timer at
    /// all, which is the difference between costing nothing and costing a wake-up
    /// every `checkInterval`.
    var isTimerRunning: Bool { timer != nil }

    /// Which incarnation of the timer is running — bumped every time one is
    /// created. `isTimerRunning` cannot tell "still the old sleep" from "restarted
    /// on the new cadence", and that difference is exactly what a changed
    /// `checkInterval` has to produce.
    private(set) var timerGeneration = 0

    private weak var registry: ControlSessionRegistry?
    private weak var globalConfigStore: GlobalConfigStore?
    private var runtimeFactory: (() -> any AgentRuntime)?

    /// The budget this instance opened with, ceilings and all — what the day's
    /// recorded figures are added to.
    ///
    /// Zero in the app, which is the case that matters: `KiteloopApp` builds the
    /// loop with `Budget(maxPasses: 12)`, so every number the day reports comes
    /// off the ledger and nothing comes from memory. A caller that *does* hand
    /// figures in is standing the loop up on a day it did not live through — a
    /// test describing a night that spent twenty passes — and those figures are
    /// its opening balance rather than a second, competing account of today.
    ///
    /// `let`, and rolled at every read: once the local day has moved past
    /// `day`, the opening balance is zero and the ledger is the whole answer.
    private let opening: QueueRefill.Budget

    /// - Parameters:
    ///   - passLedgerURL: where the day's figures are written. Nil puts it
    ///     beside `ledgerURL` — see `PassLedger.url(besideLedgerAt:)`, and note
    ///     that the default is what keeps a caller who redirected one ledger
    ///     from silently writing the other into `~/.kiteloop`.
    ///   - approvalsLedgerURL: where the escaped-defect signal reads from. Nil
    ///     takes `MetricIndex.Sources.default.approvalsURL` — the same file
    ///     `TaskMetricStore` writes to by default — which is right in the app
    ///     and wrong in a test, the same way an unstated `passLedgerURL` would be.
    ///   - budget: the ceilings, and the opening balance — see `opening`. Its
    ///     `day` is also the instant the loop opens on, so a caller can stand it
    ///     up on a chosen day without a clock parameter beside it saying the
    ///     same thing twice.
    init(ledgerURL: URL = QueueRefill.Ledger.defaultURL(),
         passLedgerURL: URL? = nil,
         approvalsLedgerURL: URL? = nil,
         budget: QueueRefill.Budget = QueueRefill.Budget(maxPasses: 12),
         blockedTriage: CoordinatorBlockedTriage = CoordinatorBlockedTriage()) {
        let passURL = passLedgerURL ?? PassLedger.url(besideLedgerAt: ledgerURL)
        let now = budget.day
        self.ledgerURL = ledgerURL
        self.passLedgerURL = passURL
        self.approvalsLedgerURL = approvalsLedgerURL ?? MetricIndex.Sources.default.approvalsURL
        self.ledger = QueueRefill.Ledger.load(from: ledgerURL)
        self.blockedTriage = blockedTriage
        self.opening = budget

        let loaded = PassLedger.load(from: passURL, now: now)
        self.passLedger = loaded.ledger
        self.budget = loaded.ledger.budget(on: now, startingFrom: budget)
        self.passHistory = loaded.ledger.passRecords(on: now)
        if !passHistory.isEmpty {
            refillLog.info("Queue refill: read back \(self.passHistory.count, privacy: .public) of today's pass(es) from the ledger")
        }
        // Only when the load actually dropped something: a ledger already inside
        // the retention bound is left exactly as it was found.
        if loaded.needsRewrite {
            PassLedger.rewrite(loaded.ledger, undecodable: loaded.undecodable, to: passURL)
        }
    }

    /// Write one entry down and re-derive the day from what is now on record.
    ///
    /// Both halves, always: the in-memory ledger is what the figures are read
    /// off — re-reading the file on every pass would be the same numbers at more
    /// cost — and the file is what makes them survive the process.
    ///
    /// The day is re-derived at the entry's *accounted* instant, which is `at`
    /// for everything but an abandonment. That is what preserves
    /// `Budget.abandonedAPass()`'s deliberate refusal to roll: an abandonment
    /// carries the deadline the pass outlived, and deriving the day from an
    /// instant that hasn't arrived would zero a day's spend before the day was
    /// over.
    private func record(_ entry: PassLedger.Entry) {
        passLedger.append(entry)
        PassLedger.append(entry, to: passLedgerURL)
        rederive(at: entry.accountedAt)
    }

    /// The day's figures as the ledger now has them, on top of the opening
    /// balance and keeping whatever the ceilings have since been set to.
    ///
    /// The figures come from `opening` rather than from the current `budget`,
    /// which is what stops each write compounding the last one's total; the
    /// ceilings come from `budget`, which is where `setBudgetLimits` and the
    /// stored settings put them.
    ///
    /// Called after every write, and on a `recordSpend` that had nothing to
    /// write: a zero-cost call still moves the day on when the clock has crossed
    /// local midnight since the last one, which is the rolling `Budget.rolled`
    /// used to do in place.
    private func rederive(at now: Date) {
        var base = opening
        base.capUSD = budget.capUSD
        base.maxPasses = budget.maxPasses
        budget = passLedger.budget(on: now, startingFrom: base)
        passHistory = passLedger.passRecords(on: now)
    }

    /// Whether anything is wired to it. Unwired, `runPass` holds whatever
    /// `enabled` says — so a reader that reported an unwired loop as merely "off"
    /// would be making a different and wrong claim about why nothing happened.
    var isConfigured: Bool {
        registry != nil && globalConfigStore != nil && runtimeFactory != nil
    }

    /// Wire the portfolio it watches and the runtime it drafts with, and take the
    /// switch and the day's ceiling from what was saved. Unwired,
    /// every pass holds — nothing here fails open.
    ///
    /// `metrics` is what the blocked half reads: a stuck item is classified from
    /// what its runs recorded, so without the store every blocked item reports
    /// no recorded run and is escalated rather than guessed at.
    func configure(registry: ControlSessionRegistry,
                   globalConfigStore: GlobalConfigStore,
                   runtimeFactory: @escaping () -> any AgentRuntime,
                   metrics: TaskMetricStore? = nil,
                   spendLedger: DailySpendLedger? = nil) {
        self.registry = registry
        self.globalConfigStore = globalConfigStore
        self.spendLedger = spendLedger
        self.runtimeFactory = runtimeFactory
        blockedTriage.configure(registry: registry, metrics: metrics)
        applyStoredSettings(globalConfigStore)
    }

    /// What the last launch chose, so a restart keeps it. Nothing stored is the
    /// shipped default — off. A stored ceiling replaces the one this instance
    /// was built with; no stored ceiling leaves that alone, since "not stated"
    /// is not the same as "uncapped on purpose".
    ///
    /// `enabled` is applied last: it is what starts the timer, and it should
    /// start against the budget that was meant to go with it.
    private func applyStoredSettings(_ store: GlobalConfigStore) {
        isLoadingConfig = true
        defer { isLoadingConfig = false }
        // One ceiling per scope: grooming is bounded by the portfolio's daily
        // number.
        if let shared = store.config.dailyBudgetUSD { budget.capUSD = shared }
        if let passes = store.config.coordinatorMaxPassesPerDay { budget.maxPasses = passes }
        enabled = store.coordinatorRefillEnabled
    }

    /// Feed the day's grooming spend in, for whoever is metering it. Clamped and
    /// rolled, so a stale figure from yesterday can't exhaust today.
    ///
    /// Written down rather than added to a property: a day's spend that only a
    /// running process knew about was zero again after every relaunch. A call
    /// that cost nothing writes nothing — a line per free call would bury the
    /// ones that spent — but the day is still re-derived from `now`, which is
    /// the rolling the old in-place `Budget.rolled` did.
    func recordSpend(_ costUSD: Double, now: Date = Date()) {
        let spent = max(0, costUSD)
        if spent > 0 {
            record(PassLedger.Entry(at: now, event: .spend, costUSD: spent))
        } else {
            rederive(at: now)
        }
        // Grooming draws from the same pool running does — the portfolio's
        // daily ledger — so "what bounds tonight" has one answer. The local
        // figure above remains what the GET reports as grooming's own draw.
        _ = spendLedger?.charge(costUSD: spent)
    }

    /// Set the day's ceilings. Nil leaves that ceiling alone.
    ///
    /// Both persist now: the cost ceiling as portfolio state, the pass ceiling
    /// as `coordinatorMaxPassesPerDay`. The pass ceiling used to last one
    /// launch on purpose, and the purpose did not survive contact with a
    /// 12/12 afternoon: a ceiling the operator tuned and the app then forgot
    /// reads as a bug, not a boundary.
    func setBudgetLimits(capUSD: Double?? = nil, maxPasses: Int?? = nil) {
        if let capUSD {
            budget.capUSD = capUSD
            if !isLoadingConfig { globalConfigStore?.setDailyBudgetUSD(capUSD) }
        }
        if let maxPasses {
            budget.maxPasses = maxPasses
            if !isLoadingConfig { globalConfigStore?.setCoordinatorRefill(maxPassesPerDay: maxPasses) }
        }
    }

    // MARK: - Triggers

    /// Start the periodic check. Idempotent, and a no-op while the loop is
    /// switched off — `enabled` is what decides whether a timer exists.
    func start() {
        isStarted = true
        syncTimer()
    }

    func stop() {
        isStarted = false
        syncTimer()
    }

    /// Pick up a new `checkInterval` now. The loop reads the interval fresh each
    /// time round, so only the sleep already in flight is stale — and that one is
    /// the whole complaint, since it is the wait the operator was trying to
    /// shorten. A loop that isn't running has nothing to restart: it will read
    /// the new interval when `syncTimer` next starts it.
    private func restartTimer() {
        guard timer != nil else { return }
        timer?.cancel()
        timer = nil
        syncTimer()
    }

    /// The timer runs exactly when the loop is both started and switched on.
    private func syncTimer() {
        guard isStarted, enabled else {
            timer?.cancel()
            timer = nil
            return
        }
        guard timer == nil else { return }
        timerGeneration += 1
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.checkInterval else { return }
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await self?.runPass()
            }
        }
    }

    /// A project's run just finished — the moment its queue is most likely to be
    /// empty. Cheaper and far more timely than waiting out the interval, and the
    /// same decision either way: a queue still above the threshold holds.
    func queueDrained() {
        Task { await runPass() }
    }

    // MARK: - The pass

    /// One refill pass: decide, draft, gate, file — for every project that needs
    /// it, neediest first, up to `Policy.maxProjectsPerPass`. Returns what it did
    /// for the last project it served.
    ///
    /// Serving more than one is the difference between a fleet that keeps up and
    /// one that starves: a pass that topped up a single project divided the
    /// cadence by the project count, so with three projects on a 300-second
    /// interval a queue's turn came round every twenty minutes and two of the
    /// three sat at `ready=0` while grooming had spent 1 of 150 passes.
    ///
    /// Still one pass: it takes the flag once, is charged against the day once,
    /// and the timer firing mid-pass must not double-file the same drafts.
    @discardableResult
    func runPass(now: Date = Date()) async -> PassOutcome {
        guard let ready = readyToPass(at: now) else { return lastOutcome ?? .disabled }
        guard case .wired(let registry, let globalConfigStore, let runtimeFactory) = ready else {
            return finish(.held(.noEligibleProject), at: now)
        }

        let portfolio = PortfolioSnapshot.capture(registry: registry,
                                                  portfolioGoal: globalConfigStore.portfolioGoal)
        idleSince = QueueRefill.trackIdle(idleSince, portfolio: portfolio, now: now)

        // The money view of the budget is the shared pool: the portfolio's
        // ceiling, against everything autonomous spent today — grooming and
        // running alike. Pass counting stays this loop's own. Without a shared
        // ceiling or a ledger, the loop's own figures stand, which is what the
        // pure tests drive.
        var moneyBudget = budget.rolled(to: now)
        if let shared = globalConfigStore.config.dailyBudgetUSD { moneyBudget.capUSD = shared }
        if let pooled = spendLedger?.spentTodayUSD {
            moneyBudget.spentUSD = max(moneyBudget.spentUSD, pooled)
        }
        let decision = QueueRefill.decidePass(portfolio: portfolio, policy: policy,
                                              budget: moneyBudget, idleSince: idleSince, now: now)
        // Every hold reaches the event stream through `finish` — a budget
        // refusal, a healthy queue and nothing eligible are all answers to
        // "why was nothing groomed today".
        return await perform(decision, registry: registry, globalConfigStore: globalConfigStore,
                             runtimeFactory: runtimeFactory, now: now)
    }

    /// The same pass, against a project a **human named** — "groom kiteloop now"
    /// — rather than the one the loop would have chosen.
    ///
    /// It is deliberately this method and not a shortcut past it: the target is
    /// chosen by `QueueRefill.decide(project:…)`, which keeps the budget
    /// refusal, the paused stop and the depth bound, and the drafting, gating
    /// and filing below are the timer's own. A human choosing *which* project
    /// does not also get to choose how much, how paused, or how gated.
    @discardableResult
    func runPass(forProject key: String, now: Date = Date()) async -> PassOutcome {
        guard let ready = readyToPass(at: now) else { return lastOutcome ?? .disabled }
        guard case .wired(let registry, let globalConfigStore, let runtimeFactory) = ready else {
            return finish(.held(.noEligibleProject), at: now)
        }

        let portfolio = PortfolioSnapshot.capture(registry: registry,
                                                  portfolioGoal: globalConfigStore.portfolioGoal)
        // A key may be a path or a folder name everywhere else in the app; the
        // portfolio knows projects by folder name, so resolve before deciding.
        let name = registry.entry(forProject: key)?.session.project.rootURL.lastPathComponent ?? key
        let decision = QueueRefill.decide(project: name, portfolio: portfolio,
                                          policy: policy, budget: budget, now: now)
        return await perform(decision.asPass, registry: registry,
                             globalConfigStore: globalConfigStore,
                             runtimeFactory: runtimeFactory,
                             honorHolds: false, now: now)
    }

    /// Whether a pass may start at all, and what it is wired to. Nil means the
    /// caller should return `lastOutcome` unchanged — the loop is off, or one is
    /// already running and must not be doubled.
    private enum PassReadiness {
        case wired(ControlSessionRegistry, GlobalConfigStore, () -> any AgentRuntime)
        case unwired
    }

    private func readyToPass(at now: Date) -> PassReadiness? {
        guard enabled else {
            finish(.disabled, at: now)
            return nil
        }
        // A pass past its deadline is stuck, and the flag it holds gates every
        // later pass. Reaped here as well as at the deadline itself: the
        // watchdog in `perform` covers a pass whose caller is still waiting on
        // it, and this covers one whose caller went away with the watchdog.
        if let stuck = inFlightPass, stuck.isOverdue(deadline: passDeadline, at: now) {
            abandon(stuck, why: .deadline, at: now)
        }
        guard !isPassing else { return nil }
        guard let registry, let globalConfigStore, let runtimeFactory else { return .unwired }
        return .wired(registry, globalConfigStore, runtimeFactory)
    }

    /// Draft, gate and file for whatever `decide` chose — the half of a pass
    /// that is identical whether the timer picked the project or a human did.
    ///
    /// The grooming itself is `groom`; this is the part that will not let it run
    /// for ever. The pass is raced against its deadline, and the loser is
    /// deliberately **not** awaited: a pass wedged in a call that does not answer
    /// cancellation would otherwise hold its caller — the timer's own loop, which
    /// awaits each pass before sleeping again — for exactly as long as it holds
    /// the flag. That is how one stuck pass stopped grooming for a whole fleet
    /// for 2h22m. Cancelling the work is best effort; ending the pass is not.
    private func perform(_ decision: QueueRefill.PassDecision,
                         registry: ControlSessionRegistry,
                         globalConfigStore: GlobalConfigStore,
                         runtimeFactory: @escaping () -> any AgentRuntime,
                         honorHolds: Bool = true,
                         now: Date) async -> PassOutcome {
        guard !decision.targets.isEmpty else {
            return finish(.held(decision.hold ?? .noEligibleProject), at: now)
        }
        // The futility hold, honored only for the timer's own passes — a human
        // who *named* the project is overriding it, and that override plus a
        // resulting success is one of the release paths. Each held target is
        // recorded as its own held pass, so "why was nothing groomed for X"
        // stays answerable from the history.
        var targets = decision.targets
        if honorHolds {
            let held = targets.filter { (futileStreaks[$0.project] ?? 0) >= Self.futileHoldThreshold }
            for target in held {
                finish(.held(.groomingHeld(project: target.project,
                                           streak: futileStreaks[target.project] ?? 0)), at: now)
            }
            targets.removeAll { target in held.contains { $0.project == target.project } }
            guard !targets.isEmpty else { return lastOutcome ?? .disabled }
        }
        // Resolved before the pass starts, so a project closed since the snapshot
        // is dropped rather than taking the pass down with it.
        let servable = targets.compactMap { target -> Served? in
            guard let entry = registry.entry(forProject: target.project),
                  let backlog = entry.session.backlogViewModel.backlogFile else { return nil }
            return Served(target: target, entry: entry, backlog: backlog)
        }
        guard let first = servable.first else { return finish(.held(.noEligibleProject), at: now) }

        let pass = beginPass(project: first.target.project, at: now)
        // The pass has started: charge it before the model call, so a crash
        // mid-draft still costs a pass rather than repeating for free. Once,
        // however many projects it goes on to serve — serving the fleet in one
        // pass must not spend the pass ceiling faster than serving one did.
        // On record rather than in a counter, so a relaunch doesn't hand the day
        // its twelve passes back.
        record(PassLedger.Entry(at: now, event: .passStarted, project: first.target.project))

        let deadline = passDeadline
        let (endings, report) = AsyncStream<PassOutcome?>.makeStream()
        let work = Task { [weak self] in
            guard let self else { return }
            for (index, next) in servable.enumerated() {
                // The flag first: a pass ended under it must write nothing more.
                guard self.isRunning(pass) else { break }
                // Then the money. The first project is already paid for by the
                // gate `decidePass` ran, but each one after it drafts on spend
                // the earlier ones have since booked, and a ceiling checked only
                // at the top of a pass would let one pass overrun it by the whole
                // width of the fleet.
                if index > 0, self.budget.rolled(to: now).spendExhaustionReason != nil { break }
                self.retarget(pass, to: next.target.project)
                report.yield(await self.groom(pass: pass, target: next.target, entry: next.entry,
                                              backlog: next.backlog,
                                              globalConfigStore: globalConfigStore,
                                              runtimeFactory: runtimeFactory, now: now))
            }
            report.finish()
        }
        passWork = work
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(deadline))
            report.yield(nil)
        }
        defer { watchdog.cancel() }

        // One value per project served; `nil` inside the optional is the
        // watchdog. Each is recorded as it lands rather than at the end, so a
        // pass ended halfway still says what the projects before it got.
        var recorded = 0
        for await ending in endings {
            guard let outcome = ending else {
                return abandon(pass, why: .deadline, at: now.addingTimeInterval(deadline))
                    ?? lastOutcome ?? .disabled
            }
            // The pass was ended without us — at its deadline, or by the loop
            // being switched off — and this is its work catching up. That ending
            // is already recorded, and one pass gets one.
            guard isRunning(pass) else { return lastOutcome ?? .disabled }
            finish(outcome, at: now)
            recorded += 1
        }
        // Nothing recorded and no watchdog: the app is going down under us. The
        // pass has not ended, so nothing is recorded here either; the reaper in
        // `readyToPass` ends it if it never comes back.
        guard recorded > 0 else { return lastOutcome ?? .disabled }
        endPass(pass)
        return lastOutcome ?? .disabled
    }

    /// One project a pass is going to serve, with what it needs to serve it.
    private struct Served {
        let target: QueueRefill.Target
        let entry: ControlSessionRegistry.Entry
        let backlog: BacklogFile
    }

    /// What the repo's own instruments already know, folded in ahead of the
    /// model's own drafts and bounded to the same `target.count` the model's
    /// own candidates already hold to — so a flaky test, a churn-times-
    /// complexity hotspot or an item that escaped review is filed alongside
    /// whatever the model proposed rather than by nobody, and never past the
    /// shortfall this pass was asked to fill.
    ///
    /// Gathering runs off the main actor, the same way the grounding sources
    /// in `groom` are — a hung instrument must not hold the app, only this
    /// pass, and the watchdog in `perform` ends that regardless of how long
    /// this takes.
    ///
    /// Skipped entirely when the model's own drafts already leave no room —
    /// the same `max(0, limit - model.count)` `QueueRefill.boundedDrafts`
    /// computes, checked here before either instrument runs rather than
    /// after. A pass whose drafter came back full was always going to
    /// discard whatever the instruments found, so running them first spent
    /// up to five minutes — `SignalSources.flakeTimeout` plus
    /// `SignalSources.hotspotTimeout` — of the pass's own deadline on a
    /// result the next line threw away.
    /// `entry` is for the project's own merge-verify, what every signal draft
    /// runs; nil when the project names none and has no verify map.
    private func withSignalDrafts(_ modelDrafts: [QueueRefill.Drafted], target: QueueRefill.Target,
                                  backlog: BacklogFile, root: URL,
                                  entry: ControlSessionRegistry.Entry) async -> [QueueRefill.Drafted] {
        let room = max(0, target.count - modelDrafts.count)
        guard room > 0 else {
            refillLog.info("""
                Queue refill: \(target.project) skipped its own instruments — the model's \
                \(modelDrafts.count, privacy: .public) draft(s) already fill the \
                \(target.count, privacy: .public)-item shortfall
                """)
            return modelDrafts
        }
        let approvalsLedgerURL = self.approvalsLedgerURL
        let projectPath = root.path(percentEncoded: false)
        let findings = await Task.detached {
            SignalSources.gather(repoRoot: root, approvalsLedgerURL: approvalsLedgerURL,
                                 projectPath: projectPath)
        }.value
        let existingIDs = Set(backlog.sections.flatMap(\.items).map(\.id))
            .union(ledger.filedIDs(project: target.project))
        // Drafted with this project's own merge-verify, never a Kiteloop one:
        // seven of seven hotspot items on a Rust project carried an
        // `xcodebuild` on 2026-09-19. A project with nothing to run has
        // nothing to give a draft, and says so rather than filing it. A map
        // with a catch-all rule gives none: the gate runs it on any diff.
        let signalVerify = SignalDrafting.verify(mergeVerify: entry.autopilot.effectiveMergeVerify.command,
                                                 map: VerifyMapFile.load(for: entry.session.project))
        if signalVerify == nil, !findings.isEmpty {
            refillLog.info("""
                Queue refill: \(target.project) names no merge-verify and has no verify map, so its \
                \(findings.count, privacy: .public) signal finding(s) are not drafted — an item needs a verify: it can run
                """)
        }
        let signalDrafts = signalVerify.map { Self.signalDrafts(for: findings, existingIDs: existingIDs, verify: $0) } ?? []
        let bounded = QueueRefill.boundedDrafts(signal: signalDrafts, model: modelDrafts, limit: target.count)
        if bounded.leftoverSignal > 0 {
            refillLog.info("""
                Queue refill: \(target.project) left \(bounded.leftoverSignal, privacy: .public) \
                signal finding(s) for the next pass — \(target.count, privacy: .public) is already spoken for
                """)
        }
        return bounded.drafts
    }

    /// The grooming a pass actually does. Returns what happened rather than
    /// recording it: `perform` decides whether this pass is still the one
    /// entitled to record anything.
    private func groom(pass: InFlightPass,
                       target: QueueRefill.Target,
                       entry: ControlSessionRegistry.Entry,
                       backlog: BacklogFile,
                       globalConfigStore: GlobalConfigStore,
                       runtimeFactory: @escaping () -> any AgentRuntime,
                       now: Date) async -> PassOutcome {
        // Recover before drafting. A rejection often says nothing about the
        // work: on 2026-08-07 five rejected items were later merged by hand,
        // unchanged — dead sessions, a flaky verify, a cost cap that killed a
        // review with the work already done. A loop that groomed new work first
        // would have drafted more on top of all five, so the blocked pile is
        // read first and a pass that recovered something ends there. Nothing
        // *recovered* means grooming carries on: a pile that only escalates
        // decides plenty and frees nothing, and must not stall the queue.
        stage(.triaging, of: pass)
        let triage = await blockedTriage.triage(project: target.project,
                                                budget: budget, now: now)
        if triage.recovered > 0 {
            return .triaged(project: target.project, tally: triage.plan.tally)
        }

        let root = entry.session.project.rootURL
        stage(.drafting, of: pass)
        let modelDrafts = await draft(target: target, entry: entry, backlog: backlog,
                                      root: root, globalConfigStore: globalConfigStore,
                                      runtimeFactory: runtimeFactory, now: now)
        var drafts = await withSignalDrafts(modelDrafts, target: target, backlog: backlog, root: root, entry: entry)

        // The one place a late pass has to be stopped. Everything that writes is
        // downstream of here, and a pass abandoned while the drafter was
        // thinking has already had a successor let through — two passes writing
        // one backlog is the double-filing the flag exists to prevent. Nothing
        // reads what this returns: the ending was recorded when it was
        // abandoned.
        guard isRunning(pass) else {
            refillLog.error("""
                Queue refill: \(target.project) drafts came back after the pass had been ended — \
                discarded \(drafts.count)
                """)
            return .abandoned(project: target.project, stage: .drafting,
                              ranFor: pass.age(at: Date()), why: .deadline)
        }
        guard !drafts.isEmpty else { return .noDrafts(project: target.project) }

        // Widened with the project's own map before either gate sees it: a
        // draft that gaps on a rule every path is subject to would otherwise
        // clear Definition-of-Ready and grounding, be picked up, run and
        // reviewed, and only then be refused by `VerifyCoverage` — a whole
        // run spent finding what this map already knew.
        let verifyMap = VerifyMapFile.load(for: entry.session.project)
        drafts = drafts.map { widenVerify($0, map: verifyMap) }

        // The vault too: a draft cites its own detail file and the backlog it
        // will be filed in, and both live there rather than in the repo.
        stage(.gating, of: pass)
        let (vault, base) = (globalConfigStore.vaultURL, entry.autopilot.baseBranch)
        let sources = await Task.detached {
            GroundingCheck.Sources.repository(root: root, vault: vault, baseBranch: base)
        }.value
        let drafted = drafts.map { gate($0, sources: sources, mapCoversEveryPath: SignalDrafting.hasCatchAll(verifyMap)) }.map {
            Proposal(project: target.project, draft: $0.draft, status: $0.status,
                     notes: $0.notes, refusals: $0.refusals)
        }

        stage(.filing, of: pass)
        var ready = 0
        var parked = 0
        var refused = 0
        for proposal in drafted {
            guard fileDraft(proposal, entry: entry, backlog: backlog, now: now).didFile else {
                refused += 1
                continue
            }
            if proposal.status == .ready { ready += 1 } else { parked += 1 }
        }
        return .filed(project: target.project, ready: ready, drafts: parked, refused: refused)
    }

    // MARK: - Grooming skeletons

    /// The repo's own instrument findings, turned into drafts whose `## What`
    /// already carries the clause its kind demands — split out of `groom`
    /// only to keep that function's body short; the dedup against
    /// `existingIDs` is the same one `SignalDrafting.drafts(for:existingIDs:)`
    /// does, reimplemented here because classifying a finding's kind needs
    /// the finding itself, which that convenience does not hand back — the
    /// pre-cap id skip included, so a finding already filed under its longer,
    /// pre-cap id is not drafted again under its new, capped one.
    private static func signalDrafts(for findings: [SignalFinding],
                                      existingIDs: Set<String>, verify: String) -> [QueueRefill.Drafted] {
        findings.compactMap { finding in
            let draft = SignalDrafting.draft(for: finding, verify: verify)
            guard !existingIDs.contains(draft.id),
                  !existingIDs.contains(SignalDrafting.preCapID(for: finding)) else { return nil }
            let kind = itemKind(for: finding)
            let what = "\(draft.what)\n\n\(clauseSentence(kind: kind, finding: finding))"
            return QueueRefill.Drafted(draft: QueueRefill.Draft(
                id: draft.id, title: draft.title, size: draft.size, verify: draft.verify,
                what: what, how: draft.how, validation: draft.validation,
                outOfScope: draft.outOfScope))
        }
    }

    /// The kind a signal's own finding picks: `SignalFinding.kind` already
    /// separates bug from refactor for `SignalDrafting`'s own wording, and a
    /// refactor an instrument found is internal work — tooling, in this
    /// widened set — never a claim of user value.
    private static func itemKind(for finding: SignalFinding) -> BacklogTemplate.ItemKind {
        finding.kind == .bug ? .bug : .tooling
    }

    /// The sentence `kind.clauseLabel` opens, built from the finding itself
    /// so the filed detail's `## What` shows the skeleton its kind demands
    /// without asking the drafter to state it — an instrument's finding
    /// already carries what the sentence needs.
    private static func clauseSentence(kind: BacklogTemplate.ItemKind, finding: SignalFinding) -> String {
        let evidence = finding.evidence.joined(separator: "; ")
        switch kind {
        case .bug:
            return "\(kind.clauseLabel) \(finding.title) — \(evidence)."
        case .tooling:
            return "\(kind.clauseLabel) keeping `\(finding.key)` off the instrument that flagged it "
                + "— \(evidence)."
        case .feature:
            // An instrument's finding is never filed as a feature — see
            // `itemKind(for:)` — so this case is unreachable in practice and
            // kept only for the switch's exhaustiveness.
            return kind.clauseLabel
        }
    }

    // MARK: - The flag

    /// Take the flag for a new pass.
    private func beginPass(project: String, at now: Date) -> InFlightPass {
        passToken += 1
        let pass = InFlightPass(project: project, startedAt: now, token: passToken)
        inFlightPass = pass
        return pass
    }

    /// Whether this pass is still the one holding the flag. False once it has
    /// been abandoned — a pass that comes back after its ending is a bystander.
    private func isRunning(_ pass: InFlightPass) -> Bool {
        inFlightPass?.token == pass.token
    }

    /// Say where the pass has got to, for whoever has to diagnose it if it never
    /// comes back. Ignored once the pass has ended: a late report from an
    /// abandoned pass must not relabel the one running now.
    private func stage(_ stage: InFlightPass.Stage, of pass: InFlightPass) {
        guard isRunning(pass) else { return }
        inFlightPass?.stage = stage
    }

    /// Move the pass on to the next project it serves. Same flag, same token,
    /// same charge — only what it is working on changes, and a stall notice from
    /// here on names this project rather than the one the pass opened with.
    private func retarget(_ pass: InFlightPass, to project: String) {
        guard isRunning(pass) else { return }
        inFlightPass?.project = project
        inFlightPass?.stage = .triaging
    }

    /// Release the flag, if it is still this pass's to release.
    @discardableResult
    private func endPass(_ pass: InFlightPass) -> Bool {
        guard isRunning(pass) else { return false }
        inFlightPass = nil
        passWork = nil
        return true
    }

    /// End a pass that never finished, and record what it was doing when it was
    /// ended. Nil when the flag was not this pass's — nothing to end, and
    /// nothing to record.
    ///
    /// The recording is the point, not a nicety. A flag cleared on a timer and
    /// nothing else leaves the next wedge exactly as undiagnosable as this one
    /// was, so the ending goes in the pass history alongside the ordinary
    /// outcomes and names the stage it was stuck in.
    ///
    /// It is counted as well as recorded. The history holds the newest 50
    /// entries and nobody reads it unless they already suspect something,
    /// whereas the day's ceilings are read every time anyone looks at the
    /// footer — so the count goes on the budget, beside the passes and the
    /// spend, and a night that hung four times and self-healed four times can
    /// be told in the morning from one that never hung.
    ///
    /// The count comes off the ledger's abandoned outcome rather than a separate
    /// entry, so the two cannot disagree about one pass — recorded once however
    /// many nets catch it, since every net comes through the guard below.
    @discardableResult
    private func abandon(_ pass: InFlightPass, why: Abandonment, at now: Date) -> PassOutcome? {
        guard isRunning(pass) else { return nil }
        let stage = inFlightPass?.stage ?? pass.stage
        // The project it is stuck on, not the one it opened with: a pass may have
        // moved on to a second or third project since `pass` was captured.
        let project = inFlightPass?.project ?? pass.project
        // Best effort, and only that. The call that wedges is the model call,
        // and a subprocess that has stopped answering does not necessarily
        // notice being cancelled — which is the whole reason ending the pass
        // does not wait to find out.
        passWork?.cancel()
        endPass(pass)
        // Counted against the day the budget is already on, not the day `now`
        // falls in. `now` here is the deadline the pass outlived, which sits
        // ahead of the clock and, late enough in the evening, in tomorrow — and
        // an abandonment must no more move the day's figures forward off disk
        // than `Budget.abandonedAPass()` lets it move them in memory.
        return finish(.abandoned(project: project, stage: stage,
                                 ranFor: pass.age(at: now), why: why),
                      at: now, countsOn: budget.day)
    }

    /// One line for a surface that has room for one, when grooming has *stopped*
    /// rather than merely being between passes. Nil the rest of the time — an
    /// ordinary pass is not news.
    ///
    /// The failure it answers: on 2026-08-12 a pass wedged at 07:34 and nothing
    /// said so until 09:56. Every recorded ceiling read healthy the whole time,
    /// and truthfully — $52.59 of $350 and 20 of 150 passes — because what had
    /// stopped grooming was not a ceiling at all, and the footer that reports
    /// the nearest one had nothing else it could say.
    func stallNotice(now: Date = Date()) -> String? {
        if let pass = inFlightPass, pass.isOverdue(deadline: passDeadline, at: now) {
            return "Stalled — \(pass.project): pass in flight "
                + "\(PortfolioReport.duration(pass.age(at: now))), \(pass.stage.phrase)"
        }
        if let last = lastOutcome, case .abandoned = last { return "Stalled — \(last.summary)" }
        return nil
    }

    /// Record the outcome, remember it, and say so out loud.
    ///
    /// A hold is information, not silence: "every queue is healthy", "nothing is
    /// eligible" and "the drafter returned nothing" each answer a different
    /// question about why no work appeared, and a loop that reported all three as
    /// nothing at all is one you can neither trust nor debug.
    ///
    /// `.disabled` is the exception, and not for tidiness: the timer keeps ticking
    /// while the loop is off, so recording it would fill the history with a
    /// switched-off loop's ticks and push real passes out of it. That the loop is
    /// off is already reported as `enabled`.

    // MARK: - Futility

    /// Consecutive passes per project that groomed and produced nothing
    /// runnable — the drafter returned nothing, or everything it drafted was
    /// gate-parked at `draft`. At `futileHoldThreshold` the timer stops
    /// choosing the project (`perform` honors the hold); a human-named pass
    /// ignores it, and any pass that files a ready item resets it.
    ///
    /// Built after 2026-08-11, when one project burned 78 check refusals in a
    /// night of re-drafting the same mistakes. Deliberately in-memory: a
    /// relaunch forgives the streak, and the durable backstop for a treadmill
    /// that survives relaunches stays the pass ceiling.
    private var futileStreaks: [String: Int] = [:]
    static let futileHoldThreshold = 3

    /// Projects the timer is currently refusing to groom, with their streaks —
    /// read by surfaces that answer "why is nothing being groomed for X".
    var groomingHeldProjects: [String: Int] {
        futileStreaks.filter { $0.value >= Self.futileHoldThreshold }
    }

    private func trackFutility(_ outcome: PassOutcome) {
        switch outcome {
        case .noDrafts(let project):
            bumpFutility(project)
        case .filed(let project, let ready, _, _):
            if ready > 0 { futileStreaks[project] = 0 } else { bumpFutility(project) }
        case .triaged(let project, _):
            // Recovering blocked work is productive grooming by another name.
            futileStreaks[project] = 0
        case .held, .abandoned, .disabled:
            // A hold or an abandonment is not evidence about the drafting.
            // Neither moves the streak.
            break
        }
    }

    private func bumpFutility(_ project: String) {
        let streak = (futileStreaks[project] ?? 0) + 1
        futileStreaks[project] = streak
        guard streak == Self.futileHoldThreshold else { return }
        refillLog.error("""
            Queue refill: grooming held for \(project) — \(streak) futile passes in a row. \
            Groom it by hand to resume.
            """)
        publish(project: project, payload: [
            "kind": "grooming-held",
            "project": project,
            "detail": "grooming held for \(project) after \(streak) futile passes"
        ])
    }

    /// - Parameter countsOn: which day this outcome's figures belong to, when
    ///   that is not the day `now` falls in. Only an abandonment passes one —
    ///   see `PassLedger.Entry.countsOn`.
    @discardableResult
    private func finish(_ outcome: PassOutcome, at now: Date = Date(),
                        countsOn: Date? = nil) -> PassOutcome {
        lastOutcome = outcome
        refillLog.info("Queue refill: \(outcome.summary)")
        guard outcome != .disabled else { return outcome }
        trackFutility(outcome)

        // Written down, then read back: `passHistory` is what the ledger says
        // about today rather than a list this process has been growing, so it
        // says the same thing after a relaunch as it did before one.
        record(PassLedger.Entry(at: now, event: .outcome, project: outcome.project,
                                outcome: outcome, countsOn: countsOn))

        var payload: [String: String] = [
            "kind": "refill-pass",
            "outcome": outcome.kind,
            "detail": outcome.summary
        ]
        if let project = outcome.project { payload["project"] = project }
        if let hold = outcome.hold {
            payload["hold"] = hold.kind
            payload["reason"] = hold.reason
        }
        publish(project: outcome.project, payload: payload)
        return outcome
    }

    /// Write one gated proposal: the backlog line, its `backlog/<id>.md`, the
    /// ledger entry and the event. The **only** path a filed item takes.
    ///
    /// Hands back the write's own verdict rather than a yes/no, so the pass can
    /// say which refusal it was rather than only counting it.
    @discardableResult
    private func fileDraft(_ proposal: Proposal,
                           entry: ControlSessionRegistry.Entry,
                           backlog: BacklogFile,
                           now: Date) -> BacklogViewModel.FilingOutcome {
        // Resolved once, and written to both halves of the filing: the line goes
        // under this section, so the detail file's `epic:` names it too. They
        // used to disagree — the line landing in the fallback while the file went
        // on naming the epic the drafter asked for — and nothing said so.
        let sectionName = section(for: proposal.draft, in: backlog)
        var draft = proposal.draft
        var notes = proposal.notes
        // And when the drafter named an epic this backlog hasn't got, say where
        // it went instead. A draft that named no epic keeps the silent fallback:
        // an unstated epic is not a mistake, and a note per item would be noise.
        if let asked = draft.epic, !asked.isEmpty, asked != sectionName {
            notes.append("epic `\(asked)` is not a section of this backlog — filed under `\(sectionName)`")
        }
        draft.epic = sectionName

        let outcome = entry.session.backlogViewModel.fileGroomedItem(
            sectionName: sectionName,
            id: draft.id,
            title: draft.title,
            size: ItemSize(rawValue: draft.size.uppercased()),
            verify: draft.lineVerify,
            status: proposal.status,
            from: draft.from,
            needs: draft.needs,
            detailMarkdown: draft.detailMarkdown(notes: notes)
        )
        guard outcome.didFile else {
            refillLog.error("""
                Queue refill: didn't file \(proposal.draft.id) for \(proposal.project) — \
                \(outcome.refusalReason ?? "")
                """)
            return outcome
        }

        record(project: proposal.project, id: proposal.draft.id, title: proposal.draft.title,
               disposition: proposal.status.rawValue, now: now)
        // Only past the guard: a write that didn't land leaves before here, so
        // the report counts items that exist. `ready` is the status that was
        // written, not what the draft hoped for — a gate-failed item parked at
        // `draft` is a filing the grooming got wrong.
        let projectPath = entry.session.project.rootURL.path(percentEncoded: false)
        groomingLedger.recordFiled(itemID: proposal.draft.id,
                                   projectPath: projectPath,
                                   projectName: proposal.project,
                                   ready: proposal.status == .ready,
                                   at: now)
        // And which gate parked it. The filing alone counts a draft; only this
        // says whether it was missing Validation or citing files that don't
        // exist, which is the difference between a report that can be acted on
        // and one that can only be read.
        for refusal in proposal.refusals {
            groomingLedger.recordCheckFailure(itemID: proposal.draft.id,
                                              projectPath: projectPath,
                                              projectName: proposal.project,
                                              check: refusal.check,
                                              reason: refusal.reason,
                                              at: now)
        }
        publishProposal(proposal, entry: entry)
        return .filed
    }

    /// Both halves of remembering: the in-memory ledger this pass reads and the
    /// JSONL that survives a relaunch.
    private func record(project: String, id: String, title: String,
                        disposition: String, now: Date) {
        ledger.record(project: project, id: id, title: title, disposition: disposition, at: now)
        QueueRefill.Ledger.append(
            QueueRefill.Ledger.Entry(at: now, project: project, itemID: id,
                                     fingerprint: QueueRefill.Ledger.fingerprint(title),
                                     disposition: disposition),
            to: ledgerURL)
    }

    // MARK: - Read the source

    /// Answer a question about one named project's **source**, read-only.
    ///
    /// The backlog answers most questions about a project and answers them for
    /// free — `ProjectInspection` is the cheap default and stays it. This is the
    /// exception, for what the backlog genuinely cannot reach: whether a file is
    /// still there, whether a symbol exists, what a test actually asserts. It
    /// spends a model call with tools, so it is asked for by name.
    ///
    /// Four things make it safe to hand a repository to:
    ///
    /// * **The project is resolved, not accepted.** `ProjectInspection.resolve`
    ///   matches an open project's own name or its path and nothing else, so a
    ///   name that missed comes back as a refusal naming the open ones rather
    ///   than as a confident answer about a project nobody asked about — and the
    ///   root read is that entry's, never a path a caller supplied.
    /// * **The grant carries no way to act.** `RepoRead` is three read verbs with
    ///   everything else denied by name; the Planner's acting path is the control
    ///   API and stays there.
    /// * **It is charged, and it is refused.** Reading draws on the same daily
    ///   pool grooming does, so a day spent on reading is a day that has stopped
    ///   grooming and vice versa. Only the *money* ceiling applies:
    ///   `maxPasses` bounds how often the loop wakes up to groom, which is no
    ///   business of a question somebody asked.
    /// * **The switch does not gate it.** Grooming off means the loop files
    ///   nothing unattended; it does not mean the operator may not ask a
    ///   question. Nor does a pass in flight — a read starts no pass, holds no
    ///   flag and files nothing.
    func answerFromSource(project name: String,
                          question: String,
                          now: Date = Date()) async -> RepoRead.Outcome {
        guard let registry, let globalConfigStore, let runtimeFactory else {
            return .unavailable("The Planner isn't wired into this window, so it has nothing to read with.")
        }
        let asked = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let open = registry.openProjects
        guard let entry = ProjectInspection.resolve(asked, in: open) else {
            let refusal = ProjectInspection.Outcome.unknownProject(
                name: asked,
                open: open.map { $0.session.project.rootURL.lastPathComponent }
            ).refusal
            return .unknownProject(refusal ?? "Couldn't look into “\(asked)”.")
        }

        // The ceiling as the pass sees it: the local counters rolled to today,
        // with the portfolio's shared number standing in for the cap when there
        // is one. Read before the call, so an exhausted day costs nothing.
        var ceiling = budget.rolled(to: now)
        if let shared = globalConfigStore.config.dailyBudgetUSD { ceiling.capUSD = shared }
        if let spent = ceiling.spendExhaustionReason {
            return .budgetExhausted(
                "\(spent) — reading \(entry.session.project.rootURL.lastPathComponent)'s source "
                    + "is refused until local midnight, or until the ceiling is raised."
            )
        }

        let grant = RepoRead.Grant(
            projectName: entry.session.project.rootURL.lastPathComponent,
            projectPath: entry.session.project.rootURL.path(percentEncoded: false)
        )
        let persona = CoordinatorAdvisor.composeSystemPrompt(
            agent: nil,  // built-in persona — the picker retired
            projectPersona: CoordinatorAdvisor.loadKiteloopFile(projectPath: grant.projectPath,
                                                                name: "coordinator-persona.md")
        ) + "\n\n" + RepoRead.contract(for: grant)

        let reply = try? await HeadlessAgentRunner.runDetailed(
            prompt: RepoRead.prompt(question: question, grant: grant),
            cwd: grant.root,
            systemPrompt: persona,
            agentName: "Coordinator",
            model: nil,
            access: grant,
            runtimeFactory: runtimeFactory,
            globalConfigStore: globalConfigStore
        )
        // Charged whatever came back, including nothing: the model ran either
        // way, and a budget that only counted useful answers would bound nothing
        // on the nights it mattered.
        let costUSD = reply?.costUSD ?? 0
        recordSpend(costUSD, now: now)

        let answer = RepoRead.bound(reply?.text ?? "")
        guard !answer.text.isEmpty else {
            return .noAnswer("The Planner read nothing back about \(grant.projectName) — "
                                + "the call came back empty. Nothing was looked at, so there is nothing to report.")
        }
        return .answered(project: grant.projectName, answer: answer, costUSD: costUSD)
    }

    // MARK: - Draft

    /// Ask the coordinator for candidates, grounded in the repo they concern.
    ///
    /// The ledger is applied twice, for two different reasons: it goes into the
    /// prompt so the drafter doesn't waste the call re-proposing a filled gap,
    /// and it filters the result because a prompt is a request, not a guarantee.
    /// The backlog itself is applied the same second way — the ledger knows only
    /// what the coordinator filed, and an item somebody wrote by hand is on the
    /// board just as much.
    ///
    /// The call is charged against the day's grooming budget, whatever came back
    /// — including a reply that turned out to be unusable, because the model ran
    /// either way. Without this the budget only ever counted conversation, and
    /// `capUSD` bounded nothing a pass did.
    ///
    /// What comes back is `Drafted` rather than `Draft`: accepting a candidate can
    /// rename it, and `QueueRefill.resolveDependencies` is what makes the pass's
    /// `needs:` ids survive that — and what has something to say when one of them
    /// named nothing at all.
    private func draft(target: QueueRefill.Target,
                       entry: ControlSessionRegistry.Entry,
                       backlog: BacklogFile,
                       root: URL,
                       globalConfigStore: GlobalConfigStore,
                       runtimeFactory: @escaping () -> any AgentRuntime,
                       now: Date) async -> [QueueRefill.Drafted] {
        let projectPath = root.path(percentEncoded: false)
        let persona = CoordinatorAdvisor.composeSystemPrompt(
            agent: nil,  // built-in persona — the picker retired
            projectPersona: CoordinatorAdvisor.loadKiteloopFile(projectPath: projectPath,
                                                                name: "coordinator-persona.md")
        ) + "\n\n" + Self.drafterContract

        // The checks' recent complaints, fed back so attempt two is attempt one
        // corrected rather than re-rolled. Without this the drafter never heard
        // why anything was refused — one project re-made the same grounding
        // mistakes 78 times in a night (2026-08-11). Deduped by reason: eight
        // copies of one complaint teach nothing six copies don't.
        var seenReasons = Set<String>()
        let recentRefusals = groomingLedger.records
            .filter { KiteloopProject.isSamePath($0.projectPath, projectPath) && $0.event == .checkFailed }
            .suffix(20)
            .compactMap { record -> String? in
                guard let reason = record.reason, seenReasons.insert(reason).inserted else { return nil }
                return "\(record.itemID) — \(record.check ?? "check"): \(reason)"
            }
            .suffix(8)

        let prompt = Self.buildPrompt(
            target: target,
            backlog: backlog,
            goal: entry.session.project.goal,
            alreadyGroomed: ledger.filedIDsInOrder(project: target.project),
            repoKnowledge: CoordinatorAdvisor.loadKiteloopFile(projectPath: projectPath,
                                                              name: "coordinator-knowledge.md"),
            recentRefusals: Array(recentRefusals)
        )

        let reply = try? await HeadlessAgentRunner.runDetailed(
            prompt: prompt,
            cwd: root,
            systemPrompt: persona,
            agentName: "Coordinator",
            model: nil,
            runtimeFactory: runtimeFactory,
            globalConfigStore: globalConfigStore
        )
        recordSpend(reply?.costUSD ?? 0, now: now)
        guard let response = reply?.text else { return [] }

        let existingItems = backlog.sections.flatMap(\.items)
        let backlogIDs = Set(existingItems.map(\.id))
        var taken = backlogIDs
            .union(ledger.filedIDs(project: target.project))
        var accepted: [QueueRefill.Draft] = []
        // What a collision cost each renamed candidate, so a sibling that named
        // the id the drafter wrote can be pointed at where that item actually
        // landed rather than at the item it collided with.
        var renamed: [String: String] = [:]
        for var candidate in QueueRefill.Draft.parse(response).prefix(target.count) {
            // The refusal that matters: a gap already filled for this project is
            // not filled again, however the drafter has reworded it.
            guard !ledger.hasFiled(project: target.project, id: candidate.id, title: candidate.title) else {
                refillLog.info("Queue refill: skipped already-groomed \(candidate.id) for \(target.project)")
                continue
            }
            // And the same refusal for an item the coordinator did *not* file.
            // The ledger above cannot see a hand-written item, and an id
            // collision alone is renamed rather than refused — so without this
            // a candidate the board already holds lands as `<id>-2` and buys a
            // full worker/reviewer run for work that is already there.
            if let existing = QueueRefill.Ledger.duplicate(of: candidate.title, in: existingItems) {
                refillLog.info("""
                    Queue refill: skipped \(candidate.id) "\(candidate.title)" for \(target.project) — \
                    already in the backlog as \(existing.id) "\(existing.title)"
                    """)
                continue
            }
            guard !accepted.contains(where: {
                QueueRefill.Ledger.fingerprint($0.title) == QueueRefill.Ledger.fingerprint(candidate.title)
            }) else { continue }
            let unique = QueueRefill.Draft.uniqueID(candidate.id, taken: taken)
            if unique != candidate.id { renamed[candidate.id] = unique }
            candidate.id = unique
            taken.insert(candidate.id)
            accepted.append(candidate)
        }
        // The backlog alone, not `taken`: the ledger's ids are what a *new* id
        // must not collide with, and not something a filed item can wait for —
        // a ledger entry may name an item a human has since deleted.
        return QueueRefill.resolveDependencies(accepted, renamed: renamed, existingIDs: backlogIDs)
    }

    // MARK: - Verify widening

    /// `drafted`, with its `verify:` widened by whatever commands the
    /// project's own verify map applies to *every* path, plus every
    /// tree-scoped rule whose glob matches a path the draft's `How` already
    /// cites — a groomed draft names no files for a rule that applies
    /// nowhere it mentions, but it does name the files its worker will
    /// touch, so a scoped rule matching one of them applies exactly as
    /// surely as an unconditional one does.
    ///
    /// A no-op, harmlessly, when `map` is empty (no verify map on disk) or
    /// the draft already runs everything it reaches — `widen` itself
    /// returns nil in both cases. A no-op too when `map` has a catch-all
    /// rule: the gate runs it on any diff, so the chain is not copied.
    private func widenVerify(_ drafted: QueueRefill.Drafted, map: VerifyCoverage.Map) -> QueueRefill.Drafted {
        guard !SignalDrafting.hasCatchAll(map) else { return drafted }
        let unconditional = map.rules.filter(VerifyCoverage.isUnconditional).map(\.command)
        let scoped = Self.scopedAdditions(citedIn: drafted.draft.how, map: map, excluding: unconditional)

        var commands = unconditional
        for addition in scoped where !commands.contains(addition.command) {
            commands.append(addition.command)
        }
        let missing = commands.filter { !VerifyCoverage.wasRun($0, in: [drafted.draft.verify]) }
        guard !missing.isEmpty,
              let widened = VerifyCoverage.widen(verify: drafted.draft.verify, adding: missing, map: map)
        else { return drafted }

        var draft = drafted.draft
        draft.verify = widened
        var notes = drafted.notes

        let missingUnconditional = missing.filter { unconditional.contains($0) }
        if !missingUnconditional.isEmpty {
            notes.append("verify: widened with " + missingUnconditional.map { "`\($0)`" }.joined(separator: ", ")
                         + " — the project's verify map applies " + (missingUnconditional.count == 1 ? "it" : "them")
                         + " to every path, and the drafted verify never ran "
                         + (missingUnconditional.count == 1 ? "it" : "them") + ".")
        }
        for addition in scoped where missing.contains(addition.command) {
            notes.append("verify: widened with `\(addition.command)` — the draft's How names "
                         + "`\(addition.path)`, which the project's verify map holds to `\(addition.command)`.")
        }
        return QueueRefill.Drafted(draft: draft, notes: notes)
    }

    /// The scoped verify-map rules a draft's `How` already reaches: every
    /// backticked, path-shaped span in the prose — read the same way
    /// `GroundingCheck` reads a citation, so a placeholder or an interpolated
    /// expression is not mistaken for a real path — matched against each rule
    /// `excluding` does not already cover, in map order, the first cited path
    /// that matches paired with the command its glob names. A rule whose glob
    /// no cited path matches is left out entirely.
    private static func scopedAdditions(
        citedIn how: String, map: VerifyCoverage.Map, excluding unconditional: [String]
    ) -> [(command: String, path: String)] {
        let citedPaths = GroundingCheck.backtickedSpans(in: how)
            .compactMap { GroundingCheck.classify($0.text) }
            .filter { $0.kind == .path }
            .map { normalizedCitedPath($0.text) }
        guard !citedPaths.isEmpty else { return [] }

        var seenCommands = Set(unconditional)
        var additions: [(command: String, path: String)] = []
        for rule in map.rules where !VerifyCoverage.isUnconditional(rule) {
            guard !seenCommands.contains(rule.command) else { continue }
            guard let path = citedPaths.first(where: { VerifyCoverage.matches(glob: rule.glob, path: $0) })
            else { continue }
            seenCommands.insert(rule.command)
            additions.append((rule.command, path))
        }
        return additions
    }

    /// Repo-relative, the way `VerifyCoverage` compares a changed file: a
    /// citation may carry a leading `./` or `/` without meaning a different
    /// file.
    private static func normalizedCitedPath(_ path: String) -> String {
        var text = path
        while text.hasPrefix("./") { text.removeFirst(2) }
        while text.hasPrefix("/") { text.removeFirst() }
        return text
    }

    // MARK: - Gate

    private struct Gated {
        let draft: QueueRefill.Draft
        let status: BacklogItemStatus
        let notes: [String]
        let refusals: [Refusal]
    }

    /// The same two gates a human-groomed item faces, run *before* the item is
    /// written rather than at pickup. A draft that fails either still lands — as
    /// `draft`, with the reason in its Notes — because an idea worth a model call
    /// is worth a human glancing at, and a `draft` item is one autopilot will
    /// never pick up.
    ///
    /// It is the **refusals** that park an item, not the notes. Grooming has
    /// things to say that aren't refusals — a `needs:` id that named nothing was
    /// dropped rather than written — and an item is not made unrunnable by
    /// something already fixed on its way here.
    private func gate(_ drafted: QueueRefill.Drafted, sources: GroundingCheck.Sources,
                      mapCoversEveryPath: Bool) -> Gated {
        let draft = drafted.draft
        var notes = drafted.notes
        var refusals: [Refusal] = []
        let item = draft.item(status: .ready)
        let detail = draft.detail

        let readiness = DefinitionOfReady.evaluate(item: item, detail: detail,
                                                   verifyMapCoversEveryPath: mapCoversEveryPath)
        if !readiness.isReady {
            notes.append("self-check failed: \(readiness.summary)")
            refusals.append(Refusal(check: GroomingRecord.Check.definitionOfReady,
                                    reason: readiness.summary))
        }

        let grounding = GroundingCheck.evaluate(item: item, detail: detail, sources: sources)
        if !grounding.isGrounded {
            notes.append("grounding check failed: \(grounding.summary)")
            refusals.append(Refusal(check: GroomingRecord.Check.grounding,
                                    reason: grounding.summary))
        }

        // A draft may *propose* a protected-path exemption; it may not grant
        // itself one. `touches:` is what excused an item from protected paths,
        // so a drafter free to write it would be an agent handing an agent the
        // permission a gate exists to withhold — and the drafter reads the repo,
        // so it will learn the token from the docs that describe it.
        //
        // Parked rather than stripped: an item that genuinely needs to write an
        // instrument file is real work, and deleting the token would file it as
        // `ready` to fail at the gate later with the declaration silently gone.
        // As a `draft` it waits for the human whose decision this is.
        if !item.touches.isEmpty {
            let claimed = item.touches.joined(separator: ", ")
            notes.append("claims a protected-path exemption (touches: \(claimed)) — "
                         + "promote it by hand if that is right")
            refusals.append(Refusal(check: GroomingRecord.Check.protectedPathClaim,
                                    reason: "drafted with touches: \(claimed)"))
        }

        return Gated(draft: draft,
                     status: refusals.isEmpty ? .ready : .draft,
                     notes: notes,
                     refusals: refusals)
    }

    /// Where a drafted item goes: the epic it named when that epic exists, the
    /// backlog's first section otherwise. Inventing an epic per item would turn
    /// a groomed backlog into a pile of one-item sections.
    private func section(for draft: QueueRefill.Draft, in backlog: BacklogFile) -> String {
        if let epic = draft.epic, backlog.sections.contains(where: { $0.name == epic }) { return epic }
        return backlog.sections.first?.name ?? "Now"
    }

    // MARK: - Surfacing

    private func publishProposal(_ proposal: Proposal, entry: ControlSessionRegistry.Entry) {
        var payload: [String: String] = [
            "kind": "refill-filed",
            "project": proposal.project,
            "item": proposal.draft.id,
            "title": proposal.draft.title,
            "status": proposal.status.rawValue
        ]
        if !proposal.notes.isEmpty { payload["gates"] = proposal.notes.joined(separator: "; ") }
        entry.session.orchestrator.publishEvent(
            KiteloopEvent(source: "Coordinator", type: .custom, payload: payload))
    }

    private func publish(project: String?, payload: [String: String]) {
        guard let orchestrator = project.flatMap({ registry?.entry(forProject: $0)?.session.orchestrator })
            ?? registry?.openProjects.first?.session.orchestrator else { return }
        orchestrator.publishEvent(KiteloopEvent(source: "Coordinator", type: .custom, payload: payload))
    }

    // MARK: - Prompt

    /// What the drafter must return. Not replaceable by a persona: `Draft.parse`
    /// depends on the shape, and a persona that dropped it would degrade the
    /// loop to silently drafting nothing.
    static let drafterContract = """
    Your job right now is GROOMING, not supervising a run: the project's ready
    queue is running dry and you are writing the next few items for it.

    Ground every item in the repository you are in. READ the code the item
    concerns before you describe it — open the files, check the symbols and paths
    you are about to name. An item written from a guess costs a whole run to
    discover it was wrong.

    Each item must satisfy Kiteloop's Definition-of-Ready or it will be parked as
    a draft rather than queued:
      - What: the outcome — what exists or behaves differently when it's done.
      - How: the approach — real files, real symbols, as they are in this repo.
      - Validation: observable acceptance criteria, at least one.
      - verify: ONE shell command that must pass. It has to be a command this
        repo can actually run.
      - size: XS, S or M. Anything larger is not autopilot work — split it.
      - outOfScope: what a well-meaning agent might do here but shouldn't.

    Where an item came from is worth writing down. If you are splitting an
    existing item, or turning one that failed into new work, set "from" to that
    item's id exactly as the backlog spells it. It records lineage and nothing
    else — it never blocks the item or changes when it runs — so leave it out
    for a gap you found in the code rather than in another item.

    When one item can only be built after another, say so with "needs": the ids
    it has to wait for, spelled exactly as the backlog spells them. Unlike "from"
    this one is read: the item is withheld at pickup until every id it names is
    done, so two pieces you split in order are run in that order instead of both
    at once. State it only for a real prerequisite — an item that waits for
    something it does not depend on just sits in the queue.

    Only backtick a path or symbol that is ALREADY in the repo. Something the item
    proposes to create should be described as being added ("add a `Foo` service"),
    not asserted to exist.

    Propose work that is genuinely worth doing next — a real gap, bug or rough
    edge you found in the code. Do not pad to the requested count: fewer good
    items beat more plausible ones.

    Respond with ONE JSON object only — no prose, no code fences:
    {"items":[{"id":"kebab-case-id","title":"one line","size":"XS|S|M",
               "verify":"<shell command>","what":"...","how":"...",
               "validation":["...","..."],"outOfScope":["..."],"epic":"<existing epic or empty>",
               "from":"<id of the item this came out of, or empty>",
               "needs":["<id this item must wait for>"]}]}
    """

    /// The grooming prompt: how empty the queue is, what the project is for, what
    /// it already has, and what has already been groomed for it.
    static func buildPrompt(target: QueueRefill.Target,
                            backlog: BacklogFile,
                            goal: String?,
                            alreadyGroomed: [String],
                            repoKnowledge: String?,
                            recentRefusals: [String] = []) -> String {
        var p = ""
        if let repoKnowledge, !repoKnowledge.isEmpty {
            p += "## What you've learned about this repo\n\(repoKnowledge)\n\n"
        }
        p += "## Why you're grooming\n"
        if let startable = target.startableCount, startable != target.readyCount {
            p += "\(target.project) has \(target.readyCount) ready item(s), but only \(startable) "
                + "of them could actually start — below the threshold. "
        } else {
            p += "\(target.project) has \(target.readyCount) ready item(s) — below the threshold. "
        }
        p += "Write \(target.count) item(s) to top the queue back up. Stop at \(target.count).\n"
        if let goal, !goal.isEmpty {
            p += "\nProject goal: \(PortfolioSnapshot.statementLine(goal))\n"
        }

        p += "\n## Epics in this backlog\n"
        let epics = backlog.sections.map(\.name)
        p += epics.isEmpty ? "(none — the backlog has no sections)\n" : epics.map { "- \($0)" }.joined(separator: "\n") + "\n"

        let open = backlog.sections.flatMap(\.items).filter { $0.status != .done }
        if !open.isEmpty {
            p += "\n## Already in the backlog — do not duplicate these\n"
            // Every open item, not a window. A duplicate of one the prompt hid
            // is now refused downstream (`Ledger.duplicate(of:in:)`), but a
            // refused candidate is a wasted slot: the pass files fewer items
            // than it was asked for, and the drafter never learns why. Showing
            // the whole board is what keeps the refusal a backstop rather than
            // the mechanism.
            p += open.map { "- \($0.id) [\($0.status.rawValue)] \($0.title)" }.joined(separator: "\n") + "\n"
        }
        if !alreadyGroomed.isEmpty {
            p += "\n## Already groomed by you for this project — never propose these again\n"
            p += alreadyGroomed.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        if !recentRefusals.isEmpty {
            p += "\n## Recently refused by the machine checks — each reason is a correction\n"
            p += "These drafts or items failed a check. Do not repeat these mistakes; "
            p += "if you revisit one of these gaps, fix what the check named.\n"
            p += recentRefusals.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        return p
    }
}

// MARK: - The day's figures, on disk

extension CoordinatorQueueRefill {

    /// Every event that moved the day's grooming figures, written down.
    ///
    /// The day's budget and the pass history used to live only in properties:
    /// `passHistory` started empty and `budget` was assigned once in the
    /// initialiser and thereafter only mutated. So a relaunch put `passesUsed`,
    /// `spentUSD` and `abandonedPasses` back to zero and emptied the history,
    /// and both consequences were seen on 2026-08-21. **The ceiling stopped
    /// being a ceiling**: `maxPasses` is 12 a day, and an app restarted three
    /// times got 12 passes each time, with nothing in the app able to say so
    /// because the counter it would say it with was the one that reset. **The
    /// panel misreported**: the Planner card read `0 of 12 passes` at a moment
    /// when 37 items had been filed that day — not idle, just forgotten.
    ///
    /// `RetryCeiling` had exactly this bug and its own documentation is the
    /// argument: *counted from recorded history, not from memory … an in-memory
    /// counter cannot do that, which is how the existing one was defeated.* This
    /// is that reasoning carried across to the grooming budget.
    ///
    /// What it is *not* is a second budget. `QueueRefill.Budget` is still the
    /// value type, still the thing every reader reads and every ceiling is
    /// stated against; `budget(on:ceilings:)` replays a day's entries through
    /// `Budget`'s own `charged` and `abandonedAPass` rather than re-deriving
    /// what they mean. Only where the numbers come from changed.
    struct PassLedger: Sendable, Equatable {

        /// One thing that happened to the day's figures.
        ///
        /// Three events rather than one row per pass, because a pass is not one
        /// moment: it is charged against the ceiling before the model is called,
        /// spends whatever its calls cost while it runs, and ends — possibly
        /// several times over, once per project it served. A single row could
        /// only be written at one of those instants and would lose the others.
        struct Entry: Codable, Sendable, Equatable {

            enum Event: String, Codable, Sendable {
                /// A pass started, and was charged against `maxPasses`. Written
                /// before the drafter is called, so a crash mid-pass still costs
                /// a pass rather than repeating for free.
                case passStarted
                /// Grooming spent money. Not always inside a pass — a source
                /// read (`answerFromSource`) draws on the same day's pool.
                case spend
                /// A pass ended, with what it did. What `passHistory` is made of,
                /// and — for an `abandoned` outcome — what `abandonedPasses`
                /// counts.
                case outcome
            }

            let at: Date
            let event: Event
            /// The project, when the entry names one.
            var project: String?
            /// What it cost. Zero for everything but `.spend`.
            var costUSD: Double = 0
            /// The outcome, whole, on an `.outcome` entry — see `PassOutcome`
            /// on why it is written whole rather than as its tag.
            var outcome: PassOutcome?
            /// The day these figures count towards, when that is **not** the day
            /// `at` falls in. Nil for every entry but one.
            ///
            /// The one is an abandonment. It is stamped with the deadline the
            /// pass outlived, which sits a little ahead of the clock and, late
            /// enough in the evening, in the next day — and
            /// `Budget.abandonedAPass()` pointedly does not roll the day for
            /// exactly that reason. Counting the abandonment against tomorrow
            /// would be that same mistake made on the way back off disk, so the
            /// day it belongs to is written down beside the instant it happened
            /// rather than inferred from it.
            var countsOn: Date?

            /// The instant this entry's figures are counted against — `at`
            /// unless something said otherwise.
            var accountedAt: Date { countsOn ?? at }
        }

        /// Oldest first, the order they were written and the order they are
        /// replayed in.
        private(set) var entries: [Entry]

        init(entries: [Entry] = []) {
            self.entries = entries
        }

        mutating func append(_ entry: Entry) {
            entries.append(entry)
        }

        // MARK: Reading the day

        /// The day's recorded figures, added to `opening`.
        ///
        /// `opening` supplies the ceilings, which are settings rather than
        /// history — `capUSD` is portfolio state the config store holds and
        /// `maxPasses` is persisted as `coordinatorMaxPassesPerDay`, so neither is
        /// a thing a pass records — and whatever figures the caller opened the day with, which
        /// is zero in the app. It is rolled first, so an opening balance from a
        /// day that has since ended contributes nothing.
        ///
        /// What the ledger decides is `spentUSD`, `passes` and
        /// `abandonedPasses`, counted over the local day `now` falls in — the
        /// same boundary `Budget.rolled(to:)` uses. Read against a different
        /// calendar the two would disagree about when the day started, so both
        /// take `Calendar.current`.
        func budget(on now: Date, startingFrom opening: QueueRefill.Budget,
                    calendar: Calendar = .current) -> QueueRefill.Budget {
            var budget = opening.rolled(to: now, calendar: calendar)
            for entry in entries where calendar.isDate(entry.accountedAt, inSameDayAs: now) {
                switch entry.event {
                // `Budget.charged` split in two, because the ledger already
                // separates them: a pass is charged when it starts and spends
                // what its calls cost while it runs, so the pass half and the
                // cost half arrive as different entries. Its third half — the
                // roll — happened above, once, and is deliberately not repeated
                // per entry: `charged` would redo it against `Calendar.current`
                // rather than the calendar this read was asked for.
                case .passStarted: budget.passes += 1
                case .spend: budget.spentUSD += max(0, entry.costUSD)
                // Through the budget's own method, which is where "counted
                // beside `passes`, never inside them" is stated — and which
                // pointedly does not roll the day, for the reason
                // `Entry.countsOn` exists.
                case .outcome:
                    if case .abandoned = entry.outcome { budget = budget.abandonedAPass() }
                }
            }
            return budget
        }

        /// The day's passes, oldest first — what `passHistory` is rebuilt from.
        ///
        /// Scoped to the day for the same reason the budget is: the panel shows
        /// the figures and the history side by side, and a history reaching back
        /// past a boundary the counters beside it had already crossed would be
        /// two answers to one question. Bounded by `maxPassHistory`, which is
        /// what it has always been bounded by.
        func passRecords(on now: Date, calendar: Calendar = .current) -> [PassRecord] {
            let today = entries.compactMap { entry -> PassRecord? in
                guard entry.event == .outcome, let outcome = entry.outcome,
                      calendar.isDate(entry.accountedAt, inSameDayAs: now) else { return nil }
                return PassRecord(at: entry.at, outcome: outcome)
            }
            return Array(today.suffix(CoordinatorQueueRefill.maxPassHistory))
        }

        // MARK: Persistence

        /// Append-only JSONL beside the coordinator's other records.
        static func defaultURL(home: URL = KiteloopHome.url) -> URL {
            home.appending(path: ".kiteloop").appending(path: "coordinator-passes.jsonl")
        }

        /// Where the pass ledger sits given where the refill ledger sits: next
        /// to it, under the same name it would have in `~/.kiteloop`.
        ///
        /// A default rather than a required argument on purpose. Both files
        /// belong to the same loop, so a caller that has already said where one
        /// goes has said where the other goes — and a test that pointed the
        /// refill ledger at a temp directory and was silently left writing this
        /// one into the developer's own `~/.kiteloop` is not hypothetical: it is
        /// what happened to `CoordinatorBlockedTriage`'s ledger, which every
        /// test missed until real records about a project living in a temp
        /// folder turned up in the real file.
        static func url(besideLedgerAt url: URL) -> URL {
            url.deletingLastPathComponent().appending(path: defaultURL().lastPathComponent)
        }

        /// How long an entry is kept. The figures that matter are today's, and
        /// a month is what the coordinator's other records keep — enough to read
        /// back a stretch of unattended nights, bounded so a file nothing ever
        /// reads the far end of doesn't grow for ever.
        static let retentionAge: TimeInterval = 30 * 24 * 60 * 60

        /// Reads what's there, dropping entries past `retentionAge`.
        ///
        /// A line that doesn't decode is skipped rather than failing the load:
        /// a half-written record — or one written by a version that knew an
        /// outcome this one doesn't — must not cost the whole day's figures. A
        /// ledger that is missing, empty or entirely unreadable loads as an
        /// empty one, which reads as a day that has groomed nothing: the app
        /// stays groomable, and the ceilings bound it from zero.
        ///
        /// The lines nobody could decode come back too, so a rewrite can put
        /// them where it found them: compaction is what would otherwise erase
        /// them, on the very launch that failed to read them — the same choice
        /// `CoordinatorRunScheduler` makes for `coordinator-starts.jsonl`.
        /// `needsRewrite` says whether anything was *dropped*, so the caller can
        /// put the kept entries back over the file and make the trim real rather
        /// than only in memory.
        ///
        /// Split on the newline byte rather than on a string of the whole file:
        /// a kill that cuts a line inside a multi-byte character leaves the file
        /// invalid UTF-8, and a whole-file string read would then load an empty
        /// day — and hand `rewrite` no lines to put back. Such a line is kept as
        /// lossy text, the way `NotificationStore` keeps one.
        static func load(from url: URL, now: Date = Date())
            -> (ledger: PassLedger, undecodable: [String], needsRewrite: Bool) {
            guard let data = try? Data(contentsOf: url) else {
                return (PassLedger(), [], false)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var entries: [Entry] = []
            var undecodable: [String] = []
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard let entry = try? decoder.decode(Entry.self, from: Data(line)) else {
                    undecodable.append(String(decoding: line, as: UTF8.self))
                    continue
                }
                entries.append(entry)
            }
            let cutoff = now.addingTimeInterval(-retentionAge)
            let kept = entries.filter { $0.accountedAt >= cutoff }
            return (PassLedger(entries: kept), undecodable, kept.count != entries.count)
        }

        /// One line of the file, newline included — the single place its shape
        /// is decided, so a line `rewrite` writes is the line `append` would
        /// have written for the same entry.
        private static func encode(_ entry: Entry) -> String? {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(entry),
                  let line = String(data: data, encoding: .utf8) else { return nil }
            return line + "\n"
        }

        /// Append one entry. Best-effort: a night's grooming must not fail
        /// because a record couldn't be written.
        ///
        /// Through `AtomicFileWriter.append`, which makes the directory when it
        /// is missing and starts a new line first when the file doesn't end in
        /// one — a plain seek-to-end writes this entry onto the remnant of one a
        /// kill cut short, and the pair decodes as neither, so a pass the day was
        /// charged for goes missing from the only record of it.
        static func append(_ entry: Entry, to url: URL) {
            guard let line = encode(entry) else { return }
            try? AtomicFileWriter.append(Data(line.utf8), to: url)
        }

        /// Write the kept entries back over the file, atomically — what bounds
        /// it rather than only what is read from it. Best-effort, for the same
        /// reason `append` is. The lines nobody could decode go back at the end,
        /// verbatim: they are already in the file, and deleting them is the one
        /// thing that can't be undone.
        static func rewrite(_ ledger: PassLedger, undecodable: [String], to url: URL) {
            let body = ledger.entries.compactMap(encode).joined()
                + undecodable.map { $0 + "\n" }.joined()
            try? AtomicFileWriter.write(Data(body.utf8), to: url)
        }
    }
}
