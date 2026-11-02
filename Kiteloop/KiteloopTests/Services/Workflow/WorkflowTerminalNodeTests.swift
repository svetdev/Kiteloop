import XCTest
import KiteloopCore
@testable import Kiteloop

/// Regression tests for the autopilot hang: transitioning into a terminal marker
/// node with no agent (e.g. the autopilot graph's `blocked`/`done` nodes) must
/// finalize the execution immediately instead of leaving it `running` forever.
final class WorkflowTerminalNodeTests: XCTestCase {

    func testAgentlessTerminalNodeFinalizesInsteadOfHanging() async throws {
        let engine = WorkflowEngine()
        let graph = WorkflowGraph(
            id: "agentless-terminal",
            name: "Agentless Terminal",
            version: 1,
            nodes: [
                "worker": WorkflowNode(id: "worker", agentID: "w", prompt: "do work"),
                "blocked": WorkflowNode(id: "blocked", prompt: "")
            ],
            edges: [WorkflowEdge(from: "worker", to: "blocked", condition: .always)],
            entryNode: "worker",
            terminalNodes: ["blocked"],
            metadata: WorkflowGraph.GraphMetadata(description: "test")
        )
        await engine.register(graph: graph)
        let execID = try await engine.start(graphID: "agentless-terminal", initialState: [:])

        let result = try await engine.handleEvent(WorkflowEvent(
            executionID: execID, nodeID: "worker", agentID: "w", type: .nodeCompleted, output: [:]
        ))

        // The transition into the agentless terminal node must finalize now.
        if case .terminal = result {} else {
            XCTFail("Expected .terminal, got \(String(describing: result))")
        }
        let exec = await engine.execution(id: execID)
        XCTAssertEqual(exec?.status, .completed, "agentless terminal must finalize as completed, not hang in running")
        XCTAssertEqual(exec?.currentNode, "blocked")
    }

    func testAgentBearingTerminalNodeStillRuns() async throws {
        // A terminal node that carries an agent must NOT auto-finalize — it still
        // runs and completes via its own nodeCompleted (the pipeline case).
        let engine = WorkflowEngine()
        let graph = WorkflowGraph(
            id: "agent-terminal",
            name: "Agent Terminal",
            version: 1,
            nodes: [
                "worker": WorkflowNode(id: "worker", agentID: "w", prompt: "do work"),
                "finalStep": WorkflowNode(id: "finalStep", agentID: "f", prompt: "finish")
            ],
            edges: [WorkflowEdge(from: "worker", to: "finalStep", condition: .always)],
            entryNode: "worker",
            terminalNodes: ["finalStep"],
            metadata: WorkflowGraph.GraphMetadata(description: "test")
        )
        await engine.register(graph: graph)
        let execID = try await engine.start(graphID: "agent-terminal", initialState: [:])

        let result = try await engine.handleEvent(WorkflowEvent(
            executionID: execID, nodeID: "worker", agentID: "w", type: .nodeCompleted, output: [:]
        ))

        if case .transitioned(let to) = result {
            XCTAssertEqual(to, "finalStep")
        } else {
            XCTFail("Expected .transitioned to finalStep, got \(String(describing: result))")
        }
        let exec = await engine.execution(id: execID)
        XCTAssertEqual(exec?.status, .running, "agent-bearing terminal should still be running until its agent completes")
    }
}
