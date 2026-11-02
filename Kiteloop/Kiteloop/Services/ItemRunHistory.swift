import Foundation
import KiteloopCore

/// One item's runs, as its page lists them.
///
/// Two ledgers record the same runs and neither is the whole story.
/// `task-metrics.jsonl` — what `GET /v1/metrics` serves, projected into
/// `MetricIndex` — is the measurement: when, how long, what it cost, how it
/// ended. `control-runs.jsonl` is the control server's own record of the run,
/// and it is the only place a *reason* is written down as a field: a red history
/// row said `blocked` on screen and the sentence explaining it was in a file. A
/// run the app died under has a record there and no measurement at all.
///
/// So the rows are the join. A mapping and nothing more: every number comes from
/// one of the two records, and nothing here recomputes a figure either of them
/// already carries — a second derivation of an item's spend is how two screens
/// come to disagree about the same night.
enum ItemRunHistory {

    /// One recorded run.
    struct Row: Identifiable, Equatable, Sendable {

        /// Stable across a reload: the execution id where there is one, the
        /// control record's run id otherwise. A row with neither falls back to
        /// its start time, which is unique enough for a list — one item cannot
        /// be run twice at the same instant.
        let id: String

        let startedAt: Date

        /// Nil when nothing measured it — a run interrupted before it ended has
        /// a start and no length, which is not the same as a run that took no
        /// time.
        let durationSeconds: Double?

        /// Nil for the same reason: an unmeasured cost is not a free run.
        let costUSD: Double?

        /// The outcome's headline, in the vocabulary the rest of the app uses —
        /// `done`, `awaiting-approval`, `blocked`, `cancelled`, `interrupted`.
        let outcome: String

        /// Why it ended that way, when it did not pass. The recorded sentence,
        /// verbatim: either the tail of the metric's outcome (`blocked:` and
        /// what followed) or the control record's `reason`.
        let reason: String?

        /// Whether the agents finished the item as asked — the same rule the run
        /// history and the run badge already use, so a row cannot be a pass here
        /// and a failure two panels away.
        let isPass: Bool

        /// The branch the work landed on, as recorded. Nil where the run left no
        /// branch (a live-tree run), which is why the page shows no chip rather
        /// than a chip pointing at a ref that never existed.
        let branch: String?

        let pullRequestURL: String?
        let qualityScore: Double?
        let judgeUnavailableReason: String?
        let judgeDimensions: [String: Double]?

        /// The workflow execution, where the run got one — what the transcript
        /// directory is named after.
        let executionID: String?

        /// Nil on a row built from a control record alone: nobody counted the
        /// reviewer's passes, which is not the same as none.
        let reviewerRetries: Int?
        let changedFileCount: Int?

        /// This run's review rounds, in order — empty for a row built from a
        /// control record alone (nothing measured them), and empty just the
        /// same for a measured run the watchdog ended before any reviewer saw
        /// it. The two are the same fact on this field: nothing to show.
        let rounds: [ReviewRound]

        /// What the run left behind, when a measurement exists to say.
        let workEvidence: TaskMetricRecord.WorkEvidence?

        /// False for a run that has a control record and no measurement — an app
        /// that died under it, or a start the pickup gates refused. Its row is
        /// deliberately still here: a run that vanished from the list is the gap
        /// this join exists to close.
        let isMeasured: Bool

        /// Whether the round-by-round detail is worth showing under this row.
        /// A run whose only round passed has nothing more to say than the
        /// outcome already on the row, so the page must not grow to say it
        /// again — false exactly then, and for a run recording no rounds at
        /// all. True for every other case, including a single round that did
        /// not pass: a run rejected once and never retried still has a round
        /// worth reading.
        var showsRoundDetail: Bool {
            if rounds.isEmpty { return false }
            if rounds.count == 1 { return rounds[0].verdict != .passed }
            return true
        }

        /// What the row's quality pill says: the judge's score as a whole
        /// percentage, or that the judge could not score the run and why. Nil
        /// when neither was recorded — a run nobody judged shows no pill, not
        /// a score of zero.
        var qualityMark: QualityMark? {
            if let qualityScore { return .scored(String(format: "%.0f%%", qualityScore * 100)) }
            return judgeUnavailableReason.map { .unscored(reason: $0) }
        }
    }

    /// The quality pill on a run's row — see `Row.qualityMark`.
    enum QualityMark: Equatable, Sendable {
        case scored(String)
        case unscored(reason: String)
    }

    /// The line above the rows: how many attempts, what they cost, how long they
    /// took in total.
    ///
    /// Computed from the rows below it, so the summary and the list cannot state
    /// different totals — and it says out loud when a row contributed nothing,
    /// rather than quietly counting an unmeasured run as zero.
    struct Summary: Equatable, Sendable {
        let attempts: Int
        let totalCostUSD: Double
        let totalDurationSeconds: Double

        /// Rows missing a cost, a duration, or both — each absent from the total
        /// it lacks. A row holding one of the two is as much a gap as a row
        /// holding neither: the spend on screen is short by that run's cost
        /// however long the run is known to have taken.
        let unmeasuredRuns: Int

        /// Of those, how many are missing each figure. A row missing both is in
        /// both counts, which is what lets `note` say what is actually absent
        /// rather than naming the pair every time.
        let runsMissingCost: Int
        let runsMissingDuration: Int

        /// e.g. `3 attempts · $11.42 · 1h 4m`.
        var text: String {
            [
                "\(attempts) attempt\(attempts == 1 ? "" : "s")",
                money(totalCostUSD),
                durationText(totalDurationSeconds)
            ].joined(separator: " · ")
        }

        /// What the totals leave out, or nil when they leave out nothing.
        var note: String? {
            guard unmeasuredRuns > 0 else { return nil }
            let runs = unmeasuredRuns == 1 ? "1 run" : "\(unmeasuredRuns) runs"
            if runsMissingDuration == 0 {
                return "\(runs) recorded no cost, so these totals are a floor"
            }
            if runsMissingCost == 0 {
                return "\(runs) recorded no duration, so these totals are a floor"
            }
            if runsMissingCost == unmeasuredRuns && runsMissingDuration == unmeasuredRuns {
                return "\(runs) recorded no cost or duration, so these totals are a floor"
            }
            // Some rows lost one figure and some the other, so neither sentence
            // above is true of all of them. Reaching here takes at least two
            // rows, which is why this one is plural.
            return "\(runs) are missing a cost or a duration, so these totals are a floor"
        }
    }

    // MARK: - Mapping

    /// Joins the two ledgers into the page's rows, newest first.
    ///
    /// - Parameters:
    ///   - metrics: this item's measured runs (`MetricIndex.runs`).
    ///   - controlRuns: this item's control-server records, in any order. Ones
    ///     that name a measured run's execution enrich it; the rest become rows
    ///     of their own.
    static func rows(metrics: [TaskMetricRecord],
                     controlRuns: [PersistedRunRecord],
                     inFlight: Bool = false) -> [Row] {
        let byExecution = latestByExecution(controlRuns)

        var joined: Set<String> = []
        var joinedRunIDs: Set<String> = []
        var rows = metrics.map { metric -> Row in
            var control = metric.executionID.flatMap { byExecution[$0] }
            if let execution = metric.executionID, control != nil { joined.insert(execution) }
            // A control record that never learned its execution id — the
            // scheduler closes a run without one when the autopilot's id did
            // not change — still describes the run that started when it did.
            if control == nil,
               let twin = nearestTwin(of: metric, in: controlRuns, claimed: joinedRunIDs) {
                control = twin
                joinedRunIDs.insert(twin.runId)
            }
            return row(metric: metric, control: control)
        }

        for record in controlRuns {
            if let execution = record.executionID, joined.contains(execution) { continue }
            if joinedRunIDs.contains(record.runId) { continue }
            rows.append(row(control: record, inFlight: inFlight))
        }

        return rows.sorted { $0.startedAt > $1.startedAt }
    }

    /// The unstamped control record that describes this measured run, or nil.
    ///
    /// Nearest start rather than the first the array happens to hold, since the
    /// records arrive in any order; and never one an earlier row already took,
    /// so a single record cannot be read as two runs.
    private static func nearestTwin(of metric: TaskMetricRecord,
                                    in controlRuns: [PersistedRunRecord],
                                    claimed: Set<String>) -> PersistedRunRecord? {
        controlRuns
            .filter { !claimed.contains($0.runId) && startedTogether($0, metric) }
            .min { startGap($0, metric) < startGap($1, metric) }
    }

    private static func startGap(_ control: PersistedRunRecord, _ metric: TaskMetricRecord) -> TimeInterval {
        abs(control.startedAt.timeIntervalSince(metric.startedAt))
    }

    /// The control records that name an execution, newest per execution — so a
    /// run re-recorded after its judge pass is read once.
    private static func latestByExecution(_ controlRuns: [PersistedRunRecord]) -> [String: PersistedRunRecord] {
        var byExecution: [String: PersistedRunRecord] = [:]
        for record in controlRuns {
            guard let execution = record.executionID, !execution.isEmpty else { continue }
            if let existing = byExecution[execution], existing.startedAt > record.startedAt { continue }
            byExecution[execution] = record
        }
        return byExecution
    }

    /// How far apart two ledgers may stamp one run's start and still be the
    /// same run: the control record is written when the scheduler picks the
    /// item, the metric when the workflow spins up.
    static let startTolerance: TimeInterval = 120

    private static func startedTogether(_ control: PersistedRunRecord, _ metric: TaskMetricRecord) -> Bool {
        guard control.executionID == nil || control.executionID?.isEmpty == true else { return false }
        // A start the pickup gates refused names a run that never reached a
        // workflow, so no measurement can be its twin. Joining it to the next
        // run is how the refusal lost its own row and the measured run came to
        // show the refusal's reason as its own.
        guard control.outcome != .didNotRun else { return false }
        return startGap(control, metric) <= startTolerance
    }

    /// The totals, over exactly the rows shown.
    ///
    /// A row is unmeasured when it is missing *either* figure, not only when it
    /// is missing both: a run that recorded its length and no cost — which is
    /// what a row built from a control record alone often is, since the close
    /// always writes a duration and the cost fields can answer nothing — is
    /// absent from the spend on screen, and used to be absent from the note
    /// explaining the gap too.
    static func summary(of rows: [Row]) -> Summary {
        Summary(
            attempts: rows.count,
            totalCostUSD: rows.compactMap(\.costUSD).reduce(0, +),
            totalDurationSeconds: rows.compactMap(\.durationSeconds).reduce(0, +),
            unmeasuredRuns: rows.count { $0.costUSD == nil || $0.durationSeconds == nil },
            runsMissingCost: rows.count { $0.costUSD == nil },
            runsMissingDuration: rows.count { $0.durationSeconds == nil })
    }

    /// A measured run, with the control record for the same run where there is
    /// one. The measurement decides every figure it carries; the control record
    /// fills in what it alone wrote down — the reason, the branch, the PR.
    private static func row(metric: TaskMetricRecord, control: PersistedRunRecord?) -> Row {
        let split = splitOutcome(metric.outcome)
        return Row(
            id: metric.executionID ?? control?.runId ?? metric.id,
            startedAt: metric.startedAt,
            durationSeconds: metric.durationSeconds,
            costUSD: metric.costUSD,
            outcome: split.outcome,
            // The metric's own tail first — it is the outcome this row is
            // labelled with — and the control record's sentence when the tail
            // says nothing. A pass has no reason to give.
            reason: split.isPass ? nil : (split.reason ?? control?.reason),
            isPass: split.isPass,
            branch: control?.branch,
            pullRequestURL: control?.pullRequestURL,
            qualityScore: metric.qualityScore,
            judgeUnavailableReason: metric.judgeUnavailableReason,
            judgeDimensions: metric.judgeDimensions,
            executionID: metric.executionID,
            reviewerRetries: metric.reviewerRetries,
            changedFileCount: metric.changedFileCount,
            rounds: metric.reviewRounds ?? [],
            workEvidence: metric.workEvidence,
            isMeasured: true)
    }

    /// A run nothing measured — interrupted, or refused before it could run.
    private static func row(control: PersistedRunRecord, inFlight: Bool = false) -> Row {
        let outcome = outcomeName(control.outcome, inFlight: inFlight)
        return Row(
            id: control.executionID ?? control.runId,
            startedAt: control.startedAt,
            durationSeconds: control.durationSec.map(Double.init),
            costUSD: control.costUSD,
            outcome: outcome,
            reason: isPass(outcome) ? nil : (control.reason ?? unfinishedReason(control, inFlight: inFlight)),
            isPass: isPass(outcome),
            branch: control.branch,
            pullRequestURL: control.pullRequestURL,
            qualityScore: control.qualityScore,
            judgeUnavailableReason: control.judgeUnavailable,
            judgeDimensions: control.judgeDimensions,
            executionID: control.executionID,
            reviewerRetries: nil,
            changedFileCount: nil,
            rounds: [],
            workEvidence: nil,
            isMeasured: false)
    }

    /// A record with no outcome at all belongs to a run this process is still
    /// holding open, or one whose ending was never written. Said in words rather
    /// than left blank: a row with an empty outcome column reads as a bug.
    private static func unfinishedReason(_ control: PersistedRunRecord, inFlight: Bool) -> String? {
        guard control.outcome == nil else { return nil }
        return inFlight ? "still running — the ending is written when the gate answers"
                        : "no ending was ever recorded for this run"
    }

    /// `blocked:review did not pass` → (`blocked`, `review did not pass`).
    ///
    /// The outcome string is a `GROUP BY` column everywhere else, so the reason
    /// travels inside it; the page is the one place that wants the two apart.
    static func splitOutcome(_ raw: String) -> (outcome: String, reason: String?, isPass: Bool) {
        guard let separator = raw.firstIndex(of: ":") else {
            return (raw, nil, isPass(raw))
        }
        let head = String(raw[raw.startIndex..<separator])
        let tail = String(raw[raw.index(after: separator)...])
            .trimmingCharacters(in: .whitespaces)
        return (head, tail.isEmpty ? nil : tail, isPass(raw))
    }

    /// The control store spells its outcomes for the wire (`awaiting_approval`,
    /// `did_not_run`); the app spells them with a hyphen everywhere else, and
    /// `isPass` reads that spelling. A record with no outcome is a run that
    /// never reached one.
    private static func outcomeName(_ outcome: PersistedRunRecord.Outcome?, inFlight: Bool = false) -> String {
        guard let outcome else { return inFlight ? "in progress" : "unfinished" }
        return outcome.rawValue.replacingOccurrences(of: "_", with: "-")
    }

    /// The app's one definition of a pass, asked here rather than restated.
    private static func isPass(_ outcome: String) -> Bool {
        AutopilotHistorySummary.isPass(outcome)
    }

    // MARK: - Formatting

    /// `$11.42`. One spelling, so the row and the total that sums it agree.
    static func money(_ usd: Double) -> String {
        String(format: "$%.2f", usd)
    }

    /// A span of time as a reader says it: `48s`, `12m`, `1h 4m`. Rows carry
    /// `m:ss`, which is right for a single run and unreadable as a total.
    static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}
