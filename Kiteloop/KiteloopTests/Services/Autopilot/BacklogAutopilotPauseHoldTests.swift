import XCTest
import KiteloopCore
@testable import Kiteloop

/// A pause outliving the run it interrupted.
///
/// The pause used to be carried as the autopilot's `status` alone, and the run
/// already in flight wrote `idle` over it on the way out — so a person who
/// paused a project to merge and rebuild got exactly one more run they had not
/// asked for, from the very next scheduler tick. The hold is its own fact now
/// (`queueHeld`), and these cover what that has to mean: the run finishing
/// leaves it standing, a resume is what lifts it, and while it stands the
/// scheduler never picks the project.
@MainActor
final class BacklogAutopilotPauseHoldTests: XCTestCase {

    // MARK: - The hold outlives the run

    /// The bug, stated: pause over the item in flight, let that item finish, and
    /// the project is still held.
    func testAPauseTakenOverTheItemInFlightHoldsAfterThatItemFinishes() async {
        let autopilot = pausedOverTheLastItemInFlight()

        // The run loop's last act, with the whole queue behind it.
        autopilot.stageExecutingRunForTesting(false)
        autopilot.settleStatusAfterRunForTesting()

        XCTAssertTrue(autopilot.queueHeld, "the pause was the person's, not the run's")
        XCTAssertTrue(autopilot.isHoldingQueue)
        XCTAssertEqual(autopilot.status, .paused, "the finishing run must not write idle over the pause")
    }

    /// A run nobody paused ends where it always did.
    func testARunNobodyPausedFinishesIdle() async {
        let autopilot = BacklogAutopilot()
        autopilot.stageRunForTesting(status: .running(itemIndex: 0, total: 1), queue: [item("a1")])
        autopilot.stageExecutingRunForTesting(true)

        autopilot.stageExecutingRunForTesting(false)
        autopilot.settleStatusAfterRunForTesting()

        XCTAssertFalse(autopilot.queueHeld)
        XCTAssertFalse(autopilot.isHoldingQueue)
        XCTAssertEqual(autopilot.status, .idle)
    }

    /// What an operator reads for that project: a hold, with nothing queued
    /// behind it and no suggestion that anything is stuck.
    func testTheHeldProjectReportsAHoldWithAnEmptyQueue() async {
        let autopilot = pausedOverTheLastItemInFlight()
        autopilot.stageExecutingRunForTesting(false)
        autopilot.settleStatusAfterRunForTesting()

        let state = await autopilot.runState()

        XCTAssertEqual(state.phase, .held)
        XCTAssertFalse(state.isRunning)
        XCTAssertEqual(state.heldItems, 0)
        XCTAssertEqual(state.statusLabel, "paused")
        XCTAssertEqual(state.detail, "paused with the queue finished — a resume lifts the hold")
    }

    /// And nothing clears it behind the person's back: the reconciliation that
    /// exists to sweep up stale claims must not read a deliberate hold as one.
    func testReconcileStatusLeavesTheHoldAlone() async {
        let autopilot = pausedOverTheLastItemInFlight()
        autopilot.stageExecutingRunForTesting(false)
        autopilot.settleStatusAfterRunForTesting()

        let cleared = await autopilot.reconcileStatus(reason: "test")

        XCTAssertFalse(cleared, "a pause is not a stale claim")
        XCTAssertEqual(autopilot.status, .paused)
        XCTAssertTrue(autopilot.queueHeld)
    }

    /// The hold refuses the Run button for the same reason it refuses the API.
    func testAHeldProjectRefusesAFreshStart() async {
        let autopilot = pausedOverTheLastItemInFlight()
        autopilot.stageExecutingRunForTesting(false)
        autopilot.settleStatusAfterRunForTesting()

        await autopilot.start()

        XCTAssertEqual(autopilot.lastStartOutcome?.refusal, .paused)
    }

    // MARK: - Only a resume lifts it

    /// A resume is the remedy, and it has to work for a hold whose queue is
    /// already finished — otherwise pausing over the last item wedges the
    /// project with nothing to pick back up and no way to say so.
    func testResumeLiftsAHoldWhoseQueueIsFinished() async {
        let autopilot = pausedOverTheLastItemInFlight()
        autopilot.stageExecutingRunForTesting(false)
        autopilot.settleStatusAfterRunForTesting()

        await autopilot.resume()

        XCTAssertFalse(autopilot.queueHeld)
        XCTAssertFalse(autopilot.isHoldingQueue)
        XCTAssertEqual(autopilot.status, .idle)
        XCTAssertTrue(autopilot.log.contains { $0.message == "Resumed" })
    }

    /// Stopping ends the queue the hold was over, so it ends the hold with it: a
    /// hold left standing here would refuse the next run with a pause the
    /// Autopilot tab — which reads `status`, by then `idle` — could not show.
    func testStopClearsTheHoldWithTheQueueItWasOver() {
        let autopilot = pausedOverTheLastItemInFlight()

        autopilot.stop()

        XCTAssertFalse(autopilot.queueHeld)
        XCTAssertFalse(autopilot.isHoldingQueue)
        XCTAssertEqual(autopilot.status, .idle)
    }

    /// A pause taken while the queue still has items behind it is untouched by
    /// any of this: it reads as it always did, and a resume picks them up.
    func testAPauseWithItemsLeftStillReadsAsAQueueToPickUp() async {
        let autopilot = BacklogAutopilot()
        autopilot.stageRunForTesting(status: .running(itemIndex: 0, total: 3),
                                     queue: [item("a1"), item("a2"), item("a3")])
        autopilot.stageQueueIndexForTesting(1)
        autopilot.pause()

        let state = await autopilot.runState()

        XCTAssertEqual(state.phase, .held)
        XCTAssertEqual(state.heldItems, 2)
        XCTAssertEqual(state.detail, "paused with 2 item(s) still queued — resume picks them up")
    }

    // MARK: - What the scheduler does with it

    /// The consequence the item is about: while the hold stands, the autonomous
    /// scheduler has no eligible project — the same refusal a project parked on
    /// the fleet board gets. Built from the autopilot's own state rather than a
    /// hand-set flag, so the whole chain is under test.
    func testTheSchedulerNeverSelectsAProjectWhileTheHoldStands() {
        let autopilot = pausedOverTheLastItemInFlight()
        autopilot.stageExecutingRunForTesting(false)
        autopilot.settleStatusAfterRunForTesting()

        let decision = decide(snapshotOf(autopilot))

        XCTAssertNil(decision.target, "a held project is never a candidate")
        XCTAssertEqual(decision.hold, .noEligibleProject)
    }

    /// And once the hold is lifted the same project is picked, so the refusal
    /// above is the hold and nothing else about the fixture.
    func testTheSchedulerPicksTheProjectAgainOnceTheHoldIsLifted() async {
        let autopilot = pausedOverTheLastItemInFlight()
        autopilot.stageExecutingRunForTesting(false)
        autopilot.settleStatusAfterRunForTesting()

        await autopilot.resume()
        let decision = decide(snapshotOf(autopilot))

        XCTAssertEqual(decision.target?.project, "alpha")
    }

    // MARK: - Fixtures

    /// The state the bug needed: a one-item queue — what every scheduler-started
    /// run is — with that item in flight and a pause taken over it.
    private func pausedOverTheLastItemInFlight() -> BacklogAutopilot {
        let autopilot = BacklogAutopilot()
        autopilot.stageRunForTesting(status: .running(itemIndex: 0, total: 1), queue: [item("a1")])
        autopilot.stageExecutingRunForTesting(true)
        autopilot.pause()
        return autopilot
    }

    private func item(_ id: String) -> BacklogItem {
        BacklogItem(id: id, title: id.uppercased(), verify: "true", status: .ready, type: .local, size: .s)
    }

    /// The portfolio the scheduler actually reads, with this project's run state
    /// derived from the autopilot the same way the fleet board derives it.
    private func snapshotOf(_ autopilot: BacklogAutopilot) -> PortfolioSnapshot {
        let project = PortfolioSnapshot.Project(
            name: "alpha",
            path: "/tmp/alpha",
            autopilotReady: true,
            autonomousWorkEnabled: true,
            approveReviewPassedRuns: false,
            statusCounts: [.ready: 1],
            readyItems: PortfolioSnapshot.ItemSample(
                items: [PortfolioSnapshot.Item(id: "a2", title: "A2", size: "S", lastRun: nil)],
                omitted: 0),
            run: PortfolioSnapshot.runState(status: autopilot.status, runQueue: autopilot.runQueue),
            recentOutcomes: [],
            paused: false,
            goal: nil
        )
        return PortfolioSnapshot(projects: [project])
    }

    private func decide(_ portfolio: PortfolioSnapshot) -> RunScheduling.Decision {
        RunScheduling.decide(portfolio: portfolio, enabled: true,
                             budget: DailyBudget(budgetUSD: 20, spentUSD: 1))
    }
}
