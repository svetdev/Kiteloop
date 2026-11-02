import XCTest
@testable import KiteloopCore

final class WorkflowGraphValidatorTests: XCTestCase {
    private func makeGraph(
        nodes: [String: WorkflowNode],
        edges: [WorkflowEdge],
        entryNode: String,
        terminalNodes: Set<String>
    ) -> WorkflowGraph {
        WorkflowGraph(
            id: "test", name: "Test", version: 1,
            nodes: nodes, edges: edges,
            entryNode: entryNode, terminalNodes: terminalNodes,
            metadata: .empty
        )
    }

    func testValidGraphYieldsNoMessages() {
        let graph = makeGraph(
            nodes: [
                "start": WorkflowNode(id: "start", agentID: "a", prompt: "p"),
                "end": WorkflowNode(id: "end", agentID: "b", prompt: "p")
            ],
            edges: [WorkflowEdge(from: "start", to: "end", condition: .always)],
            entryNode: "start",
            terminalNodes: ["end"]
        )
        XCTAssertTrue(WorkflowGraphValidator.validate(graph).isEmpty)
    }

    func testEntryNodeNamesNoNode() {
        let graph = makeGraph(
            nodes: ["a": WorkflowNode(id: "a", agentID: "x", prompt: "p")],
            edges: [],
            entryNode: "missing",
            terminalNodes: ["a"]
        )
        let errors = WorkflowGraphValidator.validate(graph)
        XCTAssertTrue(errors.contains { $0.contains("entryNode") && $0.contains("missing") })
    }

    func testTerminalNodeNamesNoNode() {
        let graph = makeGraph(
            nodes: ["a": WorkflowNode(id: "a", agentID: "x", prompt: "p")],
            edges: [],
            entryNode: "a",
            terminalNodes: ["missing"]
        )
        let errors = WorkflowGraphValidator.validate(graph)
        XCTAssertTrue(errors.contains { $0.contains("terminalNode") && $0.contains("missing") })
    }

    func testEdgeFromNamesNoNode() {
        let graph = makeGraph(
            nodes: [
                "a": WorkflowNode(id: "a", agentID: "x", prompt: "p"),
                "b": WorkflowNode(id: "b", agentID: "y", prompt: "p")
            ],
            edges: [WorkflowEdge(from: "nowhere", to: "b", condition: .always)],
            entryNode: "a",
            terminalNodes: ["b"]
        )
        let errors = WorkflowGraphValidator.validate(graph)
        XCTAssertTrue(errors.contains { $0.contains("nowhere") })
    }

    func testEdgeToNamesNoNode() {
        let graph = makeGraph(
            nodes: [
                "a": WorkflowNode(id: "a", agentID: "x", prompt: "p"),
                "b": WorkflowNode(id: "b", agentID: "y", prompt: "p")
            ],
            edges: [WorkflowEdge(from: "a", to: "nowhere", condition: .always)],
            entryNode: "a",
            terminalNodes: ["b"]
        )
        let errors = WorkflowGraphValidator.validate(graph)
        XCTAssertTrue(errors.contains { $0.contains("nowhere") })
    }

    func testNodeWithNeitherAgentNorSubGraph() {
        let graph = makeGraph(
            nodes: ["a": WorkflowNode(id: "a", prompt: "p")],
            edges: [],
            entryNode: "a",
            terminalNodes: ["a"]
        )
        let errors = WorkflowGraphValidator.validate(graph)
        XCTAssertTrue(errors.contains { $0.contains("a") && $0.contains("agentID") && $0.contains("subGraphID") })
    }

    func testGraphBreakingMultipleRulesReturnsEveryMessage() {
        let graph = makeGraph(
            nodes: ["a": WorkflowNode(id: "a", prompt: "p")],
            edges: [WorkflowEdge(from: "a", to: "nowhere", condition: .always)],
            entryNode: "missing",
            terminalNodes: ["also-missing"]
        )
        let errors = WorkflowGraphValidator.validate(graph)
        XCTAssertTrue(errors.contains { $0.contains("entryNode") })
        XCTAssertTrue(errors.contains { $0.contains("terminalNode") })
        XCTAssertTrue(errors.contains { $0.contains("nowhere") })
        XCTAssertTrue(errors.contains { $0.contains("agentID") && $0.contains("subGraphID") })
        XCTAssertEqual(errors.count, 4)
    }
}
