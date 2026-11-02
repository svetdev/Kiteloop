import Foundation
import KiteloopCore
import os.log

private let metricStoreLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "task-metrics")

/// Append-only store of task actuals and estimates for the learning engine.
/// Global (per-record `projectPath` allows per-project filtering), JSONL-backed
/// so writes are cheap appends — mirroring `BacklogAutopilot`'s history pattern.
@Observable
@MainActor
final class TaskMetricStore {
    /// The name this store reports under. A human reads it in a notification
    /// title, and it is half `StoreProblemReporter`'s dedup key, so it is
    /// spelled once: a store that spelled itself two ways would file two rows
    /// for the one problem. It names the measurements rather than any one
    /// ledger, because all four fail as one disk — the row names the file.
    static let storeName = "Task metrics"

    private let reporter: StoreProblemReporter

    /// The runs, as a reader wants them: what the log holds, with each run's
    /// merge outcome folded in from the event that recorded it. The log itself
    /// is untouched — `merged` is decided after the row is written, and the fold
    /// is how the two are joined without rewriting a line. See `MergeOutcomeFold`.
    private(set) var records: [TaskMetricRecord] = []
    private(set) var estimates: [TaskEstimate] = []
    /// Approve/reopen transitions, in the order they were observed.
    private(set) var approvalEvents: [ItemApprovalEvent] = []
    /// What became of each run's work at the merge gate, in the order it was
    /// decided.
    private(set) var mergeEvents: [ItemMergeEvent] = []

    /// How many lines of each ledger the decoder refused at load — one count per
    /// file, so a measurement taken over a ledger that lost a line is
    /// distinguishable from one taken over a whole one.
    ///
    /// `appendLine` writes through a `FileHandle` with no atomicity, so the app
    /// being killed mid-append truncates the newest line — the run that just
    /// finished. Everything computed here (`RetryCeiling`, `SizeCalibration`,
    /// `firstPassRate`, `escapedDefectRate`, `GET /v1/metrics`) is computed over
    /// what survived, so a lost line quietly lowers a denominator unless somebody
    /// says it went. Each is logged at error as well, but exposed so a caller —
    /// and a test — can see it without reading os_log, as
    /// `RunRecordStore.undecodableLineCount` is.
    private(set) var undecodableMetricLineCount = 0
    private(set) var undecodableEstimateLineCount = 0
    private(set) var undecodableApprovalLineCount = 0
    private(set) var undecodableMergeLineCount = 0

    /// How many appends across all four ledgers failed to reach disk — one count,
    /// since a failed write is one disk failing whichever ledger was being
    /// written at the time, not a property of the ledger itself. The value stays
    /// in `records`/`estimates`/`approvalEvents`/`mergeEvents` regardless, so the
    /// live view is unaffected; this is what says the ledger it was meant to join
    /// is short a line, the way `RunRecordStore.failedWriteCount` does for runs.
    ///
    /// Both ways of losing a row count here, not only the throw: a record the
    /// encoder refuses — a non-finite Double — never reaches the file either,
    /// and while that loss went uncounted the one number that exists to say a
    /// measurement was taken over a short ledger read 0 for it.
    private(set) var failedWriteCount = 0

    private let metricsURL: URL
    private let estimatesURL: URL
    private let approvalsURL: URL
    private let mergesURL: URL

    /// How long after an approval a reopen still counts as an escaped defect —
    /// the 7 days success metric #3b is defined over. The boundary is inclusive:
    /// a reopen exactly 7×24h after the approval counts, one second later does not.
    ///
    /// The value lives on `EscapedDefectRate` because the window belongs to the
    /// metric rather than to this store: `MetricIndex` computes the same rate in
    /// SQL and must be defined over the same seven days, and it cannot read a
    /// constant isolated to the main actor.
    static let escapedDefectWindow: TimeInterval = EscapedDefectRate.standardWindow

    private static var defaultDir: URL {
        let dir = KiteloopHome.url
            .appendingPathComponent(".kiteloop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    init(metricsURL: URL? = nil, estimatesURL: URL? = nil, approvalsURL: URL? = nil,
         mergesURL: URL? = nil, reporter: StoreProblemReporter = .shared) {
        self.reporter = reporter
        self.metricsURL = metricsURL ?? Self.defaultDir.appendingPathComponent("task-metrics.jsonl")
        self.estimatesURL = estimatesURL ?? Self.defaultDir.appendingPathComponent("task-estimates.jsonl")
        self.approvalsURL = approvalsURL ?? Self.defaultDir.appendingPathComponent("task-approvals.jsonl")
        self.mergesURL = mergesURL ?? Self.defaultDir.appendingPathComponent("task-merges.jsonl")
        let loadedEstimates = Self.load(TaskEstimate.self, from: self.estimatesURL)
        self.estimates = loadedEstimates.values
        self.undecodableEstimateLineCount = loadedEstimates.undecodable

        let loadedApprovals = Self.load(ItemApprovalEvent.self, from: self.approvalsURL)
        self.approvalEvents = loadedApprovals.values
        self.undecodableApprovalLineCount = loadedApprovals.undecodable

        let loadedMerges = Self.load(ItemMergeEvent.self, from: self.mergesURL)
        self.mergeEvents = loadedMerges.values
        self.undecodableMergeLineCount = loadedMerges.undecodable

        let loadedRecords = Self.load(TaskMetricRecord.self, from: self.metricsURL)
        self.undecodableMetricLineCount = loadedRecords.undecodable
        self.records = MergeOutcomeFold.apply(self.mergeEvents, to: loadedRecords.values)
    }

    // MARK: - Append

    func append(_ record: TaskMetricRecord) {
        records.append(record)
        appendLine(record, to: metricsURL)
        // The run whose gate was resolved before its row existed — an auto-merge
        // decides inside the run — gets its outcome here, on the way in.
        foldMergeOutcomes()
    }

    func appendEstimate(_ estimate: TaskEstimate) {
        estimates.append(estimate)
        appendLine(estimate, to: estimatesURL)
    }

    func appendApprovalEvent(_ event: ItemApprovalEvent) {
        approvalEvents.append(event)
        appendLine(event, to: approvalsURL)
    }

    /// Records what became of an item's work at the merge gate. The run's own row
    /// is not touched — it was written when the run ended, and this is a later
    /// measurement of a different moment.
    func appendMergeEvent(_ event: ItemMergeEvent) {
        mergeEvents.append(event)
        appendLine(event, to: mergesURL)
        foldMergeOutcomes()
    }

    /// Re-joins the merge log to the runs. Idempotent — the fold only writes an
    /// outcome where an event says one, so running it again lands on the same
    /// records.
    private func foldMergeOutcomes() {
        records = MergeOutcomeFold.apply(mergeEvents, to: records)
    }

    // MARK: - Queries

    /// Most recent estimate/actual for an item, if any.
    func latestEstimate(itemID: String) -> TaskEstimate? {
        estimates.last { $0.itemID == itemID }
    }

    /// The item's most recent *executed* run. A refusal at pickup is on record
    /// too, and it is not an actual: reporting its zeroes here would say the
    /// last attempt took no time and cost nothing, which is what a run that
    /// never started looks like from the outside and nothing like a measurement.
    func latestActual(itemID: String) -> TaskMetricRecord? {
        records.last { $0.itemID == itemID && !$0.didNotRun }
    }

    /// `latestEstimate(itemID:)` confined to one project. An item id is only
    /// unique inside a backlog — a copied epic or a shared template puts the
    /// same id in two projects — so an unscoped lookup lets one project's
    /// estimate set the other's cost ceiling. Anything deriving a number *for*
    /// a project wants this one.
    func latestEstimate(itemID: String, projectPath: String) -> TaskEstimate? {
        let canonical = KiteloopProject.canonicalPath(projectPath)
        return estimates.last {
            $0.itemID == itemID
                && KiteloopProject.canonicalPath($0.projectPath) == canonical
        }
    }

    /// Every run of one item in one project, in the order they were recorded —
    /// the pool the cost prediction's own-history rung averages. Scoped for the
    /// same reason as `latestEstimate(itemID:projectPath:)`: what an item cost
    /// in another project's checkout says nothing about what it costs here.
    func actuals(itemID: String, projectPath: String) -> [TaskMetricRecord] {
        let canonical = KiteloopProject.canonicalPath(projectPath)
        return records.filter {
            $0.itemID == itemID
                && KiteloopProject.canonicalPath($0.projectPath) == canonical
        }
    }

    /// One row per item — the newest estimate for each, since re-scoping an item
    /// appends a fresh record rather than replacing the old one. Newest first.
    /// Items are keyed per project, so two projects using the same item id keep
    /// their own estimates.
    func latestEstimatesPerItem(projectPath: String?) -> [TaskEstimate] {
        let pool = projectPath.map { path in
            let canonical = KiteloopProject.canonicalPath(path)
            return estimates.filter { KiteloopProject.canonicalPath($0.projectPath) == canonical }
        } ?? estimates

        var newest: [String: TaskEstimate] = [:]
        for estimate in pool {
            let key = KiteloopProject.canonicalPath(estimate.projectPath) + "\u{0}" + estimate.itemID
            // Strictly greater, so the last line appended wins an exact tie —
            // matching how `latestEstimate(itemID:)` reads the same file.
            if let existing = newest[key], existing.createdAt > estimate.createdAt { continue }
            newest[key] = estimate
        }
        return newest.values.sorted { lhs, rhs in
            lhs.createdAt == rhs.createdAt ? lhs.itemID < rhs.itemID : lhs.createdAt > rhs.createdAt
        }
    }

    /// Rolled-up actuals for a size bucket. Prefers records from `projectPath`;
    /// falls back to all projects when the project has too few of its own.
    func summary(forSize size: String, projectPath: String?, minProjectSamples: Int = 3) -> TaskMetricSummary? {
        let sizeMatches = records.filter { $0.declaredSize == size }
        let scoped = projectPath.map { path in
            sizeMatches.filter { KiteloopProject.isSamePath($0.projectPath, path) }
        } ?? []
        let pool = scoped.count >= minProjectSamples ? scoped : sizeMatches
        return Self.summarize(pool)
    }

    /// What this project's runs say a size actually costs and takes: p10/p50/p90
    /// of cost and duration over the recent window, computed only from runs that
    /// produced something. Nil when the size has too few such runs to be
    /// measured — see `SizeCalibration`.
    ///
    /// Unlike `summary(forSize:projectPath:)` this never falls back to other
    /// projects' records: a band is used as a ceiling and as a check on a label,
    /// and both are claims about *this* project's work.
    func sizeBand(forSize size: String, projectPath: String, now: Date = Date()) -> SizeCalibration.Band? {
        SizeCalibration.band(forSize: size, records: records, projectPath: projectPath, now: now)
    }

    /// One band per size that has enough evidence, smallest first.
    func sizeBands(projectPath: String, now: Date = Date()) -> [SizeCalibration.Band] {
        SizeCalibration.bands(records: records, projectPath: projectPath, now: now)
    }

    /// One summary per size bucket seen in the data (project-filtered if given).
    func summariesBySize(projectPath: String?) -> [(size: String, summary: TaskMetricSummary)] {
        let pool = projectPath.map { path in
            records.filter { KiteloopProject.isSamePath($0.projectPath, path) }
        } ?? records
        let bySize = Dictionary(grouping: pool.filter { $0.declaredSize != nil }) { $0.declaredSize! }
        return bySize.compactMap { size, recs in
            Self.summarize(recs).map { (size, $0) }
        }
        .sorted { sizeRank($0.size) < sizeRank($1.size) }
    }

    /// One summary per epic (project-filtered if given).
    func summariesByEpic(projectPath: String?) -> [(epic: String, summary: TaskMetricSummary)] {
        let pool = projectPath.map { path in
            records.filter { KiteloopProject.isSamePath($0.projectPath, path) }
        } ?? records
        let byEpic = Dictionary(grouping: pool.filter { $0.epic != nil }) { $0.epic! }
        return byEpic.compactMap { epic, recs in
            Self.summarize(recs).map { (epic, $0) }
        }
        .sorted { $0.epic < $1.epic }
    }

    // MARK: - Escaped defects (metric #3b)

    /// The approval a reopen of this item would be measured against: the last
    /// time it reached `done` in this project. Nil when the app never observed
    /// the item being approved — which is exactly when a return to `ready` is a
    /// retry rather than an escaped defect.
    func latestApproval(itemID: String, projectPath: String) -> ItemApprovalEvent? {
        let canonical = KiteloopProject.canonicalPath(projectPath)
        return approvalEvents.last {
            $0.kind == .approved
                && $0.itemID == itemID
                && KiteloopProject.canonicalPath($0.projectPath) == canonical
        }
    }

    /// Whether this item already has a reopen on record no earlier than `date`
    /// in this project. Read against `latestApproval(itemID:projectPath:)`, it
    /// separates an approved item that has come back and been counted from one
    /// whose return nobody has recorded yet.
    func hasReopen(itemID: String, projectPath: String, onOrAfter date: Date) -> Bool {
        let canonical = KiteloopProject.canonicalPath(projectPath)
        return approvalEvents.contains {
            $0.kind == .reopened
                && $0.itemID == itemID
                && $0.at >= date
                && KiteloopProject.canonicalPath($0.projectPath) == canonical
        }
    }

    /// Success metric #3b: the share of approvals reopened inside `window`.
    ///
    /// Every approval counts in the denominator, including ones made in the last
    /// seven days that have not had their full window to come back yet — so the
    /// rate reads slightly low right after a burst of approvals and settles as
    /// the window passes.
    ///
    /// `MergeRetryChurn` runs first: a reopen the gate-retry loop re-approved
    /// within its own retry window is the same approval continuing, not a new
    /// approval and not an escape, so neither side of it reaches the counts
    /// below.
    func escapedDefectRate(projectPath: String?,
                           window: TimeInterval = TaskMetricStore.escapedDefectWindow) -> EscapedDefectRate {
        let pool = projectPath.map { path in
            let canonical = KiteloopProject.canonicalPath(path)
            return approvalEvents.filter { KiteloopProject.canonicalPath($0.projectPath) == canonical }
        } ?? approvalEvents

        let moments = pool.map { event in
            MergeRetryChurn.Moment(
                key: KiteloopProject.canonicalPath(event.projectPath) + "\u{0}" + event.itemID,
                isReopen: event.kind == .reopened, at: event.at, payload: event)
        }
        return MergeRetryChurn.escapedDefectRate(moments, window: window,
                                                 kind: { $0.kind }, approvedAt: { $0.approvedAt })
    }

    // MARK: - First pass (metric #3a)

    /// Success metric #3a: the share of judged runs review passed on the first
    /// worker attempt. `FirstPassRate` holds the whole definition — what counts
    /// as judged, and what counts as a pass.
    ///
    /// Every record ever written is in scope, so this does not move with the
    /// page `GET /v1/metrics` returns: the rate is about the history, not about
    /// the last few runs.
    func firstPassRate(projectPath: String?) -> FirstPassRate {
        let pool = projectPath.map { path in
            let canonical = KiteloopProject.canonicalPath(path)
            return records.filter { KiteloopProject.canonicalPath($0.projectPath) == canonical }
        } ?? records

        var judged = 0
        var firstPass = 0
        for record in pool where FirstPassRate.reachedVerdict(record.outcome) {
            judged += 1
            if FirstPassRate.isFirstPass(outcome: record.outcome,
                                         reviewerRetries: record.reviewerRetries) {
                firstPass += 1
            }
        }
        return FirstPassRate(judged: judged, firstPass: firstPass)
    }

    /// Estimate/actual pairs for items that have both — for calibration.
    ///
    /// Each run is paired with an estimate from **its own** project, not merely
    /// with the newest estimate carrying that item id: pairing a run here with
    /// another project's forecast measures nothing, and the error survives
    /// filtering the actuals by project.
    ///
    /// Only runs that actually ran are paired. A refusal at pickup is written
    /// with the item's id — again on every refused start — and paired with its
    /// estimate it would read as that work finishing in a minute.
    func calibration(projectPath: String?) -> [(estimate: TaskEstimate, actual: TaskMetricRecord)] {
        let ran = records.filter { !$0.didNotRun }
        let actualPool = projectPath.map { path in
            ran.filter { KiteloopProject.isSamePath($0.projectPath, path) }
        } ?? ran
        return actualPool.compactMap { actual in
            latestEstimate(itemID: actual.itemID, projectPath: actual.projectPath).map { ($0, actual) }
        }
    }

    // MARK: - Helpers

    /// Averages over the runs that actually ran. A refusal at pickup carries a
    /// size and an epic like any other row, so it lands in these buckets — and
    /// it measured nothing, so averaging its zeroes in would report that work of
    /// that size got cheaper and quicker every time a gate turned an item away.
    private static func summarize(_ all: [TaskMetricRecord]) -> TaskMetricSummary? {
        let recs = all.filter { !$0.didNotRun }
        guard !recs.isEmpty else { return nil }
        let n = Double(recs.count)
        return TaskMetricSummary(
            sampleCount: recs.count,
            avgDurationSeconds: recs.reduce(0) { $0 + $1.durationSeconds } / n,
            avgCostUSD: recs.reduce(0) { $0 + $1.costUSD } / n,
            avgReviewerRetries: recs.reduce(0.0) { $0 + Double($1.reviewerRetries) } / n
        )
    }

    private func sizeRank(_ size: String) -> Int {
        ["XS", "S", "M", "L", "XL"].firstIndex(of: size.uppercased()) ?? 99
    }

    /// Appends one ledger line, and counts and reports whatever stopped it.
    ///
    /// Generic over all four ledgers, so the one report site covers metrics,
    /// estimates, approvals and merges; the row names whichever file it was.
    /// The record stays in the live view either way — this says only that the
    /// ledger it was meant to join is short a line.
    private func appendLine<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? Self.makeEncoder().encode(value),
              let line = String(data: data, encoding: .utf8) else {
            // Counted, not merely logged: a record the encoder refuses is as
            // lost as one the disk refused, and this is the count that says so.
            failedWriteCount += 1
            metricStoreLog.error("Failed to encode metric record")
            return
        }
        // Through `AtomicFileWriter.append`, which starts a new line first when the
        // ledger doesn't end in one. A plain seek-to-end writes this record onto
        // the remnant of one a kill cut short, and the pair decodes as neither —
        // so the attempt `RetryCeiling` counts, or the cost `CostGovernor`
        // predicts from, is lost to the crash that happened before it.
        do {
            try AtomicFileWriter.append(Data((line + "\n").utf8), to: url)
        } catch {
            failedWriteCount += 1
            metricStoreLog.error("""
                Failed to write to \(url.lastPathComponent, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            // os_log alone left the person to notice that the numbers stopped
            // moving. One row in the inbox they already watch, refreshed rather
            // than repeated however many appends the same disk goes on to eat.
            reporter.report(store: Self.storeName, operation: .write, url: url, error: error)
        }
    }

    /// Reads a ledger, and says how much of it it could not read.
    ///
    /// A line the decoder refuses costs neither the lines around it nor the
    /// caller's knowledge that it was there: it is counted, and logged once per
    /// file rather than once per line, so a truncated tail is one error line
    /// naming the ledger. Blank lines are not lines — `split(separator:)` drops
    /// them before anything is asked to decode them.
    ///
    /// The file's bytes are split on the newline byte and each line's bytes are
    /// decoded on their own, the way `AtomicFileWriter.loadLines` and
    /// `RunRecordStore.collapse` read this same shape. Reading the whole file as
    /// one string first was all-or-nothing: a kill part-way through a multi-byte
    /// character — the exact truncation `AtomicFileWriter.append` is written to
    /// survive — left one line that is not valid UTF-8, the whole-file read
    /// failed, and all four ledgers came back empty reporting nothing wrong,
    /// which is the store saying every measurement was taken over no history at
    /// all. Bytes that are not valid UTF-8 now join the lines the JSON decoder
    /// refuses, and are counted with them.
    ///
    /// The ledger itself is left alone. It is append-only, so unlike
    /// `RunRecordStore` — which compacts, and must therefore hold the lines it
    /// couldn't read verbatim to avoid erasing them — there is nothing here that
    /// would rewrite the file over them.
    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> (values: [T], undecodable: Int) {
        guard let content = try? Data(contentsOf: url) else { return ([], 0) }
        let decoder = makeDecoder()
        var out: [T] = []
        var undecodable = 0
        for line in content.split(separator: UInt8(ascii: "\n")) {
            guard let value = try? decoder.decode(T.self, from: line) else {
                undecodable += 1
                continue
            }
            out.append(value)
        }
        if undecodable > 0 {
            metricStoreLog.error("""
                \(undecodable, privacy: .public) line(s) in \
                \(url.lastPathComponent, privacy: .public) could not be decoded — skipped, \
                so anything measured over this ledger is measured over what is left
                """)
        }
        return (out, undecodable)
    }
}
