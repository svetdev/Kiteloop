import XCTest
import KiteloopCore
@testable import Kiteloop

/// The coordinator's portfolio view: every open project's status counts,
/// `autopilotReady`, the run in flight if any, and recent item outcomes.
///
/// Two things matter here. First, the snapshot has to agree with what the
/// control API reports for the same projects — it is built from the same
/// registry, so a divergence would be a second source of truth. Second, it is
/// read-only: capturing must leave every project exactly as it found it.
@MainActor
final class PortfolioSnapshotTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "portfolio-snapshot")
        registry = ControlSessionRegistry()
    }

    override func tearDown() async throws {
        registry = nil
    }

    // MARK: - Capturing the portfolio

    /// The headline case: several projects open, each listed with its own status
    /// counts and readiness rather than the supervising project's.
    func testCaptureListsEveryOpenProjectWithItsStatus() throws {
        try openProject(named: "alpha", items: [("a1", .ready), ("a2", .ready), ("a3", .blocked)]) {
            $0.workerAgentID = "worker-1"
            $0.reviewerAgentID = "reviewer-1"
        }
        try openProject(named: "beta", items: [("b1", .done)])

        let snapshot = PortfolioSnapshot.capture(registry: registry)

        XCTAssertEqual(snapshot.projects.map(\.name), ["alpha", "beta"])
        let alpha = try XCTUnwrap(snapshot.project(named: "alpha"))
        XCTAssertEqual(alpha.count(.ready), 2)
        XCTAssertEqual(alpha.count(.blocked), 1)
        XCTAssertEqual(alpha.count(.done), 0)
        XCTAssertEqual(alpha.totalItems, 3)
        XCTAssertTrue(alpha.autopilotReady)
        let beta = try XCTUnwrap(snapshot.project(named: "beta"))
        XCTAssertEqual(beta.count(.done), 1)
        XCTAssertFalse(beta.autopilotReady, "no worker or reviewer assigned")
    }

    /// `autopilotReady` is the condition a portfolio-level coordinator would
    /// check before considering a project runnable, so a half-configured one
    /// must not read as ready.
    func testAutopilotReadyNeedsBothWorkerAndReviewer() throws {
        try openProject(named: "alpha") { $0.workerAgentID = "worker-1" }

        let snapshot = PortfolioSnapshot.capture(registry: registry)

        XCTAssertEqual(snapshot.project(named: "alpha")?.autopilotReady, false)
    }

    /// A project with no backlog loaded is still a project — it reports no
    /// items rather than dropping out of the portfolio.
    func testProjectWithoutABacklogReportsNoItems() throws {
        try openProject(named: "alpha", backlog: nil)

        let alpha = try XCTUnwrap(PortfolioSnapshot.capture(registry: registry).project(named: "alpha"))

        XCTAssertEqual(alpha.totalItems, 0)
        XCTAssertTrue(alpha.statusCounts.isEmpty)
    }

    func testEmptyRegistryCapturesAnEmptyPortfolio() {
        let snapshot = PortfolioSnapshot.capture(registry: registry)

        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertEqual(snapshot.promptSection, "")
    }

    // MARK: - Runs in flight

    /// The distinction the whole snapshot turns on: a project running an item is
    /// reported as running, and an idle one is not reported as running at all.
    func testRunInFlightIsReportedAndAnIdleProjectIsNot() throws {
        let busy = try openProject(named: "alpha", items: [("a1", .active)])
        busy.stageRunForTesting(status: .running(itemIndex: 0, total: 3),
                                queue: [item("a1"), item("a2"), item("a3")])
        try openProject(named: "beta", items: [("b1", .ready)])

        let snapshot = PortfolioSnapshot.capture(registry: registry)

        let alpha = try XCTUnwrap(snapshot.project(named: "alpha"))
        XCTAssertTrue(alpha.isRunning)
        let run = try XCTUnwrap(alpha.run)
        XCTAssertEqual(run.phase, .running)
        XCTAssertEqual(run.itemID, "a1")
        XCTAssertEqual(run.position, 1, "positions read 1-based; the status counts from 0")
        XCTAssertEqual(run.total, 3)
        let beta = try XCTUnwrap(snapshot.project(named: "beta"))
        XCTAssertFalse(beta.isRunning)
        XCTAssertNil(beta.run)
    }

    func testReviewingRunCarriesItsAttempt() {
        let run = PortfolioSnapshot.runState(
            status: .reviewing(itemIndex: 1, total: 2, attempt: 3),
            runQueue: [item("a1"), item("a2")]
        )

        XCTAssertEqual(run?.phase, .reviewing)
        XCTAssertEqual(run?.itemID, "a2")
        XCTAssertEqual(run?.position, 2)
        XCTAssertEqual(run?.attempt, 3)
    }

    /// A paused run is not an idle project — it is a run someone has to resume,
    /// which is exactly the kind of thing a portfolio view exists to surface.
    func testPausedRunIsReportedRatherThanIdle() {
        let run = PortfolioSnapshot.runState(status: .paused, runQueue: [item("a1"), item("a2")])

        XCTAssertEqual(run?.phase, .paused)
        XCTAssertEqual(run?.total, 2)
    }

    func testIdleStatusHasNoRunState() {
        XCTAssertNil(PortfolioSnapshot.runState(status: .idle, runQueue: [item("a1")]))
    }

    /// The status index and the queue can disagree — a cancelled run empties the
    /// queue. The phase still reports; only the item identity is missing.
    func testRunIndexOutsideTheQueueStillReportsThePhase() {
        let run = PortfolioSnapshot.runState(status: .running(itemIndex: 4, total: 5), runQueue: [])

        XCTAssertEqual(run?.phase, .running)
        XCTAssertNil(run?.itemID)
        XCTAssertEqual(run?.position, 5)
    }

    // MARK: - The phase rail

    /// The headline case: a run still in the worker has nothing ticked yet,
    /// and the worker step is the one ringed.
    func testPhaseRailForAWorkerRun() {
        let run = PortfolioSnapshot.runState(
            status: .running(itemIndex: 0, total: 1), runQueue: [item("a1")],
            currentRunPhase: .worker, currentRunAttempt: 1,
            lastActivityAt: Date(), stallTimeoutMinutes: 20)

        let rail = try? XCTUnwrap(run?.phaseRail)
        XCTAssertEqual(rail?.current, .worker)
        XCTAssertEqual(rail?.stepsDone, [])
        XCTAssertEqual(rail?.attempt, 1)
    }

    /// A run in its second review round: attempt 2, and both the steps before
    /// review — worker and verify — read done, since the workflow only reaches
    /// the reviewer once the verify has passed.
    func testPhaseRailForASecondReviewRound() {
        let run = PortfolioSnapshot.runState(
            status: .reviewing(itemIndex: 0, total: 1, attempt: 2), runQueue: [item("a1")],
            currentRunPhase: .reviewer, currentRunAttempt: 2,
            lastActivityAt: Date(), stallTimeoutMinutes: 20)

        let rail = try? XCTUnwrap(run?.phaseRail)
        XCTAssertEqual(rail?.current, .review)
        XCTAssertEqual(rail?.stepsDone, [.worker, .verify])
        XCTAssertEqual(rail?.attempt, 2)
    }

    /// The app running the item's own `verify:` before the review is a step a
    /// person can watch: for as long as that build takes, the rail is on
    /// `verify` with the worker behind it. It used to sit on `worker` with its
    /// clock ageing, so a run deliberately building read as one gone quiet.
    func testPhaseRailWhileTheAppRunsTheItemsVerify() {
        let run = PortfolioSnapshot.runState(
            status: .running(itemIndex: 0, total: 1), runQueue: [item("a1")],
            currentRunPhase: .verify, currentRunAttempt: 1,
            lastActivityAt: Date(), stallTimeoutMinutes: 20)

        let rail = try? XCTUnwrap(run?.phaseRail)
        XCTAssertEqual(rail?.current, .verify)
        XCTAssertEqual(rail?.stepsDone, [.worker], "the worker is behind it, the review is not yet")
    }

    /// A run at the merge: worker, verify and review are all behind it.
    func testPhaseRailAtMerge() {
        let run = PortfolioSnapshot.runState(
            status: .running(itemIndex: 0, total: 1), runQueue: [item("a1")],
            currentRunPhase: .merge, currentRunAttempt: 2,
            lastActivityAt: Date(), stallTimeoutMinutes: 20)

        let rail = try? XCTUnwrap(run?.phaseRail)
        XCTAssertEqual(rail?.current, .merge)
        XCTAssertEqual(rail?.stepsDone, [.worker, .verify, .review, .waitingForGate])
    }

    /// An idle project has no run at all, so it has no rail either — the
    /// question doesn't arise.
    func testIdleProjectHasNoPhaseRail() {
        let run = PortfolioSnapshot.runState(
            status: .idle, runQueue: [], currentRunPhase: .worker,
            currentRunAttempt: 1, lastActivityAt: Date(), stallTimeoutMinutes: 20)

        XCTAssertNil(run)
    }

    /// A paused run reports its phase but not a rail: nothing is currently
    /// active for the ring to point at.
    func testPausedRunHasNoPhaseRail() {
        let run = PortfolioSnapshot.runState(
            status: .paused, runQueue: [item("a1")], currentRunPhase: .reviewer,
            currentRunAttempt: 1, lastActivityAt: Date(), stallTimeoutMinutes: 20)

        XCTAssertNil(run?.phaseRail)
    }

    /// The age past which the rail warns is half the project's own
    /// `stallTimeoutMinutes` — derived from the setting, not a constant.
    func testPhaseRailWarnsAtHalfTheStallTimeout() {
        let now = Date()
        let rail = PortfolioSnapshot.phaseRail(
            currentRunPhase: .worker, attempt: 1,
            lastActivityAt: now.addingTimeInterval(-301), stallTimeoutMinutes: 10, now: now)

        XCTAssertEqual(rail?.warnAtSeconds, 300, "half of 10 minutes")
        XCTAssertTrue(rail?.isStale == true, "301s past a 300s warning threshold")
    }

    func testPhaseRailIsNotStaleBeforeItsWarnThreshold() {
        let now = Date()
        let rail = PortfolioSnapshot.phaseRail(
            currentRunPhase: .worker, attempt: 1,
            lastActivityAt: now.addingTimeInterval(-10), stallTimeoutMinutes: 10, now: now)

        XCTAssertFalse(rail?.isStale == true)
    }

    /// Every `RunPhase` the run log can write maps to a step, or is explicitly
    /// named as one the rail draws nothing for — nothing falls through
    /// unnoticed. `RunPhase.step(for:)`'s own switch is exhaustive at compile
    /// time; this pins the mapping itself so a case moved to the wrong step
    /// fails a test rather than only a reviewer's reading of the diff.
    func testEveryRunPhaseMapsToAStepOrIsExplicitlyNotShown() {
        typealias Step = PortfolioSnapshot.RunState.PhaseRail.Step
        let expected: [BacklogAutopilot.RunPhase: Step?] = [
            .runStart: nil,
            .itemStart: nil,
            .itemRelease: nil,
            .worker: .worker,
            .workerEmptyDiff: .worker,
            .workerSteer: .worker,
            .verify: .verify,
            .reviewer: .review,
            .reviewerClarify: .review,
            .reviewerClarifyTimeout: .review,
            .itemAbort: nil,
            .itemOverBudget: nil,
            .itemNearCap: nil,
            .itemEnd: nil,
            .agentRestart: nil,
            .merge: .merge,
            .mergeWaiting: .waitingForGate,
            .pullRequest: .gate,
            .pullRequestChecks: .gate,
            .pullRequestFix: .gate,
            .pullRequestComments: .gate,
            .runPause: nil,
            .runEnd: nil
        ]

        XCTAssertEqual(Set(expected.keys), Set(BacklogAutopilot.RunPhase.allCases),
                       "every RunPhase case is accounted for here, and no stale one lingers")
        for phase in BacklogAutopilot.RunPhase.allCases {
            XCTAssertEqual(PortfolioSnapshot.RunState.PhaseRail.step(for: phase), expected[phase] ?? nil,
                           "\(phase.rawValue) mapped unexpectedly")
        }
    }

    /// A merge queued behind another on the same project reads as its own step
    /// — not as a merge already verifying, which is what it used to read as —
    /// and `merge` still reads past it once the gate is held.
    func testAQueuedMergeReadsAsWaitingForTheGateAndMergeReadsPastIt() {
        typealias Step = PortfolioSnapshot.RunState.PhaseRail.Step
        let waiting = PortfolioSnapshot.phaseRail(
            currentRunPhase: .mergeWaiting, attempt: 1, lastActivityAt: Date(), stallTimeoutMinutes: 10)

        XCTAssertEqual(waiting?.current, .waitingForGate)
        XCTAssertEqual(waiting?.stepsDone, [.worker, .verify, .review],
                       "the wait sits after review and before the merge itself")

        let merging = PortfolioSnapshot.phaseRail(
            currentRunPhase: .merge, attempt: 1, lastActivityAt: Date(), stallTimeoutMinutes: 10)

        XCTAssertEqual(merging?.current, .merge)
        XCTAssertEqual(merging?.stepsDone, [.worker, .verify, .review, .waitingForGate],
                       "a gate that is verifying has the wait behind it")
        XCTAssertEqual(Step.allCases,
                       [.worker, .verify, .review, .waitingForGate, .merge, .gate],
                       "declaration order is the pipeline order stepsDone reads")
    }

    // MARK: - Reflecting change

    /// The snapshot is captured, not cached: an item moving ready → active shows
    /// up on the next capture, otherwise the coordinator would reason on the
    /// portfolio as it was when the run began.
    func testCaptureReflectsAStatusChange() throws {
        try openProject(named: "alpha", items: [("a1", .ready), ("a2", .ready)])

        let before = try XCTUnwrap(PortfolioSnapshot.capture(registry: registry).project(named: "alpha"))
        XCTAssertEqual(before.count(.ready), 2)
        XCTAssertEqual(before.count(.active), 0)

        let entry = try XCTUnwrap(registry.entry(forProject: "alpha"))
        entry.session.backlogViewModel.backlogFile = backlogFile([("a1", .active), ("a2", .ready)])

        let after = try XCTUnwrap(PortfolioSnapshot.capture(registry: registry).project(named: "alpha"))
        XCTAssertEqual(after.count(.ready), 1)
        XCTAssertEqual(after.count(.active), 1)
    }

    /// Read-only is the item's central promise: capturing must not file, edit or
    /// start anything. Nothing about the project may differ afterwards.
    func testCaptureLeavesEveryProjectUntouched() throws {
        let autopilot = try openProject(named: "alpha", items: [("a1", .ready)])
        let entry = try XCTUnwrap(registry.entry(forProject: "alpha"))
        let itemsBefore = entry.session.backlogViewModel.backlogFile?.sections.flatMap(\.items) ?? []

        _ = PortfolioSnapshot.capture(registry: registry)
        _ = PortfolioSnapshot.capture(registry: registry)

        let itemsAfter = entry.session.backlogViewModel.backlogFile?.sections.flatMap(\.items) ?? []
        XCTAssertEqual(itemsAfter.map(\.id), itemsBefore.map(\.id))
        XCTAssertEqual(itemsAfter.map(\.status), itemsBefore.map(\.status))
        XCTAssertEqual(autopilot.status, .idle, "capturing must not start a run")
        XCTAssertTrue(autopilot.runQueue.isEmpty)
        XCTAssertTrue(autopilot.results.isEmpty)
        XCTAssertEqual(registry.entries.count, 1)
    }

    // MARK: - Recent outcomes

    /// Newest first and capped, so a run of failures is visible without the
    /// prompt carrying a whole run log.
    func testRecentOutcomesAreNewestFirstAndCapped() {
        let results: [BacklogAutopilot.ItemResult] = (1...7).map {
            result(id: "i\($0)", outcome: $0 == 7 ? .blocked("verify failed") : .done)
        }

        let recent = PortfolioSnapshot.recentOutcomes(results, limit: 3)

        XCTAssertEqual(recent.map(\.itemID), ["i7", "i6", "i5"])
        XCTAssertEqual(recent.first?.outcome, "blocked", "the reason belongs to the run, not the portfolio")
    }

    func testRecentOutcomesNameEveryOutcomeKind() {
        let recent = PortfolioSnapshot.recentOutcomes([
            result(id: "i1", outcome: .done),
            result(id: "i2", outcome: .awaitingApproval),
            result(id: "i3", outcome: .cancelled)
        ])

        XCTAssertEqual(recent.map(\.outcome), ["cancelled", "awaiting-approval", "done"])
    }

    // MARK: - Item-level detail

    /// The point of the whole thing: the snapshot names what would run next and
    /// what is stuck, rather than only counting them.
    func testSnapshotNamesReadyAndBlockedItems() {
        let project = PortfolioSnapshot.project(
            name: "alpha", path: "/tmp/alpha", autopilotReady: true,
            backlog: backlogFile([("a1", .ready), ("a2", .blocked), ("a3", .done)]),
            status: .idle, runQueue: [], results: []
        )

        XCTAssertEqual(project.readyItems.items.map(\.id), ["a1"])
        XCTAssertEqual(project.readyItems.items.first?.title, "A1")
        XCTAssertEqual(project.readyItems.items.first?.size, "S")
        XCTAssertEqual(project.blockedItems.items.map(\.id), ["a2"])
        XCTAssertEqual(project.blockedItems.items.first?.size, "S")
    }

    /// Ready items come back in the order the run will walk them: lane first,
    /// the file's order second. It has to be the run order and not the file's
    /// because the list is capped — a `now` item further down the file than the
    /// cap reaches would otherwise be missing from the "next items" the
    /// coordinator reads and from the queue on the phone.
    func testReadyItemsAreReportedLaneFirst() {
        let project = PortfolioSnapshot.project(
            name: "alpha", path: "/tmp/alpha", autopilotReady: true,
            backlog: BacklogFile(project: "test", sections: [
                BacklogSection(name: "Platform", items: [
                    laneItem("first-later", lane: .later),
                    laneItem("first-now", lane: .now),
                ]),
                BacklogSection(name: "Onboarding", items: [
                    laneItem("last-later", lane: .later),
                    laneItem("last-now", lane: .now),
                ]),
            ]),
            status: .idle, runQueue: [], results: []
        )

        XCTAssertEqual(project.readyItems.items.map(\.id),
                       ["first-now", "last-now", "first-later", "last-later"])
    }

    /// The cap is applied to the run order, so a promoted item past it is
    /// carried and a `later` one is what goes unshown.
    func testTheCapIsTakenOffTheLaneOrderedQueue() {
        let sample = PortfolioSnapshot.items(
            BacklogFile(project: "test", sections: [
                BacklogSection(name: "Platform", items: [
                    laneItem("a", lane: .later),
                    laneItem("b", lane: .later),
                    laneItem("c", lane: .now),
                ]),
            ]),
            status: .ready, limit: 2)

        XCTAssertEqual(sample.items.map(\.id), ["c", "a"])
        XCTAssertEqual(sample.omitted, 1)
    }

    // MARK: - Startable

    /// The figure a caller (`QueueRefill`) judges hunger against: how many of
    /// the ready items could actually start, as opposed to how many merely sit
    /// at `ready`. Threaded straight through the split-out assembly, so `capture`
    /// filling it from a project's `QueueHealth` is a one-line change downstream
    /// of this passthrough rather than a second derivation.
    func testStartableIsThreadedThroughFromTheAssembly() {
        let project = PortfolioSnapshot.project(
            name: "alpha", path: "/tmp/alpha", autopilotReady: true,
            backlog: backlogFile([("a1", .ready), ("a2", .ready), ("a3", .ready)]),
            status: .idle, runQueue: [], results: [], startable: 1
        )

        XCTAssertEqual(project.count(.ready), 3, "the raw tally is unaffected")
        XCTAssertEqual(project.startable, 1)
    }

    /// A caller that says nothing about it — every existing construction in
    /// this file and in `QueueRefillTests` — must keep reading as "unknown",
    /// never as zero: zero is a stalled queue, unknown is a queue nobody
    /// measured.
    func testStartableDefaultsToNilWhenNotSupplied() {
        let project = PortfolioSnapshot.project(
            name: "alpha", path: "/tmp/alpha", autopilotReady: true,
            backlog: backlogFile([("a1", .ready)]), status: .idle, runQueue: [], results: []
        )

        XCTAssertNil(project.startable)
    }

    // MARK: - Idle with runnable work

    /// The headline case: `idle` is written for two states that mean opposite
    /// things — a project with nothing left to do, and one with runnable items
    /// the fleet keeps declining to start — and only the second wants anybody's
    /// attention. This is the pair being read together.
    func testIdleWithRunnableWorkIsToldApartFromAFinishedProject() throws {
        let stalled = idleProject(runnable: 6, refusal: observedRefusal)
        let finished = idleProject(runnable: 0, ready: [])

        let reading = try XCTUnwrap(stalled.idleWithRunnableWork)
        XCTAssertEqual(reading.runnable, 6)
        XCTAssertEqual(reading.headline, "idle, 6 runnable")
        XCTAssertNil(finished.idleWithRunnableWork,
                     "a project with nothing runnable is the healthy case and reads as it always did")
    }

    /// One run at a time per project is the design, so a queue waiting behind a
    /// running item is normal. Flagging it would make the surface lie about the
    /// healthy case — which is the whole reason the two states are kept apart.
    func testARunInFlightIsNotFlaggedHoweverDeepTheQueue() {
        let running = idleProject(runnable: 6, status: .running(itemIndex: 0, total: 6),
                                  runQueue: [item("a1")])
        let reviewing = idleProject(runnable: 6, status: .reviewing(itemIndex: 0, total: 6, attempt: 2),
                                    runQueue: [item("a1")])

        XCTAssertNil(running.idleWithRunnableWork)
        XCTAssertNil(reviewing.idleWithRunnableWork)
    }

    /// A paused run is queued work somebody stopped, and `RunState` reports it
    /// precisely so it is not read as idleness. It must not be read as it here
    /// either.
    func testAPausedRunIsNotFlaggedAsIdle() {
        let held = idleProject(runnable: 6, status: .paused, runQueue: [item("a1"), item("a2")])

        XCTAssertNil(held.idleWithRunnableWork)
    }

    /// The hard stop is the human's, it is the answer to "why is nothing
    /// running", and the paused control already carries it.
    func testAPausedProjectIsNotFlagged() {
        let paused = idleProject(runnable: 6, paused: true, refusal: observedRefusal)

        XCTAssertNil(paused.idleWithRunnableWork)
    }

    /// A queue nobody measured is not a queue with nothing in it. An unasked
    /// question has no answer, and reporting one would be a claim nobody made.
    func testAnUnmeasuredQueueIsNotFlagged() {
        XCTAssertNil(idleProject(runnable: nil, refusal: observedRefusal).idleWithRunnableWork)
    }

    /// The refusal is the deciding gate's own sentence, carried through
    /// unchanged — a second wording drifts from the one that actually decided,
    /// and then the screen and the run log say different things about one tick.
    func testTheLastRefusalIsCarriedVerbatim() throws {
        let reading = try XCTUnwrap(idleProject(runnable: 6, refusal: observedRefusal)
            .idleWithRunnableWork)

        XCTAssertEqual(reading.refusal, observedRefusal.detail)
        XCTAssertEqual(reading.refusalLine, "declined: \(observedRefusal.detail)")
    }

    /// The contradiction is worth stating whether or not anything wrote down a
    /// reason for it: a project idling on runnable work is the finding, and the
    /// reason is what it has to add.
    func testARefusalWithNoRecordedReasonStillRenders() throws {
        let reading = try XCTUnwrap(idleProject(runnable: 6, refusal: nil).idleWithRunnableWork)

        XCTAssertEqual(reading.headline, "idle, 6 runnable")
        XCTAssertNil(reading.refusal)
        XCTAssertNil(reading.refusalLine, "no line at all, rather than an empty one")
        XCTAssertEqual(reading.namedItems, [])
    }

    /// The item the refusal named, so the reader has somewhere to go — matched
    /// against ids the backlog actually holds, in backlog order.
    func testTheRefusalNamesTheItemItNamed() throws {
        let reading = try XCTUnwrap(
            idleProject(runnable: 6, refusal: observedRefusal,
                        ready: ["a1", "memory-proposals-are-invisible-headlessly"])
                .idleWithRunnableWork)

        XCTAssertEqual(reading.namedItems, ["memory-proposals-are-invisible-headlessly"],
                       "the item the sentence names, and not the one it doesn't")
    }

    /// A match against real ids, never a parse of the sentence: an id nothing
    /// wrote down is not named, and a name the backlog doesn't hold cannot be
    /// produced at all.
    func testOnlyItemsTheBacklogHoldsCanBeNamed() {
        XCTAssertEqual(
            PortfolioSnapshot.itemsNamed(in: "no runnable items — a2 (not grounded)",
                                         among: ["a1", "a2", "a3"]),
            ["a2"])
        XCTAssertEqual(
            PortfolioSnapshot.itemsNamed(in: "no runnable items — b9 (not grounded)",
                                         among: ["a1", "a2"]),
            [], "an id outside the backlog is not named, however plainly it is written")
    }

    /// `a` and `a-b` can both be ready items, and a sentence naming `a-b`
    /// contains `a` — the longer one is what was actually written down.
    func testAnIDContainedInAnotherIsNotNamedAlongsideIt() {
        XCTAssertEqual(
            PortfolioSnapshot.itemsNamed(in: "no runnable items — fleet-board-idle (not grounded)",
                                         among: ["fleet-board", "fleet-board-idle"]),
            ["fleet-board-idle"])
    }

    /// An accepted start is not a reason nothing is running. Carried as one, a
    /// project that finished the queue it was given would report the acceptance
    /// that started it as the cause of its own idleness.
    func testAnAcceptedStartIsNotCarriedAsARefusal() {
        let accepted = BacklogAutopilot.StartOutcome(attempt: 4, refusal: nil, detail: "3 items queued")

        XCTAssertNil(PortfolioSnapshot.startRefusal(accepted))
        XCTAssertNil(PortfolioSnapshot.startRefusal(nil), "nothing has asked yet")
        XCTAssertEqual(
            PortfolioSnapshot.startRefusal(
                BacklogAutopilot.StartOutcome(attempt: 5, refusal: .noRunnableItems, detail: "nope")),
            PortfolioSnapshot.StartRefusal(gate: "no-runnable-items", detail: "nope"))
    }

    /// The two facts come off the live project, not off a second derivation:
    /// `runnable` is the queue's own verdict — which is why it reads 0 here
    /// while three items sit at `ready` — and the refusal is whatever the
    /// autopilot last recorded a `start()` deciding.
    func testCaptureCarriesTheQueueVerdictAndTheLastRefusal() async throws {
        let autopilot = try openProject(named: "alpha",
                                        items: [("a1", .ready), ("a2", .ready), ("a3", .ready)])
        await autopilot.start()

        let alpha = try XCTUnwrap(PortfolioSnapshot.capture(registry: registry).project(named: "alpha"))

        XCTAssertEqual(alpha.count(.ready), 3)
        XCTAssertEqual(alpha.runnable, 0, "the queue's verdict, not the raw ready tally")
        XCTAssertEqual(alpha.lastStartRefusal?.gate, "not-configured")
        XCTAssertEqual(alpha.lastStartRefusal?.detail,
                       "orchestrator or backlogViewModel not configured")
    }

    /// Stated, never acted on — `ItemDisagreement`'s discipline, one level up.
    /// Reading the contradiction starts nothing, reorders nothing and retries
    /// nothing: the fleet's decision stands, it is only being made legible.
    func testReadingTheContradictionStartsNothing() throws {
        let autopilot = try openProject(named: "alpha", items: [("a1", .ready)])
        autopilot.selectedItemIDs = ["a1"]

        let alpha = try XCTUnwrap(PortfolioSnapshot.capture(registry: registry).project(named: "alpha"))
        _ = alpha.idleWithRunnableWork
        _ = idleProject(runnable: 6, refusal: observedRefusal).idleWithRunnableWork

        XCTAssertEqual(autopilot.status, .idle, "no run was started")
        XCTAssertTrue(autopilot.runQueue.isEmpty, "nothing was queued")
        XCTAssertEqual(autopilot.selectedItemIDs, ["a1"], "nothing was reordered or reselected")
        XCTAssertNil(autopilot.lastStartOutcome, "start() was never reached")
    }

    /// The reason half of `blocked:<reason>`, which is what turns "12 blocked"
    /// into "12 blocked, 9 of them on verify_passed".
    func testBlockedItemCarriesTheReasonItsLastRunRecorded() {
        let lookup = PortfolioSnapshot.lastRunLookup(
            metrics: metricStore([
                metric(itemID: "a2", projectPath: "/tmp/alpha",
                       outcome: "blocked:verify_passed", quality: 0.42)
            ]),
            projectPath: "/tmp/alpha"
        )

        let project = PortfolioSnapshot.project(
            name: "alpha", path: "/tmp/alpha", autopilotReady: true,
            backlog: backlogFile([("a2", .blocked)]), status: .idle,
            runQueue: [], results: [], lastRun: lookup
        )

        let run = project.blockedItems.items.first?.lastRun
        XCTAssertEqual(run?.outcome, "blocked")
        XCTAssertEqual(run?.reason, "verify_passed")
        XCTAssertEqual(run?.qualityScore, 0.42)
    }

    /// The honesty clause: an item nothing has ever run says exactly that. A
    /// guessed reason here is worse than no reason — it reads identically to a
    /// recorded one.
    func testBlockedItemWithNoRecordedRunSaysSoRatherThanInventingAReason() {
        let lookup = PortfolioSnapshot.lastRunLookup(
            metrics: metricStore([metric(itemID: "other", projectPath: "/tmp/alpha",
                                         outcome: "blocked:something else")]),
            projectPath: "/tmp/alpha"
        )

        let project = PortfolioSnapshot.project(
            name: "alpha", path: "/tmp/alpha", autopilotReady: true,
            backlog: backlogFile([("a2", .blocked)]), status: .idle,
            runQueue: [], results: [], lastRun: lookup
        )

        XCTAssertNil(project.blockedItems.items.first?.lastRun)
        XCTAssertTrue(PortfolioSnapshot.itemLines(project).contains("no recorded run"),
                      PortfolioSnapshot.itemLines(project))
    }

    /// Records are global and keyed by item id, so a lookup that didn't scope to
    /// the project would hand one project's reason to another's same-named item.
    func testLastRunLookupIsScopedToItsOwnProject() {
        let store = metricStore([
            metric(itemID: "shared", projectPath: "/tmp/alpha", outcome: "blocked:alpha's reason"),
            metric(itemID: "shared", projectPath: "/tmp/beta", outcome: "blocked:beta's reason")
        ])

        XCTAssertEqual(PortfolioSnapshot.lastRunLookup(metrics: store, projectPath: "/tmp/beta")("shared")?.reason,
                       "beta's reason")
        XCTAssertEqual(PortfolioSnapshot.lastRunLookup(metrics: store, projectPath: "/tmp/alpha")("shared")?.reason,
                       "alpha's reason")
    }

    /// The store is append-only, so a re-run of the same item is a later line —
    /// and the *last* one is what the item is blocked on now.
    func testLastRunLookupTakesTheNewestRecordForAnItem() {
        let store = metricStore([
            metric(itemID: "a1", projectPath: "/tmp/alpha", outcome: "blocked:first try"),
            metric(itemID: "a1", projectPath: "/tmp/alpha", outcome: "blocked:second try")
        ])

        XCTAssertEqual(PortfolioSnapshot.lastRunLookup(metrics: store, projectPath: "/tmp/alpha")("a1")?.reason,
                       "second try")
    }

    /// Unwired metrics is not a reason to hide the items — they are named, and
    /// they report nothing on record.
    func testWithoutAMetricStoreItemsAreStillNamed() {
        let lookup = PortfolioSnapshot.lastRunLookup(metrics: nil, projectPath: "/tmp/alpha")
        let project = PortfolioSnapshot.project(
            name: "alpha", path: "/tmp/alpha", autopilotReady: true,
            backlog: backlogFile([("a1", .blocked)]), status: .idle,
            runQueue: [], results: [], lastRun: lookup
        )

        XCTAssertEqual(project.blockedItems.items.map(\.id), ["a1"])
        XCTAssertNil(project.blockedItems.items.first?.lastRun)
    }

    /// `done`, `cancelled` and the rest carry no reason; the whole string is the
    /// class, and nothing is invented to fill the second half.
    func testSplitOutcomeSeparatesTheClassFromTheReason() {
        XCTAssertEqual(PortfolioSnapshot.splitOutcome("blocked:verify failed").outcome, "blocked")
        XCTAssertEqual(PortfolioSnapshot.splitOutcome("blocked:verify failed").reason, "verify failed")
        XCTAssertEqual(PortfolioSnapshot.splitOutcome("done").outcome, "done")
        XCTAssertNil(PortfolioSnapshot.splitOutcome("done").reason)
        XCTAssertNil(PortfolioSnapshot.splitOutcome("blocked:").reason, "an empty half is no reason")
        XCTAssertEqual(PortfolioSnapshot.splitOutcome("awaiting-approval").outcome, "awaiting-approval",
                       "a hyphen is not a separator")
    }

    // MARK: - The bound

    /// The hard bound the prompt depends on: the list is capped, what it left
    /// out is counted, and the counts stay the truth about the totals.
    func testItemListsAreCappedAndSayHowManyWereOmitted() {
        let items = (1...20).map { ("b\($0)", BacklogItemStatus.blocked) }
        let project = PortfolioSnapshot.project(
            name: "alpha", path: "/tmp/alpha", autopilotReady: true,
            backlog: backlogFile(items), status: .idle, runQueue: [], results: [],
            itemLimit: 5
        )

        XCTAssertEqual(project.blockedItems.items.count, 5)
        XCTAssertEqual(project.blockedItems.omitted, 15)
        XCTAssertEqual(project.blockedItems.total, 20)
        XCTAssertEqual(project.count(.blocked), 20, "the counts stay authoritative, the list is a sample")
        XCTAssertTrue(PortfolioSnapshot.itemLines(project).contains("blocked (5 of 20, 15 not shown)"),
                      PortfolioSnapshot.itemLines(project))
    }

    /// A list that fits under the cap must not read as though something was
    /// held back.
    func testAnUncappedListSaysItIsWhole() {
        let project = PortfolioSnapshot.project(
            name: "alpha", path: "/tmp/alpha", autopilotReady: true,
            backlog: backlogFile([("a1", .ready), ("a2", .ready)]), status: .idle,
            runQueue: [], results: []
        )

        XCTAssertEqual(project.readyItems.omitted, 0)
        XCTAssertTrue(PortfolioSnapshot.itemLines(project).contains("ready (all 2)"),
                      PortfolioSnapshot.itemLines(project))
    }

    /// A title pasted from a detail file can be a paragraph; the prompt gets a
    /// phrase.
    func testALongTitleIsCappedRatherThanCarriedWhole() {
        let long = String(repeating: "long ", count: 200)
        let project = PortfolioSnapshot.project(
            name: "alpha", path: "/tmp/alpha", autopilotReady: true,
            backlog: BacklogFile(project: "test", repo: nil, verifyDefault: nil, sections: [
                BacklogSection(name: "Epic", items: [
                    BacklogItem(id: "a1", title: long, verify: "true", status: .ready,
                                type: .local, size: .s)
                ])
            ]),
            status: .idle, runQueue: [], results: []
        )

        let title = try? XCTUnwrap(project.readyItems.items.first?.title)
        XCTAssertEqual(title?.count, PortfolioSnapshot.itemTextLimit + 1, "capped, plus the ellipsis")
    }

    /// A status with nothing in it contributes no lines at all — an empty
    /// heading is prompt tokens spent saying nothing.
    func testAStatusWithNoItemsRendersNothing() {
        let project = PortfolioSnapshot.project(
            name: "alpha", path: "/tmp/alpha", autopilotReady: true,
            backlog: backlogFile([("a1", .done)]), status: .idle, runQueue: [], results: []
        )

        XCTAssertEqual(PortfolioSnapshot.itemLines(project), "")
    }

    // MARK: - Item detail in the prompt

    /// What the coordinator actually reads: the ids, the titles and the reason
    /// each blocked item's last run recorded.
    func testPromptSectionNamesBlockedItemsAndTheirReasons() {
        let lookup = PortfolioSnapshot.lastRunLookup(
            metrics: metricStore([
                metric(itemID: "a2", projectPath: "/tmp/alpha",
                       outcome: "blocked:verify_passed", quality: 0.4)
            ]),
            projectPath: "/tmp/alpha"
        )
        let snapshot = PortfolioSnapshot(projects: [
            PortfolioSnapshot.project(
                name: "alpha", path: "/tmp/alpha", autopilotReady: true,
                backlog: backlogFile([("a1", .ready), ("a2", .blocked), ("a3", .blocked)]),
                status: .idle, runQueue: [], results: [], lastRun: lookup
            )
        ])

        let section = snapshot.promptSection

        XCTAssertTrue(section.contains("- alpha: ready 1, blocked 2 | autopilot ready | idle"), section)
        XCTAssertTrue(section.contains("ready (all 1): a1 “A1” [S]"), section)
        XCTAssertTrue(section.contains("- a2 “A2” [S] — last run blocked: verify_passed (quality 0.40)"), section)
        XCTAssertTrue(section.contains("- a3 “A3” [S] — no recorded run"), section)
    }

    /// End to end off a live registry: the snapshot the chat captures carries
    /// the detail, and the metric store it was given is where the reason came
    /// from.
    func testCaptureCarriesItemDetailForEveryOpenProject() throws {
        try openProject(named: "alpha", items: [("a1", .ready), ("a2", .blocked)])
        let alphaPath = tempDir.appendingPathComponent("alpha", isDirectory: true)
            .path(percentEncoded: false)
        let store = metricStore([
            metric(itemID: "a2", projectPath: alphaPath, outcome: "blocked:reviewer rejected twice")
        ])

        let snapshot = PortfolioSnapshot.capture(registry: registry, metrics: store)

        let alpha = try XCTUnwrap(snapshot.project(named: "alpha"))
        XCTAssertEqual(alpha.readyItems.items.map(\.id), ["a1"])
        XCTAssertEqual(alpha.blockedItems.items.first?.lastRun?.reason, "reviewer rejected twice")
    }

    // MARK: - The advisor's view of it

    /// The snapshot reaches the persona as prompt context — the item's "structured
    /// context in the shape `recommend` already takes its inputs".
    func testPromptSectionListsEachProject() {
        let snapshot = PortfolioSnapshot(projects: [
            PortfolioSnapshot.project(
                name: "alpha", path: "/tmp/alpha", autopilotReady: true,
                backlog: backlogFile([("a1", .ready), ("a2", .blocked)]),
                status: .running(itemIndex: 0, total: 2), runQueue: [item("a1"), item("a2")],
                results: [result(id: "a0", outcome: .done)]
            ),
            PortfolioSnapshot.project(
                name: "beta", path: "/tmp/beta", autopilotReady: false,
                backlog: nil, status: .idle, runQueue: [], results: []
            )
        ])

        let section = snapshot.promptSection

        XCTAssertTrue(section.hasPrefix("## Portfolio (2 projects open)\n"), section)
        XCTAssertTrue(section.contains("- alpha: ready 1, blocked 1 | autopilot ready | running 1/2 a1"), section)
        XCTAssertTrue(section.contains("recent: a0=done"), section)
        XCTAssertTrue(section.contains("- beta: no items | autopilot not ready | idle"), section)
    }

    /// Captured from a registry, the snapshot sees every open project.
    func testCaptureSeesEveryOpenProject() throws {
        try openProject(named: "alpha", items: [("a1", .ready)])
        try openProject(named: "beta", items: [("b1", .blocked)])

        let snapshot = PortfolioSnapshot.capture(registry: registry, portfolioGoal: nil)

        XCTAssertEqual(snapshot.projects.map(\.name), ["alpha", "beta"])
        XCTAssertEqual(snapshot.project(named: "beta")?.count(.blocked), 1)
    }

    // MARK: - Helpers

    /// The refusal this repo actually sat on for half an hour on 2026-08-21,
    /// built through the production formatter rather than typed out, so the
    /// wording the reading is exercised against cannot drift from the wording a
    /// gate writes.
    private var observedRefusal: PortfolioSnapshot.StartRefusal {
        PortfolioSnapshot.StartRefusal(
            gate: "no-runnable-items",
            detail: BacklogAutopilot.noRunnableItemsDetail(
                selected: 1, wrongStatus: [], notReady: [], retired: [],
                notGrounded: [(id: "memory-proposals-are-invisible-headlessly",
                               summary: "cites a test file that is not in the repo or the vault")]))
    }

    /// A project that is running nothing, with the two facts the reading is
    /// made of — how much of its queue is runnable, and what its last start
    /// decision said.
    // MARK: - The fleet board's state cell

    /// The item a run is on is what the cell names.
    func testTheStateCellNamesTheItemARunIsOn() {
        let running = idleProject(runnable: 6, status: .running(itemIndex: 0, total: 2),
                                  runQueue: [item("a1"), item("a2")])

        guard case .inFlight(_, let itemID) = running.boardState else {
            return XCTFail("a running project shows its item: \(running.boardState)")
        }
        XCTAssertEqual(itemID, "a1")
    }

    /// Parking a project lets the run in flight finish, so the cell keeps
    /// naming its item rather than reading as already parked.
    func testAProjectParkedMidRunStillNamesTheItemInFlight() {
        let parked = idleProject(runnable: 6, status: .reviewing(itemIndex: 1, total: 2, attempt: 1),
                                 runQueue: [item("a1"), item("a2")], paused: true)

        guard case .inFlight(_, let itemID) = parked.boardState else {
            return XCTFail("the run in flight is still named: \(parked.boardState)")
        }
        XCTAssertEqual(itemID, "a2")
    }

    /// A held run and a project parked by hand both read as paused — never as
    /// idle with runnable work, which is a different thing to go and look at.
    func testAHeldRunOrAParkedProjectReadsAsPaused() {
        let held = idleProject(runnable: 6, status: .paused, runQueue: [item("a1")], refusal: observedRefusal)
        let parked = idleProject(runnable: 6, paused: true, refusal: observedRefusal)

        XCTAssertEqual(held.boardState, .paused)
        XCTAssertEqual(parked.boardState, .paused)
    }

    /// Idle with runnable work it keeps declining is said as one statement;
    /// idle with nothing to do is quiet.
    func testIdleWithRunnableWorkIsToldApartFromQuietOnTheBoard() throws {
        let stalled = idleProject(runnable: 6, refusal: observedRefusal)
        let finished = idleProject(runnable: 0, ready: [])

        XCTAssertEqual(stalled.boardState, .idleWithWork(try XCTUnwrap(stalled.idleWithRunnableWork)))
        XCTAssertEqual(finished.boardState, .quiet)
    }

    private func idleProject(runnable: Int?,
                             status: BacklogAutopilot.Status = .idle,
                             runQueue: [BacklogItem] = [],
                             paused: Bool = false,
                             refusal: PortfolioSnapshot.StartRefusal? = nil,
                             ready: [String] = ["a1"]) -> PortfolioSnapshot.Project {
        PortfolioSnapshot.project(
            name: "alpha", path: "/tmp/alpha", autopilotReady: true,
            backlog: backlogFile(ready.map { ($0, .ready) }),
            status: status, runQueue: runQueue, results: [], paused: paused,
            runnable: runnable, lastStartRefusal: refusal)
    }

    private func item(_ id: String) -> BacklogItem {
        BacklogItem(id: id, title: id.uppercased(), verify: "true", status: .ready, type: .local, size: .s)
    }

    private func result(id: String, outcome: BacklogAutopilot.ItemResult.Outcome)
        -> BacklogAutopilot.ItemResult {
        BacklogAutopilot.ItemResult(id: id, title: id.uppercased(), outcome: outcome, duration: 1)
    }

    /// A metric store backed by this test's temp directory, pre-loaded in the
    /// order given — the order matters, since the newest record for an item wins.
    private func metricStore(_ records: [TaskMetricRecord]) -> TaskMetricStore {
        let store = TaskMetricStore(
            metricsURL: tempDir.appendingPathComponent("metrics-\(UUID().uuidString).jsonl"),
            estimatesURL: tempDir.appendingPathComponent("estimates-\(UUID().uuidString).jsonl")
        )
        records.forEach { store.append($0) }
        return store
    }

    private func metric(itemID: String, projectPath: String, outcome: String,
                        quality: Double? = nil) -> TaskMetricRecord {
        var record = TaskMetricRecord(
            projectPath: projectPath, projectName: URL(fileURLWithPath: projectPath).lastPathComponent,
            itemID: itemID, title: itemID.uppercased(), epic: nil, declaredSize: "S",
            startedAt: Date(), completedAt: Date(), durationSeconds: 1, costUSD: 0.1,
            reviewerRetries: 0, outcome: outcome, workerAgent: nil, reviewerAgent: nil,
            executionID: nil
        )
        record.qualityScore = quality
        return record
    }

    private func laneItem(_ id: String, lane: BacklogLane) -> BacklogItem {
        BacklogItem(id: id, title: id.uppercased(), verify: "true",
                    status: .ready, type: .local, size: .s, lane: lane)
    }

    private func backlogFile(_ items: [(String, BacklogItemStatus)]) -> BacklogFile {
        BacklogFile(project: "test", repo: nil, verifyDefault: nil, sections: [
            BacklogSection(name: "Epic", items: items.map {
                BacklogItem(id: $0.0, title: $0.0.uppercased(), verify: "true",
                            status: $0.1, type: .local, size: .s)
            })
        ])
    }

    /// Registers a project the way `MainWindow` does — a real session and a real
    /// autopilot — so the snapshot is captured off the same registry the control
    /// API reads. No agents are started.
    @discardableResult
    private func openProject(named name: String,
                             items: [(String, BacklogItemStatus)] = [],
                             configure: (BacklogAutopilot) -> Void = { _ in }) throws -> BacklogAutopilot {
        try openProject(named: name, backlog: backlogFile(items), configure: configure)
    }

    @discardableResult
    private func openProject(named name: String,
                             backlog: BacklogFile?,
                             configure: (BacklogAutopilot) -> Void = { _ in }) throws -> BacklogAutopilot {
        let root = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = KiteloopProject(rootURL: root)
        try project.ensureDirectoryExists()

        let eventBus = EventBus(eventsURL: project.eventsURL)
        let orchestrator = Orchestrator(
            runtime: MockAgentRuntime(),
            eventBus: eventBus,
            subscriptionEngine: SubscriptionEngine(eventBus: eventBus),
            memoryManager: MemoryManager(project: project)
        )
        let session = ProjectSession(
            project: project,
            projectURL: root,
            orchestrator: orchestrator,
            sessionStore: SessionStore(projectDir: root),
            knowledgeStore: AgentKnowledgeStore(baseURL: project.knowledgeURL),
            knowledgeIndex: KnowledgeIndex(baseURL: project.knowledgeURL),
            context: ProjectSessionContext(
                runtimeFactory: { MockAgentRuntime() },
                agentCatalogStore: AgentCatalogStore(storageURL: tempDir.appendingPathComponent("catalog.json")),
                packageResolver: nil,
                globalConfigStore: GlobalConfigStore(storageURL: tempDir.appendingPathComponent("global.json")),
                orgManifestLoader: OrgManifestLoader(),
                repoCloneService: RepoCloneService()
            )
        )
        session.backlogViewModel.backlogFile = backlog
        let autopilot = BacklogAutopilot()
        configure(autopilot)
        registry.register(session: session, autopilot: autopilot)
        return autopilot
    }
}
