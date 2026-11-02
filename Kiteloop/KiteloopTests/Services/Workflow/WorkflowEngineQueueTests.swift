import XCTest
import KiteloopCore
@testable import Kiteloop

final class WorkflowEngineQueueTests: XCTestCase {

    private func simpleGraph(id: String = "test-graph", agentIDs: [String] = ["agent-a", "agent-b"]) -> WorkflowGraph {
        var nodes: [String: WorkflowNode] = [:]
        for (i, agentID) in agentIDs.enumerated() {
            nodes["node-\(i)"] = WorkflowNode(id: "node-\(i)", agentID: agentID, prompt: "Do work")
        }
        let edges: [WorkflowEdge] = agentIDs.count > 1
            ? [WorkflowEdge(from: "node-0", to: "node-1", condition: .always)]
            : []
        return WorkflowGraph(
            id: id, name: id, version: 1,
            nodes: nodes,
            edges: edges,
            entryNode: "node-0",
            terminalNodes: [agentIDs.count > 1 ? "node-1" : "node-0"],
            metadata: .empty
        )
    }

    func testOverlappingStartQueuesInsteadOfRejecting() async throws {
        let engine = WorkflowEngine(queueTimeout: 5.0)
        let graph = simpleGraph()
        await engine.register(graph: graph)

        let exec1 = try await engine.start(graphID: "test-graph", initialState: [:])

        // Second start with same agents — should queue, not throw
        let task = Task<String, Error> {
            try await engine.start(graphID: "test-graph", initialState: [:])
        }

        // Give it time to enqueue
        try await Task.sleep(for: .milliseconds(50))

        // Complete exec1 to release agents
        let event1 = WorkflowEvent(executionID: exec1, nodeID: "node-0", agentID: "agent-a", type: .nodeCompleted)
        _ = try await engine.handleEvent(event1)
        let event2 = WorkflowEvent(executionID: exec1, nodeID: "node-1", agentID: "agent-b", type: .nodeCompleted)
        _ = try await engine.handleEvent(event2)

        // Second execution should now proceed
        let exec2 = try await task.value
        XCTAssertNotEqual(exec1, exec2)

        let execution = await engine.execution(id: exec2)
        XCTAssertEqual(execution?.status, .running)
    }

    func testQueueTimeoutThrowsError() async throws {
        let engine = WorkflowEngine(queueTimeout: 0.1)
        let graph = simpleGraph()
        await engine.register(graph: graph)

        _ = try await engine.start(graphID: "test-graph", initialState: [:])

        // Second start should time out
        do {
            _ = try await engine.start(graphID: "test-graph", initialState: [:])
            XCTFail("Expected timeout")
        } catch {
            XCTAssertTrue("\(error)".contains("Timed out") || "\(error)".contains("timeout"))
        }
    }

    func testDisjointGraphsStillStartImmediately() async throws {
        let engine = WorkflowEngine(queueTimeout: 5.0)
        let graph1 = simpleGraph(id: "g1", agentIDs: ["agent-a", "agent-b"])
        let graph2 = simpleGraph(id: "g2", agentIDs: ["agent-c", "agent-d"])
        await engine.register(graph: graph1)
        await engine.register(graph: graph2)

        let exec1 = try await engine.start(graphID: "g1", initialState: [:])
        let exec2 = try await engine.start(graphID: "g2", initialState: [:])

        XCTAssertNotEqual(exec1, exec2)
    }

    func testCancelledExecutionReleasesQueue() async throws {
        let engine = WorkflowEngine(queueTimeout: 5.0)
        let graph = simpleGraph()
        await engine.register(graph: graph)

        let exec1 = try await engine.start(graphID: "test-graph", initialState: [:])

        let task = Task<String, Error> {
            try await engine.start(graphID: "test-graph", initialState: [:])
        }

        try await Task.sleep(for: .milliseconds(50))

        // Cancel exec1 instead of completing
        await engine.cancel(executionID: exec1)

        let exec2 = try await task.value
        XCTAssertNotEqual(exec1, exec2)
    }
}
