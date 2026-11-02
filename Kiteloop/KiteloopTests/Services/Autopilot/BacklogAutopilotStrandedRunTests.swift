import XCTest
import KiteloopCore
@testable import Kiteloop

/// A run that has ended holds nothing, whatever its execution is still doing.
///
/// On 2026-08-11 one did. The run ended with
///
///     Timed out waiting for agents ["07142AEE-…", "template-claude"]
///     for execution '432EA14E-…'
///
/// and from then on the run history read `finished` while `GET /v1/projects`
/// read `running` for the same item. The project could never start another run:
/// one run at a time is the rule, and what held the slot was the execution id,
/// not the status — so a run request 409'd against it, reopening the project
/// changed nothing (`reconcileStatus` bails on an `idle` status, and this one
/// was idle), and only restarting the app cleared it. An unattended night cannot
/// restart the app.
///
/// These cover the three halves of the fix: the slot belongs to the run loop and
/// nothing else, a claim that outlives its run is named rather than waited on,
/// and reconciliation clears it — agents included, since an abandoned execution
/// still holding them is what the *next* run's reservation wait times out
/// against.
@MainActor
final class BacklogAutopilotStrandedRunTests: XCTestCase {

    // MARK: - What the timeout leaves behind

    /// The mechanics the wedge rests on, driven through the real reservation
    /// queue: the execution the timeout was waiting for is still live and still
    /// holding the agents afterwards. Nothing about timing out cleans it up —
    /// which is why an autopilot that goes on naming it never gets its slot back.
    func testATimedOutReservationLeavesTheHolderLiveAndStillHolding() async throws {
        let engine = WorkflowEngine(queueTimeout: 0.05)
        await engine.register(graph: graph(agentIDs: ["worker", "reviewer"]))

        let holder = try await engine.start(graphID: "g", initialState: [:])

        do {
            _ = try await engine.start(graphID: "g", initialState: [:])
            XCTFail("the second start had to time out — the first one holds both agents")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Timed out waiting for agents"),
                          "the error the run reported, verbatim: \(error.localizedDescription)")
        }

        let holderExecution = await engine.execution(id: holder)
        XCTAssertEqual(holderExecution?.status, .running,
                       "the timeout does nothing to the execution that caused it")
    }

    // MARK: - The slot belongs to the run loop

    /// The wedged state itself: a live execution with no run loop behind it. It
    /// is not a run — nobody is advancing it and nobody will read its result —
    /// so it must not hold the project's one run slot.
    func testAnExecutionLeftLiveByAFinishedRunIsNotARunInFlight() async throws {
        let (autopilot, stranded) = try await autopilotWithLiveExecution()
        autopilot.stageRunForTesting(status: .idle, queue: [])
        autopilot.stageExecutionIDForTesting(stranded)

        let inFlight = await autopilot.inFlightRun()

        XCTAssertNil(inFlight, "a run that has ended holds nothing, whatever its execution is doing")
    }

    /// And the guard is not weakened in the other direction: while the run loop
    /// really is executing, its live execution is reported as the run it is.
    func testARunLoopWithALiveExecutionIsStillReportedAsARun() async throws {
        let (autopilot, execution) = try await autopilotWithLiveExecution()
        autopilot.stageRunForTesting(status: .running(itemIndex: 0, total: 1), queue: [item("a1")])
        autopilot.stageExecutionIDForTesting(execution)
        autopilot.stageExecutingRunForTesting(true)

        let inFlight = await autopilot.inFlightRun()

        XCTAssertEqual(inFlight?.itemID, "a1")
        XCTAssertEqual(inFlight?.executionID, execution)
    }

    // MARK: - What an operator reads

    /// `GET /v1/projects` must never call this a run — that reading is what sent
    /// the driver away to wait for a run that had already finished. It is named
    /// instead: the contradiction is detectable, so it is said out loud rather
    /// than rounded to `idle` and left for someone to find.
    func testRunStateNamesTheStrandedExecutionInsteadOfReportingARun() async throws {
        let (autopilot, stranded) = try await autopilotWithLiveExecution()
        autopilot.stageRunForTesting(status: .idle, queue: [])
        autopilot.stageExecutionIDForTesting(stranded)

        let state = await autopilot.runState()

        XCTAssertFalse(state.isRunning, "the run finished; nothing may report it as running")
        XCTAssertEqual(state.phase, .inconsistent)
        XCTAssertNil(state.inFlight)
        XCTAssertEqual(state.detail,
                       "run \(stranded) is still live with no run loop behind it — a finished "
                       + "run's execution, cleared by the next run request or by reopening the project")
    }

    /// The property the busy guard and the reported state have always had to
    /// share, extended to the state that broke it: they are one call, so they
    /// cannot disagree about whether the project is free.
    func testTheReportedStateAndTheBusyGuardAgreeAboutAStrandedExecution() async throws {
        let (autopilot, stranded) = try await autopilotWithLiveExecution()
        autopilot.stageRunForTesting(status: .idle, queue: [])
        autopilot.stageExecutionIDForTesting(stranded)

        let state = await autopilot.runState()
        let guardSees = await autopilot.inFlightRun()

        XCTAssertEqual(state.isRunning, guardSees != nil)
        XCTAssertEqual(state.inFlight, guardSees)
    }

    // MARK: - Recovery

    /// The recovery that failed on the night: `reconcileStatus` is what a run
    /// request and a project open both call, and it used to answer "nothing to
    /// do" here because the status was a perfectly ordinary `idle`. The stale
    /// claim was never the status.
    func testReconcileClearsAnExecutionStrandedByAFinishedRun() async throws {
        let (autopilot, stranded) = try await autopilotWithLiveExecution()
        autopilot.stageRunForTesting(status: .idle, queue: [])
        autopilot.stageExecutionIDForTesting(stranded)

        let cleared = await autopilot.reconcileStatus(reason: "run requested")

        XCTAssertTrue(cleared, "an idle status is not evidence the slot is free")
        XCTAssertNil(autopilot.currentExecutionID)
        let inFlight = await autopilot.inFlightRun()
        XCTAssertNil(inFlight)
        XCTAssertTrue(autopilot.log.contains {
            $0.message == "Cleared a stale busy state (run requested): run \(stranded) was still "
                        + "live with no run loop behind it"
        }, "clearing a stale claim has to be visible in the run log: \(autopilot.log.map(\.message))")
    }

    /// The payoff, and the half that forgetting the id alone would not buy: the
    /// stranded execution is called off, so the agents it was holding go back to
    /// the engine's reservation queue. Asserted by starting a real workflow on
    /// those same agents afterwards — the thing that had been timing out.
    func testReconcileReleasesTheAgentsTheStrandedRunWasHolding() async throws {
        let (autopilot, stranded) = try await autopilotWithLiveExecution()
        autopilot.stageRunForTesting(status: .idle, queue: [])
        autopilot.stageExecutionIDForTesting(stranded)

        let heldBefore = await orchestrator.workflowRoutingMode(for: "worker")
        XCTAssertEqual(reservation(heldBefore), stranded, "the stranded run is holding the worker")

        await autopilot.reconcileStatus(reason: "project opened")

        let strandedExecution = await orchestrator.workflowEngine.execution(id: stranded)
        XCTAssertEqual(strandedExecution?.status, .cancelled,
                       "an execution nobody is running is called off, not just forgotten")
        let heldAfter = await orchestrator.workflowRoutingMode(for: "worker")
        XCTAssertNil(reservation(heldAfter),
                     "the agents have to go back, or the next run times out on them")

        // And the reservation that had been timing out now succeeds. This runs
        // against the orchestrator's own 30s queue timeout, so it hanging would
        // be the bug rather than a slow test.
        let next = try await orchestrator.workflowEngine.start(graphID: "g", initialState: [:])
        XCTAssertNotEqual(next, stranded)
    }

    /// A run genuinely in flight is never reconciled out from under itself — the
    /// execution it is running under is not stranded, it is the run.
    func testReconcileLeavesTheExecutionOfARunInFlightAlone() async throws {
        let (autopilot, execution) = try await autopilotWithLiveExecution()
        autopilot.stageRunForTesting(status: .running(itemIndex: 0, total: 1), queue: [item("a1")])
        autopilot.stageExecutionIDForTesting(execution)
        autopilot.stageExecutingRunForTesting(true)

        let cleared = await autopilot.reconcileStatus(reason: "run requested")

        XCTAssertFalse(cleared)
        XCTAssertEqual(autopilot.currentExecutionID, execution)
        let stillThere = await orchestrator.workflowEngine.execution(id: execution)
        XCTAssertEqual(stillThere?.status, .running)
    }

    /// The ordinary endings are untouched. A run that reached `done`, `blocked`
    /// or a cancel left its execution terminal, and a terminal execution holds
    /// nothing — so there is no stale claim, nothing to report, and nothing for
    /// reconciliation to say.
    func testAnEndedRunWhoseExecutionIsTerminalNeedsNoReconciling() async throws {
        let (autopilot, execution) = try await autopilotWithLiveExecution()
        await orchestrator.workflowEngine.cancel(executionID: execution)
        autopilot.stageRunForTesting(status: .idle, queue: [])
        autopilot.stageExecutionIDForTesting(execution)
        let logCountBefore = autopilot.log.count

        let state = await autopilot.runState()
        let cleared = await autopilot.reconcileStatus(reason: "project opened")

        XCTAssertEqual(state.phase, .idle, "a terminal execution is not a claim on anything")
        XCTAssertFalse(state.isRunning)
        XCTAssertFalse(cleared)
        XCTAssertEqual(autopilot.log.count, logCountBefore, "nothing was wrong, so nothing is reported")
    }

    // MARK: - Helpers

    /// The orchestrator the fixture built, kept alive for the length of the test.
    ///
    /// `BacklogAutopilot` holds its orchestrator **weakly**, so a fixture that
    /// only returned it would let it deallocate the moment a test bound it to
    /// `_`: `hasLiveExecution()` would then answer "no execution" for the reason
    /// that has nothing to do with the code under test, and three of the tests
    /// below quietly passed that way while the fix was still absent.
    private var orchestrator: Orchestrator!

    /// An autopilot wired to a real orchestrator whose engine is running a real
    /// execution holding the worker and reviewer — the state a run leaves behind
    /// between `startWorkflow` returning and the item ending. The execution id is
    /// staged the way the run loop sets it.
    private func autopilotWithLiveExecution() async throws -> (BacklogAutopilot, String) {
        let orchestrator = Orchestrator(runtime: MockAgentRuntime())
        self.orchestrator = orchestrator
        await orchestrator.workflowEngine.register(graph: graph(agentIDs: ["worker", "reviewer"]))
        let execution = try await orchestrator.workflowEngine.start(graphID: "g", initialState: [:])

        let autopilot = BacklogAutopilot()
        autopilot.configure(orchestrator: orchestrator,
                            backlogViewModel: BacklogViewModel(
                                globalConfigStore: GlobalConfigStore(storageURL: try tempFile("global-config.json"))
                            ),
                            configURL: nil)
        return (autopilot, execution)
    }

    /// Two agent nodes, so an execution of it reserves both — the shape the
    /// autopilot's own worker/reviewer graph has, and what makes the reservation
    /// queue the thing a second run waits on.
    private func graph(agentIDs: [String]) -> WorkflowGraph {
        var nodes: [String: WorkflowNode] = [:]
        for (index, agentID) in agentIDs.enumerated() {
            nodes["node-\(index)"] = WorkflowNode(id: "node-\(index)", agentID: agentID, prompt: "Do work")
        }
        return WorkflowGraph(
            id: "g", name: "g", version: 1,
            nodes: nodes,
            edges: [WorkflowEdge(from: "node-0", to: "node-1", condition: .always)],
            entryNode: "node-0",
            terminalNodes: ["node-1"],
            metadata: .empty
        )
    }

    /// Which execution, if any, has an agent reserved — the engine's own answer
    /// to "is this agent still held?", read through the routing mode it drives.
    private func reservation(_ mode: RoutingMode) -> String? {
        if case .graphControlled(let executionID) = mode { return executionID }
        return nil
    }

    private func item(_ id: String) -> BacklogItem {
        BacklogItem(id: id, title: id.uppercased(), verify: "true", status: .ready, type: .local, size: .s)
    }

    /// Stores are pointed at a temp directory so no test reads or writes the
    /// developer's real global config.
    private func tempFile(_ name: String) throws -> URL {
        try makeTemporaryDirectory(prefix: "stranded-run-tests").appendingPathComponent(name)
    }

    override func tearDown() {
        orchestrator = nil
        super.tearDown()
    }
}
