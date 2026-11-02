import XCTest
import KiteloopCore
@testable import Kiteloop

/// The report exists to answer "was the night worth it?", so the behaviour worth
/// pinning down is the arithmetic that could flatter the answer: a merge rate
/// with nothing to divide by, a period that silently swallows work outside it,
/// and a rejection whose cause was never attributed.
final class PortfolioReportTests: XCTestCase {

    // MARK: - Merge rate

    func testMergeRateIsMergedOverFiled() {
        let rate = PortfolioReport.MergeRate(merged: 3, of: 8, basis: .filed)
        XCTAssertEqual(rate.fraction ?? 0, 3.0 / 8.0, accuracy: 0.0001)
        XCTAssertTrue(rate.text.contains("3"))
    }

    /// Nothing filed is "no rate", not "0%". Reporting 0% for an idle period
    /// would read as a catastrophic night rather than a quiet one.
    func testMergeRateWithNothingFiledHasNoFraction() {
        let rate = PortfolioReport.MergeRate(merged: 0, of: 0, basis: .filed)
        XCTAssertNil(rate.fraction)
    }

    func testPerfectAndZeroRates() {
        XCTAssertEqual(PortfolioReport.MergeRate(merged: 5, of: 5, basis: .run).fraction ?? 0,
                       1.0, accuracy: 0.0001)
        XCTAssertEqual(PortfolioReport.MergeRate(merged: 0, of: 4, basis: .run).fraction ?? -1,
                       0.0, accuracy: 0.0001)
    }

    // MARK: - What counts as a rejection

    func testBlockedIsARejectionAndCancelledIsNot() {
        XCTAssertTrue(PortfolioReport.isRejected("blocked"))
        XCTAssertTrue(PortfolioReport.isRejected("blocked: review did not pass"))
        XCTAssertFalse(PortfolioReport.isRejected("cancelled"),
                       "a human stopping the queue says nothing about the item")
        XCTAssertFalse(PortfolioReport.isRejected("done"))
    }

    // MARK: - Period

    func testPeriodContainsOnlyItsOwnWindow() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let period = PortfolioReport.Period.last(hours: 24, endingAt: end)

        XCTAssertTrue(period.contains(end))
        XCTAssertTrue(period.contains(end.addingTimeInterval(-60 * 60)))
        XCTAssertFalse(period.contains(end.addingTimeInterval(-25 * 60 * 60)),
                       "work before the window must not be counted in it")
        XCTAssertFalse(period.contains(end.addingTimeInterval(60)))
        XCTAssertEqual(period.length, 24 * 60 * 60, accuracy: 1)
    }

    // MARK: - What the headline counts

    /// The bug this report was reading for months: with nothing ever recording an
    /// outcome, every run was "unknown", and the headline said `0/… (0%)` over a
    /// night that had merged most of what it ran. Given runs that carry one, the
    /// rate is the merges.
    func testMergedCountsTheRunsWhoseWorkLanded() {
        let period = PortfolioReport.Period.last(hours: 24, endingAt: t(0))
        let report = PortfolioReport.make(
            runs: [
                run(itemID: "a", merged: true, completedAt: t(-3600)),
                run(itemID: "b", merged: true, completedAt: t(-1800)),
                run(itemID: "c", merged: false, completedAt: t(-900))
            ],
            grooming: [],
            period: period)

        XCTAssertEqual(report.total.merged, 2)
        XCTAssertEqual(report.total.mergeRate.text, "2/3 run (67%)")
    }

    /// A run nobody has resolved a gate for is not a run that failed to merge —
    /// but it is not a merge either, and the rate must not credit it. Unknown
    /// counts against, which is the conservative direction and the one the field
    /// has always promised.
    func testARunWithAnUnknownOutcomeIsNotCountedAsMerged() {
        let period = PortfolioReport.Period.last(hours: 24, endingAt: t(0))
        let report = PortfolioReport.make(
            runs: [
                run(itemID: "a", merged: true, completedAt: t(-3600)),
                run(itemID: "b", merged: nil, completedAt: t(-1800))
            ],
            grooming: [],
            period: period)

        XCTAssertEqual(report.total.merged, 1)
        XCTAssertEqual(report.total.run, 2, "it still ran — only the merge is unknown")
    }

    // MARK: - Causes

    func testCausesRankByCountThenLabel() {
        let a = PortfolioReport.Cause(label: "verify_passed", count: 3, example: nil)
        let b = PortfolioReport.Cause(label: "scope", count: 3, example: nil)
        let c = PortfolioReport.Cause(label: "tests", count: 5, example: "no tests")

        var causes = [a, b, c]
        causes.sort { lhs, rhs in
            lhs.count == rhs.count ? lhs.label < rhs.label : lhs.count > rhs.count
        }
        XCTAssertEqual(causes.map(\.label), ["tests", "scope", "verify_passed"],
                       "biggest cause first; ties broken by label so the order is stable")
    }

    // MARK: - Idle across projects

    /// The total row is built by the same code as a project row, and summing busy
    /// time only equals the union when the intervals cannot overlap — true within
    /// one project, false across them. Two projects each busy for the same ten
    /// hours summed to twenty, and the total reported a 24h night as four hours
    /// idle when nothing had run for fourteen of them.
    func testTotalIdleUsesTheUnionOfConcurrentProjectsNotTheirSum() {
        let period = PortfolioReport.Period.last(hours: 24, endingAt: t(0))
        let report = PortfolioReport.make(
            runs: [
                run(project: "alpha", itemID: "a", startedAt: t(-10 * 3600), completedAt: t(0)),
                run(project: "beta", itemID: "b", startedAt: t(-10 * 3600), completedAt: t(0))
            ],
            grooming: [],
            period: period)

        XCTAssertEqual(report.total.idle, 14 * 3600, accuracy: 1,
                       "the two projects were busy over the same ten hours, not twenty")
        for row in report.rows {
            XCTAssertEqual(row.idle, 14 * 3600, accuracy: 1,
                           "\(row.projectName)'s own idle is unchanged by the fix")
        }
    }

    /// Partly overlapping is the case a union has to actually merge: alpha runs
    /// hours 8–4-before-the-end, beta 6–2, so the stretch with something running
    /// is hours 8 to 2 — six, not the eight the sum would give.
    func testPartlyOverlappingProjectsCountTheMergedStretchOnce() {
        let period = PortfolioReport.Period.last(hours: 24, endingAt: t(0))
        let report = PortfolioReport.make(
            runs: [
                run(project: "alpha", itemID: "a", startedAt: t(-8 * 3600), completedAt: t(-4 * 3600)),
                run(project: "beta", itemID: "b", startedAt: t(-6 * 3600), completedAt: t(-2 * 3600))
            ],
            grooming: [],
            period: period)

        XCTAssertEqual(report.total.idle, 18 * 3600, accuracy: 1)
    }

    /// Disjoint intervals still add up — a union is not a maximum.
    func testProjectsThatNeverOverlapStillSum() {
        let period = PortfolioReport.Period.last(hours: 24, endingAt: t(0))
        let report = PortfolioReport.make(
            runs: [
                run(project: "alpha", itemID: "a", startedAt: t(-20 * 3600), completedAt: t(-18 * 3600)),
                run(project: "beta", itemID: "b", startedAt: t(-5 * 3600), completedAt: t(-2 * 3600))
            ],
            grooming: [],
            period: period)

        XCTAssertEqual(report.total.idle, 19 * 3600, accuracy: 1)
    }

    /// A run that began before the window is clipped to it, so it cannot report
    /// more busy time than the window holds — the property the sum had and the
    /// union must keep.
    func testARunThatStartedBeforeThePeriodIsClippedToIt() {
        let period = PortfolioReport.Period.last(hours: 24, endingAt: t(0))
        let report = PortfolioReport.make(
            runs: [run(project: "alpha", itemID: "a",
                       startedAt: t(-40 * 3600), completedAt: t(-22 * 3600))],
            grooming: [],
            period: period)

        XCTAssertEqual(report.total.idle, 22 * 3600, accuracy: 1,
                       "only the two hours inside the window count as busy")
        XCTAssertEqual(report.rows.first?.idle ?? -1, 22 * 3600, accuracy: 1)
    }

    /// One project is the case the total already got right, and the fix must not
    /// move it: consecutive runs in one project sum exactly as they did.
    func testASingleProjectsArithmeticIsUnchanged() {
        let period = PortfolioReport.Period.last(hours: 24, endingAt: t(0))
        let report = PortfolioReport.make(
            runs: [
                run(project: "alpha", itemID: "a", startedAt: t(-6 * 3600), completedAt: t(-5 * 3600)),
                run(project: "alpha", itemID: "b", startedAt: t(-3 * 3600), completedAt: t(-1 * 3600))
            ],
            grooming: [checkFailed(project: "alpha", itemID: "foo", at: t(-7 * 3600))],
            period: period)

        XCTAssertEqual(report.total.idle, 21 * 3600, accuracy: 1)
        XCTAssertEqual(report.total.skippedByCheck, 1)
        XCTAssertEqual(report.rows.count, 1)
        XCTAssertEqual(report.rows[0], report.total.withName(report.rows[0].projectName),
                       "with nothing to mix, the total is the one project row verbatim")
    }

    // MARK: - Skipped items across projects

    /// The same item id in two projects is two refusals. Keyed on the id alone
    /// they collapsed into one, and the total under-reported what never ran —
    /// the cross-project id collision the verdict keys already guard against.
    func testTheSameItemIDRefusedInTwoProjectsCountsTwiceInTheTotal() {
        let period = PortfolioReport.Period.last(hours: 24, endingAt: t(0))
        let report = PortfolioReport.make(
            runs: [],
            grooming: [
                checkFailed(project: "alpha", itemID: "foo", at: t(-3600)),
                checkFailed(project: "beta", itemID: "foo", at: t(-1800))
            ],
            period: period)

        XCTAssertEqual(report.total.skippedByCheck, 2)
        XCTAssertEqual(report.rows.count, 2)
        for row in report.rows {
            XCTAssertEqual(row.skippedByCheck, 1, "\(row.projectName) refused one item")
        }
    }

    /// Deduplication is still what the set is for: an item refused twice in one
    /// project — re-groomed, refused again — is one item that never ran.
    func testAnItemRefusedTwiceInOneProjectCountsOnce() {
        let period = PortfolioReport.Period.last(hours: 24, endingAt: t(0))
        let report = PortfolioReport.make(
            runs: [],
            grooming: [
                checkFailed(project: "alpha", itemID: "foo", at: t(-3600)),
                checkFailed(project: "alpha", itemID: "foo", at: t(-1800))
            ],
            period: period)

        XCTAssertEqual(report.total.skippedByCheck, 1)
    }

    // MARK: - Attempts that never ran

    /// A pickup refusal now writes a row to the run ledger, so the retry ceiling
    /// can count it — but this report already has it, once, as the
    /// `skippedByCheck` the same moment wrote to the grooming ledger. Counted
    /// here as well it would be said twice, the second time as a run that never
    /// happened, and it would divide the merge rate by itself.
    func testARefusalAtPickupIsNotCountedAsARun() {
        let period = PortfolioReport.Period.last(hours: 24, endingAt: t(0))
        let report = PortfolioReport.make(
            runs: [
                run(itemID: "a", merged: true, completedAt: t(-3600)),
                refusal(itemID: "foo", at: t(-1800)),
            ],
            grooming: [checkFailed(project: "alpha", itemID: "foo", at: t(-1800))],
            period: period)

        XCTAssertEqual(report.total.run, 1, "one run happened")
        XCTAssertEqual(report.total.skippedByCheck, 1, "and the refusal is counted there, once")
        XCTAssertEqual(report.total.mergeRate.text, "1/1 run (100%)",
                       "the refusal must not divide the rate")
        XCTAssertEqual(report.total.spendUSD, 1.0, accuracy: 0.0001)
    }

    // MARK: - Fixtures

    private func refusal(itemID: String, at: Date) -> TaskMetricRecord {
        RetryCeiling.refusalRecord(
            item: BacklogItem(id: itemID, title: "Task \(itemID)", verify: nil, status: .ready,
                              type: .local, size: .m, queries: nil, cost: nil, completedDate: nil,
                              blockedReason: nil, jiraKey: nil, team: nil, detailPath: nil),
            refusal: .notGrounded, projectPath: "/tmp/alpha", projectName: "alpha", at: at)
    }

    private func t(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_770_000_000 + offset)
    }

    private func run(itemID: String, merged: Bool?, completedAt: Date) -> TaskMetricRecord {
        var record = run(project: "alpha", itemID: itemID,
                         startedAt: completedAt.addingTimeInterval(-600), completedAt: completedAt)
        record.merged = merged
        return record
    }

    private func run(project: String,
                     itemID: String,
                     startedAt: Date,
                     completedAt: Date) -> TaskMetricRecord {
        TaskMetricRecord(
            projectPath: "/tmp/\(project)", projectName: project, itemID: itemID,
            title: "Task \(itemID)", epic: nil, declaredSize: "M",
            startedAt: startedAt, completedAt: completedAt,
            durationSeconds: completedAt.timeIntervalSince(startedAt), costUSD: 1.0,
            reviewerRetries: 0, outcome: "done",
            workerAgent: "Builder", reviewerAgent: "Reviewer",
            executionID: "exec-\(project)-\(itemID)")
    }

    private func checkFailed(project: String, itemID: String, at: Date) -> GroomingRecord {
        GroomingRecord(at: at, projectPath: "/tmp/\(project)", projectName: project,
                       itemID: itemID, event: .checkFailed,
                       check: GroomingRecord.Check.definitionOfReady,
                       reason: "no verify: command")
    }
}

private extension PortfolioReport.Row {
    /// The total row under a project row's name, so the two can be compared as
    /// whole values when there is only one project to total.
    func withName(_ name: String) -> PortfolioReport.Row {
        PortfolioReport.Row(
            projectName: name, filed: filed, ready: ready, draft: draft, run: run,
            merged: merged, rejected: rejected, awaitingApproval: awaitingApproval,
            skippedByCheck: skippedByCheck, spendUSD: spendUSD, idle: idle,
            mergeRate: mergeRate, causes: causes)
    }
}
