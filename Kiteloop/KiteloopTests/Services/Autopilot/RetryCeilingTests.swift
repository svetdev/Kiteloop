import XCTest
import KiteloopCore
@testable import Kiteloop

/// The lifetime bound on an item that produces nothing.
///
/// What is worth pinning down is every way the count could be lost or
/// misattributed — because losing it is exactly what happened: the within-run
/// breaker's counter is reset at the start of every run, so a driver starting a
/// fresh run per item never trips it, and `control-openapi` was started 231
/// times on 2026-08-08. So: the count comes off recorded history and therefore
/// survives a restart; a real attempt is not mistaken for an empty one; and one
/// project's history does not retire another project's item.
final class RetryCeilingTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_800_000_000)

    /// A recorded run. The outcome strings are the ones the run loop actually
    /// writes — `RunWorkEvidence.noWorkPrefix` is what `producedWork` reads.
    private func record(
        itemID: String = "control-openapi",
        project: String = "/tmp/kiteloop",
        outcome: String,
        changedFileCount: Int? = nil,
        at offset: TimeInterval = 0
    ) -> TaskMetricRecord {
        let end = day.addingTimeInterval(offset)
        var record = TaskMetricRecord(
            projectPath: project, projectName: "kiteloop", itemID: itemID, title: "Publish an OpenAPI spec",
            epic: nil, declaredSize: "M", startedAt: end.addingTimeInterval(-600),
            completedAt: end, durationSeconds: 600, costUSD: 0, reviewerRetries: 0,
            outcome: outcome, workerAgent: "worker", reviewerAgent: "reviewer",
            executionID: "e-1", toolErrors: nil
        )
        record.changedFileCount = changedFileCount
        return record
    }

    /// The shape of a run that produced nothing at all — the dead-session case,
    /// verbatim from 2026-08-08's ledger.
    private func empty(_ offset: TimeInterval = 0, itemID: String = "control-openapi",
                       project: String = "/tmp/kiteloop") -> TaskMetricRecord {
        record(itemID: itemID, project: project,
               outcome: "blocked:\(RunWorkEvidence.noWorkPrefix) — no commits and an unchanged worktree",
               at: offset)
    }

    /// A run that changed nothing and said, with evidence, that the item was
    /// already built — in the outcome the run loop writes for it. The file count
    /// is 0 and that is the truth: no diff exists, which is exactly why the
    /// exemption has to be keyed on the outcome rather than on the measurement.
    private func alreadyImplemented(_ offset: TimeInterval = 0,
                                    itemID: String = "control-openapi",
                                    project: String = "/tmp/kiteloop") -> TaskMetricRecord {
        record(itemID: itemID, project: project,
               outcome: BacklogAutopilot.outcomeString(.alreadyImplemented),
               changedFileCount: 0, at: offset)
    }

    /// A run the stall watchdog ended, in the words the run loop writes. No file
    /// count by default: that is the live-tree run, and the record the ledger
    /// actually holds for 2026-08-08 predates the field entirely.
    private func stalled(_ offset: TimeInterval = 0, changedFileCount: Int? = nil,
                         itemID: String = "control-openapi",
                         project: String = "/tmp/kiteloop") -> TaskMetricRecord {
        record(itemID: itemID, project: project,
               outcome: "blocked:stalled: no progress for 20 min on worker",
               changedFileCount: changedFileCount, at: offset)
    }

    /// A run whose reviewer answered in a form nothing could route, in the words
    /// the run loop writes (`"blocked:" + unreadableVerdictReason`). A file count
    /// is the *normal* case here, not the exception: the worker had written its
    /// files long before the reviewer failed to say anything about them, and all
    /// five such runs in the ledger carry one.
    private func unreadableVerdict(_ offset: TimeInterval = 0, changedFileCount: Int? = nil,
                                   itemID: String = "control-openapi",
                                   project: String = "/tmp/kiteloop") -> TaskMetricRecord {
        record(itemID: itemID, project: project,
               outcome: "blocked:\(BacklogAutopilot.unreadableVerdictReason)",
               changedFileCount: changedFileCount, at: offset)
    }

    private func verdict(_ records: [TaskMetricRecord],
                         itemID: String = "control-openapi",
                         project: String? = "/tmp/kiteloop") -> RetryCeiling.Verdict {
        RetryCeiling.evaluate(itemID: itemID, projectPath: project, records: records)
    }

    // MARK: - The ceiling

    /// N empty attempts, no N+1th.
    func testAnItemIsRetiredOnceItHitsTheCeiling() {
        XCTAssertEqual(RetryCeiling.limit, 3)

        XCTAssertFalse(verdict([empty(0)]).isRetired)
        XCTAssertFalse(verdict([empty(0), empty(60)]).isRetired)

        let third = verdict([empty(0), empty(60), empty(120)])
        XCTAssertTrue(third.isRetired)
        XCTAssertEqual(third.noWorkAttempts, 3)
    }

    func testAnItemWithNoHistoryIsRunnable() {
        let clean = verdict([])
        XCTAssertFalse(clean.isRetired)
        XCTAssertEqual(clean.noWorkAttempts, 0)
    }

    /// Past the ceiling stays retired — the count keeps rising, and the verdict
    /// reports what it actually is rather than clamping at the limit, because
    /// "231 attempts" is the number that tells a human what happened.
    func testThePastTheCeilingCountIsReportedInFull() {
        let history = (0..<231).map { empty(TimeInterval($0) * 60) }
        let judged = verdict(history)

        XCTAssertTrue(judged.isRetired)
        XCTAssertEqual(judged.noWorkAttempts, 231)
    }

    // MARK: - What counts as an attempt

    /// The distinction the whole ceiling turns on: an item bounced by a reviewer
    /// was attempted on its merits and may be reworked. Retiring it would retire
    /// items that are simply hard.
    func testAReviewRejectionIsARealAttemptAndDoesNotCount() {
        let history = [
            record(outcome: "blocked:review did not pass", changedFileCount: 4, at: 0),
            record(outcome: "blocked:review did not pass", changedFileCount: 2, at: 60),
            record(outcome: "blocked:review did not pass", changedFileCount: 7, at: 120),
            record(outcome: "blocked:review did not pass", changedFileCount: 1, at: 180),
        ]
        let judged = verdict(history)

        XCTAssertEqual(judged.noWorkAttempts, 0)
        XCTAssertFalse(judged.isRetired, "Four rejections on the merits is not four empty runs")
    }

    /// A rejection whose diff nobody could read (no branch to inspect, a
    /// live-tree run) is still an attempt: `producedWork` only calls a run empty
    /// when something says so.
    func testARejectionWithNoRecordedFileCountIsStillARealAttempt() {
        XCTAssertEqual(verdict([
            record(outcome: "blocked:review did not pass", at: 0),
            record(outcome: "blocked:review did not pass", at: 60),
            record(outcome: "blocked:review did not pass", at: 120),
        ]).noWorkAttempts, 0)
    }

    func testAnAttemptThatProducedWorkClearsTheCount() {
        let history = [
            empty(0), empty(60),
            record(outcome: "awaiting-approval", changedFileCount: 3, at: 120),
            empty(180),
        ]
        let judged = verdict(history)

        XCTAssertEqual(judged.noWorkAttempts, 1, "Only the empty run after the delivery counts")
        XCTAssertFalse(judged.isRetired)
    }

    /// An item that delivered and was later reopened starts fresh — otherwise a
    /// long-lived item accumulates a retirement it earned in a previous life.
    func testAnItemThatDeliveredAndWasReopenedStartsFresh() {
        let history = [empty(0), empty(60), empty(120),
                       record(outcome: "done", changedFileCount: 9, at: 180)]

        XCTAssertFalse(verdict(history).isRetired)
        XCTAssertEqual(verdict(history).noWorkAttempts, 0)
    }

    /// A cancelled run says nothing about the item — it was stopped before it
    /// could. Counting it would retire items for having been interrupted;
    /// clearing on it would hand a stuck item three fresh attempts per cancel.
    func testACancelledRunNeitherCountsNorClears() {
        XCTAssertEqual(verdict([empty(0), record(outcome: "cancelled:stopped by user", at: 60)])
                        .noWorkAttempts, 1)

        let stillRetired = verdict([empty(0), empty(60),
                                    record(outcome: "cancelled:stopped by user", at: 120),
                                    empty(180)])
        XCTAssertEqual(stillRetired.noWorkAttempts, 3)
        XCTAssertTrue(stillRetired.isRetired)
    }

    // MARK: - The run that changed nothing because there was nothing to change

    /// The whole point of the third ending. A worker that changes no files and
    /// says, with evidence, that the item is already built is doing exactly what
    /// CLAUDE.md tells it to do — and until this outcome existed that answer was
    /// filed as `run produced no work` and counted, so following the rule was
    /// what retired the item.
    func testAnEvidencedAlreadyImplementedClaimDoesNotCount() {
        XCTAssertEqual(verdict([alreadyImplemented(0)]).noWorkAttempts, 0)
    }

    /// `RetryCeiling.limit` of them in a row still leaves the item runnable —
    /// which is the shape `wizard-hands-off-to-a-first-project` was retired in
    /// on 2026-08-21, three runs by three workers, each of them right.
    func testThreeClaimsInARowDoNotRetireTheItem() {
        let history = (0..<RetryCeiling.limit).map { alreadyImplemented(TimeInterval($0) * 60) }
        let judged = verdict(history)
        XCTAssertEqual(judged.noWorkAttempts, 0)
        XCTAssertFalse(judged.isRetired)
    }

    /// Neither counts *nor clears*, exactly as a cancel doesn't: it is an answer
    /// about the item rather than an attempt at it, so it must not hand a stuck
    /// item fresh attempts either.
    func testAClaimDoesNotClearAnExistingStreak() {
        let history = [empty(0), empty(60), alreadyImplemented(120), empty(180)]
        let judged = verdict(history)
        XCTAssertEqual(judged.noWorkAttempts, 3)
        XCTAssertTrue(judged.isRetired)
    }

    /// The cheap whole-backlog pass is what marks an item as possibly retired in
    /// a list, so it has to skip the same rows `evaluate` does — a row that does
    /// not count towards retirement must not be what puts the mark there.
    func testTheByItemPassSkipsAClaimToo() {
        let streaks = RetryCeiling.noWorkAttemptsByItem(
            projectPath: "/tmp/kiteloop",
            records: [alreadyImplemented(0), alreadyImplemented(60)])
        XCTAssertNil(streaks["control-openapi"])
    }

    /// A claim is not evidence that work happened. The run left no diff, and
    /// `workEvidence` — the measurement — says so; what the outcome buys the
    /// item is exemption from the count, not a pretence that a diff exists.
    func testAClaimIsStillAnEmptyRunAsFarAsTheMeasurementGoes() {
        XCTAssertEqual(alreadyImplemented(0).workEvidence, .empty)
        XCTAssertFalse(alreadyImplemented(0).producedWork)
        XCTAssertTrue(alreadyImplemented(0).claimsAlreadyImplemented)
    }

    /// Matched exactly, and spelled the same way the run loop writes it — the
    /// same guard `outcomesReachingNoVerdict` carries, so a rename of the
    /// outcome cannot quietly empty the set that exempts it.
    func testTheClaimSetHoldsTheOutcomeTheRunLoopWrites() {
        // Two members now, both written by the run loop's no-work path: the
        // claim, and the refuted premise (`investigation`) added on purpose
        // after 2026-09-03 — an answer about the item, counted the same way.
        XCTAssertEqual(TaskMetricRecord.outcomesClaimingAlreadyImplemented,
                       [BacklogAutopilot.outcomeString(.alreadyImplemented),
                        BacklogAutopilot.outcomeString(.investigation("- refuted: one of four"))])
        XCTAssertEqual(RunWorkEvidence.AlreadyImplementedClaim.outcome,
                       TaskMetricRecord.alreadyImplementedOutcome)
        // Not one of the other two families: a claim shows no work, and it is
        // not a run that failed to reach a verdict.
        XCTAssertTrue(TaskMetricRecord.outcomesClaimingAlreadyImplemented
            .isDisjoint(with: TaskMetricRecord.outcomesShowingWork))
        XCTAssertTrue(TaskMetricRecord.outcomesClaimingAlreadyImplemented
            .isDisjoint(with: TaskMetricRecord.outcomesReachingNoVerdict))
    }

    /// An empty run that made no claim is untouched — the exemption is keyed on
    /// the outcome the claim path writes, and nothing else reaches it.
    func testAnOrdinaryEmptyRunStillCounts() {
        XCTAssertFalse(empty(0).claimsAlreadyImplemented)
        XCTAssertEqual(verdict([empty(0), empty(60), empty(120)]).noWorkAttempts, 3)
    }

    // MARK: - Runs nobody measured

    /// A stall that left no branch and no changed files is the same failure the
    /// ceiling exists to bound: the run sat for twenty minutes and produced
    /// nothing. It used to *clear* the count, because `producedWork` read every
    /// outcome it didn't recognise as work.
    func testAStalledRunThatChangedNothingCountsAsAnEmptyAttempt() {
        XCTAssertEqual(verdict([stalled(0, changedFileCount: 0)]).noWorkAttempts, 1)

        // And with no count at all — the live-tree stall, where the outcome
        // string is still the only thing to go on.
        let unmeasured = verdict([stalled(0), stalled(60), stalled(120)])
        XCTAssertEqual(unmeasured.noWorkAttempts, 3)
        XCTAssertTrue(unmeasured.isRetired)
    }

    /// The false positive that matters: a run can stall *after* writing files.
    /// That is precisely why the file count, and not the word "stalled",
    /// decides it.
    func testAStalledRunThatDidChangeFilesDoesNotAdvanceTheStreak() {
        let history = [empty(0), empty(60), stalled(120, changedFileCount: 7)]

        XCTAssertEqual(verdict(history).noWorkAttempts, 0)
        XCTAssertFalse(verdict(history).isRetired,
                       "Files on the branch are work, whatever ended the run")
    }

    /// Every other way a run can be cut short reads the same way. Assuming work
    /// happened is the direction that fails open, and an unbounded retry loop is
    /// what it costs.
    func testAnOutcomeTheCodeDoesNotRecogniseIsNotCountedAsWork() {
        for outcome in ["blocked:cost cap $8.00 exceeded ($16.95) on reviewer",
                        "blocked:max retries",
                        "blocked:timed out",
                        "blocked:a reason no build has ever written"] {
            XCTAssertEqual(verdict([record(outcome: outcome, at: 0)]).noWorkAttempts, 1, outcome)
        }
    }

    /// The counterweight, so the rule above can't be satisfied by counting
    /// everything: an outcome that could only have been reached with a diff in
    /// hand still clears the streak, file count or not.
    func testAnOutcomeThatCouldOnlyFollowRealWorkStillClearsTheStreak() {
        for outcome in ["done", "awaiting-approval", "blocked:review did not pass"] {
            XCTAssertEqual(verdict([empty(0), empty(60), record(outcome: outcome, at: 120)])
                            .noWorkAttempts, 0, outcome)
        }
    }

    /// What a record says about itself, since that is where the defect was:
    /// `empty` and `unknown` are both "no work to show", but only a measured
    /// zero is evidence the run produced nothing.
    func testARecordSeparatesAMeasuredEmptyRunFromAnUnmeasuredOne() {
        XCTAssertEqual(stalled(changedFileCount: 0).workEvidence, .empty)
        XCTAssertEqual(stalled(changedFileCount: 3).workEvidence, .produced)
        XCTAssertEqual(stalled().workEvidence, .unknown)
        XCTAssertFalse(stalled().producedWork, "Unmeasured is not productive")
        XCTAssertEqual(empty().workEvidence, .empty)
        XCTAssertEqual(record(outcome: "done").workEvidence, .produced)
    }

    // MARK: - Runs that reached no verdict

    /// The one path around the ceiling. A reviewer whose answer nothing could
    /// route left no verdict on the work, but the worker had already written
    /// files — and the file count used to decide first, so the run read as
    /// productive and cleared the streak. Every recorded instance took that
    /// path: all five such runs in the ledger changed files.
    func testAnUnreadableVerdictOverFilesIsNotWorkProduced() {
        let run = unreadableVerdict(changedFileCount: 8)

        XCTAssertEqual(run.workEvidence, .unknown,
                       "No verdict was routed, so the run says nothing on the merits")
        XCTAssertFalse(run.producedWork)
    }

    /// `.unknown` and not `.empty`: the run really did leave eight files behind,
    /// and calling that empty would misreport it to everything downstream that
    /// reads the same value.
    func testAnUnreadableVerdictIsNotReportedAsAnEmptyRun() {
        XCTAssertNotEqual(unreadableVerdict(changedFileCount: 8).workEvidence, .empty)
        XCTAssertNotEqual(unreadableVerdict(changedFileCount: 0).workEvidence, .empty,
                          "The outcome vetoes the count in both directions")
    }

    /// The reading with no count recorded — the live-tree run — is what it
    /// always was, which is the half of the rule that already worked.
    func testAnUnreadableVerdictWithNoFileCountIsUnchanged() {
        XCTAssertEqual(unreadableVerdict().workEvidence, .unknown)
        XCTAssertFalse(unreadableVerdict().producedWork)
    }

    /// What the whole item is for: such a run costs the item an attempt, so an
    /// unparseable verdict repeating forever is bounded like anything else.
    func testAnUnreadableVerdictCountsAsAnAttempt() {
        XCTAssertEqual(verdict([unreadableVerdict(0, changedFileCount: 2)]).noWorkAttempts, 1)

        let retired = verdict([unreadableVerdict(0, changedFileCount: 2),
                               unreadableVerdict(60, changedFileCount: 8),
                               unreadableVerdict(120, changedFileCount: 6)])
        XCTAssertEqual(retired.noWorkAttempts, 3)
        XCTAssertTrue(retired.isRetired, "The loop the ceiling exists to stop")
    }

    /// And it does not clear a streak already running — the other way the same
    /// defect showed, since one such run between two empty ones reset the count.
    func testAnUnreadableVerdictDoesNotClearTheStreak() {
        let history = [empty(0), unreadableVerdict(60, changedFileCount: 2), empty(120)]

        XCTAssertEqual(verdict(history).noWorkAttempts, 3)
        XCTAssertTrue(verdict(history).isRetired)
    }

    /// The portfolio-wide pass reads the same value, so a list of possibly
    /// retired items agrees with the per-item judgement it precedes.
    func testTheByItemPassCountsAnUnreadableVerdictToo() {
        let streaks = RetryCeiling.noWorkAttemptsByItem(
            projectPath: "/tmp/kiteloop",
            records: [unreadableVerdict(0, changedFileCount: 2),
                      unreadableVerdict(60, changedFileCount: 8)])

        XCTAssertEqual(streaks["control-openapi"], 2)
    }

    /// The set is matched exactly, so a rejection on the merits — the outcome it
    /// is deliberately spelled apart from — still clears the streak.
    func testARejectionIsStillAnAttemptOnTheMerits() {
        XCTAssertEqual(record(outcome: "blocked:review did not pass",
                              changedFileCount: 4).workEvidence, .produced)
        XCTAssertEqual(record(outcome: "done", changedFileCount: 4).workEvidence, .produced)
        XCTAssertEqual(record(outcome: "awaiting-approval",
                              changedFileCount: 4).workEvidence, .produced)
    }

    /// The set holds the string the run loop actually composes. Spelled as a
    /// literal beside `outcomesShowingWork`, so this is what stops a rename of
    /// the reason from quietly emptying it.
    func testTheSetHoldsTheOutcomeTheRunLoopWrites() {
        XCTAssertEqual(TaskMetricRecord.outcomesReachingNoVerdict,
                       ["blocked:\(BacklogAutopilot.unreadableVerdictReason)"])
        XCTAssertTrue(TaskMetricRecord.outcomesShowingWork
            .isDisjoint(with: TaskMetricRecord.outcomesReachingNoVerdict))
    }

    // MARK: - Attribution

    /// The ledger is portfolio-wide and item ids are unique only within a
    /// project, so two projects sharing an id must not accumulate each other's
    /// attempts.
    func testAnotherProjectsHistoryDoesNotRetireThisItem() {
        let history = [empty(0, project: "/tmp/other"),
                       empty(60, project: "/tmp/other"),
                       empty(120, project: "/tmp/other"),
                       empty(180)]

        XCTAssertEqual(verdict(history).noWorkAttempts, 1)
        XCTAssertEqual(verdict(history, project: "/tmp/other").noWorkAttempts, 3)
    }

    /// Paths are compared canonically, so the same project reached by a symlink
    /// or a trailing slash is the same project.
    func testTheProjectPathIsMatchedCanonically() {
        XCTAssertEqual(verdict([empty(0), empty(60), empty(120)], project: "/tmp/kiteloop/")
                        .noWorkAttempts, 3)
    }

    func testAnotherItemsHistoryIsNotCounted() {
        let history = [empty(0, itemID: "control-openapi"),
                       empty(60, itemID: "docs-architecture"),
                       empty(120, itemID: "docs-architecture")]

        XCTAssertEqual(verdict(history).noWorkAttempts, 1)
    }

    // MARK: - 2026-08-08

    /// The night this exists for, replayed in the order it was recorded: two
    /// runs the reviewer bounced, then the run of empty ones. Under the ceiling
    /// the 231 starts stop at 3.
    func testReplayingTheControlOpenapiLoopRetiresItAfterThreeEmptyRuns() {
        var history = [
            record(outcome: "blocked:review did not pass", at: 0),
            record(outcome: "blocked:review did not pass", at: 60),
        ]
        XCTAssertFalse(verdict(history).isRetired, "Two rejections on the merits: still runnable")

        // The dead-session stretch. Each append is one more start that happened.
        for index in 0..<228 {
            history.append(empty(TimeInterval(120 + index * 60)))
            let judged = verdict(history)
            XCTAssertEqual(judged.isRetired, index + 1 >= RetryCeiling.limit,
                           "Empty run \(index + 1) should\(index + 1 >= 3 ? "" : " not") be retiring")
        }

        XCTAssertEqual(verdict(history).noWorkAttempts, 228)
    }

    /// travel's `test-useplanpolling`, replayed from the three records
    /// `~/.kiteloop/task-metrics.jsonl` holds for it. The stall carries no file
    /// count — it predates the field — and under the old rule read as work,
    /// resetting the streak to zero so a fourth run started. This is the
    /// regression case.
    func testReplayingTestUsePlanPollingReachesTheCeilingInsteadOfResettingAtTheStall() {
        let travel = "/Users/me/code/travel"
        let item = "test-useplanpolling"
        let history = [
            stalled(0, itemID: item, project: travel),
            empty(60, itemID: item, project: travel),
            empty(120, itemID: item, project: travel),
        ]

        let judged = verdict(history, itemID: item, project: travel)
        XCTAssertEqual(judged.noWorkAttempts, 3)
        XCTAssertTrue(judged.isRetired, "The fourth run must not start")
    }

    // MARK: - What a human is told

    func testTheSummaryStatesTheCountAndTheCeiling() {
        let summary = verdict([empty(0), empty(60), empty(120)]).summary

        XCTAssertTrue(summary.contains("3 attempts started and produced no work"), summary)
        XCTAssertTrue(summary.contains("ceiling 3"), summary)
    }

    func testTheNoteCarriesTheCountAndItsOwnMarker() {
        let note = verdict((0..<5).map { empty(TimeInterval($0) * 60) }).note

        XCTAssertTrue(note.hasPrefix(RetryCeiling.noteMarker), note)
        XCTAssertTrue(note.contains("5 attempts"), note)
        XCTAssertTrue(note.contains("ceiling 3"), note)
    }

    /// The note is the whole interface at the moment someone needs it, and it
    /// used to end in an instruction that could not be carried out: "a run that
    /// produces anything clears the count", on an item nothing will run. Both
    /// ways out have to be named, in terms someone can act on without knowing how
    /// the ceiling is implemented.
    func testTheNoteSaysHowToGetTheItemRunningAgain() {
        let note = verdict([empty(0), empty(60), empty(120)]).note

        XCTAssertTrue(note.contains("What / How / Validation"),
                      "the re-grooming release is not described: \(note)")
        XCTAssertTrue(note.contains("Release for Autopilot"),
                      "the UI action is not named: \(note)")
        XCTAssertTrue(note.contains("/v1/backlog/release"),
                      "the headless action is not named: \(note)")
        XCTAssertTrue(note.contains("grooming.jsonl"),
                      "the note should say where the release is recorded: \(note)")
    }

    /// And it no longer promises the one thing a retired item cannot do. It also
    /// has to keep steering off the rename, which severs the item's history to
    /// work around the missing button.
    func testTheNoteDoesNotPromiseSomethingThatCannotHappen() {
        let note = verdict([empty(0), empty(60), empty(120)]).note

        XCTAssertFalse(note.contains("A run that produces anything clears the count"),
                       "a retired item cannot run, so nothing it does can clear the count: \(note)")
        XCTAssertTrue(note.contains("Do not rename"), note)
        XCTAssertTrue(note.contains("retire it again"),
                      "the ceiling still applies after a release: \(note)")
    }

    /// The note is written once, not at every pickup — a retired item is refused
    /// every time it is selected.
    func testTheNoteIsOnlyWrittenWhenItIsNotAlreadyThere() {
        let note = verdict([empty(0), empty(60), empty(120)]).note

        XCTAssertTrue(RetryCeiling.needsNote(existingNotes: nil))
        XCTAssertTrue(RetryCeiling.needsNote(existingNotes: "- 2026-08-08 — blocked (review did not pass)"))
        XCTAssertFalse(RetryCeiling.needsNote(existingNotes: "- 2026-08-08 — \(note)"))
    }
}

/// The half of the rule that cannot be shown with values alone: that the count
/// is read back off disk, so restarting the app — or pointing a fresh driver
/// process at the same project — does not hand a retired item three more
/// attempts. This is the failure the in-memory breaker had.
@MainActor
final class RetryCeilingDurabilityTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "retry-ceiling")
    }

    func testTheCountSurvivesAnAppRestart() throws {
        let metricsURL = tempDir.appending(path: "task-metrics.jsonl")
        let store = makeStore(at: metricsURL)
        for index in 0..<3 { store.append(emptyRun(at: TimeInterval(index) * 60)) }

        // A second store over the same file is what the next launch — or a fresh
        // driver process — sees. Nothing is carried over in memory.
        let afterRestart = makeStore(at: metricsURL)
        XCTAssertEqual(afterRestart.records.count, 3, "Precondition: the ledger was read back")

        let judged = RetryCeiling.evaluate(itemID: "control-openapi", projectPath: "/tmp/kiteloop",
                                           records: afterRestart.records)
        XCTAssertTrue(judged.isRetired)
        XCTAssertEqual(judged.noWorkAttempts, 3)
    }

    private func makeStore(at url: URL) -> TaskMetricStore {
        TaskMetricStore(metricsURL: url,
                        estimatesURL: tempDir.appending(path: "task-estimates.jsonl"),
                        approvalsURL: tempDir.appending(path: "task-approvals.jsonl"))
    }

    private func emptyRun(at offset: TimeInterval) -> TaskMetricRecord {
        let end = Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(offset)
        return TaskMetricRecord(
            projectPath: "/tmp/kiteloop", projectName: "kiteloop", itemID: "control-openapi",
            title: "Publish an OpenAPI spec", epic: nil, declaredSize: "M",
            startedAt: end.addingTimeInterval(-600), completedAt: end, durationSeconds: 600,
            costUSD: 0, reviewerRetries: 0,
            outcome: "blocked:\(RunWorkEvidence.noWorkPrefix) — no commits and an unchanged worktree",
            workerAgent: "worker", reviewerAgent: "reviewer", executionID: "e-1", toolErrors: nil
        )
    }
}

/// The retirement has to be somewhere a human will actually look, or an item
/// that quietly stops being picked up is indistinguishable from one nobody has
/// got to yet. These cover the note as it lands in the item's own file.
@MainActor
final class RetryCeilingNoteTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "retry-ceiling")
    }

    func testTheRetirementLandsInTheItemsNotesWithItsCount() throws {
        let vm = try loadProject()
        let verdict = RetryCeiling.Verdict(noWorkAttempts: 3, limit: RetryCeiling.limit)

        vm.appendNote(itemID: "control-openapi", verdict.note)

        let notes = try XCTUnwrap(vm.loadDetail(for: try item(vm))?.notes)
        XCTAssertTrue(notes.contains(RetryCeiling.noteMarker), notes)
        XCTAssertTrue(notes.contains("3 attempts in a row started and produced no work"), notes)
        XCTAssertFalse(RetryCeiling.needsNote(existingNotes: notes),
                       "Once it is on record the next pickup must not write it again")
    }

    // MARK: - Fixtures

    private func loadProject() throws -> BacklogViewModel {
        let repo = tempDir.appending(path: "kiteloop")
        try FileManager.default.createDirectory(at: repo.appending(path: "backlog"),
                                                withIntermediateDirectories: true)
        try """
        ---
        project: kiteloop
        verify_default: swift build
        ---

        # Kiteloop Backlog

        ## Epic: Now

        - [ ] control-openapi | Publish an OpenAPI spec | ready → [detail](backlog/control-openapi.md)
        """.write(to: repo.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)
        try """
        ---
        id: control-openapi
        title: Publish an OpenAPI spec
        ---

        ## What

        Serve the control API's own spec.
        """.write(to: repo.appending(path: "backlog/control-openapi.md"),
                  atomically: true, encoding: .utf8)

        let store = GlobalConfigStore(storageURL: tempDir.appending(path: "global-config.json"))
        let vm = BacklogViewModel(globalConfigStore: store)
        vm.loadForProject(repoPath: repo.path(percentEncoded: false))
        XCTAssertEqual(vm.backlogURL?.lastPathComponent, "BACKLOG.md")
        return vm
    }

    private func item(_ vm: BacklogViewModel) throws -> BacklogItem {
        try XCTUnwrap(vm.backlogFile?.sections.flatMap(\.items).first { $0.id == "control-openapi" })
    }
}

/// The way out of a retirement.
///
/// The ceiling had no release at all: it refuses to start the item, the count
/// only clears on a run that produces something, and a refused item never runs —
/// so the note telling a human to re-groom the item described something that
/// could not happen, and the only escape was renaming the id, which throws the
/// item's whole history away. Two releases replace that, and what is pinned here
/// is that each one actually releases, that neither raises the ceiling, and that
/// nothing releases on its own.
final class RetryCeilingReleaseTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_800_000_000)
    private let project = "/tmp/kiteloop"
    private let item = "grounding-check-false-positives"

    /// A run that produced nothing, against a named version of the item.
    private func empty(_ offset: TimeInterval, spec: String? = nil) -> TaskMetricRecord {
        var record = TaskMetricRecord(
            projectPath: project, projectName: "kiteloop", itemID: item,
            title: "Stop the grounding check firing on prose", epic: nil, declaredSize: "M",
            startedAt: day.addingTimeInterval(offset - 600),
            completedAt: day.addingTimeInterval(offset), durationSeconds: 600, costUSD: 0,
            reviewerRetries: 0,
            outcome: "blocked:\(RunWorkEvidence.noWorkPrefix) — no commits and an unchanged worktree",
            workerAgent: "worker", reviewerAgent: "reviewer", executionID: "e-1", toolErrors: nil
        )
        record.changedFileCount = 0
        record.specFingerprint = spec
        return record
    }

    private func verdict(_ records: [TaskMetricRecord], releasedAt: Date? = nil,
                         spec: String? = nil) -> RetryCeiling.Verdict {
        RetryCeiling.evaluate(itemID: item, projectPath: project, records: records,
                              releasedAt: releasedAt, specFingerprint: spec)
    }

    // MARK: - A human said so

    func testAHumanReleaseDiscountsEveryAttemptBeforeIt() {
        let history = [empty(0), empty(60), empty(120)]
        XCTAssertTrue(verdict(history).isRetired, "Precondition: retired")

        let released = verdict(history, releasedAt: day.addingTimeInterval(180))
        XCTAssertEqual(released.noWorkAttempts, 0)
        XCTAssertFalse(released.isRetired)
    }

    /// A release is a line, not an erasure: an attempt made *after* it counts
    /// normally, which is what stops a release from being an off switch.
    func testAttemptsAfterTheReleaseStillCount() {
        let history = [empty(0), empty(60), empty(120), empty(300)]

        let released = verdict(history, releasedAt: day.addingTimeInterval(180))
        XCTAssertEqual(released.noWorkAttempts, 1)
        XCTAssertFalse(released.isRetired)
    }

    /// The ceiling is not a budget a release refills. Three more empty attempts
    /// and the item is retired again — this is what keeps a release from being a
    /// nightly reset by hand.
    func testAReleasedItemIsRetiredAgainAfterTheCeilingIsReached() {
        let releasedAt = day.addingTimeInterval(180)
        var history = [empty(0), empty(60), empty(120)]
        for index in 0..<RetryCeiling.limit {
            history.append(empty(240 + TimeInterval(index) * 60))
            let judged = verdict(history, releasedAt: releasedAt)
            XCTAssertEqual(judged.isRetired, index + 1 >= RetryCeiling.limit,
                           "Post-release empty run \(index + 1)")
        }
        XCTAssertEqual(verdict(history, releasedAt: releasedAt).noWorkAttempts, RetryCeiling.limit)
    }

    /// An attempt that finished at the same instant as the release is on the
    /// released side of the line — the release is a decision about everything
    /// that has happened so far.
    func testAnAttemptFinishingExactlyAtTheReleaseIsDiscounted() {
        let history = [empty(0), empty(60), empty(120)]

        XCTAssertEqual(verdict(history, releasedAt: day.addingTimeInterval(120)).noWorkAttempts, 0)
    }

    // MARK: - The item was rewritten

    /// The 2026-08-08 case: three empty runs against a version of the item that
    /// asked for a redesign, then the item rewritten into something much smaller.
    /// The old attempts are evidence about the old item.
    func testAttemptsAgainstAnEarlierVersionOfTheItemDoNotCount() {
        let history = [empty(0, spec: "redesign"), empty(60, spec: "redesign"),
                       empty(120, spec: "redesign")]
        XCTAssertTrue(verdict(history, spec: "redesign").isRetired, "Precondition: retired as written")

        let rewritten = verdict(history, spec: "two-named-conditions")
        XCTAssertEqual(rewritten.noWorkAttempts, 0)
        XCTAssertFalse(rewritten.isRetired)
    }

    /// And re-running the *same* wording is not a rewrite, or the release would
    /// fire on every pickup and the ceiling would never hold.
    func testAttemptsAgainstTheCurrentWordingStillCount() {
        let history = [empty(0, spec: "same"), empty(60, spec: "same"), empty(120, spec: "same")]

        XCTAssertTrue(verdict(history, spec: "same").isRetired)
    }

    /// Rewriting buys the item the ceiling's attempts back, not immunity.
    func testARewrittenItemIsRetiredAgainAfterThreeMoreEmptyRuns() {
        var history = [empty(0, spec: "old"), empty(60, spec: "old"), empty(120, spec: "old")]
        for index in 0..<RetryCeiling.limit {
            history.append(empty(240 + TimeInterval(index) * 60, spec: "new"))
        }

        let judged = verdict(history, spec: "new")
        XCTAssertEqual(judged.noWorkAttempts, RetryCeiling.limit)
        XCTAssertTrue(judged.isRetired)
    }

    /// A ledger written before fingerprints existed says nothing about which
    /// wording its attempts were made against. Reading that silence as "the item
    /// has changed" would release every item in the old ledger at once — so an
    /// unknown version counts, and the human release is the way out for those.
    func testAnAttemptWithNoRecordedVersionStillCounts() {
        let history = [empty(0), empty(60), empty(120)]

        XCTAssertTrue(verdict(history, spec: "whatever-it-says-now").isRetired)
    }

    /// The mirror: a caller that can't compute a fingerprint (no detail file)
    /// must not have the recorded ones treated as mismatches.
    func testAnUnknownCurrentVersionDoesNotReleaseRecordedAttempts() {
        let history = [empty(0, spec: "a"), empty(60, spec: "a"), empty(120, spec: "a")]

        XCTAssertTrue(verdict(history, spec: nil).isRetired)
    }

    // MARK: - Why it ran again

    func testTheVerdictNamesTheReleaseThatBroughtTheItemBack() throws {
        let human = try XCTUnwrap(
            verdict([empty(0), empty(60), empty(120)],
                    releasedAt: day.addingTimeInterval(180)).release)
        XCTAssertEqual(human.discountedAttempts, 3)
        XCTAssertEqual(human.humanAt, day.addingTimeInterval(180))
        XCTAssertFalse(human.rewritten)
        XCTAssertTrue(human.explanation.contains("released by hand"), human.explanation)
        XCTAssertEqual(human.logValue, "human")

        let rewrite = try XCTUnwrap(
            verdict([empty(0, spec: "old"), empty(60, spec: "old"), empty(120, spec: "old")],
                    spec: "new").release)
        XCTAssertTrue(rewrite.rewritten)
        XCTAssertTrue(rewrite.explanation.contains("rewritten"), rewrite.explanation)
        XCTAssertEqual(rewrite.logValue, "rewritten")
    }

    /// Reported only when it actually bought an attempt back. A release recorded
    /// against a runnable item is not why that item runs, and saying so would put
    /// a misleading line in the run log every night afterwards.
    func testAReleaseThatDiscountedNothingIsNotReported() {
        XCTAssertNil(verdict([], releasedAt: day).release)
        XCTAssertNil(verdict([empty(0)], releasedAt: day.addingTimeInterval(-600)).release,
                     "The attempt is after the release — nothing was discounted")
    }

    // MARK: - Nothing releases on its own

    /// The rule the ceiling exists for: time alone releases nothing. A month of
    /// wall clock between the attempts and the question changes no answer.
    func testTimePassingReleasesNothing() {
        let history = [empty(0), empty(60), empty(120)]
        let judged = RetryCeiling.evaluate(itemID: item, projectPath: project, records: history,
                                           releasedAt: nil, specFingerprint: "unchanged")

        XCTAssertTrue(judged.isRetired)
        XCTAssertNil(judged.release)
    }
}

/// The fingerprint that decides whether an attempt was made against *this* item.
///
/// Its correctness is what keeps the rewrite release honest in both directions: a
/// fingerprint that moved on its own would release every item continuously, and
/// one that ignored the item's wording would never release anything. Parsed from
/// real detail-file markdown rather than assembled by hand, because what a
/// re-grooming actually changes is that text.
final class RetryCeilingFingerprintTests: XCTestCase {

    private func item(size: ItemSize? = .s) -> BacklogItem {
        BacklogItem(id: "item-1", title: "An item", verify: nil, status: .ready, type: .local,
                    size: size, queries: nil, cost: nil, completedDate: nil, blockedReason: nil,
                    jiraKey: nil, team: nil, detailPath: "backlog/item-1.md")
    }

    private func fingerprint(_ markdown: String, size: ItemSize? = .s) -> String? {
        RetryCeiling.specFingerprint(item: item(size: size),
                                     detail: BacklogParser.parseDetail(markdown, fallbackID: "item-1"))
    }

    private func detail(what: String = "Serve the control API's own spec.",
                        how: String = "Derive it from the routing table.",
                        validation: String = "- [ ] The document validates",
                        outOfScope: String = "- Anything else",
                        notes: String = "",
                        status: String = "ready",
                        size: String = "S") -> String {
        """
        ---
        id: item-1
        title: An item
        status: \(status)
        size: \(size)
        verify:
          - name: build
            cmd: "swift build"
        ---

        ## What

        \(what)

        ## How

        \(how)

        ## Validation

        \(validation)

        ## Out of Scope

        \(outOfScope)
        \(notes.isEmpty ? "" : "\n## Notes\n\n\(notes)\n")
        """
    }

    /// The defect this shape exists to avoid. The retirement note is appended to
    /// the item's own detail file, so a fingerprint covering Notes would be
    /// invalidated by the act of recording the retirement — and every retired
    /// item would release itself on the very next pickup.
    func testTheRetirementNoteItselfDoesNotChangeTheFingerprint() {
        let before = fingerprint(detail())
        let retired = fingerprint(detail(notes: "- 2026-08-08 — \(RetryCeiling.noteMarker) — 3 attempts"))

        XCTAssertNotNil(before)
        XCTAssertEqual(before, retired)
    }

    /// Status changes on every run (ready → active → ready) and would otherwise
    /// release the item constantly.
    func testStatusDoesNotChangeTheFingerprint() {
        XCTAssertEqual(fingerprint(detail(status: "ready")), fingerprint(detail(status: "blocked")))
    }

    /// Reflowing a paragraph is not a rewrite — the question is whether what the
    /// item *asks for* changed.
    func testReflowingTheProseDoesNotChangeTheFingerprint() {
        let wrapped = fingerprint(detail(what: "Serve the control API's own\nspec."))

        XCTAssertEqual(fingerprint(detail()), wrapped)
    }

    /// And every part of the spec a re-grooming would touch does change it.
    func testRewritingWhatTheItemAsksForChangesTheFingerprint() {
        let base = fingerprint(detail())

        XCTAssertNotEqual(base, fingerprint(detail(what: "Something else entirely.")))
        XCTAssertNotEqual(base, fingerprint(detail(how: "A different approach.")))
        XCTAssertNotEqual(base, fingerprint(detail(validation: "- [ ] A different bar")))
        XCTAssertNotEqual(base, fingerprint(detail(outOfScope: "- A narrower boundary")))
        XCTAssertNotEqual(base, fingerprint(detail(size: "M")),
                          "Breaking an item down is exactly the re-grooming the note asks for")
    }

    /// Stable for the same input, which `Hasher` would not be: it is seeded per
    /// process, so a fingerprint built on it would differ at every launch and
    /// release every item every time the app started.
    func testTheSameSpecAlwaysFingerprintsTheSame() {
        XCTAssertEqual(fingerprint(detail()), fingerprint(detail()))
    }

    /// Nothing to fingerprint without a detail file — and nil disables the
    /// rewrite release rather than granting it.
    func testAnItemWithNoDetailFileHasNoFingerprint() {
        XCTAssertNil(RetryCeiling.specFingerprint(item: item(), detail: nil))
    }
}

/// The whole-backlog form, which the UI uses to mark retired items without
/// re-walking the ledger once per row.
final class RetryCeilingBulkTests: XCTestCase {

    private func record(_ itemID: String, project: String = "/tmp/kiteloop",
                        outcome: String, changedFileCount: Int?) -> TaskMetricRecord {
        var record = TaskMetricRecord(
            projectPath: project, projectName: "kiteloop", itemID: itemID, title: "An item",
            epic: nil, declaredSize: "S", startedAt: Date(), completedAt: Date(),
            durationSeconds: 1, costUSD: 0, reviewerRetries: 0, outcome: outcome,
            workerAgent: nil, reviewerAgent: nil, executionID: nil, toolErrors: nil
        )
        record.changedFileCount = changedFileCount
        return record
    }

    func testOnePassGivesEveryItemTheSameStreakTheSingleItemFormWould() {
        let records = [
            record("a", outcome: "blocked:no work", changedFileCount: 0),
            record("b", outcome: "done", changedFileCount: 4),
            record("a", outcome: "blocked:no work", changedFileCount: 0),
            record("a", outcome: "blocked:no work", changedFileCount: 0),
            record("b", outcome: "blocked:no work", changedFileCount: 0),
            record("c", outcome: "cancelled:stopped by user", changedFileCount: nil),
        ]

        let streaks = RetryCeiling.noWorkAttemptsByItem(projectPath: "/tmp/kiteloop", records: records)

        XCTAssertEqual(streaks["a"], 3)
        XCTAssertEqual(streaks["b"], 1)
        XCTAssertNil(streaks["c"], "A cancelled run neither counts nor clears")
        for id in ["a", "b"] {
            XCTAssertEqual(streaks[id],
                           RetryCeiling.noWorkAttempts(itemID: id, projectPath: "/tmp/kiteloop",
                                                       records: records),
                           "\(id) disagrees with the single-item form")
        }
    }

    func testAnotherProjectsRunsAreNotCounted() {
        let records = [
            record("a", project: "/tmp/other", outcome: "blocked:no work", changedFileCount: 0),
            record("a", outcome: "blocked:no work", changedFileCount: 0),
        ]

        XCTAssertEqual(RetryCeiling.noWorkAttemptsByItem(projectPath: "/tmp/kiteloop",
                                                        records: records)["a"], 1)
    }
}

/// The attempt that never started.
///
/// The ceiling is counted off recorded attempts, and an item a pickup gate
/// refused wrote no record at all — so a run that spawned a session and produced
/// nothing was bounded while an item turned away at the door was not, though
/// both are the item failing to advance.
/// `memory-proposals-cannot-be-answered-headlessly` was refused three times on
/// 2026-08-21 with zero rows in `task-metrics.jsonl`. What is pinned here is
/// that a `wrong-status` refusal counts exactly as an empty run does, that both
/// releases lift it, that a grounding or definition-of-ready refusal counts
/// *not at all* — pickup sends that item to `draft` instead, so three citations
/// to reword must not retire it the way three real runs would — and, the one
/// that must not regress either way, that an item merely waiting its turn is
/// not counted at all.
final class RetryCeilingPickupRefusalTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_800_000_000)
    private let project = "/tmp/kiteloop"
    private let id = "memory-proposals-cannot-be-answered-headlessly"

    private func item(_ id: String, status: BacklogItemStatus = .ready,
                      needs: [String] = []) -> BacklogItem {
        BacklogItem(id: id, title: "Answer memory proposals headlessly", verify: "swift build",
                    status: status, type: .local, size: .s, queries: nil, cost: nil,
                    completedDate: nil, blockedReason: nil, jiraKey: nil, team: nil,
                    detailPath: "backlog/\(id).md", needs: needs)
    }

    /// A groomed detail file — every Definition-of-Ready clause but the one
    /// about sequencing satisfied, so what a verdict reports is only the
    /// dependency.
    private func groomed() -> BacklogItemDetail {
        BacklogItemDetail(
            id: id, title: "Answer memory proposals headlessly", status: "ready", epic: nil,
            priority: nil, size: "S", owner: nil, jira: nil, repo: nil,
            verifyCommands: [.init(name: "build", cmd: "swift build", expect: nil)],
            why: nil, acceptanceCriteria: ["- [ ] A proposal can be answered over the API"],
            outOfScope: [], context: nil, notes: nil,
            what: "Let a proposal be answered headlessly.",
            approach: "An endpoint beside the ones that read them.")
    }

    private func refusal(_ clause: RetryCeiling.PickupRefusal = .notGrounded,
                         spec: String? = nil, at offset: TimeInterval = 0) -> TaskMetricRecord {
        RetryCeiling.refusalRecord(item: item(id), refusal: clause, projectPath: project,
                                   projectName: "kiteloop", epic: "Autonomy",
                                   specFingerprint: spec, at: day.addingTimeInterval(offset))
    }

    private func run(_ offset: TimeInterval, outcome: String,
                     changedFileCount: Int?) -> TaskMetricRecord {
        var record = TaskMetricRecord(
            projectPath: project, projectName: "kiteloop", itemID: id, title: "An item",
            epic: nil, declaredSize: "S", startedAt: day.addingTimeInterval(offset - 600),
            completedAt: day.addingTimeInterval(offset), durationSeconds: 600, costUSD: 2.20,
            reviewerRetries: 0, outcome: outcome,
            workerAgent: "worker", reviewerAgent: "reviewer", executionID: "e-1", toolErrors: nil
        )
        record.changedFileCount = changedFileCount
        return record
    }

    /// A run that started and left nothing — what a refusal has to count like.
    private func empty(_ offset: TimeInterval) -> TaskMetricRecord {
        run(offset, outcome: "blocked:\(RunWorkEvidence.noWorkPrefix) — empty diff against base",
            changedFileCount: 0)
    }

    private func verdict(_ records: [TaskMetricRecord], releasedAt: Date? = nil,
                         spec: String? = nil) -> RetryCeiling.Verdict {
        RetryCeiling.evaluate(itemID: id, projectPath: project, records: records,
                              releasedAt: releasedAt, specFingerprint: spec)
    }

    // MARK: - What a refusal records

    func testARefusalNamesTheItemAndTheClauseThatRefusedIt() {
        let record = refusal(.notGrounded)

        XCTAssertEqual(record.itemID, id)
        XCTAssertEqual(record.projectPath, project)
        XCTAssertEqual(record.outcome, "did-not-run:not-grounded")
        XCTAssertTrue(record.didNotRun)
    }

    /// Every gate gets its own clause, and each is readable back as a value
    /// rather than as a sentence to re-parse.
    func testEveryGateHasItsOwnClause() {
        XCTAssertEqual(RetryCeiling.PickupRefusal.allCases.map(\.outcome), [
            "did-not-run:wrong-status",
            "did-not-run:not-ready",
            "did-not-run:retired",
            "did-not-run:not-grounded",
        ])
        for clause in RetryCeiling.PickupRefusal.allCases {
            XCTAssertTrue(refusal(clause).didNotRun, clause.rawValue)
        }
    }

    /// No session was spawned, so a refusal must move neither the day's spend
    /// nor the session's — and its duration is a measurement of nothing having
    /// run, not an unmeasured run.
    func testARefusalCostsNothingAndTakesNoTime() {
        let record = refusal()

        XCTAssertEqual(record.costUSD, 0)
        XCTAssertEqual(record.durationSeconds, 0)
        XCTAssertEqual(record.startedAt, record.completedAt)
        XCTAssertNil(record.executionID, "There was no execution to name")
        XCTAssertNil(record.workerAgent)
        XCTAssertNil(record.reviewerAgent)
    }

    /// `0` rather than nil, so `workEvidence` answers from the file count — the
    /// measurement — instead of falling through to reading the outcome string.
    func testARefusalRecordsThatItChangedNothing() {
        XCTAssertEqual(refusal().changedFileCount, 0)
        XCTAssertEqual(refusal().workEvidence, .empty)
        XCTAssertFalse(refusal().producedWork)
    }

    // MARK: - The ceiling counts a wrong-status refusal

    /// `wrongStatus` is not a grooming defect — the item's wording is fine, it
    /// was simply selected outside a pickup stage — so it keeps counting
    /// exactly as before.
    func testRefusalsInARowRetireTheItem() {
        XCTAssertFalse(verdict([refusal(.wrongStatus, at: 0), refusal(.wrongStatus, at: 60)]).isRetired)

        let third = verdict([refusal(.wrongStatus, at: 0), refusal(.wrongStatus, at: 60),
                             refusal(.wrongStatus, at: 120)])
        XCTAssertEqual(third.noWorkAttempts, RetryCeiling.limit)
        XCTAssertTrue(third.isRetired, "Three refusals is three attempts that went nowhere")
    }

    /// The point of recording them: the two populations are one streak. Before
    /// this, an item that alternated could never reach the ceiling.
    func testARefusalAndAnEmptyRunCountTowardTheSameStreak() {
        let mixed = verdict([empty(0), refusal(.wrongStatus, at: 60), empty(120)])

        XCTAssertEqual(mixed.noWorkAttempts, 3)
        XCTAssertTrue(mixed.isRetired)
    }

    func testAnAttemptThatProducedWorkClearsARefusalStreak() {
        let delivered = run(180, outcome: "awaiting-approval", changedFileCount: 6)

        let judged = verdict([refusal(.wrongStatus, at: 0), refusal(.wrongStatus, at: 60), delivered,
                              refusal(.wrongStatus, at: 240)])
        XCTAssertEqual(judged.noWorkAttempts, 1)
        XCTAssertFalse(judged.isRetired)
    }

    /// The bulk form the UI marks retired items with has to agree with the
    /// single-item one about refusals too.
    func testTheBulkFormCountsRefusalsTheSameWay() {
        let records = [refusal(.wrongStatus, at: 0), refusal(.wrongStatus, at: 60),
                       refusal(.wrongStatus, at: 120)]

        XCTAssertEqual(RetryCeiling.noWorkAttemptsByItem(projectPath: project,
                                                        records: records)[id],
                       RetryCeiling.noWorkAttempts(itemID: id, projectPath: project,
                                                   records: records))
    }

    // MARK: - And both releases lift a wrong-status streak

    func testRewritingTheItemReleasesARefusalStreak() {
        let history = [refusal(.wrongStatus, spec: "old", at: 0), refusal(.wrongStatus, spec: "old", at: 60),
                       refusal(.wrongStatus, spec: "old", at: 120)]
        XCTAssertTrue(verdict(history, spec: "old").isRetired, "Precondition: retired")

        let rewritten = verdict(history, spec: "new")
        XCTAssertEqual(rewritten.noWorkAttempts, 0)
        XCTAssertFalse(rewritten.isRetired)
        XCTAssertEqual(rewritten.release?.rewritten, true)
        XCTAssertEqual(rewritten.release?.discountedAttempts, 3)
    }

    func testAHumanReleaseDiscountsRefusalsToo() {
        let history = [refusal(.wrongStatus, at: 0), refusal(.wrongStatus, at: 60), refusal(.wrongStatus, at: 120)]

        let released = verdict(history, releasedAt: day.addingTimeInterval(180))
        XCTAssertEqual(released.noWorkAttempts, 0)
        XCTAssertEqual(released.release?.discountedAttempts, 3)
    }

    // MARK: - A grounding or readiness refusal does not count at all

    /// The defect this exists to fix: three items were retired on a single
    /// citation to reword, no run ever having started. A grounding or
    /// definition-of-ready refusal now sends the item to `draft` instead of
    /// leaving it `ready` to rack up a streak, so it must not count even when
    /// it keeps happening — which it shouldn't, once the item is `draft`, but
    /// the count itself is the second line of defense.
    func testGroundingRefusalsInARowDoNotRetireTheItem() {
        let history = [refusal(.notGrounded, at: 0), refusal(.notGrounded, at: 60),
                       refusal(.notGrounded, at: 120)]

        let judged = verdict(history)
        XCTAssertEqual(judged.noWorkAttempts, 0)
        XCTAssertFalse(judged.isRetired)
    }

    /// Same exemption, the other clause: an item refused for its own wording by
    /// `DefinitionOfReady` — not a `needs:` deferral, which is not a refusal at
    /// all (see below) — is just as much a grooming defect as a bad citation.
    func testReadinessRefusalsInARowDoNotRetireTheItem() {
        let history = [refusal(.notReady, at: 0), refusal(.notReady, at: 60), refusal(.notReady, at: 120)]

        let judged = verdict(history)
        XCTAssertEqual(judged.noWorkAttempts, 0)
        XCTAssertFalse(judged.isRetired)
    }

    /// Excluded outright, not merely forgiven by a release — a grounding
    /// refusal skips the release bookkeeping entirely, so neither a rewrite nor
    /// a human release has anything to discount.
    func testAGroundingRefusalIsExcludedRegardlessOfReleaseOrRewrite() {
        let history = [refusal(.notGrounded, spec: "old", at: 0), refusal(.notGrounded, spec: "old", at: 60),
                       refusal(.notGrounded, spec: "old", at: 120)]

        XCTAssertNil(verdict(history, spec: "old").release)
        XCTAssertNil(verdict(history, releasedAt: day.addingTimeInterval(180)).release)
        XCTAssertFalse(verdict(history, spec: "old").isRetired)
    }

    /// It does not join a mixed streak either — an empty run either side of a
    /// grounding refusal reads exactly as if the refusal were never recorded.
    func testAGroundingRefusalDoesNotJoinAMixedStreak() {
        let mixed = verdict([empty(0), refusal(.notGrounded, at: 60), empty(120)])

        XCTAssertEqual(mixed.noWorkAttempts, 2, "Only the two empty runs count")
        XCTAssertFalse(mixed.isRetired)
    }

    // MARK: - A deferral is not a refusal

    /// The one case that must not regress. An item withheld because its
    /// prerequisite isn't `done` is the sequencing gate working, and counting it
    /// would retire a queue's whole tail before its head had shipped.
    func testAnItemWaitingOnADependencyIsNotARefusal() {
        let first = item("first-in-the-chain")
        let second = item(id, needs: [first.id])
        let waiting = DefinitionOfReady.evaluate(
            item: second, detail: groomed(),
            dependencies: .init(items: [first, second]))

        XCTAssertEqual(waiting.unmet, [.dependency], "Precondition: waiting, and nothing else")
        XCTAssertNil(RetryCeiling.refusal(for: waiting))
    }

    /// …and the deferral doesn't launder the rest. An item refused for its own
    /// wording is refused whether or not it also happens to be second in a chain.
    func testAnItemRefusedForItsOwnWordingCountsEvenWhileItWaits() {
        let first = item("first-in-the-chain")
        let second = item(id, needs: [first.id])
        let ungroomed = DefinitionOfReady.evaluate(
            item: second, detail: nil,
            dependencies: .init(items: [first, second]))

        XCTAssertTrue(ungroomed.unmet.contains(.detail))
        XCTAssertTrue(ungroomed.unmet.contains(.dependency))
        XCTAssertEqual(RetryCeiling.refusal(for: ungroomed), .notReady)
    }

    func testAReadyItemIsNoRefusalAtAll() {
        XCTAssertNil(RetryCeiling.refusal(for: .ready))
        XCTAssertNil(RetryCeiling.refusal(for: DefinitionOfReady.evaluate(item: item(id),
                                                                          detail: groomed())))
    }

    /// Ids are unique inside a backlog, not across the machine — a refusal in
    /// one project must not retire another project's item of the same name.
    func testARefusalIsScopedToItsProject() {
        let elsewhere = RetryCeiling.refusalRecord(
            item: item(id), refusal: .wrongStatus, projectPath: "/tmp/other",
            projectName: "other", at: day)

        XCTAssertEqual(verdict([elsewhere, refusal(.wrongStatus, at: 60)]).noWorkAttempts, 1)
    }

    // MARK: - The ceiling's own refusal is not evidence about the item

    /// The two names for the same string have to agree — `Models` sits below
    /// `Services` and cannot import `RetryCeiling` to check it directly.
    func testTheRetiredRefusalOutcomeMatchesTheClauseItNames() {
        XCTAssertEqual(TaskMetricRecord.retiredRefusalOutcome,
                       RetryCeiling.PickupRefusal.retired.outcome)
    }

    /// The exact shape from 2026-08-26: three attempts that actually ran, then
    /// fourteen refusals the ceiling wrote itself on every later pass over the
    /// queue. The reported count has to stop at 3, not climb to 17.
    func testACeilingsOwnRefusalDoesNotInflateTheCount() {
        var history = [empty(0), empty(60), empty(120)]
        XCTAssertTrue(verdict(history).isRetired, "Precondition: retired after three real attempts")

        for index in 0..<14 {
            history.append(refusal(.retired, at: 180 + TimeInterval(index) * 60))
        }

        let judged = verdict(history)
        XCTAssertEqual(judged.noWorkAttempts, 3,
                       "Fourteen refusals the ceiling wrote about its own retirement add nothing")
        XCTAssertTrue(judged.isRetired, "The item stays retired")
    }

    /// It neither counts nor clears, for the same reason a cancel doesn't: a
    /// retired-refusal row sitting between two other rows leaves the streak
    /// either side of it exactly as it was.
    func testARetiredRefusalNeitherCountsNorClearsAStreak() {
        XCTAssertEqual(verdict([empty(0), refusal(.retired, at: 60), empty(120)]).noWorkAttempts, 2)

        let afterDelivery = [run(0, outcome: "awaiting-approval", changedFileCount: 3),
                             refusal(.retired, at: 60), empty(120)]
        XCTAssertEqual(verdict(afterDelivery).noWorkAttempts, 1)
    }

    /// The bulk form is what marks an item "possibly retired" in a list before
    /// the per-item verdict is ever asked, so it has to skip these rows too —
    /// the two must not be able to disagree about how many attempts there were.
    func testTheBulkFormSkipsARetiredRefusalToo() {
        let history = [empty(0), empty(60), empty(120),
                       refusal(.retired, at: 180), refusal(.retired, at: 240)]

        XCTAssertEqual(RetryCeiling.noWorkAttemptsByItem(projectPath: project, records: history)[id], 3)
        XCTAssertEqual(RetryCeiling.noWorkAttemptsByItem(projectPath: project, records: history)[id],
                       RetryCeiling.noWorkAttempts(itemID: id, projectPath: project, records: history))
    }

    /// A release's `discountedAttempts` is the sentence a human reads to know
    /// how many attempts it bought back — and the refusals the ceiling wrote
    /// after the item was already retired were never real attempts, so they
    /// must not swell that number either.
    func testARetiredRefusalDoesNotSwellWhatAReleaseDiscounts() {
        var history = [empty(0), empty(60), empty(120)]
        for index in 0..<14 { history.append(refusal(.retired, at: 180 + TimeInterval(index) * 60)) }

        let released = verdict(history, releasedAt: day.addingTimeInterval(1000))
        XCTAssertEqual(released.noWorkAttempts, 0)
        XCTAssertEqual(released.release?.discountedAttempts, 3,
                       "Only the three real attempts were discounted, not the fourteen refusals")
    }
}

/// Releases as the grooming ledger holds them — the record `RetryCeiling` reads
/// back at every pickup, which makes it the one kind of record in that file
/// whose loss changes what the app does.
@MainActor
final class GroomingLedgerReleaseTests: XCTestCase {
    private var tempDir: URL!
    private var url: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "retry-ceiling")
        url = tempDir.appending(path: "grooming.jsonl")
    }

    func testAReleaseIsReadBackAfterARestart() throws {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let ledger = GroomingLedger(url: url)
        ledger.recordRelease(itemID: "item-1", projectPath: "/tmp/kiteloop", projectName: "kiteloop",
                             reason: "released by hand (backlog)", at: at)

        // A second ledger over the same file is what the next launch sees.
        let reloaded = GroomingLedger(url: url)
        XCTAssertEqual(reloaded.latestRelease(itemID: "item-1", projectPath: "/tmp/kiteloop"), at)
    }

    /// Latest, not first: an item released, retired again and released again has
    /// to be measured from the second one, or the second release does nothing.
    func testTheLatestReleaseWins() {
        let ledger = GroomingLedger(url: url)
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        let second = first.addingTimeInterval(86_400)
        ledger.recordRelease(itemID: "item-1", projectPath: "/tmp/kiteloop",
                             projectName: "kiteloop", reason: "first", at: first)
        ledger.recordRelease(itemID: "item-1", projectPath: "/tmp/kiteloop",
                             projectName: "kiteloop", reason: "second", at: second)

        XCTAssertEqual(ledger.latestRelease(itemID: "item-1", projectPath: "/tmp/kiteloop"), second)
    }

    /// The ledger is portfolio-wide and ids are unique only within a project.
    func testAReleaseIsScopedToItsProject() {
        let ledger = GroomingLedger(url: url)
        ledger.recordRelease(itemID: "item-1", projectPath: "/tmp/kiteloop",
                             projectName: "kiteloop", reason: "released")

        XCTAssertNotNil(ledger.latestRelease(itemID: "item-1", projectPath: "/tmp/kiteloop/"),
                        "A trailing slash is the same project")
        XCTAssertNil(ledger.latestRelease(itemID: "item-1", projectPath: "/tmp/other"))
    }

    /// The trim is why this matters: every other record is a report, but losing a
    /// release silently re-retires an item a human deliberately released — and a
    /// busy portfolio rolls 2000 records over in a matter of nights.
    func testAReleaseSurvivesTheRetentionTrim() {
        let ledger = GroomingLedger(url: url)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        ledger.recordRelease(itemID: "item-1", projectPath: "/tmp/kiteloop",
                             projectName: "kiteloop", reason: "released", at: at)
        for index in 0..<(GroomingLedger.retentionLimit + 10) {
            ledger.recordCheckFailure(itemID: "noise-\(index)", projectPath: "/tmp/kiteloop",
                                      projectName: "kiteloop",
                                      check: GroomingRecord.Check.definitionOfReady,
                                      reason: "no verify: command")
        }

        XCTAssertEqual(ledger.latestRelease(itemID: "item-1", projectPath: "/tmp/kiteloop"), at)
        XCTAssertLessThanOrEqual(ledger.records.filter { $0.event != .released }.count,
                                 GroomingLedger.retentionLimit,
                                 "Everything else is still trimmed")
        XCTAssertEqual(GroomingLedger(url: url).latestRelease(itemID: "item-1",
                                                              projectPath: "/tmp/kiteloop"), at,
                       "and the rewritten file still holds it")
    }

    /// The same invariant on the read path. The trim keeps releases, but a
    /// relaunch reads the file rather than the trimmed array — and a blanket
    /// tail read would throw the release away while it is still sitting in the
    /// file, re-retiring the item on the next pickup.
    func testAReleaseSurvivesTheLoadOfAnOversizedFile() throws {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        try writeFixture(oversizedFileHeadedByARelease(at: at))

        XCTAssertEqual(GroomingLedger(url: url).latestRelease(itemID: "item-1",
                                                              projectPath: "/tmp/kiteloop"), at,
                       "The oldest line in the file is the release a human made")
    }

    /// Everything else is a report, and the limit is what stops the file from
    /// growing without bound — so the load still drops the oldest of them.
    func testTheLoadStillBoundsEveryOtherRecord() throws {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = oversizedFileHeadedByARelease(at: at)
        try writeFixture(fixture)

        let records = GroomingLedger(url: url).records
        let others = records.filter { $0.event != .released }
        XCTAssertLessThanOrEqual(others.count, GroomingLedger.retentionLimit)
        XCTAssertFalse(others.contains { $0.itemID == "noise-0" }, "the oldest went first")
        XCTAssertEqual(others.last?.itemID, fixture.last?.itemID, "and the newest stayed")
        XCTAssertEqual(records.map(\.at), records.map(\.at).sorted(),
                       "still oldest first, which latestRelease and records(from:to:) read on")
    }

    /// A release, then enough noise to put the file over the limit — the shape a
    /// busy portfolio leaves behind after a few nights.
    private func oversizedFileHeadedByARelease(at: Date) -> [GroomingRecord] {
        var fixture = [GroomingRecord(at: at, projectPath: "/tmp/kiteloop", projectName: "kiteloop",
                                      itemID: "item-1", event: .released,
                                      check: GroomingRecord.Check.retryCeiling,
                                      reason: "released by hand (backlog)")]
        for index in 0..<(GroomingLedger.retentionLimit + 10) {
            fixture.append(GroomingRecord(at: at.addingTimeInterval(TimeInterval(index + 1)),
                                          projectPath: "/tmp/kiteloop", projectName: "kiteloop",
                                          itemID: "noise-\(index)", event: .checkFailed,
                                          check: GroomingRecord.Check.definitionOfReady,
                                          reason: "no verify: command"))
        }
        return fixture
    }

    /// Writes the JSONL a previous launch would have left, in the ledger's own
    /// encoding — the point is to load a file no live ledger trimmed on the way out.
    private func writeFixture(_ records: [GroomingRecord]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try records.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
            .joined(separator: "\n")
        try Data((body + "\n").utf8).write(to: url)
    }
}
