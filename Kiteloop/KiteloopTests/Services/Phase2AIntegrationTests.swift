import XCTest
import KiteloopCore
@testable import Kiteloop

final class Phase2AIntegrationTests: XCTestCase {
    func testFullWorkflowExecution() async throws {
        let engine = WorkflowEngine()

        // Register a 3-node graph
        let graph = WorkflowGraph(
            id: "content-pipeline",
            name: "Content Pipeline",
            version: 1,
            nodes: [
                "research": WorkflowNode(id: "research", agentID: "researcher", prompt: "Research {{state.topic}}"),
                "write": WorkflowNode(id: "write", agentID: "writer", prompt: "Write about {{state.topic}} using {{state.*}}"),
                "review": WorkflowNode(id: "review", agentID: "reviewer", prompt: "Review the draft")
            ],
            edges: [
                WorkflowEdge(from: "research", to: "write", condition: .always),
                WorkflowEdge(from: "write", to: "review", condition: .always)
            ],
            entryNode: "research",
            terminalNodes: ["review"],
            metadata: WorkflowGraph.GraphMetadata(description: "Content creation pipeline")
        )
        await engine.register(graph: graph)

        // Start execution
        let execID = try await engine.start(
            graphID: "content-pipeline",
            initialState: ["topic": .string("workflow engines")]
        )

        // Verify whole-graph reservation — ALL agents reserved, not just current node
        let researcherMode = await engine.routingMode(for: "researcher")
        let writerMode = await engine.routingMode(for: "writer")
        let reviewerMode = await engine.routingMode(for: "reviewer")
        if case .graphControlled = researcherMode { } else { XCTFail("Expected graphControlled for researcher") }
        if case .graphControlled = writerMode { } else { XCTFail("Expected graphControlled for writer") }
        if case .graphControlled = reviewerMode { } else { XCTFail("Expected graphControlled for reviewer") }

        // Advance: research → write
        let event1 = WorkflowEvent(
            executionID: execID,
            nodeID: "research",
            agentID: "researcher",
            type: .nodeCompleted,
            output: ["findings": .string("Key insight about workflow engines")]
        )
        let result1 = try await engine.handleEvent(event1)
        if case .transitioned(let to) = result1 {
            XCTAssertEqual(to, "write")
        } else { XCTFail("Expected transition to write") }

        // After handoff, researcher is STILL graphControlled (whole-graph reservation)
        let researcherModeAfter = await engine.routingMode(for: "researcher")
        if case .graphControlled = researcherModeAfter { } else {
            XCTFail("Expected graphControlled for researcher even after handoff (whole-graph reservation)")
        }

        // Verify state carry-forward
        let exec1 = await engine.execution(id: execID)
        XCTAssertEqual(exec1?.state["topic"], .string("workflow engines"))
        XCTAssertEqual(exec1?.state["findings"], .string("Key insight about workflow engines"))

        // Test state templating
        let templateResult = WorkflowStateTemplater.render(
            template: "Write about {{state.topic}} using {{state.*}}",
            state: exec1!.state
        )
        XCTAssertTrue(templateResult.rendered.contains("Write about workflow engines"))
        XCTAssertTrue(templateResult.rendered.contains("findings"))

        // Advance: write → review
        let event2 = WorkflowEvent(
            executionID: execID,
            nodeID: "write",
            agentID: "writer",
            type: .nodeCompleted,
            output: ["draft": .string("Article draft content")]
        )
        let result2 = try await engine.handleEvent(event2)
        if case .transitioned(let to) = result2 {
            XCTAssertEqual(to, "review")
        } else { XCTFail("Expected transition to review") }

        // Complete terminal node: review
        let event3 = WorkflowEvent(
            executionID: execID,
            nodeID: "review",
            agentID: "reviewer",
            type: .nodeCompleted,
            output: ["verdict": .string("approved")]
        )
        let result3 = try await engine.handleEvent(event3)
        if case .terminal = result3 { } else { XCTFail("Expected terminal") }

        // Verify execution completed
        let finalExec = await engine.execution(id: execID)
        XCTAssertEqual(finalExec?.status, .completed)
        XCTAssertEqual(finalExec?.steps.count, 3)

        // Verify all agents released after completion
        let researcherFinal = await engine.routingMode(for: "researcher")
        let writerFinal = await engine.routingMode(for: "writer")
        let reviewerFinal = await engine.routingMode(for: "reviewer")
        if case .freeform = researcherFinal { } else { XCTFail("Expected freeform after completion") }
        if case .freeform = writerFinal { } else { XCTFail("Expected freeform after completion") }
        if case .freeform = reviewerFinal { } else { XCTFail("Expected freeform after completion") }
    }

    func testConcurrentDisjointWorkflows() async throws {
        let engine = WorkflowEngine()

        let graph1 = WorkflowGraph(
            id: "pipeline-a", name: "A", version: 1,
            nodes: [
                "n1": WorkflowNode(id: "n1", agentID: "agent-a", prompt: "p"),
                "n2": WorkflowNode(id: "n2", agentID: "agent-b", prompt: "p")
            ],
            edges: [WorkflowEdge(from: "n1", to: "n2", condition: .always)],
            entryNode: "n1", terminalNodes: ["n2"], metadata: .empty
        )
        let graph2 = WorkflowGraph(
            id: "pipeline-b", name: "B", version: 1,
            nodes: [
                "m1": WorkflowNode(id: "m1", agentID: "agent-c", prompt: "p"),
                "m2": WorkflowNode(id: "m2", agentID: "agent-d", prompt: "p")
            ],
            edges: [WorkflowEdge(from: "m1", to: "m2", condition: .always)],
            entryNode: "m1", terminalNodes: ["m2"], metadata: .empty
        )
        await engine.register(graph: graph1)
        await engine.register(graph: graph2)

        // Both can run concurrently (disjoint agent sets)
        let exec1 = try await engine.start(graphID: "pipeline-a", initialState: [:])
        let exec2 = try await engine.start(graphID: "pipeline-b", initialState: [:])
        XCTAssertNotEqual(exec1, exec2)

        // Each agent is controlled by its own execution
        if case .graphControlled(let id) = await engine.routingMode(for: "agent-a") {
            XCTAssertEqual(id, exec1)
        } else { XCTFail("Expected graphControlled") }

        if case .graphControlled(let id) = await engine.routingMode(for: "agent-c") {
            XCTAssertEqual(id, exec2)
        } else { XCTFail("Expected graphControlled") }
    }

    func testHumanApprovalWorkflow() async throws {
        let engine = WorkflowEngine()

        let graph = WorkflowGraph(
            id: "deploy-flow", name: "Deploy", version: 1,
            nodes: [
                "build": WorkflowNode(id: "build", agentID: "builder", prompt: "Build"),
                "deploy": WorkflowNode(id: "deploy", agentID: "deployer", prompt: "Deploy"),
                "rollback": WorkflowNode(id: "rollback", agentID: "builder", prompt: "Rollback")
            ],
            edges: [
                WorkflowEdge(from: "build", to: "deploy", condition: .humanApproval(question: "Deploy to prod?", deniedEdge: "rollback")),
                WorkflowEdge(from: "rollback", to: "build", condition: .always)
            ],
            entryNode: "build", terminalNodes: ["deploy"], metadata: .empty
        )
        await engine.register(graph: graph)
        let execID = try await engine.start(graphID: "deploy-flow", initialState: [:])

        // Build completes → human approval needed
        let buildEvent = WorkflowEvent(executionID: execID, nodeID: "build", agentID: "builder", type: .nodeCompleted)
        let result = try await engine.handleEvent(buildEvent)
        if case .awaitingApproval(let q, _) = result {
            XCTAssertEqual(q, "Deploy to prod?")
        } else { XCTFail("Expected awaitingApproval") }

        // Human denies → goes to rollback
        let denyResult = try await engine.resolveHumanApproval(executionID: execID, edgeIndex: 0, approved: false, reason: "Not ready")
        if case .transitioned(let to) = denyResult {
            XCTAssertEqual(to, "rollback")
        } else { XCTFail("Expected transition to rollback") }

        let exec = await engine.execution(id: execID)
        XCTAssertEqual(exec?.state["_denialReason"], .string("Not ready"))
    }
}
