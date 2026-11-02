import XCTest
import KiteloopCore
@testable import Kiteloop

final class SubWorkflowIntegrationTests: XCTestCase {

    func testTransitionToSubWorkflowNodeCreatesNestedExecution() async throws {
        let engine = WorkflowEngine()

        let subGraph = WorkflowGraph(
            id: "sub", name: "Sub", version: 1,
            nodes: [
                "s1": WorkflowNode(id: "s1", agentID: "sub-agent", prompt: "Do"),
            ],
            edges: [],
            entryNode: "s1", terminalNodes: ["s1"], metadata: .empty
        )

        let parentGraph = WorkflowGraph(
            id: "parent", name: "Parent", version: 1,
            nodes: [
                "start": WorkflowNode(id: "start", agentID: "agent-a", prompt: "Begin"),
                "sub-node": WorkflowNode(id: "sub-node", subGraphID: "sub", prompt: "Delegate"),
                "end": WorkflowNode(id: "end", agentID: "agent-b", prompt: "Finish")
            ],
            edges: [
                WorkflowEdge(from: "start", to: "sub-node", condition: .always),
                WorkflowEdge(from: "sub-node", to: "end", condition: .always)
            ],
            entryNode: "start", terminalNodes: ["end"], metadata: .empty
        )

        await engine.register(graph: subGraph)
        await engine.register(graph: parentGraph)

        let execID = try await engine.start(graphID: "parent", initialState: ["data": .string("test")])

        // Complete start node -> transitions to sub-node
        let event = WorkflowEvent(executionID: execID, nodeID: "start", agentID: "agent-a", type: .nodeCompleted)
        let result = try await engine.handleEvent(event)

        if case .transitioned(let toNode) = result {
            XCTAssertEqual(toNode, "sub-node")
        } else { XCTFail("Expected transition to sub-node") }

        // Verify a child execution was created
        let childExecs = await engine.childExecutions(parentID: execID)
        XCTAssertEqual(childExecs.count, 1)
        XCTAssertEqual(childExecs.first?.graphID, "sub")
        XCTAssertEqual(childExecs.first?.parentExecutionID, execID)
    }

    func testSubWorkflowCompletionAdvancesParent() async throws {
        let engine = WorkflowEngine()

        let subGraph = WorkflowGraph(
            id: "sub", name: "Sub", version: 1,
            nodes: [
                "s1": WorkflowNode(id: "s1", agentID: "sub-agent", prompt: "Do"),
            ],
            edges: [],
            entryNode: "s1", terminalNodes: ["s1"], metadata: .empty
        )

        let parentGraph = WorkflowGraph(
            id: "parent", name: "Parent", version: 1,
            nodes: [
                "start": WorkflowNode(id: "start", agentID: "agent-a", prompt: "Begin"),
                "sub-node": WorkflowNode(id: "sub-node", subGraphID: "sub", prompt: "Delegate"),
                "end": WorkflowNode(id: "end", agentID: "agent-b", prompt: "Finish")
            ],
            edges: [
                WorkflowEdge(from: "start", to: "sub-node", condition: .always),
                WorkflowEdge(from: "sub-node", to: "end", condition: .always)
            ],
            entryNode: "start", terminalNodes: ["end"], metadata: .empty
        )

        await engine.register(graph: subGraph)
        await engine.register(graph: parentGraph)

        let execID = try await engine.start(graphID: "parent", initialState: ["data": .string("test")])

        // Advance to sub-node
        let event1 = WorkflowEvent(executionID: execID, nodeID: "start", agentID: "agent-a", type: .nodeCompleted)
        _ = try await engine.handleEvent(event1)

        // Get child execution
        let childExecs = await engine.childExecutions(parentID: execID)
        let childExecID = childExecs.first!.id

        // Complete the sub-workflow's terminal node
        let subEvent = WorkflowEvent(
            executionID: childExecID, nodeID: "s1", agentID: "sub-agent",
            type: .nodeCompleted, output: ["sub-output": .string("result")]
        )
        _ = try await engine.handleEvent(subEvent)

        // Parent should have advanced past sub-node to "end"
        let parentExec = await engine.execution(id: execID)
        XCTAssertEqual(parentExec?.currentNode, "end")
    }

    func testSubWorkflowMergesStateIntoParent() async throws {
        let engine = WorkflowEngine()

        let subGraph = WorkflowGraph(
            id: "sub", name: "Sub", version: 1,
            nodes: [
                "s1": WorkflowNode(id: "s1", agentID: "sub-agent", prompt: "Do"),
            ],
            edges: [],
            entryNode: "s1", terminalNodes: ["s1"], metadata: .empty
        )

        let parentGraph = WorkflowGraph(
            id: "parent", name: "Parent", version: 1,
            nodes: [
                "start": WorkflowNode(id: "start", agentID: "agent-a", prompt: "Begin"),
                "sub-node": WorkflowNode(id: "sub-node", subGraphID: "sub", prompt: "Delegate"),
                "end": WorkflowNode(id: "end", agentID: "agent-b", prompt: "Finish")
            ],
            edges: [
                WorkflowEdge(from: "start", to: "sub-node", condition: .always),
                WorkflowEdge(from: "sub-node", to: "end", condition: .always)
            ],
            entryNode: "start", terminalNodes: ["end"], metadata: .empty
        )

        await engine.register(graph: subGraph)
        await engine.register(graph: parentGraph)

        let execID = try await engine.start(graphID: "parent", initialState: ["original": .string("kept")])

        // Advance to sub-node
        let event1 = WorkflowEvent(executionID: execID, nodeID: "start", agentID: "agent-a", type: .nodeCompleted)
        _ = try await engine.handleEvent(event1)

        // Complete child with new state
        let childExecs = await engine.childExecutions(parentID: execID)
        let childExecID = childExecs.first!.id

        let subEvent = WorkflowEvent(
            executionID: childExecID, nodeID: "s1", agentID: "sub-agent",
            type: .nodeCompleted, output: ["enriched": .string("from-child")]
        )
        _ = try await engine.handleEvent(subEvent)

        // Parent state should contain both original and child-merged state
        let parentExec = await engine.execution(id: execID)
        XCTAssertEqual(parentExec?.state["original"]?.stringValue, "kept")
        XCTAssertEqual(parentExec?.state["enriched"]?.stringValue, "from-child")
    }
}
