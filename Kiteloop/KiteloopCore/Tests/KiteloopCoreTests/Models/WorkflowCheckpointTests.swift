import XCTest
@testable import KiteloopCore

final class WorkflowCheckpointTests: XCTestCase {
    private func makeGraph(id: String = "graph-1") -> WorkflowGraph {
        WorkflowGraph(
            id: id,
            name: "Test Graph",
            version: 1,
            nodes: [
                "start": WorkflowNode(id: "start", agentID: "agent-a", prompt: "Begin"),
                "end": WorkflowNode(id: "end", agentID: "agent-b", prompt: "Finish")
            ],
            edges: [WorkflowEdge(from: "start", to: "end", condition: .always)],
            entryNode: "start",
            terminalNodes: ["end"],
            metadata: .empty
        )
    }

    private func makeExecution(id: String = "exec-1", graphID: String = "graph-1") -> WorkflowExecution {
        WorkflowExecution(
            id: id,
            graphID: graphID,
            graphVersion: 1,
            traceID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1",
            currentNode: "write",
            status: .running,
            state: ["draft": .string("text")]
        )
    }

    func testCheckpointRoundTrip() throws {
        let graph = makeGraph()
        let execution = makeExecution()
        let checkpoint = WorkflowCheckpoint(
            id: "cp-1",
            executionID: "exec-1",
            graphSnapshot: graph,
            executionSnapshot: execution,
            checkpointedAt: Date(),
            reason: .nodeTransition
        )
        let data = try JSONEncoder().encode(checkpoint)
        let decoded = try JSONDecoder().decode(WorkflowCheckpoint.self, from: data)
        XCTAssertEqual(decoded.id, "cp-1")
        XCTAssertEqual(decoded.executionID, "exec-1")
        XCTAssertEqual(decoded.reason, .nodeTransition)
        XCTAssertEqual(decoded.executionSnapshot.currentNode, "write")
        XCTAssertEqual(decoded.graphSnapshot.id, "graph-1")
    }

    func testCheckpointReasons() {
        XCTAssertEqual(CheckpointReason.started.rawValue, "started")
        XCTAssertEqual(CheckpointReason.nodeTransition.rawValue, "nodeTransition")
        XCTAssertEqual(CheckpointReason.paused.rawValue, "paused")
        XCTAssertEqual(CheckpointReason.completed.rawValue, "completed")
        XCTAssertEqual(CheckpointReason.failed.rawValue, "failed")
    }
}
