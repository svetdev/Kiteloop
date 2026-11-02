import XCTest
import KiteloopCore
@testable import Kiteloop

/// The cost sample the run loop takes while an item's workflow runs: what it
/// reads the item's spend from, and what each cap does with it. The loop only
/// samples on every eighth 2s poll, so these take the sample directly rather
/// than wait 16s of a live run for it.
@MainActor
final class BacklogAutopilotCostSampleTests: XCTestCase {

    private var tempDir: URL!
    private var orchestrator: Orchestrator!
    private var autopilot: BacklogAutopilot!
    private var executionID: String!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "cost-sample")
        orchestrator = Orchestrator(runtime: MockAgentRuntime())
        orchestrator.configureTracing(tracesURL: tempDir.appending(path: "traces", directoryHint: .isDirectory))
        let graph = WorkflowGraph(
            id: "cost-sample-graph", name: "Cost sample", version: 1,
            nodes: ["worker": WorkflowNode(id: "worker", agentID: "worker", prompt: "work")],
            edges: [], entryNode: "worker", terminalNodes: ["worker"], metadata: .empty)
        await orchestrator.workflowEngine.register(graph: graph)
        executionID = try await orchestrator.workflowEngine.start(graphID: graph.id, initialState: [:])

        autopilot = BacklogAutopilot()
        autopilot.configure(
            orchestrator: orchestrator,
            backlogViewModel: BacklogViewModel(globalConfigStore: GlobalConfigStore(
                storageURL: tempDir.appending(path: "global-config.json"))),
            projectPath: tempDir.path(percentEncoded: false))
        autopilot.workerAgentID = "worker"
    }

    /// The worker's turns so far in this run, as `ChatViewModel` stamps them.
    private func spend(_ costUSD: Double) async throws {
        let start = Date()
        try await XCTUnwrap(orchestrator.traceStore).append(TraceSpan(
            id: UUID().uuidString, agentID: "worker", sessionID: "session-worker",
            startTime: start, endTime: start.addingTimeInterval(60), type: .turn,
            metadata: ["costUSD": String(format: "%.6f", costUSD),
                       TraceSpan.MetadataKey.executionID: executionID,
                       TraceSpan.MetadataKey.role: "worker"]))
    }

    private func sample(poll: Int = 8) async -> BacklogAutopilot.CostSampleOutcome? {
        await autopilot.sampleCostForTesting(executionID: executionID, itemID: "item-1", pollCount: poll)
    }

    func testOnlyEveryEighthPollReadsTheSpend() async throws {
        try await spend(3)
        autopilot.stageInFlightCostForTesting(spentUSD: 0, capUSD: 10)

        let skipped = await sample(poll: 7)
        XCTAssertEqual(skipped, .carryOn)
        XCTAssertEqual(autopilot.costGovernor.currentItemSpendUSD, 0, "a skipped poll reads no traces")

        let taken = await sample(poll: 8)
        XCTAssertEqual(taken, .carryOn)
        XCTAssertEqual(autopilot.costGovernor.currentItemSpendUSD, 3, accuracy: 0.001)
    }

    func testSpendNearTheItemCapIsWarnedOfAndTheRunCarriesOn() async throws {
        try await spend(8.5)
        autopilot.stageInFlightCostForTesting(spentUSD: 0, capUSD: 10)

        let outcome = await sample()
        XCTAssertEqual(outcome, .carryOn)
        XCTAssertTrue(autopilot.log.contains { $0.message.hasPrefix("Approaching cost cap") },
                      autopilot.log.map(\.message).joined(separator: "\n"))
    }

    /// The item cap is advisory: the overrun is counted once and the run keeps
    /// developing — this poll ends, the execution does not.
    func testSpendPastTheItemCapIsCountedAndTheRunKeepsGoing() async throws {
        try await spend(12)
        autopilot.stageInFlightCostForTesting(spentUSD: 0, capUSD: 10)

        let outcome = await sample()
        XCTAssertEqual(outcome, .nextPoll)
        XCTAssertEqual(autopilot.costOverrunItemIDs, ["item-1"])
        let status = await orchestrator.workflowEngine.execution(id: executionID)?.status
        XCTAssertNotEqual(status, .cancelled)
    }

    /// The session cap is hard: past it the run ends and its execution is
    /// cancelled, with the reason left for the board.
    func testSpendPastTheSessionCapEndsTheRun() async throws {
        try await spend(2)
        autopilot.stageSpentSessionForTesting(capUSD: 5, spentUSD: 4)

        let outcome = await sample()
        XCTAssertEqual(outcome, .end(.timedOut))
        XCTAssertTrue(autopilot.costGovernor.sessionCapBreached)
        XCTAssertEqual(autopilot.lastStallReasonForTesting?.hasPrefix("session cost cap $5.00 exceeded ($6.00)"), true,
                       autopilot.lastStallReasonForTesting ?? "no reason")
        let status = await orchestrator.workflowEngine.execution(id: executionID)?.status
        XCTAssertEqual(status, .cancelled)
    }
}
