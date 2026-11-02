import XCTest
import KiteloopCore
@testable import Kiteloop

final class Phase2BIntegrationTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "phase2b-integration")
    }

    func testFullLifecycleWithCheckpoints() async throws {
        // Setup: write graph file
        let graphJSON = """
        {
            "id": "integration-wf", "name": "Integration", "version": 2,
            "entryNode": "research", "terminalNodes": ["publish"],
            "metadata": {"description": "Integration test workflow"},
            "nodes": {
                "research": {"id": "research", "agentID": "researcher", "prompt": "Research {{state.topic}}"},
                "publish": {"id": "publish", "agentID": "publisher", "prompt": "Publish findings"}
            },
            "edges": [{"from": "research", "to": "publish", "condition": {"type": "always"}}]
        }
        """
        let workflowDir = tempDir.appending(path: "workflows")
        try FileManager.default.createDirectory(at: workflowDir, withIntermediateDirectories: true)
        try graphJSON.data(using: .utf8)!.write(to: workflowDir.appending(path: "int.workflow.json"))

        // Load from disk
        let engine = WorkflowEngine()
        await engine.loadGraphs(from: workflowDir)

        let loaded = await engine.registeredGraph(id: "integration-wf")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.version, 2)

        // Start execution
        let execID = try await engine.start(graphID: "integration-wf", initialState: ["topic": .string("testing")])
        let execution = await engine.execution(id: execID)
        XCTAssertEqual(execution?.graphVersion, 2)
        XCTAssertFalse(execution?.traceID.isEmpty ?? true)

        // Checkpoint store
        let checkpointDir = tempDir.appending(path: "checkpoints")
        let store = WorkflowCheckpointStore(baseURL: checkpointDir)

        // Write checkpoint on start
        let startCP = WorkflowCheckpoint(
            id: UUID().uuidString,
            executionID: execID,
            graphSnapshot: loaded!,
            executionSnapshot: execution!,
            checkpointedAt: Date(),
            reason: .started
        )
        try await store.write(startCP)

        // Advance: research → publish
        let event = WorkflowEvent(
            executionID: execID, nodeID: "research",
            agentID: "researcher", type: .nodeCompleted,
            output: ["findings": .string("important data")]
        )
        let result = try await engine.handleEvent(event)
        if case .transitioned(let to) = result {
            XCTAssertEqual(to, "publish")
        } else { XCTFail("Expected transition") }

        // Write transition checkpoint
        let transExec = await engine.execution(id: execID)!
        let transCP = WorkflowCheckpoint(
            id: UUID().uuidString,
            executionID: execID,
            graphSnapshot: loaded!,
            executionSnapshot: transExec,
            checkpointedAt: Date(),
            reason: .nodeTransition
        )
        try await store.write(transCP)

        // Verify state carry-forward in checkpoint
        let latestCP = try await store.latestCheckpoint(executionID: execID)
        XCTAssertEqual(latestCP?.executionSnapshot.state["topic"], .string("testing"))
        XCTAssertEqual(latestCP?.executionSnapshot.state["findings"], .string("important data"))
        XCTAssertEqual(latestCP?.executionSnapshot.currentNode, "publish")

        // Complete terminal node
        let event2 = WorkflowEvent(
            executionID: execID, nodeID: "publish",
            agentID: "publisher", type: .nodeCompleted
        )
        let result2 = try await engine.handleEvent(event2)
        if case .terminal = result2 { } else { XCTFail("Expected terminal") }
    }

    func testCircuitBreakerTimesOut() async throws {
        let engine = WorkflowEngine()
        let graph = WorkflowGraph(
            id: "timeout-int", name: "TO", version: 1,
            nodes: ["n1": WorkflowNode(id: "n1", agentID: "a1", prompt: "p", maxTurns: 3)],
            edges: [], entryNode: "n1", terminalNodes: ["n1"], metadata: .empty
        )
        await engine.register(graph: graph)
        let execID = try await engine.start(graphID: "timeout-int", initialState: [:])

        // Exceed maxTurns
        for _ in 0..<4 {
            await engine.recordTurn(executionID: execID)
        }

        let breaker = await engine.checkCircuitBreaker(executionID: execID)
        XCTAssertEqual(breaker, .maxTurnsExceeded)
    }

    func testHotReloadDoesNotAffectActiveExecution() async throws {
        let workflowDir = tempDir.appending(path: "workflows")
        try FileManager.default.createDirectory(at: workflowDir, withIntermediateDirectories: true)

        let v1JSON = """
        {
            "id": "hot-reload-wf", "name": "HR v1", "version": 1,
            "entryNode": "n1", "terminalNodes": ["n1"],
            "metadata": {"description": ""},
            "nodes": {"n1": {"id": "n1", "agentID": "a1", "prompt": "v1 prompt"}},
            "edges": []
        }
        """
        try v1JSON.data(using: .utf8)!.write(to: workflowDir.appending(path: "hr.workflow.json"))

        let engine = WorkflowEngine()
        await engine.loadGraphs(from: workflowDir)
        let execID = try await engine.start(graphID: "hot-reload-wf", initialState: [:])

        // Hot reload with v2
        let v2JSON = """
        {
            "id": "hot-reload-wf", "name": "HR v2", "version": 2,
            "entryNode": "n1", "terminalNodes": ["n1"],
            "metadata": {"description": ""},
            "nodes": {"n1": {"id": "n1", "agentID": "a1", "prompt": "v2 prompt"}},
            "edges": []
        }
        """
        try v2JSON.data(using: .utf8)!.write(to: workflowDir.appending(path: "hr.workflow.json"))
        await engine.reloadGraphs(from: workflowDir)

        // Active execution still uses v1 snapshot
        let execution = await engine.execution(id: execID)
        XCTAssertEqual(execution?.graphVersion, 1)

        // New registration has v2
        let registered = await engine.registeredGraph(id: "hot-reload-wf")
        XCTAssertEqual(registered?.version, 2)
    }
}
