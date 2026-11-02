import XCTest
import KiteloopCore
@testable import Kiteloop

/// The join behind the item page's Runs section.
///
/// Two ledgers record the same runs. `task-metrics.jsonl` measures them; the
/// control server's `control-runs.jsonl` is the only place a *reason* is a field
/// — a red history row said `blocked` and the sentence explaining it was in a
/// file nothing in the app pointed at. These are the rules that put the two on
/// one row without inventing a third account of the same night.
final class ItemRunHistoryTests: XCTestCase {

    private static let start = Date(timeIntervalSince1970: 1_770_000_000)

    // MARK: - Order and identity

    /// Newest first, whatever order either ledger hands its records over in. The
    /// question a reader has is "what happened last", and a list that answers it
    /// in file order answers a different one.
    func testRowsAreNewestFirstAcrossBothLedgers() {
        let rows = ItemRunHistory.rows(
            metrics: [metric(execution: "exec-old", startedAt: Self.start),
                      metric(execution: "exec-new", startedAt: Self.start.addingTimeInterval(7200))],
            controlRuns: [control(runId: "run-mid", execution: nil,
                                  startedAt: Self.start.addingTimeInterval(3600))])

        XCTAssertEqual(rows.map(\.id), ["exec-new", "run-mid", "exec-old"])
    }

    /// One run, one row. The two ledgers name the same run by its execution id,
    /// and a run listed twice reads as an item that was attempted twice —
    /// which is the number the summary above the list then reports.
    func testAControlRecordNamingAMeasuredRunDoesNotBecomeASecondRow() {
        let rows = ItemRunHistory.rows(
            metrics: [metric(execution: "exec-1")],
            controlRuns: [control(runId: "run-1", execution: "exec-1")])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, "exec-1")
        XCTAssertTrue(rows[0].isMeasured)
    }

    /// The scheduler closes a run without an execution id when the autopilot's
    /// id did not change, so a control record can name the run only by when
    /// it started. Started within two minutes of the measured run, it is that
    /// run — one row, not two.
    func testAControlRecordWithoutAnExecutionIdJoinsTheRunThatStartedWithIt() {
        let rows = ItemRunHistory.rows(
            metrics: [metric(execution: "exec-1", startedAt: Self.start)],
            controlRuns: [control(runId: "run-1", execution: nil, outcome: nil,
                                  startedAt: Self.start.addingTimeInterval(20))])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, "exec-1")
        XCTAssertTrue(rows[0].isMeasured)
    }

    /// A start the pickup gates refused reached no workflow, so nothing
    /// measured it — and the run that follows it, seconds later, is a
    /// different run. Joined to that measurement the refusal lost its row and
    /// handed the measured run its reason: the exact disappearance this join
    /// exists to prevent.
    func testARefusedStartKeepsItsOwnRowRatherThanJoiningTheRunAfterIt() {
        let rows = ItemRunHistory.rows(
            metrics: [metric(execution: "exec-1", outcome: "done",
                             startedAt: Self.start.addingTimeInterval(30))],
            controlRuns: [control(runId: "run-refused", execution: nil, outcome: .didNotRun,
                                  startedAt: Self.start,
                                  reason: "needs:item-0 is not done")])

        XCTAssertEqual(rows.map(\.id), ["exec-1", "run-refused"])
        XCTAssertNil(rows[0].reason)
        XCTAssertTrue(rows[0].isMeasured)
        XCTAssertEqual(rows[1].outcome, "did-not-run")
        XCTAssertEqual(rows[1].reason, "needs:item-0 is not done")
    }

    /// Two unstamped records inside the tolerance and one measurement: the
    /// record that started nearest is the one that describes it. The records
    /// arrive in any order, so the answer must not be whichever the array
    /// happens to hold first.
    func testAMeasuredRunJoinsTheNearestUnstampedRecordWhateverTheOrder() {
        let near = control(runId: "run-near", execution: nil, outcome: nil,
                           startedAt: Self.start.addingTimeInterval(20), reason: "near")
        let far = control(runId: "run-far", execution: nil, outcome: nil,
                          startedAt: Self.start.addingTimeInterval(100), reason: "far")

        for records in [[near, far], [far, near]] {
            let rows = ItemRunHistory.rows(
                metrics: [metric(execution: "exec-1", outcome: "blocked", startedAt: Self.start)],
                controlRuns: records)

            XCTAssertEqual(rows.count, 2)
            let measured = rows.first { $0.isMeasured }
            XCTAssertEqual(measured?.reason, "near")
            XCTAssertEqual(rows.first { !$0.isMeasured }?.id, "run-far")
        }
    }

    /// One record describes one run. Inside the tolerance of two measurements
    /// it can only be the twin of one of them — read twice, it would put the
    /// same reason and branch on two rows.
    func testAnUnstampedRecordIsReadByAtMostOneMeasuredRun() {
        let rows = ItemRunHistory.rows(
            metrics: [metric(execution: "exec-1", outcome: "blocked", startedAt: Self.start),
                      metric(execution: "exec-2", outcome: "blocked",
                             startedAt: Self.start.addingTimeInterval(60))],
            controlRuns: [control(runId: "run-1", execution: nil, outcome: nil,
                                  startedAt: Self.start.addingTimeInterval(20),
                                  reason: "the only record")])

        XCTAssertEqual(rows.map(\.id), ["exec-2", "exec-1"])
        XCTAssertEqual(rows.compactMap(\.reason), ["the only record"])
        XCTAssertEqual(rows.first { $0.reason != nil }?.id, "exec-1")
    }

    /// A run still going has no ending yet — and says that, rather than
    /// reading as one nobody ever recorded.
    func testARunStillInFlightReadsAsInProgressNotUnfinished() {
        let control = control(runId: "run-1", execution: nil, outcome: nil)

        let live = ItemRunHistory.rows(metrics: [], controlRuns: [control], inFlight: true)
        let dead = ItemRunHistory.rows(metrics: [], controlRuns: [control], inFlight: false)

        XCTAssertEqual(live[0].outcome, "in progress")
        XCTAssertEqual(live[0].reason, "still running — the ending is written when the gate answers")
        XCTAssertEqual(dead[0].outcome, "unfinished")
        XCTAssertEqual(dead[0].reason, "no ending was ever recorded for this run")
    }

    // MARK: - The reason

    /// The gap this section was built to close: the outcome carries the reason
    /// in its tail, and the page is the one place that wants the two apart.
    func testABlockedRunSaysWhyOnItsOwnRow() {
        let rows = ItemRunHistory.rows(
            metrics: [metric(execution: "exec-1", outcome: "blocked:review did not pass")],
            controlRuns: [])

        XCTAssertEqual(rows[0].outcome, "blocked")
        XCTAssertEqual(rows[0].reason, "review did not pass")
        XCTAssertFalse(rows[0].isPass)
    }

    /// And where the measurement's outcome is a bare `blocked`, the sentence
    /// comes from the control record — the one that lived only in
    /// `control-runs.jsonl`.
    func testTheControlRecordSuppliesTheReasonTheMetricDoesNotCarry() {
        let rows = ItemRunHistory.rows(
            metrics: [metric(execution: "exec-1", outcome: "blocked")],
            controlRuns: [control(runId: "run-1", execution: "exec-1",
                                  reason: "cost cap $8.00 exceeded")])

        XCTAssertEqual(rows[0].outcome, "blocked")
        XCTAssertEqual(rows[0].reason, "cost cap $8.00 exceeded")
    }

    /// A pass has no reason to give. `done` never carries one, and a control
    /// record left over from an earlier attempt must not put a refusal under a
    /// row that succeeded.
    func testAPassCarriesNoReason() {
        let rows = ItemRunHistory.rows(
            metrics: [metric(execution: "exec-1", outcome: "done")],
            controlRuns: [control(runId: "run-1", execution: "exec-1", reason: "stalled")])

        XCTAssertTrue(rows[0].isPass)
        XCTAssertNil(rows[0].reason)
    }

    /// Parked for approval is a pass — the agents finished, the human hasn't —
    /// which is the rule the run history and the run badge already apply. The
    /// control store spells it for the wire; the app spells it with a hyphen,
    /// and a row that disagreed would be a pass on one screen and a failure on
    /// the next.
    func testAwaitingApprovalIsAPassInEitherSpelling() {
        let measured = ItemRunHistory.rows(
            metrics: [metric(execution: "exec-1", outcome: "awaiting-approval")],
            controlRuns: [])
        let recorded = ItemRunHistory.rows(
            metrics: [],
            controlRuns: [control(runId: "run-1", execution: nil, outcome: .awaitingApproval)])

        XCTAssertTrue(measured[0].isPass)
        XCTAssertEqual(recorded[0].outcome, "awaiting-approval")
        XCTAssertTrue(recorded[0].isPass)
    }

    /// A pickup gate's refusal is recorded on the wire as `did_not_run`; the row
    /// spells it the way every other outcome on screen is spelled.
    func testADidNotRunRefusalReadsWithAHyphenNotAnUnderscore() {
        let rows = ItemRunHistory.rows(
            metrics: [],
            controlRuns: [control(runId: "run-1", execution: nil, outcome: .didNotRun)])

        XCTAssertEqual(rows[0].outcome, "did-not-run")
        XCTAssertFalse(rows[0].isPass)
    }

    /// No future outcome can reach the row still wearing the wire's underscore:
    /// every case in `PersistedRunRecord.Outcome` must come out hyphenated.
    func testEveryOutcomeReadsWithNoUnderscoreOnTheRow() {
        for outcome in PersistedRunRecord.Outcome.allCases {
            let rows = ItemRunHistory.rows(
                metrics: [],
                controlRuns: [control(runId: "run-1", execution: nil, outcome: outcome)])

            XCTAssertFalse(rows[0].outcome.contains("_"),
                           "\(outcome.rawValue) reached the row as \(rows[0].outcome)")
        }
    }

    // MARK: - Runs nothing measured

    /// A run the app died under has a control record and no measurement at all.
    /// It is still a row: a run that vanishes from the list is exactly the hole
    /// this join exists to fill.
    func testAnInterruptedRunWithNoMeasurementIsStillARow() {
        let rows = ItemRunHistory.rows(
            metrics: [],
            controlRuns: [control(runId: "run-1", execution: nil, outcome: .interrupted)])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].outcome, "interrupted")
        XCTAssertFalse(rows[0].isMeasured)
        XCTAssertNil(rows[0].durationSeconds, "nothing timed it — which is not a run of zero length")
        XCTAssertNil(rows[0].costUSD, "and nothing priced it — which is not a free run")
    }

    /// A record with no ending at all says so in words. An empty outcome column
    /// reads as a rendering bug rather than as a run whose ending was never
    /// written down.
    func testARecordWithNoEndingSaysThatInsteadOfShowingNothing() {
        let rows = ItemRunHistory.rows(
            metrics: [],
            controlRuns: [control(runId: "run-1", execution: nil, outcome: nil)])

        XCTAssertEqual(rows[0].outcome, "unfinished")
        XCTAssertEqual(rows[0].reason, "no ending was ever recorded for this run")
    }

    // MARK: - What the row carries

    /// The branch and the PR are the control record's to give — the measurement
    /// has neither — and the chip on the row is what makes a finished run's work
    /// findable.
    func testTheBranchAndPullRequestComeFromTheControlRecord() {
        let rows = ItemRunHistory.rows(
            metrics: [metric(execution: "exec-1")],
            controlRuns: [control(runId: "run-1", execution: "exec-1",
                                  branch: "kiteloop/item-1",
                                  pullRequestURL: "https://example.com/pr/1")])

        XCTAssertEqual(rows[0].branch, "kiteloop/item-1")
        XCTAssertEqual(rows[0].pullRequestURL, "https://example.com/pr/1")
    }

    /// The measurement decides every figure it carries, so a control record's
    /// cost never overwrites the metered one. Two answers to "what did this run
    /// cost" is the drift this mapping exists to avoid.
    func testTheMeasurementWinsOnFiguresItRecorded() {
        let rows = ItemRunHistory.rows(
            metrics: [metric(execution: "exec-1", costUSD: 3.50, duration: 600)],
            controlRuns: [control(runId: "run-1", execution: "exec-1",
                                  costUSD: 99, durationSec: 1)])

        XCTAssertEqual(rows[0].costUSD, 3.50)
        XCTAssertEqual(rows[0].durationSeconds, 600)
    }

    // MARK: - Summary

    /// Attempts, spend and time, over exactly the rows on screen — the summary
    /// is a sum of the list, not a second account of the same runs.
    func testTheSummaryTotalsTheRowsBelowIt() {
        let rows = ItemRunHistory.rows(
            metrics: [metric(execution: "exec-1", costUSD: 3.50, duration: 600),
                      metric(execution: "exec-2", costUSD: 4.25, duration: 1800,
                             startedAt: Self.start.addingTimeInterval(3600))],
            controlRuns: [])

        let summary = ItemRunHistory.summary(of: rows)

        XCTAssertEqual(summary.attempts, 2)
        XCTAssertEqual(summary.totalCostUSD, 7.75, accuracy: 0.0001)
        XCTAssertEqual(summary.totalDurationSeconds, 2400)
        XCTAssertEqual(summary.text, "2 attempts · $7.75 · 40m")
        XCTAssertEqual(summary.unmeasuredRuns, 0)
        XCTAssertNil(summary.note, "nothing was left out, so there is nothing to say about it")
    }

    /// A run that recorded how long it took and not what it cost is missing from
    /// the spend on screen just as surely as one that recorded neither — so it
    /// is unmeasured, and the note says which figure went missing. It used to
    /// count as neither, leaving the spend short with nothing on screen saying so.
    func testARunThatRecordedADurationAndNoCostIsUnmeasured() {
        let rows = ItemRunHistory.rows(
            metrics: [metric(execution: "exec-1", costUSD: 3.50, duration: 600)],
            controlRuns: [control(runId: "run-1", execution: nil, outcome: .interrupted,
                                  startedAt: Self.start.addingTimeInterval(3600),
                                  costUSD: nil, durationSec: 300)])

        let summary = ItemRunHistory.summary(of: rows)

        XCTAssertEqual(summary.attempts, 2)
        XCTAssertEqual(summary.unmeasuredRuns, 1)
        XCTAssertEqual(summary.totalCostUSD, 3.50, accuracy: 0.0001,
                       "the run's cost is unknown, not zero — the total is what was measured")
        XCTAssertEqual(summary.totalDurationSeconds, 900,
                       "the length it did record still counts towards the time")
        XCTAssertEqual(summary.note,
                       "1 run recorded no cost, so these totals are a floor")
    }

    /// The other half of the same rule: a cost with no length beside it leaves
    /// the total run time short, and the note names that figure rather than both.
    func testARunThatRecordedACostAndNoDurationIsUnmeasured() {
        let rows = ItemRunHistory.rows(
            metrics: [metric(execution: "exec-1", costUSD: 3.50, duration: 600)],
            controlRuns: [control(runId: "run-1", execution: nil, outcome: .interrupted,
                                  startedAt: Self.start.addingTimeInterval(3600),
                                  costUSD: 1.25, durationSec: nil)])

        let summary = ItemRunHistory.summary(of: rows)

        XCTAssertEqual(summary.unmeasuredRuns, 1)
        XCTAssertEqual(summary.totalCostUSD, 4.75, accuracy: 0.0001)
        XCTAssertEqual(summary.totalDurationSeconds, 600)
        XCTAssertEqual(summary.note,
                       "1 run recorded no duration, so these totals are a floor")
    }

    /// One row short of a cost and another short of a length: neither sentence
    /// about a single missing figure is true of both, so the note says what it
    /// can rather than claiming either run recorded nothing.
    func testTheNoteDoesNotClaimBothFiguresWentMissingFromEveryRun() {
        let rows = ItemRunHistory.rows(
            metrics: [],
            controlRuns: [control(runId: "run-1", execution: nil, outcome: .interrupted,
                                  costUSD: nil, durationSec: 300),
                          control(runId: "run-2", execution: nil, outcome: .interrupted,
                                  startedAt: Self.start.addingTimeInterval(3600),
                                  costUSD: 1.25, durationSec: nil)])

        let summary = ItemRunHistory.summary(of: rows)

        XCTAssertEqual(summary.unmeasuredRuns, 2)
        XCTAssertEqual(summary.note,
                       "2 runs are missing a cost or a duration, so these totals are a floor")
    }

    /// A run nothing measured contributes nothing to the totals — and the
    /// summary says so, rather than counting it as zero and reading like a
    /// complete account of the item's spend.
    func testTotalsSayWhenARunContributedNothingToThem() {
        let rows = ItemRunHistory.rows(
            metrics: [metric(execution: "exec-1", costUSD: 3.50, duration: 600)],
            controlRuns: [control(runId: "run-1", execution: nil, outcome: .interrupted,
                                  startedAt: Self.start.addingTimeInterval(3600),
                                  costUSD: nil, durationSec: nil)])

        let summary = ItemRunHistory.summary(of: rows)

        XCTAssertEqual(summary.attempts, 2, "it was an attempt, whatever was measured of it")
        XCTAssertEqual(summary.totalCostUSD, 3.50, accuracy: 0.0001)
        XCTAssertEqual(summary.totalDurationSeconds, 600)
        XCTAssertEqual(summary.unmeasuredRuns, 1)
        XCTAssertEqual(summary.note,
                       "1 run recorded no cost or duration, so these totals are a floor")
    }

    /// An item nobody has run has no rows and no totals to report.
    func testAnItemThatNeverRanHasNoRows() {
        let rows = ItemRunHistory.rows(metrics: [], controlRuns: [])

        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(ItemRunHistory.summary(of: rows).attempts, 0)
    }

    /// One attempt is one attempt — the summary is read by a person, not by a
    /// parser.
    func testTheSummaryReadsAsASentenceForASingleRun() {
        let rows = ItemRunHistory.rows(
            metrics: [metric(execution: "exec-1", costUSD: 1.20, duration: 45)],
            controlRuns: [])

        XCTAssertEqual(ItemRunHistory.summary(of: rows).text, "1 attempt · $1.20 · 45s")
    }

    /// Hours are said as hours. A night's runs on one item total into the
    /// thousands of seconds, and `4260s` is not a length anybody reads.
    func testLongTotalsAreSaidInHoursAndMinutes() {
        XCTAssertEqual(ItemRunHistory.durationText(4260), "1h 11m")
        XCTAssertEqual(ItemRunHistory.durationText(59), "59s")
        XCTAssertEqual(ItemRunHistory.durationText(60), "1m")
    }

    // MARK: - Review rounds

    /// What this feature exists to make readable: a rejection and the review
    /// after the rework — two rounds, in order, each with its own verdict and
    /// counts, on the row's own field.
    func testATwoRoundRejectPassRunCarriesBothRounds() {
        let rounds = [
            ReviewRound(label: "review 1", verdict: .rejected, blockingCount: 2),
            ReviewRound(label: "review 2", verdict: .passed),
        ]
        let rows = ItemRunHistory.rows(
            metrics: [metric(execution: "exec-1", reviewRounds: rounds)],
            controlRuns: [])

        XCTAssertEqual(rows[0].rounds.map(\.label), ["review 1", "review 2"])
        XCTAssertEqual(rows[0].rounds.map(\.verdict), [.rejected, .passed])
        XCTAssertEqual(rows[0].rounds[0].blockingCount, 2)
        XCTAssertTrue(rows[0].showsRoundDetail, "a rejected round is exactly what the detail exists to show")
    }

    /// The common case: a first review that passed. One round, and the page
    /// must not grow to say so a second time.
    func testAFirstRoundPassCollapsesTheRoundDetail() {
        let rows = ItemRunHistory.rows(
            metrics: [metric(execution: "exec-1",
                             reviewRounds: [ReviewRound(label: "review 1", verdict: .passed)])],
            controlRuns: [])

        XCTAssertEqual(rows[0].rounds.count, 1)
        XCTAssertFalse(rows[0].showsRoundDetail, "a single pass has nothing more to say than the row above it")
    }

    /// A run the watchdog killed in the worker — a stall, a cost cap — never
    /// reached a reviewer. Empty, not a crash, and nothing to show.
    func testARunWithNoReviewEventsHasAnEmptyRoundsList() {
        let rows = ItemRunHistory.rows(
            metrics: [metric(execution: "exec-1", outcome: "blocked:stalled: no progress")],
            controlRuns: [])

        XCTAssertEqual(rows[0].rounds, [])
        XCTAssertFalse(rows[0].showsRoundDetail)
    }

    // MARK: - Quality pill

    /// A judged run shows its score as a whole percentage.
    func testAScoredRunShowsItsScoreAsAPercentage() {
        var judged = metric(execution: "exec-1")
        judged.qualityScore = 0.847
        let rows = ItemRunHistory.rows(metrics: [judged], controlRuns: [])

        XCTAssertEqual(rows[0].qualityMark, .scored("85%"))
    }

    /// A run the judge could not score says so, and why — rather than reading
    /// as a run that scored nothing.
    func testARunTheJudgeCouldNotScoreSaysWhy() {
        var unjudged = metric(execution: "exec-1")
        unjudged.judgeUnavailableReason = "the diff was empty"
        let rows = ItemRunHistory.rows(metrics: [unjudged], controlRuns: [])

        XCTAssertEqual(rows[0].qualityMark, .unscored(reason: "the diff was empty"))
    }

    /// A run nobody judged shows no pill at all.
    func testARunNobodyJudgedHasNoPill() {
        let rows = ItemRunHistory.rows(metrics: [metric(execution: "exec-1")],
                                       controlRuns: [control(runId: "run-2", execution: nil,
                                                             startedAt: Self.start.addingTimeInterval(3600))])

        XCTAssertEqual(rows.map(\.qualityMark), [nil, nil])
    }

    // MARK: - Fixtures

    private func metric(execution: String,
                        outcome: String = "done",
                        costUSD: Double = 1,
                        duration: Double = 600,
                        startedAt: Date = ItemRunHistoryTests.start,
                        reviewRounds: [ReviewRound]? = nil) -> TaskMetricRecord {
        var record = TaskMetricRecord(
            projectPath: "/tmp/p", projectName: "p", itemID: "item-1", title: "Item",
            epic: nil, declaredSize: "M", startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(duration), durationSeconds: duration,
            costUSD: costUSD, reviewerRetries: 0, outcome: outcome, workerAgent: "Builder",
            reviewerAgent: "Reviewer", executionID: execution)
        record.reviewRounds = reviewRounds
        return record
    }

    private func control(runId: String,
                         execution: String?,
                         outcome: PersistedRunRecord.Outcome? = .blocked,
                         startedAt: Date = ItemRunHistoryTests.start,
                         reason: String? = nil,
                         branch: String? = nil,
                         pullRequestURL: String? = nil,
                         costUSD: Double? = nil,
                         durationSec: Int? = nil) -> PersistedRunRecord {
        var record = PersistedRunRecord(runId: runId, projectID: "/tmp/p", itemID: "item-1",
                                        title: "Item", startedAt: startedAt)
        record.executionID = execution
        record.outcome = outcome
        record.reason = reason
        record.branch = branch
        record.pullRequestURL = pullRequestURL
        record.costUSD = costUSD
        record.durationSec = durationSec
        return record
    }
}
