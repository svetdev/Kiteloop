import XCTest
import KiteloopCore
@testable import Kiteloop

/// Whether autopilot is busy, and what it says it is busy with.
///
/// A project could be permanently stuck "busy" with nothing running: `status` was
/// left non-idle by a run that never began (the session cost cap fires before the
/// first item starts), and from then on every run request was refused, resume
/// changed nothing, and only restarting the app cleared it. These cover the two
/// halves of the fix — busy derived from a run that actually exists, and the
/// reconciliation that clears a claim with nothing behind it.
@MainActor
final class BacklogAutopilotBusyStateTests: XCTestCase {

    // MARK: - What "busy" means

    func testAnIdleAutopilotIsRunningNothing() async {
        let autopilot = BacklogAutopilot()
        let inFlight = await autopilot.inFlightRun()
        XCTAssertNil(inFlight)
    }

    /// The case that stuck a project: paused before the item it was queued on ever
    /// started. Nothing is executing, so nothing is in flight — whatever the flag
    /// says.
    func testAPausedStatusWithNoRunBehindItIsNotBusy() async {
        let autopilot = BacklogAutopilot()
        autopilot.stageRunForTesting(status: .paused, queue: [item("a1")])

        let inFlight = await autopilot.inFlightRun()

        XCTAssertNil(inFlight, "a status with no run behind it must not read as busy")
    }

    /// A `running` status is not evidence either — only the loop actually
    /// executing is.
    func testARunningStatusWithNoRunBehindItIsNotBusy() async {
        let autopilot = BacklogAutopilot()
        autopilot.stageRunForTesting(status: .running(itemIndex: 0, total: 1), queue: [item("a1")])

        let inFlight = await autopilot.inFlightRun()

        XCTAssertNil(inFlight)
    }

    /// The guard must not be weakened: a run genuinely in flight is reported as
    /// one, and names the item so a refusal can quote it.
    func testARunInFlightIsReportedAndNamed() async {
        let autopilot = BacklogAutopilot()
        autopilot.stageRunForTesting(status: .running(itemIndex: 0, total: 2),
                                     queue: [item("a1"), item("a2")])
        autopilot.stageExecutingRunForTesting(true)

        let inFlight = await autopilot.inFlightRun()

        XCTAssertEqual(inFlight?.itemID, "a1")
        XCTAssertEqual(inFlight?.summary, "running a1 (A1)")
    }

    /// With an execution id the summary names the run itself, which is what makes
    /// a stale claim falsifiable from outside the app.
    func testTheSummaryNamesTheRunWhenThereIsOne() {
        let run = BacklogAutopilot.InFlightRun(itemID: "a1", itemTitle: "A1", executionID: "exec-1")
        XCTAssertEqual(run.summary, "running a1 (A1) as run exec-1")
    }

    // MARK: - The state an operator reads

    func testRunStateOfAnIdleAutopilotIsIdle() async {
        let autopilot = BacklogAutopilot()

        let state = await autopilot.runState()

        XCTAssertEqual(state.phase, .idle)
        XCTAssertFalse(state.isRunning)
        XCTAssertNil(state.inFlight)
        XCTAssertNil(state.detail, "an idle project needs no explanation")
    }

    /// The answer an operator wants: what, and since when.
    func testRunStateNamesTheItemInFlightAndWhenItStarted() async {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let autopilot = BacklogAutopilot()
        autopilot.stageRunForTesting(status: .running(itemIndex: 0, total: 2),
                                     queue: [item("a1"), item("a2")])
        autopilot.stageExecutingRunForTesting(true)
        autopilot.stageItemStartedAtForTesting(started)

        let state = await autopilot.runState()

        XCTAssertEqual(state.phase, .running)
        XCTAssertTrue(state.isRunning)
        XCTAssertEqual(state.inFlight?.itemID, "a1")
        XCTAssertEqual(state.inFlight?.itemTitle, "A1")
        XCTAssertEqual(state.inFlight?.startedAt, started)
        XCTAssertEqual(state.statusLabel, "running")
    }

    /// A genuine hold is not a run and not a fault: it has items left and a
    /// resume that picks them up, and reads as its own thing.
    func testRunStateReportsAPausedQueueWithItemsLeftAsHeld() async {
        let autopilot = BacklogAutopilot()
        autopilot.stageRunForTesting(status: .paused, queue: [item("a1"), item("a2")])
        autopilot.stageQueueIndexForTesting(1)

        let state = await autopilot.runState()

        XCTAssertEqual(state.phase, .held)
        XCTAssertFalse(state.isRunning)
        XCTAssertEqual(state.heldItems, 1)
        XCTAssertEqual(state.statusLabel, "paused")
        XCTAssertEqual(state.detail, "paused with 1 item(s) still queued — resume picks them up")
    }

    /// The state that cost an hour of guessing: the autopilot claims a run and
    /// there is none. Reported as exactly that rather than rounded to `idle` —
    /// smoothing it over is what left the operator with nothing to look at.
    func testRunStateReportsABusyClaimWithNoRunBehindItAsInconsistent() async {
        let autopilot = BacklogAutopilot()
        autopilot.stageRunForTesting(status: .running(itemIndex: 0, total: 1), queue: [item("a1")])

        let state = await autopilot.runState()

        XCTAssertEqual(state.phase, .inconsistent)
        XCTAssertFalse(state.isRunning)
        XCTAssertNil(state.inFlight)
        XCTAssertEqual(state.statusLabel, "running", "the claim itself is reported, not hidden")
        XCTAssertEqual(state.detail,
                       "autopilot reads running with no run behind it — a stale claim, "
                       + "cleared by the next run request or by reopening the project")
    }

    /// And the paused variant of it: the cost cap fired before the first item, so
    /// the hold has nothing left to resume into.
    func testRunStateReportsAPausedClaimWithNothingLeftAsInconsistent() async {
        let autopilot = BacklogAutopilot()
        autopilot.stageRunForTesting(status: .paused, queue: [item("a1")])
        autopilot.stageQueueIndexForTesting(1)

        let state = await autopilot.runState()

        XCTAssertEqual(state.phase, .inconsistent)
        XCTAssertEqual(state.statusLabel, "paused")
    }

    /// The property the whole feature rests on: what the state reports and what
    /// the busy guard decides are the same call, so they cannot drift. Checked
    /// across every state, not just the running one.
    func testRunStateAgreesWithTheBusyGuardInEveryState() async {
        let idle = BacklogAutopilot()

        let running = BacklogAutopilot()
        running.stageRunForTesting(status: .running(itemIndex: 0, total: 1), queue: [item("a1")])
        running.stageExecutingRunForTesting(true)

        let held = BacklogAutopilot()
        held.stageRunForTesting(status: .paused, queue: [item("a1"), item("a2")])
        held.stageQueueIndexForTesting(1)

        let staleRunning = BacklogAutopilot()
        staleRunning.stageRunForTesting(status: .running(itemIndex: 0, total: 1), queue: [item("a1")])

        let stalePaused = BacklogAutopilot()
        stalePaused.stageRunForTesting(status: .paused, queue: [item("a1")])
        stalePaused.stageQueueIndexForTesting(1)

        for (name, autopilot) in [("idle", idle), ("running", running), ("held", held),
                                  ("stale running", staleRunning), ("stale paused", stalePaused)] {
            let state = await autopilot.runState()
            let guardSees = await autopilot.inFlightRun()

            XCTAssertEqual(state.isRunning, guardSees != nil,
                           "\(name): the reported state and the busy guard must never disagree")
            XCTAssertEqual(state.inFlight, guardSees,
                           "\(name): and they must be reporting the same run")
        }
    }

    // MARK: - Reconciliation

    func testReconcileLeavesAnIdleAutopilotAlone() async {
        let autopilot = BacklogAutopilot()

        let logCountBefore = autopilot.log.count

        let cleared = await autopilot.reconcileStatus(reason: "project opened")

        XCTAssertFalse(cleared)
        XCTAssertEqual(autopilot.status, .idle)
        XCTAssertEqual(autopilot.log.count, logCountBefore, "nothing was wrong, so nothing is reported")
    }

    /// The stuck project, recovered: paused on an item it never started, so there
    /// is nothing to resume into and the claim is stale.
    func testReconcileClearsAPausedClaimWithNothingLeftToRun() async {
        let autopilot = BacklogAutopilot()
        autopilot.stageRunForTesting(status: .paused, queue: [item("a1")])
        autopilot.stageQueueIndexForTesting(1)   // the queue ran out under the hold

        let cleared = await autopilot.reconcileStatus(reason: "project opened")

        XCTAssertTrue(cleared)
        XCTAssertEqual(autopilot.status, .idle)
        XCTAssertTrue(autopilot.log.contains { $0.message.contains("Cleared a stale busy state (project opened)") },
                      "clearing a stale claim has to be visible in the run log")
    }

    /// A `running` claim has no resume to wait for, so it is stale whatever the
    /// queue still holds.
    func testReconcileClearsARunningClaimWithNoRunBehindIt() async {
        let autopilot = BacklogAutopilot()
        autopilot.stageRunForTesting(status: .running(itemIndex: 0, total: 2),
                                     queue: [item("a1"), item("a2")])

        let cleared = await autopilot.reconcileStatus(reason: "run requested")

        XCTAssertTrue(cleared)
        XCTAssertEqual(autopilot.status, .idle)
    }

    /// A user's pause at an item boundary is a genuine hold: it has items left and
    /// a resume that picks them up, so reconciliation must not throw it away.
    func testReconcileKeepsAHoldThatStillHasItemsToRun() async {
        let autopilot = BacklogAutopilot()
        autopilot.stageRunForTesting(status: .paused, queue: [item("a1"), item("a2")])
        autopilot.stageQueueIndexForTesting(1)

        let cleared = await autopilot.reconcileStatus(reason: "project opened")

        XCTAssertFalse(cleared)
        XCTAssertEqual(autopilot.status, .paused)
    }

    /// And a run actually executing is never reconciled out from under itself.
    func testReconcileLeavesARunInFlightAlone() async {
        let autopilot = BacklogAutopilot()
        autopilot.stageRunForTesting(status: .running(itemIndex: 0, total: 1), queue: [item("a1")])
        autopilot.stageExecutingRunForTesting(true)

        let cleared = await autopilot.reconcileStatus(reason: "run requested")

        XCTAssertFalse(cleared)
        XCTAssertEqual(autopilot.status, .running(itemIndex: 0, total: 1))
    }

    // MARK: - Resume

    /// The session ledger survives across runs, so a spent cap would hold the
    /// queue until the app was relaunched — starting another run no longer clears
    /// it. A person asking the queue to continue is the session boundary: resume
    /// opens a fresh budget and picks the items back up.
    func testResumeOpensAFreshSessionForAQueueHeldByASpentCap() async {
        let autopilot = BacklogAutopilot()
        autopilot.stageRunForTesting(status: .paused, queue: [item("a1"), item("a2")])
        autopilot.stageSpentSessionForTesting(capUSD: 5, spentUSD: 6)

        await autopilot.resume()

        XCTAssertEqual(autopilot.sessionCostSoFar, 0, accuracy: 0.0001)
        XCTAssertNil(autopilot.costGovernor.sessionPause,
                     "the queue must not still be held by the budget the resume cleared")
        XCTAssertTrue(autopilot.log.contains { $0.message.hasSuffix("resuming on a fresh session budget") },
                      "the reset has to say what it cleared and what it cost")
        XCTAssertTrue(autopilot.log.contains { $0.message == "Resumed" })
    }

    /// And the items are continued, not thrown away: the queue a spent cap was
    /// holding is exactly what the fresh budget is for.
    func testResumePastASpentCapKeepsTheHeldQueue() async {
        let autopilot = BacklogAutopilot()
        autopilot.stageRunForTesting(status: .paused, queue: [item("a1"), item("a2")])
        autopilot.stageQueueIndexForTesting(1)
        autopilot.stageSpentSessionForTesting(capUSD: 5, spentUSD: 6)

        // No orchestrator is wired, so the run loop returns at once — what is
        // being read here is the queue the resume left behind for it.
        await autopilot.resume()

        let state = await autopilot.runState()
        XCTAssertEqual(state.heldItems, 1, "the item the cap stopped on is still there to run")
        XCTAssertTrue(autopilot.results.isEmpty)
    }

    /// Only a spent cap opens a new session. A queue held by the user, by the
    /// circuit breaker or by a quiesce carries its spend into the rest of the
    /// sitting — otherwise any pause at all would clear the ledger the cap is
    /// measured against.
    func testResumeKeepsTheSessionSpendWhenTheCapIsNotWhatPaused() async {
        let autopilot = BacklogAutopilot()
        autopilot.stageRunForTesting(status: .paused, queue: [item("a1")])
        autopilot.stageSpentSessionForTesting(capUSD: 20, spentUSD: 6)

        await autopilot.resume()

        XCTAssertEqual(autopilot.sessionCostSoFar, 6, accuracy: 0.0001)
        XCTAssertFalse(autopilot.log.contains { $0.message.hasSuffix("resuming on a fresh session budget") })
    }

    // MARK: - Starting on a spent session budget

    /// The start a spent cap will hold is refused where it is asked, not accepted
    /// and held a moment later. The queue loop's own check would pause at index 0
    /// having minted no execution, which is indistinguishable from a run that is
    /// merely slow to spin up — so the caller was told one was.
    func testAStartOverASpentSessionBudgetIsRefusedRatherThanAccepted() async {
        let autopilot = BacklogAutopilot()
        autopilot.stageSpentSessionForTesting(capUSD: 5, spentUSD: 6.25)

        await autopilot.start()

        let outcome = autopilot.lastStartOutcome
        XCTAssertEqual(outcome?.refusal, .sessionCap)
        XCTAssertEqual(outcome?.isAccepted, false, "nothing was queued, so nothing was accepted")
        // The pause's own wording, so the refusal names the ceiling and the spend
        // rather than leaving the caller to go and read them.
        XCTAssertEqual(outcome?.detail,
                       CostGovernor.SessionPause(capUSD: 5, spentUSD: 6.25).logLine)
        XCTAssertTrue(autopilot.log.contains { $0.message == outcome?.detail },
                      "the refusal is narrated as well as recorded")
    }

    /// And it refuses the person as well as the scheduler: the session ceiling is
    /// not a rule about autonomy — the queue stops at the next item however it was
    /// started, so a human start over one has nothing to offer either.
    func testTheSessionCapRefusesAHumanStartToo() async {
        let autopilot = BacklogAutopilot()
        autopilot.stageSpentSessionForTesting(capUSD: 5, spentUSD: 6)

        await autopilot.start(initiator: .human)

        XCTAssertEqual(autopilot.lastStartOutcome?.refusal, .sessionCap)
    }

    /// The refusal decides nothing about the run's lifecycle: a queue the cap is
    /// holding is still held, with its items, and still resumable. Moving it would
    /// take the way out away from the operator it is being reported to.
    func testTheRefusalLeavesAHeldQueueExactlyAsItWas() async {
        let autopilot = BacklogAutopilot()
        autopilot.stageRunForTesting(status: .paused, queue: [item("a1"), item("a2")])
        autopilot.stageQueueIndexForTesting(1)
        autopilot.stageSpentSessionForTesting(capUSD: 5, spentUSD: 6)

        await autopilot.start()

        XCTAssertEqual(autopilot.status, .paused)
        let state = await autopilot.runState()
        XCTAssertEqual(state.heldItems, 1, "the item the cap stopped on is still there to run")
    }

    /// The session cap is cleared the moment `resume()` is asked for, whether or
    /// not the queue itself can actually move — this bare autopilot has no
    /// orchestrator, so `continueFromCurrentIndex` returns at its very first
    /// guard and `status` never leaves `.paused`. A further start is correctly
    /// refused over that: the project's own pause holds even though the session
    /// cap that used to be the visible cause is gone, rather than a resume that
    /// did nothing real being read as one that lifted the hold.
    func testAResumeClearsTheSessionCapEvenWhenTheQueueCannotActuallyMove() async {
        let autopilot = BacklogAutopilot()
        autopilot.stageRunForTesting(status: .paused, queue: [item("a1")])
        autopilot.stageSpentSessionForTesting(capUSD: 5, spentUSD: 6)

        await autopilot.resume()
        await autopilot.start()

        XCTAssertEqual(autopilot.sessionCostSoFar, 0, accuracy: 0.0001,
                       "the resume itself always opens a fresh session")
        XCTAssertEqual(autopilot.lastStartOutcome?.refusal, .paused,
                       "still paused — nothing here ever actually ran to clear it")
    }

    /// A session with budget left is not this gate's business at all.
    func testAStartWithBudgetLeftIsNotRefusedByTheSessionCap() async {
        let autopilot = BacklogAutopilot()
        autopilot.stageSpentSessionForTesting(capUSD: 20, spentUSD: 6)

        await autopilot.start()

        XCTAssertEqual(autopilot.lastStartOutcome?.refusal, .notConfigured)
    }

    // MARK: - Starting while the fleet is quiesced

    /// The gate the UI's Start button used to bypass entirely: quiescing a
    /// project doesn't stop `start()` on its own, so without this a fresh run
    /// began right into a fleet held for a restart. Refused here the same way
    /// `POST /v1/runs` refuses it, and minting no execution.
    func testAStartWhileTheFleetIsQuiescedIsRefused() async {
        let autopilot = BacklogAutopilot()
        autopilot.isFleetQuiesced = { true }

        await autopilot.start()

        let outcome = autopilot.lastStartOutcome
        XCTAssertEqual(outcome?.refusal, .fleetQuiesced)
        XCTAssertEqual(outcome?.isAccepted, false, "nothing was queued, so nothing was accepted")
        XCTAssertEqual(autopilot.status, .idle, "no execution was minted, so status is untouched")
        XCTAssertTrue(outcome?.detail.contains("quiesced") == true)
        XCTAssertTrue(outcome?.detail.contains("resume") == true,
                      "the refusal says a resume lifts the hold, not just that it's held")
        XCTAssertTrue(autopilot.log.contains { $0.message == "Cannot start: \(outcome?.detail ?? "")" },
                      "the refusal is narrated as well as recorded")
    }

    /// And it refuses the scheduler's autonomous starts too — the hold is
    /// fleet-wide, not a rule about who asked.
    func testTheFleetQuiesceRefusesAnAutonomousStartToo() async {
        let autopilot = BacklogAutopilot()
        autopilot.isFleetQuiesced = { true }

        await autopilot.start(initiator: .autonomous)

        XCTAssertEqual(autopilot.lastStartOutcome?.refusal, .fleetQuiesced)
    }

    /// With the gate open, nothing about this changes: the start proceeds to
    /// whichever gate would ordinarily refuse it next.
    func testAStartWithTheFleetGateOpenIsNotRefusedByIt() async {
        let autopilot = BacklogAutopilot()
        autopilot.isFleetQuiesced = { false }

        await autopilot.start()

        XCTAssertEqual(autopilot.lastStartOutcome?.refusal, .notConfigured,
                       "the fleet gate let this one through")
    }

    /// And with no closure wired up at all — the state every test above this
    /// one runs in, and any autopilot the app hasn't attached the fleet
    /// control to — the gate is inert rather than refusing by default.
    func testAStartWithNoFleetGateWiredIsNotRefusedByIt() async {
        let autopilot = BacklogAutopilot()

        await autopilot.start()

        XCTAssertEqual(autopilot.lastStartOutcome?.refusal, .notConfigured)
    }

    // MARK: - Helpers

    private func item(_ id: String) -> BacklogItem {
        BacklogItem(id: id, title: id.uppercased(), verify: "true", status: .ready, type: .local, size: .s)
    }
}
