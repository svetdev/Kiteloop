// Kiteloop/KiteloopTests/Services/Phase2CIntegrationTests.swift
import XCTest
import KiteloopCore
@testable import Kiteloop

final class Phase2CIntegrationTests: XCTestCase {

    func testFullSubWorkflowCycle() async throws {
        let engine = WorkflowEngine()

        // Sub-graph: two steps
        let subGraph = WorkflowGraph(
            id: "review-sub", name: "Review", version: 1,
            nodes: [
                "analyze": WorkflowNode(id: "analyze", agentID: "analyzer", prompt: "Analyze {{state.code}}"),
                "report": WorkflowNode(id: "report", agentID: "reporter", prompt: "Report findings")
            ],
            edges: [WorkflowEdge(from: "analyze", to: "report", condition: .always)],
            entryNode: "analyze", terminalNodes: ["report"], metadata: .empty
        )

        // Parent graph: code → sub-workflow review → merge
        let parentGraph = WorkflowGraph(
            id: "dev-flow", name: "Dev", version: 1,
            nodes: [
                "code": WorkflowNode(id: "code", agentID: "coder", prompt: "Write code"),
                "review": WorkflowNode(id: "review", subGraphID: "review-sub", prompt: "Review the code"),
                "merge": WorkflowNode(id: "merge", agentID: "merger", prompt: "Merge PR")
            ],
            edges: [
                WorkflowEdge(from: "code", to: "review", condition: .always),
                WorkflowEdge(from: "review", to: "merge", condition: .always)
            ],
            entryNode: "code", terminalNodes: ["merge"], metadata: .empty
        )

        await engine.register(graph: subGraph)
        await engine.register(graph: parentGraph)

        let execID = try await engine.start(graphID: "dev-flow", initialState: ["code": .string("print('hi')")])

        // Complete code → triggers sub-workflow
        let e1 = WorkflowEvent(executionID: execID, nodeID: "code", agentID: "coder", type: .nodeCompleted)
        _ = try await engine.handleEvent(e1)

        let children = await engine.childExecutions(parentID: execID)
        XCTAssertEqual(children.count, 1)
        let childID = children.first!.id

        // Complete sub-workflow: analyze → report (terminal)
        let se1 = WorkflowEvent(executionID: childID, nodeID: "analyze", agentID: "analyzer", type: .nodeCompleted,
                                 output: ["findings": .string("looks good")])
        _ = try await engine.handleEvent(se1)

        let se2 = WorkflowEvent(executionID: childID, nodeID: "report", agentID: "reporter", type: .nodeCompleted,
                                 output: ["report": .string("approved")])
        _ = try await engine.handleEvent(se2)

        // Parent should have advanced to merge
        let parentExec = await engine.execution(id: execID)
        XCTAssertEqual(parentExec?.currentNode, "merge")
        XCTAssertEqual(parentExec?.state["findings"], .string("looks good"))
        XCTAssertEqual(parentExec?.state["report"], .string("approved"))
    }

    func testApprovalBridgeEndToEnd() async throws {
        let engine = WorkflowEngine()
        let bridge = WorkflowApprovalBridge(engine: engine)

        let graph = WorkflowGraph(
            id: "deploy", name: "Deploy", version: 1,
            nodes: [
                "build": WorkflowNode(id: "build", agentID: "builder", prompt: "Build"),
                "stage": WorkflowNode(id: "stage", agentID: "deployer", prompt: "Stage"),
                "prod": WorkflowNode(id: "prod", agentID: "deployer", prompt: "Deploy to prod")
            ],
            edges: [
                WorkflowEdge(from: "build", to: "stage", condition: .always),
                WorkflowEdge(from: "stage", to: "prod", condition: .humanApproval(question: "Deploy to production?", deniedEdge: nil))
            ],
            entryNode: "build", terminalNodes: ["prod"], metadata: .empty
        )

        await engine.register(graph: graph)
        let execID = try await engine.start(graphID: "deploy", initialState: [:])

        // build → stage
        let e1 = WorkflowEvent(executionID: execID, nodeID: "build", agentID: "builder", type: .nodeCompleted)
        _ = try await engine.handleEvent(e1)

        // stage → awaiting approval
        let e2 = WorkflowEvent(executionID: execID, nodeID: "stage", agentID: "deployer", type: .nodeCompleted)
        let result = try await engine.handleEvent(e2)

        guard case .awaitingApproval(let question, let edgeID) = result else {
            XCTFail("Expected approval"); return
        }

        await bridge.registerPendingApproval(executionID: execID, question: question, edgeIndex: edgeID)
        let pending = await bridge.pendingApprovals
        XCTAssertEqual(pending.count, 1)

        // Approve via bridge
        let transResult = try await bridge.resolve(executionID: execID, approved: true, reason: nil)
        if case .transitioned(let toNode) = transResult {
            XCTAssertEqual(toNode, "prod")
        } else { XCTFail("Expected transition to prod") }

        let finalPending = await bridge.pendingApprovals
        XCTAssertTrue(finalPending.isEmpty)
    }


    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false

        func set(_ newValue: Bool) {
            lock.lock(); defer { lock.unlock() }
            flag = newValue
        }

        var value: Bool {
            lock.lock(); defer { lock.unlock() }
            return flag
        }
    }
}
