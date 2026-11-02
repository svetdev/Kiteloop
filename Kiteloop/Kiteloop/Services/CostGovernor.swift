import Foundation
import KiteloopCore

/// Everything the autopilot knows about money: what an item is predicted to cost,
/// what it is therefore allowed to spend, what the item in flight and the session
/// have spent, and when a ceiling has been crossed.
///
/// Lifted out of `BacklogAutopilot` because these are the decisions that end a
/// legitimate run early when they're wrong, and they were only reachable through
/// a live run loop. Here they're a value: construct one, feed it spend, ask it
/// what it thinks. `AutopilotCostBudget` stays the pure cap arithmetic
/// underneath; the governor adds the prediction chain, the session bookkeeping
/// and the wording the log and panel show.
///
/// The prediction-reading members are `@MainActor` because `TaskMetricStore` is;
/// the arithmetic and the formatting are not, so views and parsers can use them
/// off the run loop.
struct CostGovernor {

    // MARK: - Configuration

    /// The session cap, plus what the session has spent (see
    /// `AutopilotCostBudget`).
    var budget = AutopilotCostBudget()
    /// The per-item ceiling this project's landed runs imply — no longer a
    /// setting, but read off the ledger beside the run deadlines
    /// (`RunTimeouts`). Each item's prediction is folded in at `beginItem`.
    var itemCostBound = RunTimeouts.Deadlines.defaults.itemCost

    /// Where predictions come from: this item's past runs, its stored estimate,
    /// and the size-class average. Nil = nothing to predict from, so every item
    /// gets the flat cap.
    var metricStore: TaskMetricStore?
    /// Scopes every rung of the prediction chain to this project — a size class
    /// averaged across unrelated projects predicts nothing useful about this
    /// one, and neither do another project's runs of an item that happens to
    /// share an id. Nil = nothing to scope to, so the reading stays
    /// portfolio-wide.
    var projectPath: String?

    // MARK: - Live session state

    /// What the item in flight has spent. Fed by the run watchdog's samples
    /// (`sample(itemSpendUSD:)`), 0 between items.
    private(set) var currentItemSpendUSD: Double = 0
    /// The effective ceiling for the item in flight, so the panel can show the
    /// number the run is measured against rather than the flat cap in settings.
    /// Nil between items, or when uncapped.
    private(set) var currentItemCapUSD: Double?
    /// The forecast the item in flight was started on, held so the run can
    /// record it beside what the item actually cost. Read once at `beginItem`:
    /// re-deriving it at the end would ask the store a question whose answer the
    /// run itself has since changed. Nil between items, or when nothing was
    /// predicted.
    private(set) var currentItemPrediction: Prediction?
    /// Set when a sample pushed the *session* past its cap, so the run loop
    /// pauses once the item unwinds instead of starting the next one.
    private(set) var sessionCapBreached = false
    /// Set the first time a sample crosses `Readout.warnThreshold` of the item
    /// in flight's effective cap, so `nearCapWarning` fires once per item
    /// rather than on every sample that stays above the threshold. Cleared at
    /// the item boundary alongside the other in-flight figures.
    private var itemNearCapWarned = false

    /// Convenience passthrough — the session cap is configuration the
    /// autopilot persists, so it's addressed by name rather than through
    /// `budget`.
    var sessionCapUSD: Double? {
        get { budget.sessionCapUSD }
        set { budget.sessionCapUSD = newValue }
    }
    /// What the items this session has already finished cost — every run of it,
    /// since the app started or since a resume opened a new one. The item in
    /// flight is counted separately until it's charged here — see `readout`.
    var spentThisSession: Double { budget.spentThisSession }

    // MARK: - Prediction

    /// Which rung of `predictedCost`'s precedence chain produced a prediction.
    /// Logged with the effective cap so an unexpected ceiling can be traced back
    /// to the data that set it.
    enum PredictionSource: String, Sendable {
        case ownHistory = "own history"
        case storedEstimate = "stored estimate"
        /// The size's measured p50 — see `SizeCalibration`. Replaced a mean over
        /// every record of that size, which counted the runs that cost $0 or
        /// changed no file and so predicted the pipeline's failures as much as
        /// the work.
        case sizeBand = "size band p50"
    }

    /// A predicted cost and the rung it came from.
    struct Prediction: Equatable, Sendable {
        var usd: Double
        var source: PredictionSource
    }

    /// How many of an item's own recent runs are averaged. Enough to smooth a
    /// single freak run, short enough that a change in the item's shape shows up.
    nonisolated static let ownHistoryWindow = 3

    /// Predicted per-item cost, most-specific first: the item's OWN recent
    /// actuals (most accurate — captures items pricier than their size class,
    /// like sync-dedup-guard), then a stored estimate, then the measured p50 of
    /// its size class. Using the item's own history keeps the cost cap from
    /// firing on legitimate work whose cost a stale/size-based estimate
    /// under-predicts.
    ///
    /// The last rung is the calibrated band rather than a flat constant, so a
    /// size's ceiling tracks what work of that size actually costs. Below
    /// `SizeCalibration.minimumSamples` there is deliberately **no** prediction:
    /// the caller keeps its fixed cap, which is a better answer than a confident
    /// number derived from three runs.
    ///
    /// All three rungs read only `projectPath`'s own history. An item id is
    /// unique inside a backlog, not across the machine, so without that scope a
    /// second project's runs of the same id would set this project's ceiling.
    @MainActor
    func predictedCost(for item: BacklogItem) -> Prediction? {
        guard let store = metricStore else { return nil }
        // 1. This item's own recent runs — the accurate, per-item signal.
        let ownRuns = projectPath.map { store.actuals(itemID: item.id, projectPath: $0) }
            ?? store.records.filter { $0.itemID == item.id }
        let ownCosts = ownRuns
            .filter { $0.costUSD > 0 }
            .suffix(Self.ownHistoryWindow)
            .map(\.costUSD)
        if !ownCosts.isEmpty {
            return Prediction(usd: ownCosts.reduce(0, +) / Double(ownCosts.count), source: .ownHistory)
        }
        // 2. A stored estimate.
        let stored: TaskEstimate? = projectPath.map { store.latestEstimate(itemID: item.id, projectPath: $0) }
            ?? store.latestEstimate(itemID: item.id)
        if let estimate = stored?.predictedCostUSD, estimate > 0 {
            return Prediction(usd: estimate, source: .storedEstimate)
        }
        // 3. The size's measured middle.
        if let band = sizeBand(for: item), band.costUSD.p50 > 0 {
            return Prediction(usd: band.costUSD.p50, source: .sizeBand)
        }
        return nil
    }

    /// `predictedCost` without the provenance.
    @MainActor
    func predictedCostUSD(for item: BacklogItem) -> Double? { predictedCost(for: item)?.usd }

    // MARK: - Does the label match the work?

    /// What this project's history says about the item's size class, or nil when
    /// the item has no size, there's no project to scope to, or the size has too
    /// little evidence to be measured yet.
    @MainActor
    func sizeBand(for item: BacklogItem) -> SizeCalibration.Band? {
        guard let store = metricStore, let size = item.size?.rawValue, let path = projectPath else {
            return nil
        }
        return store.sizeBand(forSize: size, projectPath: path)
    }

    /// The pickup check: an item whose predicted cost lands outside its size's
    /// measured band, or nil when it lands inside one (or there is no band).
    ///
    /// Advisory by design — this flags, it does not refuse. The point is to say
    /// "this looks like an M wearing an S label" at the cheap moment, before a
    /// run spends an hour against the wrong ceiling.
    @MainActor
    func sizeFlag(for item: BacklogItem) -> SizeCalibration.Flag? {
        guard let prediction = predictedCost(for: item) else { return nil }
        return SizeCalibration.flag(predictedCostUSD: prediction.usd, band: sizeBand(for: item))
    }

    // MARK: - The per-item ceiling

    /// This item's ceiling: this project's p95 run cost plus half again, never
    /// below the item's own prediction, once enough runs have landed to
    /// measure it; the prediction plus the same half again before then — see
    /// `RunTimeouts.CostBound`. Nil = uncapped.
    @MainActor
    func effectiveItemCap(for item: BacklogItem) -> Double? {
        itemCostBound.itemCapUSD(predicted: predictedCostUSD(for: item))
    }

    /// The one-line budget statement logged before each item runs: what this item
    /// is allowed to spend and which input set that number. Without it a run that
    /// ends on "cost cap" gives no way to tell whether the project's runs or a
    /// stale prediction was the binding constraint.
    @MainActor
    func capLogLine(for item: BacklogItem) -> String {
        let prediction = predictedCost(for: item)
        guard let cap = itemCostBound.itemCapUSD(predicted: prediction?.usd) else {
            return "Cost cap: none (too few landed runs and no cost prediction)"
        }
        let predicted = prediction.map { String(format: "%@ $%.2f", $0.source.rawValue, $0.usd) }
        guard let measured = itemCostBound.usd else {
            return String(format: "Cost cap: $%.2f (%@ × %g headroom)", cap, predicted ?? "", RunTimeouts.headroom)
        }
        // A measured cap is max(project p95 × headroom, predicted) — name the winner.
        if let predicted, cap > measured {
            return String(format: "Cost cap: $%.2f (%@ above the project's runs)", cap, predicted)
        }
        return String(format: "Cost cap: $%.2f (project p95 run cost × %g headroom)", cap, RunTimeouts.headroom)
    }

    // MARK: - Session lifecycle

    /// Clears what belongs to one run: the item in flight and everything derived
    /// from it. Called when a run starts.
    ///
    /// The session ledger deliberately survives. It used to be zeroed here, which
    /// was right when a run meant a queue of items — but every driver the app has
    /// (the scheduler, the marathon harness, the control API) starts **one item
    /// per run**, so zeroing made each item its own session: the panel's Session
    /// figure always equalled the Item figure, and the session cap — the one that
    /// stops the queue rather than recording an overrun — bounded a single item
    /// instead of the operator's sitting. A session is now the app instance's,
    /// and `startSession` is the only thing that opens a fresh one.
    mutating func startRun() {
        currentItemSpendUSD = 0
        currentItemCapUSD = nil
        currentItemPrediction = nil
        itemNearCapWarned = false
    }

    /// Opens a fresh session ledger — the session's spend, and everything derived
    /// from it, back to zero.
    ///
    /// The boundary is a person, not a clock or a run: resuming a queue the
    /// session cap paused is someone saying "keep going", and that is what starts
    /// the next sitting. Nothing else calls this, which is what keeps the cap
    /// bounding a night's work rather than a single item.
    mutating func startSession() {
        budget.spentThisSession = 0
        sessionCapBreached = false
        startRun()
    }

    /// Fixes the ceiling this item will be measured against, and returns it so
    /// the caller can log it. Nil = uncapped.
    @MainActor
    @discardableResult
    mutating func beginItem(_ item: BacklogItem) -> Double? {
        currentItemPrediction = predictedCost(for: item)
        currentItemCapUSD = itemCostBound.itemCapUSD(predicted: currentItemPrediction?.usd)
        return currentItemCapUSD
    }

    /// Charges a finished item to the session and clears it from the in-flight
    /// figure the same instant — the readout adds the two, so leaving it would
    /// count the item's cost twice for as long as the caller's remaining awaits
    /// take.
    mutating func chargeItem(_ costUSD: Double) {
        budget.spentThisSession += costUSD
        currentItemSpendUSD = 0
    }

    /// Drops the in-flight item. However it ended, its spend has been charged to
    /// the session by now, so this covers the early exits (a cost-cap pause, the
    /// circuit breaker) as well as the normal path.
    mutating func endItem() {
        currentItemSpendUSD = 0
        currentItemCapUSD = nil
        currentItemPrediction = nil
        itemNearCapWarned = false
    }

    // MARK: - Breaches

    /// Records a live spend sample for the item in flight and reports whether it
    /// crossed a ceiling. A session breach is remembered as well as returned:
    /// the run loop ends this item on it, then `takeSessionPause` stops the rest
    /// of the queue.
    mutating func sample(itemSpendUSD spent: Double) -> AutopilotCostBudget.Breach? {
        currentItemSpendUSD = spent
        guard let breach = budget.breach(itemSpend: spent, itemCap: currentItemCapUSD) else { return nil }
        if case .session = breach { sessionCapBreached = true }
        return breach
    }

    /// The first warning shy of the cap: the item in flight's spend and the
    /// ceiling it's approaching, the first time a sample crosses
    /// `Readout.warnThreshold` of `currentItemCapUSD`.
    struct NearCapWarning: Equatable, Sendable {
        var capUSD: Double
        var spentUSD: Double

        var utilizationPercent: Int { Int((spentUSD / capUSD * 100).rounded()) }
        var logLine: String {
            String(format: "%d%% of cost cap $%.2f spent ($%.2f)", utilizationPercent, capUSD, spentUSD)
        }
    }

    /// Checked alongside `sample`, against the same spend and the same
    /// `currentItemCapUSD` it reads — so the warning and the cap it warns about
    /// can't drift apart. Fires once per item: nil when uncapped, still below
    /// the threshold, or already warned this item. Doesn't touch
    /// `currentItemSpendUSD` itself; call `sample` for that.
    mutating func nearCapWarning(itemSpendUSD spent: Double) -> NearCapWarning? {
        guard !itemNearCapWarned,
              let cap = currentItemCapUSD, cap > 0,
              spent / cap >= Readout.warnThreshold
        else { return nil }
        itemNearCapWarned = true
        return NearCapWarning(capUSD: cap, spentUSD: spent)
    }

    /// How a breach reads in the log and in the `workflowFailed` event — the two
    /// ceilings say different things because they have different consequences.
    nonisolated static func breachReason(_ breach: AutopilotCostBudget.Breach, node: String) -> String {
        switch breach {
        case .item(let cap, let spent):
            return String(format: "cost cap $%.2f exceeded ($%.2f) on %@", cap, spent, node)
        case .session(let cap, let spent):
            return String(format: "session cost cap $%.2f exceeded ($%.2f) on %@", cap, spent, node)
        }
    }

    /// A spent session budget, with the wording the pause reports.
    struct SessionPause: Equatable, Sendable {
        var capUSD: Double
        var spentUSD: Double

        var logLine: String {
            String(
                format: "Session cost cap $%.2f reached ($%.2f) — pausing autopilot; "
                      + "resume to keep going on a fresh session budget",
                capUSD, spentUSD
            )
        }
        /// What the log says when a person resumes the queue this stopped: the
        /// same two figures, and the fact that the ledger starts again from here.
        /// Beside `logLine` rather than at the call site so the pause and the
        /// resume can't drift into describing different budgets.
        var resumeLine: String {
            String(
                format: "Session cost cap $%.2f reached ($%.2f) — resuming on a fresh session budget",
                capUSD, spentUSD
            )
        }
        var eventReason: String { String(format: "session cost cap $%.2f reached", capUSD) }
        var spentText: String { String(format: "%.2f", spentUSD) }
    }

    /// Set when there's no budget left to start another item, so the run pauses
    /// with that item untouched and a resume picks it up from the top.
    var sessionPause: SessionPause? {
        guard let cap = budget.sessionCapUSD, budget.isSessionExhausted else { return nil }
        return SessionPause(capUSD: cap, spentUSD: budget.spentThisSession)
    }

    /// As `sessionPause`, and also set when a sample already saw the session go
    /// over mid-item — the item is finished by the time this is asked, so the
    /// flag is cleared as it's reported.
    mutating func takeSessionPause() -> SessionPause? {
        guard let cap = budget.sessionCapUSD,
              sessionCapBreached || budget.isSessionExhausted else { return nil }
        sessionCapBreached = false
        return SessionPause(capUSD: cap, spentUSD: budget.spentThisSession)
    }

    // MARK: - What the panel shows

    /// A snapshot of the two budgets, with the formatting the panel renders.
    /// Separated from the view so "what does $0.42 of a $2.00 cap read as" is
    /// testable without standing up SwiftUI.
    ///
    /// Also what the control API reports on a run (`GET /v1/runs`, and the run's
    /// result payload), so a headless driver and the panel are reading the same
    /// figures rather than two answers to the same question.
    struct Readout: Equatable, Sendable {
        var itemSpendUSD: Double
        /// The item's effective ceiling; nil = uncapped.
        var itemCapUSD: Double?
        var sessionSpendUSD: Double
        /// The session ceiling; nil = uncapped.
        var sessionCapUSD: Double?
        /// Which rung of the prediction chain produced the forecast behind
        /// `itemCapUSD` — nil when nothing was predicted and the flat cap is the
        /// whole story. The panel doesn't show it; the control API does, because
        /// a ceiling with no provenance leaves a driver unable to tell one
        /// raised by this item's own history from the number in settings.
        var itemPredictionSource: PredictionSource?

        /// "$0.42 of $2.00" — just the spend when that ceiling is unset, since
        /// "of nothing" would read as a cap of zero.
        static func format(spend: Double, cap: Double?) -> String {
            guard let cap else { return String(format: "$%.2f", spend) }
            return String(format: "$%.2f of $%.2f", spend, cap)
        }

        /// Share of a ceiling spent; nil when uncapped (nothing to be near).
        static func utilization(spend: Double, cap: Double?) -> Double? {
            guard let cap, cap > 0 else { return nil }
            return spend / cap
        }

        /// Past this share of a cap the run is close enough to being cut off that
        /// the panel says so — early enough to raise the cap before it fires.
        static let warnThreshold = 0.8

        var itemText: String { Self.format(spend: itemSpendUSD, cap: itemCapUSD) }
        var sessionText: String { Self.format(spend: sessionSpendUSD, cap: sessionCapUSD) }

        var isItemNearCap: Bool {
            (Self.utilization(spend: itemSpendUSD, cap: itemCapUSD) ?? 0) >= Self.warnThreshold
        }
        var isSessionNearCap: Bool {
            (Self.utilization(spend: sessionSpendUSD, cap: sessionCapUSD) ?? 0) >= Self.warnThreshold
        }
    }

    /// What the Autopilot panel shows about money while a run is live: what the
    /// item in flight has spent against its own effective ceiling, and what the
    /// session has spent against the session cap. Both spends trail the live turn
    /// by at most one watchdog sample (~16s).
    var readout: Readout {
        Readout(
            itemSpendUSD: currentItemSpendUSD,
            itemCapUSD: currentItemCapUSD,
            sessionSpendUSD: budget.spentThisSession + currentItemSpendUSD,
            sessionCapUSD: budget.sessionCapUSD,
            itemPredictionSource: currentItemPrediction?.source
        )
    }

    // MARK: - Reading and writing the settings

    /// Reads what the Autopilot tab's cost-cap fields accept into a cap value.
    /// Blank, unparseable, or non-positive all mean **no cap** (nil): a $0 or
    /// negative ceiling would end every item before it spent anything, which is
    /// never what someone clearing the field meant.
    nonisolated static func parseCapUSD(_ text: String) -> Double? {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "$", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(cleaned), value > 0 else { return nil }
        return value
    }

    /// The cap as the field shows it — dollars and cents, empty when uncapped.
    nonisolated static func formatCapUSD(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "%.2f", value)
    }

}

#if DEBUG
/// Test seam. Reaching the in-flight figures for real means a metric store, a
/// picked-up item and a watchdog sample; this puts the governor straight into the
/// state that sequence leaves, so what reads the figures — the control API's run
/// payloads — can be tested against them. In this file because they are
/// `private(set)`, and DEBUG-only so no release path can write them behind
/// `beginItem`/`sample`'s back.
extension CostGovernor {
    mutating func stageInFlightForTesting(
        spendUSD: Double,
        capUSD: Double?,
        prediction: Prediction? = nil
    ) {
        currentItemSpendUSD = spendUSD
        currentItemCapUSD = capUSD
        currentItemPrediction = prediction
    }
}
#endif
