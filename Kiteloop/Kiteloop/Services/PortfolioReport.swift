import Foundation
import KiteloopCore

/// What a period of unattended work produced, per project: what was groomed,
/// what ran, what merged, what was rejected, and what it cost.
///
/// The backlog shows the end state — it does not say whether a night produced
/// value or motion. This does, and it leads with the rate that answers it:
/// **merged ÷ filed**. A night that files six items and merges one is the
/// failure this report exists to make obvious, and a total ("six filed!") hides
/// exactly that.
///
/// Pure: it takes the two ledgers as values and holds no reference to anything
/// live, so the whole aggregation is exercised without an app, a run or a repo.
/// Its inputs are both already on disk and already bounded — one line per item
/// run (`TaskMetricRecord`) and one per grooming verdict (`GroomingRecord`) —
/// and the report itself is bounded twice over: to a period, and to
/// `projectLimit` rows.
struct PortfolioReport: Sendable, Equatable {

    // MARK: - Period

    /// The window being reported on. A day by default — "what did it do
    /// overnight" is the question this answers.
    struct Period: Sendable, Equatable {
        let start: Date
        let end: Date
        /// How the window reads in a header, e.g. "last 24h".
        let label: String

        var length: TimeInterval { max(0, end.timeIntervalSince(start)) }

        func contains(_ date: Date) -> Bool { date >= start && date <= end }

        /// The `hours` up to `end`. The default period, and the only one the UI
        /// asks for today.
        static func last(hours: Int, endingAt end: Date) -> Period {
            Period(start: end.addingTimeInterval(-Double(hours) * 3600),
                   end: end,
                   label: "last \(hours)h")
        }
    }

    // MARK: - The headline

    /// merged ÷ filed — the rate that says whether the grooming was any good.
    ///
    /// Its denominator is stated rather than assumed. Filing is what the rate is
    /// *for*, but nothing files items in a period where the coordinator did no
    /// grooming, and "0/0" would report a good night as a blank. So a period with
    /// runs but no filings falls back to merged ÷ run and says so — a different
    /// question ("did what ran land?"), never silently swapped for the first one.
    struct MergeRate: Sendable, Equatable {
        enum Basis: String, Sendable {
            /// Items filed in the period — the rate that judges the grooming.
            case filed
            /// Items run in the period — the fallback when nothing was filed.
            case run
        }

        let merged: Int
        let of: Int
        let basis: Basis

        /// Nil when there is nothing to divide by — rendered as "—", never 0%.
        var fraction: Double? { of > 0 ? Double(merged) / Double(of) : nil }

        /// e.g. `3/5 filed (60%)`, or `—` when nothing was filed or run.
        var text: String {
            guard let fraction else { return "—" }
            return "\(merged)/\(of) \(basis.rawValue) (\(Int((fraction * 100).rounded()))%)"
        }
    }

    /// Why the rejected items were rejected, as far as the ledgers can say.
    /// Grouped by cause rather than listed per item: a cause is bounded (there
    /// are two checks), a list of items is not.
    struct Cause: Sendable, Equatable {
        /// The check that had refused the item, or `unattributed` when none had.
        let label: String
        let count: Int
        /// One verdict verbatim, so the reader has something to go and fix.
        let example: String?

        /// Rejected with no check verdict on record — the run, not the grooming,
        /// is where to look.
        static let unattributed = "no check verdict"
    }

    // MARK: - Rows

    /// One project's period. Also the shape of the portfolio total, so the
    /// summary line and a project line are read the same way.
    struct Row: Sendable, Equatable, Identifiable {
        let projectName: String
        /// Items filed in the period, and how they were filed.
        let filed: Int
        let ready: Int
        let draft: Int
        /// Items that ran (reached a terminal outcome) in the period.
        let run: Int
        /// Landed on main.
        let merged: Int
        /// Ended `blocked` — the review never passed, or the run was cut short.
        let rejected: Int
        /// Passed review and is parked for a human. Neither merged nor rejected,
        /// and counted so the row's numbers reconcile.
        let awaitingApproval: Int
        /// Refused at pickup by a check, so it never ran at all.
        let skippedByCheck: Int
        let spendUSD: Double
        /// Period time with no item running. A project that ran nothing is idle
        /// for the whole period.
        let idle: TimeInterval
        let mergeRate: MergeRate
        /// Bounded, most common first.
        let causes: [Cause]

        var id: String { projectName }

        /// Nothing was groomed, nothing ran, nothing was refused. The row renders
        /// as "nothing ran" rather than as a line of zeroes.
        var isQuiet: Bool { filed == 0 && run == 0 && skippedByCheck == 0 }

        /// e.g. `filed 5 (4 ready · 1 draft) · run 4 · merged 3 · rejected 1 · $3.90 · idle 19h`.
        /// Clauses that are zero are dropped — a night reads as what happened,
        /// not as every counter that could have moved.
        var text: String {
            guard !isQuiet else { return "nothing ran" }
            var parts: [String] = []
            if filed > 0 {
                var clause = "filed \(filed)"
                let split = [ready > 0 ? "\(ready) ready" : nil, draft > 0 ? "\(draft) draft" : nil]
                    .compactMap { $0 }
                if !split.isEmpty { clause += " (\(split.joined(separator: " · ")))" }
                parts.append(clause)
            }
            if run > 0 { parts.append("run \(run)") }
            if merged > 0 { parts.append("merged \(merged)") }
            if rejected > 0 { parts.append("rejected \(rejected)") }
            if awaitingApproval > 0 { parts.append("awaiting \(awaitingApproval)") }
            if skippedByCheck > 0 { parts.append("skipped \(skippedByCheck)") }
            parts.append(PortfolioReport.usd(spendUSD))
            parts.append("idle \(PortfolioReport.duration(idle))")
            return parts.joined(separator: " · ")
        }
    }

    // MARK: - The report

    let period: Period
    /// Per project, busiest first. Bounded by `projectLimit`.
    let rows: [Row]
    /// Every project in the period, including the ones `rows` left out.
    let total: Row
    /// How many projects were folded into the total but not shown. Named rather
    /// than dropped: a truncated report that looks complete is worse than no
    /// report.
    let omittedProjects: Int

    /// Nothing was groomed and nothing ran anywhere. The caller renders this as
    /// an explicit statement, never as a blank panel.
    var isEmpty: Bool { total.isQuiet }

    /// The one line a collapsed panel shows.
    var summaryLine: String {
        guard !isEmpty else { return "Nothing ran in the \(period.label)" }
        var parts = ["merged \(total.mergeRate.text)"]
        if total.rejected > 0 { parts.append("\(total.rejected) rejected") }
        parts.append(Self.usd(total.spendUSD))
        return parts.joined(separator: " · ")
    }

    /// The whole report as plain text — what a skimming human reads, and the
    /// rendering the tests assert on. Plain beats charts for v1.
    var plainText: String {
        var out = "Portfolio — \(period.label)\n"
        guard !isEmpty else { return out + "Nothing ran in the \(period.label)\n" }
        out += "Merged \(total.mergeRate.text) · \(Self.usd(total.spendUSD))\n"
        for row in rows {
            out += "\(row.projectName): \(row.text)\n"
            for cause in row.causes {
                out += "  rejected — \(cause.label) \(cause.count)"
                out += cause.example.map { ": \($0)" } ?? ""
                out += "\n"
            }
        }
        if omittedProjects > 0 {
            out += "+\(omittedProjects) more project\(omittedProjects == 1 ? "" : "s") in the total\n"
        }
        return out
    }

    // MARK: - Build

    /// How many project rows are rendered. The rest are still counted in the
    /// total — this bounds the *list*, not the arithmetic.
    static let defaultProjectLimit = 6

    /// How many causes a row names.
    static let causeLimit = 3

    /// Aggregate a period.
    ///
    /// - Parameters:
    ///   - runs: every run metric on record. Filtered here by `completedAt` —
    ///     an item is counted in the period it *finished* in, so an item that
    ///     straddles midnight is counted once, not twice.
    ///   - grooming: every grooming record on record. Filings are counted in the
    ///     period; check verdicts are read from the whole list up to the period's
    ///     end, because the verdict that explains an item rejected tonight was
    ///     very often written when it was groomed days ago.
    ///   - period: the window.
    ///   - projectLimit: how many rows to render.
    static func make(runs: [TaskMetricRecord],
                     grooming: [GroomingRecord],
                     period: Period,
                     projectLimit: Int = defaultProjectLimit) -> PortfolioReport {
        // Runs that ran. An item a pickup gate refused is on the run ledger too
        // — that is how the retry ceiling counts it — but it is already in this
        // report as a `skippedByCheck`, from the grooming record written at the
        // same moment. Counting it here as well would say it twice, once as a
        // run that never happened, and would divide the merge rate by it.
        let periodRuns = runs.filter { period.contains($0.completedAt) && !$0.didNotRun }
        let periodGrooming = grooming.filter { period.contains($0.at) }
        // The verdict that explains a rejection may predate the period.
        let verdicts = latestCheckFailures(in: grooming.filter { $0.at <= period.end })

        var names: [String: String] = [:]      // project key → display name
        for record in periodRuns { names[key(record.projectPath)] = record.projectName }
        for record in periodGrooming { names[key(record.projectPath)] = record.projectName }

        var rows = names.map { projectKey, name in
            row(projectName: name,
                runs: periodRuns.filter { key($0.projectPath) == projectKey },
                grooming: periodGrooming.filter { key($0.projectPath) == projectKey },
                verdicts: verdicts,
                period: period)
        }
        // Busiest first — a quiet project is not what the reader opened this for.
        rows.sort { lhs, rhs in
            let (l, r) = (lhs.run + lhs.filed + lhs.skippedByCheck, rhs.run + rhs.filed + rhs.skippedByCheck)
            return l == r ? lhs.projectName < rhs.projectName : l > r
        }

        let total = row(projectName: "All projects", runs: periodRuns, grooming: periodGrooming,
                        verdicts: verdicts, period: period)
        let limit = max(0, projectLimit)
        return PortfolioReport(period: period,
                               rows: Array(rows.prefix(limit)),
                               total: total,
                               omittedProjects: max(0, rows.count - limit))
    }

    /// One project's counts. Also builds the portfolio total, from the same code
    /// — so the total can never disagree with the rows it sums.
    ///
    /// Which means every term here has to hold over a set of runs from *several*
    /// projects, not just one. The two that didn't are `idle`, whose busy time is
    /// now a union rather than a sum (see `busyTime`), and `skippedByCheck`,
    /// keyed on project *and* item so the same item id refused in two projects
    /// counts twice. Both give the same answer as before for a single project.
    private static func row(projectName: String,
                            runs: [TaskMetricRecord],
                            grooming: [GroomingRecord],
                            verdicts: [String: GroomingRecord],
                            period: Period) -> Row {
        let filings = grooming.filter(\.isFiled)
        let ready = filings.count { $0.event == .filedReady }
        let merged = runs.count { $0.merged == true }
        let rejected = runs.filter { isRejected($0.outcome) }

        let busy = busyTime(of: runs, in: period)
        let denominator = filings.isEmpty ? runs.count : filings.count
        let basis: MergeRate.Basis = filings.isEmpty ? .run : .filed

        return Row(
            projectName: projectName,
            filed: filings.count,
            ready: ready,
            draft: filings.count - ready,
            run: runs.count,
            merged: merged,
            rejected: rejected.count,
            awaitingApproval: runs.count { $0.outcome.hasPrefix("awaiting-approval") },
            skippedByCheck: Set(grooming.filter { $0.event == .checkFailed }
                .map { verdictKey(projectPath: $0.projectPath, itemID: $0.itemID) }).count,
            spendUSD: runs.reduce(0.0) { $0 + $1.costUSD },
            idle: max(0, period.length - busy),
            mergeRate: MergeRate(merged: merged, of: denominator, basis: basis),
            causes: causes(for: rejected, verdicts: verdicts)
        )
    }

    /// The most recent check failure per item, which is the one that still
    /// stands: an item refused for a missing `verify:`, re-groomed, then refused
    /// for an invented symbol is a grounding failure now.
    private static func latestCheckFailures(in grooming: [GroomingRecord]) -> [String: GroomingRecord] {
        var latest: [String: GroomingRecord] = [:]
        for record in grooming where record.event == .checkFailed {
            let key = verdictKey(projectPath: record.projectPath, itemID: record.itemID)
            if let existing = latest[key], existing.at > record.at { continue }
            latest[key] = record
        }
        return latest
    }

    /// Groups the rejected items by the check that had refused them. An item with
    /// no verdict on record is grouped under `Cause.unattributed` rather than
    /// dropped — "we don't know" is a finding too.
    private static func causes(for rejected: [TaskMetricRecord],
                               verdicts: [String: GroomingRecord]) -> [Cause] {
        var counts: [String: (count: Int, example: String?)] = [:]
        for record in rejected {
            let verdict = verdicts[verdictKey(projectPath: record.projectPath, itemID: record.itemID)]
            let label = verdict?.check ?? Cause.unattributed
            let existing = counts[label]
            counts[label] = (
                count: (existing?.count ?? 0) + 1,
                example: existing?.example ?? verdict?.reason
            )
        }
        // Split into typed steps: as one chained expression the type checker
        // gives up ("unable to type-check in reasonable time").
        var causes: [Cause] = counts.map { entry -> Cause in
            Cause(label: entry.key, count: entry.value.count, example: entry.value.example)
        }
        causes.sort { lhs, rhs in
            lhs.count == rhs.count ? lhs.label < rhs.label : lhs.count > rhs.count
        }
        return Array(causes.prefix(causeLimit))
    }

    /// `blocked` is the rejection: the reviewer never passed the work, or the run
    /// was cut short and there was nothing to salvage. `cancelled` is a human
    /// stopping the queue, which says nothing about the item.
    static func isRejected(_ outcome: String) -> Bool { outcome.hasPrefix("blocked") }

    /// How much of the period had *something* running — the union of the runs'
    /// intervals, not their sum.
    ///
    /// Summing is right for one project, where only one item runs at a time and
    /// the intervals cannot overlap. It is wrong for the portfolio total, which
    /// is built from the same code over every project's runs at once: three
    /// projects each busy for ten hours of a day sum to thirty, and
    /// `period.length - busy` then reports a day that was two-thirds idle as
    /// never idle at all. Merging first gives the same answer as the sum
    /// whenever the intervals really don't overlap, so the project rows are
    /// unchanged.
    private static func busyTime(of runs: [TaskMetricRecord], in period: Period) -> TimeInterval {
        // Clipped to the window, so a run that started before it doesn't report
        // more busy time than the window holds.
        var intervals = runs
            .map { (start: max($0.startedAt, period.start), end: min($0.completedAt, period.end)) }
            .filter { $0.end > $0.start }
        guard !intervals.isEmpty else { return 0 }
        intervals.sort { $0.start < $1.start }

        var busy: TimeInterval = 0
        var current = intervals[0]
        for interval in intervals.dropFirst() {
            if interval.start <= current.end {
                current.end = max(current.end, interval.end)   // overlapping or touching — one stretch
            } else {
                busy += current.end.timeIntervalSince(current.start)
                current = interval
            }
        }
        return busy + current.end.timeIntervalSince(current.start)
    }

    private static func key(_ projectPath: String) -> String {
        KiteloopProject.canonicalPath(projectPath)
    }

    private static func verdictKey(projectPath: String, itemID: String) -> String {
        key(projectPath) + "\u{0}" + itemID
    }

    // MARK: - Formatting

    /// Cents, because a night's spend is usually a few dollars and rounding it to
    /// whole dollars would report most of them as "$0".
    static func usd(_ value: Double) -> String { String(format: "$%.2f", value) }

    /// Coarse on purpose — idle time is read to the nearest hour, and "19h" is
    /// the answer to "did it sit there all night".
    static func duration(_ interval: TimeInterval) -> String {
        let minutes = Int((interval / 60).rounded())
        if minutes < 60 { return "\(max(0, minutes))m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h\(remainder)m"
    }
}
