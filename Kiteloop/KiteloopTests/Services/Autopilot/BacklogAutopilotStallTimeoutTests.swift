import XCTest
import KiteloopCore
@testable import Kiteloop

/// Covers the stall watchdog: where `stallTimeoutMinutes` comes from now that
/// it is derived from this project's own worker phases rather than set on the
/// Autopilot page, and the progress test that decides whether its clock is
/// reset at all. `RunTimeoutsTests` pins the arithmetic; this pins the wiring,
/// including the graph the derived number is actually handed to.
@MainActor
final class BacklogAutopilotStallTimeoutTests: XCTestCase {

    private var tempDir: URL!
    /// Held for the stall fixture: the autopilot's references to both are
    /// weak, and a watchdog with no orchestrator ends nothing.
    private var backlog: BacklogViewModel?
    private var orchestrator: Orchestrator?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try makeTemporaryDirectory(prefix: "autopilot-stall-timeout")
    }

    /// One landed run: both phase durations present, which is what makes a
    /// record a sample.
    private func landed(worker: Double, gate: Double) -> TaskMetricRecord {
        var record = TaskMetricRecord(
            projectPath: tempDir.path(percentEncoded: false), projectName: "demo",
            itemID: "item-1", title: "An item", epic: nil, declaredSize: nil,
            startedAt: Date(), completedAt: Date(), durationSeconds: 7_200, costUSD: 1,
            reviewerRetries: 0, outcome: "done", workerAgent: nil, reviewerAgent: nil,
            executionID: nil, toolErrors: nil)
        record.workerPhaseSeconds = worker
        record.gatePhaseSeconds = gate
        return record
    }

    private func makeAutopilot(landedRuns: [TaskMetricRecord]) -> BacklogAutopilot {
        let store = TaskMetricStore(
            metricsURL: tempDir.appendingPathComponent("task-metrics.jsonl"),
            estimatesURL: tempDir.appendingPathComponent("task-estimates.jsonl"),
            approvalsURL: tempDir.appendingPathComponent("task-approvals.jsonl"),
            mergesURL: tempDir.appendingPathComponent("task-merges.jsonl"))
        landedRuns.forEach(store.append)
        let autopilot = BacklogAutopilot()
        autopilot.configure(
            orchestrator: Orchestrator(runtime: MockAgentRuntime()),
            backlogViewModel: BacklogViewModel(
                globalConfigStore: GlobalConfigStore(
                    storageURL: tempDir.appendingPathComponent("global-config.json"))),
            configURL: tempDir.appendingPathComponent("autopilot-config.json"),
            metricStore: store,
            projectPath: tempDir.path(percentEncoded: false),
            projectName: "demo")
        return autopilot
    }

    // MARK: - Where the worker's clock comes from

    /// Ten landed runs, and the worker's clock is their p95 *worker* phase plus
    /// half again — 1800s × 1.5 = 45 minutes. The gate phase in the same
    /// records is short, and the whole run longer still: each deadline reads
    /// the phase it bounds, which is the failure this derivation exists to fix.
    func testTenLandedRunsDeriveTheWorkerDeadline() {
        let autopilot = makeAutopilot(landedRuns: (0..<10).map { _ in landed(worker: 1_800, gate: 120) })

        XCTAssertEqual(autopilot.stallTimeoutMinutes, 45)
        XCTAssertEqual(autopilot.autoMergeVerifyTimeoutMinutes, RunTimeouts.gateFloorMinutes)
        XCTAssertEqual(autopilot.runTimeouts.worker.source, .derived)
    }

    /// Four landed runs is not a distribution — the project stays on the number
    /// every project ran on before the derivation existed.
    func testFourLandedRunsKeepTheDefaultDeadline() {
        let autopilot = makeAutopilot(landedRuns: (0..<4).map { _ in landed(worker: 1_800, gate: 120) })

        XCTAssertEqual(autopilot.stallTimeoutMinutes, RunTimeouts.defaultWorkerMinutes)
        XCTAssertEqual(autopilot.runTimeouts.worker.source, .default)
    }

    /// The watchdog stays armed however fast this project's rounds are: the
    /// floor is what keeps it from firing inside a normal one.
    func testAFastProjectStillGetsTheFloor() {
        let autopilot = makeAutopilot(landedRuns: (0..<6).map { _ in landed(worker: 30, gate: 30) })

        XCTAssertEqual(autopilot.stallTimeoutMinutes, RunTimeouts.workerFloorMinutes)
    }

    /// The graph the run is actually executed under is built from the derived
    /// number — the wiring the deadline is worthless without.
    func testTheRunGraphIsBuiltFromTheDerivedDeadline() {
        let autopilot = makeAutopilot(landedRuns: (0..<10).map { _ in landed(worker: 1_800, gate: 120) })

        let graph = BacklogAutopilot.buildWorkflowGraph(
            workerAgentID: "w", reviewerAgentID: "r", maxIterations: 3,
            nodeTimeoutSeconds: autopilot.stallTimeoutMinutes * 60)

        XCTAssertEqual(graph.nodes["worker"]?.timeoutSeconds, 45 * 60)
        XCTAssertEqual(graph.nodes["reviewer"]?.timeoutSeconds, 45 * 60)
    }

    // MARK: - The progress test the watchdog's clock is reset by

    /// The hang this watchdog exists to end. A run parked on `reviewer` with the
    /// pre-review evidence gate unanswered moves nothing: the node it sits on is
    /// the node it sat on, no step is appended, and the reviewer agent is not
    /// working because it was never let through. The progress test must say so —
    /// while it read the *announced* node, which never became `reviewer`, every
    /// poll looked like a node change and the timeout was unreachable.
    func testAPendingReviewGateIsNotMistakenForProgress() {
        XCTAssertFalse(BacklogAutopilot.madeProgress(
            node: "reviewer",
            previousNode: "reviewer",
            stepCount: 4,
            previousStepCount: 4,
            agentWorking: false
        ))
    }

    /// Each of the three signals still resets the clock on its own, so an
    /// ordinary long node is not killed for being slow.
    func testEachSignalOfLifeStillCountsAsProgress() {
        XCTAssertTrue(BacklogAutopilot.madeProgress(
            node: "reviewer", previousNode: "worker",
            stepCount: 4, previousStepCount: 4, agentWorking: false
        ), "a node transition is progress")

        XCTAssertTrue(BacklogAutopilot.madeProgress(
            node: "worker", previousNode: "worker",
            stepCount: 5, previousStepCount: 4, agentWorking: false
        ), "a new step is progress")

        XCTAssertTrue(BacklogAutopilot.madeProgress(
            node: "worker", previousNode: "worker",
            stepCount: 4, previousStepCount: 4, agentWorking: true
        ), "an agent that is working is progress, however quiet the execution is")
    }

    /// The first poll of a run compares against the empty node and the -1 step
    /// count the loop starts from, which is a start, not a stall.
    func testTheFirstPollOfARunCountsAsProgress() {
        XCTAssertTrue(BacklogAutopilot.madeProgress(
            node: "worker", previousNode: "",
            stepCount: 0, previousStepCount: -1, agentWorking: false
        ))
    }

    // MARK: - What the run announces is still gated on the review gate

    /// The span and the `→ Reviewer (attempt N)` line wait for the gate, so a run
    /// the gate closes writes no `reviewer` phase row — separating the observed
    /// node from the announced one must not have changed that.
    func testTheReviewerIsAnnouncedOnlyOnceTheGateIsOpen() {
        XCTAssertFalse(BacklogAutopilot.nodeHasStarted("reviewer", reviewGateOpen: false))
        XCTAssertTrue(BacklogAutopilot.nodeHasStarted("reviewer", reviewGateOpen: true))
    }

    /// Every other node starts the moment the execution enters it — the gate is
    /// the reviewer's alone.
    func testEveryOtherNodeStartsOnEntryWhateverTheGateSays() {
        XCTAssertTrue(BacklogAutopilot.nodeHasStarted("worker", reviewGateOpen: false))
        XCTAssertTrue(BacklogAutopilot.nodeHasStarted(BacklogAutopilot.reviewerClarifyNodeID,
                                                      reviewGateOpen: false))
    }

    /// Every judged node in the run's graph takes its wall clock from the
    /// deadline it is built with, not a constant: built for a 20-minute budget,
    /// each is 1200 s, and no node keeps the old literal 600/900.
    func testRunGraphNodeTimeoutsFollowTheStallBudget() {
        let graph = BacklogAutopilot.buildWorkflowGraph(
            workerAgentID: "w", reviewerAgentID: "r", maxIterations: 3,
            nodeTimeoutSeconds: 20 * 60)
        XCTAssertEqual(graph.nodes["worker"]?.timeoutSeconds, 1200)
        XCTAssertEqual(graph.nodes["reviewer"]?.timeoutSeconds, 1200)
        let fix = BacklogAutopilot.buildCheckFixGraph(workerAgentID: "w", nodeTimeoutSeconds: 1200)
        XCTAssertEqual(fix.nodes["worker"]?.timeoutSeconds, 1200)
    }

    /// A breaker-ended run's blocked reason carries the breaker's own sentence,
    /// so "max retries" no longer stands in for a timeout nobody could see.
    func testBreakerReasonSurfacesTheFailureReasonTheEngineWrote() {
        let state: [String: AnyCodable] =
            ["_failureReason": .string("Node timeout (600s) exceeded for node 'worker'")]
        XCTAssertEqual(BacklogAutopilot.breakerReason(state: state),
                       "Node timeout (600s) exceeded for node 'worker'")
        XCTAssertNil(BacklogAutopilot.breakerReason(state: [:]))
        XCTAssertNil(BacklogAutopilot.breakerReason(state: nil))
    }

    // MARK: - What the watchdog does once the clock has run out

    /// A project holding `stalled-item` with a detail file for its Notes, and
    /// an autopilot whose orchestrator the test can see.
    private func stallFixture() throws -> (BacklogAutopilot, Orchestrator) {
        try """
        # Demo Backlog

        ## Epic: Now

        - [ ] stalled-item | Stalled item | active → [detail](backlog/stalled-item.md)
        """.write(to: tempDir.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)
        let details = tempDir.appending(path: "backlog")
        try FileManager.default.createDirectory(at: details, withIntermediateDirectories: true)
        try "# Stalled item\n\nWhat: test item.\n"
            .write(to: details.appending(path: "stalled-item.md"), atomically: true, encoding: .utf8)
        let backlog = BacklogViewModel(globalConfigStore: GlobalConfigStore(
            storageURL: tempDir.appendingPathComponent("global-config.json")))
        backlog.loadForProject(repoPath: tempDir.path(percentEncoded: false))
        let orchestrator = Orchestrator(runtime: MockAgentRuntime())
        let autopilot = BacklogAutopilot()
        autopilot.configure(orchestrator: orchestrator, backlogViewModel: backlog,
                            configURL: tempDir.appendingPathComponent("autopilot-config.json"),
                            projectPath: tempDir.path(percentEncoded: false))
        self.backlog = backlog
        self.orchestrator = orchestrator
        return (autopilot, orchestrator)
    }

    private func execution(_ status: ExecutionStatus) -> WorkflowExecution {
        WorkflowExecution(id: "stalled-exec", graphID: "g", currentNode: "worker", status: status,
                          state: [:], steps: [])
    }

    /// Nothing has moved for longer than the deadline: the run ends as timed
    /// out, and the reason it ends on — which the item's failure path reads —
    /// names the deadline and the node it hung on.
    func testARunWithNoProgressPastTheDeadlineEndsTimedOut() async throws {
        let (autopilot, _) = try stallFixture()

        let ended = await autopilot.handleStallForTesting(
            execution: execution(.running), itemID: "stalled-item", activeAgentID: "worker",
            lastProgressAt: Date().addingTimeInterval(-120), stallTimeout: 60)

        XCTAssertEqual(ended, .timedOut)
        let reason = try XCTUnwrap(autopilot.lastStallReasonForTesting)
        XCTAssertEqual(reason, "stalled: no progress for \(autopilot.stallTimeoutMinutes) min on worker")
        XCTAssertTrue(autopilot.log.contains { $0.message == "Stalled — \(reason); ending run" })
        let notes = try String(contentsOf: tempDir.appending(path: "backlog/stalled-item.md"), encoding: .utf8)
        XCTAssertFalse(notes.contains("stalled"), "a plain stall is not written to the Notes: \(notes)")
    }

    /// A worker whose turn is parked on background agents that never reported
    /// back says so — in the reason, and in the item's Notes, because that is
    /// the one stall whose cause is not the worker itself.
    func testAStallWaitingOnBackgroundAgentsSaysSoInTheNotes() async throws {
        let (autopilot, orchestrator) = try stallFixture()
        orchestrator.setPendingBackgroundAgentCount(2, for: "worker")

        let ended = await autopilot.handleStallForTesting(
            execution: execution(.pending), itemID: "stalled-item", activeAgentID: "worker",
            lastProgressAt: Date().addingTimeInterval(-120), stallTimeout: 60)

        XCTAssertEqual(ended, .timedOut)
        XCTAssertEqual(autopilot.lastStallReasonForTesting,
                       "stalled: no progress for \(autopilot.stallTimeoutMinutes) min on worker"
                       + " — still waiting on 2 background agents")
        let notes = try String(contentsOf: tempDir.appending(path: "backlog/stalled-item.md"), encoding: .utf8)
        XCTAssertTrue(notes.contains("still waiting on 2 background agents"), notes)
    }

    /// Inside the deadline the watchdog keeps polling, and a finished
    /// execution is never a stall however long ago it last moved.
    func testTheWatchdogLeavesALiveRunInsideItsDeadlineAndAFinishedOneAlone() async throws {
        let (autopilot, _) = try stallFixture()

        let fresh = await autopilot.handleStallForTesting(
            execution: execution(.running), itemID: "stalled-item", activeAgentID: "worker",
            lastProgressAt: Date(), stallTimeout: 60)
        let finished = await autopilot.handleStallForTesting(
            execution: execution(.completed), itemID: "stalled-item", activeAgentID: "worker",
            lastProgressAt: Date().addingTimeInterval(-120), stallTimeout: 60)

        XCTAssertNil(fresh)
        XCTAssertNil(finished)
        XCTAssertNil(autopilot.lastStallReasonForTesting)
        XCTAssertFalse(autopilot.log.contains { $0.message.hasPrefix("Stalled") })
    }

    private func workerStep(_ output: [String: AnyCodable]) -> ExecutionStep {
        ExecutionStep(nodeID: "worker", agentID: "w", spanID: nil, startedAt: Date(), output: output)
    }

    /// A worker that ran out of turns ends on its own reason — the budget it
    /// used and that the work is unfinished — not on a verify failure.
    func testAWorkerCutShortByItsSessionCapEndsOnTheTurnBudgetItUsed() {
        let steps = [workerStep([StreamEvent.ResultPayload.turnsOutputKey: .int(50),
                                 StreamEvent.ResultPayload.turnCapOutputKey: .bool(true)])]
        let turns = BacklogAutopilot.workerCutShortTurns(steps: steps, engineTurns: 1, maxTurns: 50)
        XCTAssertEqual(turns, 50)
        XCTAssertEqual(BacklogAutopilot.workerTurns(in: steps), 50)
        XCTAssertEqual(BacklogAutopilot.workerCutShortReason(turns: 50),
                       "worker cut short: it used its 50-turn budget with the work unfinished")
    }

    /// The engine's own `maxTurns` trip on the worker node counts the same.
    func testAnEngineMaxTurnsTripOnTheWorkerIsCutShortToo() {
        XCTAssertEqual(BacklogAutopilot.workerCutShortTurns(steps: [], engineTurns: 51, maxTurns: 50), 50)
        XCTAssertNil(BacklogAutopilot.workerCutShortTurns(steps: [], engineTurns: 50, maxTurns: 50))
    }

    /// Any other ending is not cut short, so it still goes to the salvage verify.
    func testAWorkerThatFinishedIsNotCutShort() {
        let finished = [workerStep([StreamEvent.ResultPayload.turnsOutputKey: .int(12)])]
        XCTAssertNil(BacklogAutopilot.workerCutShortTurns(steps: finished, engineTurns: 3, maxTurns: 50))
        XCTAssertEqual(BacklogAutopilot.workerTurns(in: finished), 12)
        XCTAssertNil(BacklogAutopilot.workerCutShortTurns(steps: [], engineTurns: 0, maxTurns: 50))
        XCTAssertNil(BacklogAutopilot.workerTurns(in: []))
        // A reviewer's cap is not the worker's.
        let reviewer = ExecutionStep(nodeID: "reviewer", agentID: "r", spanID: nil, startedAt: Date(),
                                     output: [StreamEvent.ResultPayload.turnCapOutputKey: .bool(true)])
        XCTAssertNil(BacklogAutopilot.workerCutShortTurns(steps: finished + [reviewer], engineTurns: 3, maxTurns: 50))
    }
}
