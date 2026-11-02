import XCTest
import KiteloopCore
@testable import Kiteloop

final class WorkflowEngineTests: XCTestCase {
    private func twoNodeGraph(
        entryAgentID: String = "researcher",
        secondAgentID: String = "writer",
        allowFreeform: Bool = false
    ) -> WorkflowGraph {
        WorkflowGraph(
            id: "test-graph",
            name: "Test",
            version: 1,
            nodes: [
                "research": WorkflowNode(id: "research", agentID: entryAgentID, prompt: "Research {{state.topic}}"),
                "write": WorkflowNode(id: "write", agentID: secondAgentID, prompt: "Write about {{state.topic}}", allowFreeform: allowFreeform)
            ],
            edges: [WorkflowEdge(from: "research", to: "write", condition: .always)],
            entryNode: "research",
            terminalNodes: ["write"],
            metadata: .empty
        )
    }

    // MARK: - Registration

    func testRegisterGraph() async {
        let engine = WorkflowEngine()
        let graph = twoNodeGraph()
        await engine.register(graph: graph)
        let registered = await engine.registeredGraph(id: "test-graph")
        XCTAssertNotNil(registered)
    }

    // MARK: - Start + Whole-Graph Reservation

    func testStartExecution() async throws {
        let engine = WorkflowEngine()
        let graph = twoNodeGraph()
        await engine.register(graph: graph)

        let execID = try await engine.start(graphID: "test-graph", initialState: ["topic": .string("testing")])

        let execution = await engine.execution(id: execID)
        XCTAssertNotNil(execution)
        XCTAssertEqual(execution?.currentNode, "research")
        XCTAssertEqual(execution?.status, .running)
    }

    func testWholeGraphReservation() async throws {
        let engine = WorkflowEngine()
        let graph = twoNodeGraph()
        await engine.register(graph: graph)
        _ = try await engine.start(graphID: "test-graph", initialState: [:])

        // Both agents in graph are reserved, even before execution reaches them
        let researcherMode = await engine.routingMode(for: "researcher")
        let writerMode = await engine.routingMode(for: "writer")

        if case .graphControlled = researcherMode { } else { XCTFail("Expected researcher graphControlled") }
        if case .graphControlled = writerMode { } else { XCTFail("Expected writer graphControlled") }
    }

    func testUnrelatedAgentRemaindsFreeform() async throws {
        let engine = WorkflowEngine()
        let graph = twoNodeGraph()
        await engine.register(graph: graph)
        _ = try await engine.start(graphID: "test-graph", initialState: [:])

        let mode = await engine.routingMode(for: "unrelated-agent")
        if case .freeform = mode { } else { XCTFail("Expected freeform for unrelated agent") }
    }

    // MARK: - Concurrent Disjointness

    func testStartQueuesOverlappingAgentsInsteadOfRejecting() async throws {
        // The engine now queues overlapping starts rather than throwing agentOverlap.
        // With a very short timeout the second start should time out (not throw agentOverlap).
        let engine = WorkflowEngine(queueTimeout: 0.05)
        let graph = twoNodeGraph()
        await engine.register(graph: graph)
        _ = try await engine.start(graphID: "test-graph", initialState: [:])

        do {
            _ = try await engine.start(graphID: "test-graph", initialState: [:])
            XCTFail("Expected timeout error for overlapping agents")
        } catch {
            // Should be a queue timeout, not agentOverlap
            let isAgentOverlap: Bool
            if case WorkflowEngineError.agentOverlap = error {
                isAgentOverlap = true
            } else {
                isAgentOverlap = false
            }
            XCTAssertFalse(isAgentOverlap, "Expected queue timeout, not agentOverlap — got \(error)")
        }
    }

    func testDisjointGraphsCanRunConcurrently() async throws {
        let engine = WorkflowEngine()
        let graph1 = twoNodeGraph(entryAgentID: "agent-a", secondAgentID: "agent-b")
        let graph2 = WorkflowGraph(
            id: "graph-2", name: "G2", version: 1,
            nodes: [
                "n1": WorkflowNode(id: "n1", agentID: "agent-c", prompt: "p"),
                "n2": WorkflowNode(id: "n2", agentID: "agent-d", prompt: "p")
            ],
            edges: [WorkflowEdge(from: "n1", to: "n2", condition: .always)],
            entryNode: "n1", terminalNodes: ["n2"], metadata: .empty
        )
        await engine.register(graph: graph1)
        await engine.register(graph: graph2)

        let exec1 = try await engine.start(graphID: "test-graph", initialState: [:])
        let exec2 = try await engine.start(graphID: "graph-2", initialState: [:])
        XCTAssertNotEqual(exec1, exec2)
    }

    // MARK: - canRoute + allowFreeform

    func testCanRouteFreeformBlocksGraphAgents() async throws {
        let engine = WorkflowEngine()
        let graph = twoNodeGraph(allowFreeform: true)
        await engine.register(graph: graph)
        _ = try await engine.start(graphID: "test-graph", initialState: [:])

        // Advance to write node (allowFreeform=true)
        let event = WorkflowEvent(
            executionID: await engine.executionIDs().first!,
            nodeID: "research",
            agentID: "researcher",
            type: .nodeCompleted,
            output: ["result": .string("done")]
        )
        _ = try await engine.handleEvent(event)

        let canRouteExternal = await engine.canRoute(from: "writer", to: "external-agent")
        XCTAssertTrue(canRouteExternal)

        // Cannot route to graph agent even with allowFreeform
        let canRouteGraphAgent = await engine.canRoute(from: "writer", to: "researcher")
        XCTAssertFalse(canRouteGraphAgent)
    }

    // MARK: - Event Handling + Correlation

    func testHandleEventAdvancesExecution() async throws {
        let engine = WorkflowEngine()
        let graph = twoNodeGraph()
        await engine.register(graph: graph)
        let execID = try await engine.start(graphID: "test-graph", initialState: ["topic": .string("testing")])

        let event = WorkflowEvent(
            executionID: execID,
            nodeID: "research",
            agentID: "researcher",
            type: .nodeCompleted,
            output: ["result": .string("findings")]
        )
        let result = try await engine.handleEvent(event)

        if case .transitioned(let toNode) = result {
            XCTAssertEqual(toNode, "write")
        } else { XCTFail("Expected transitioned, got \(result)") }

        let execution = await engine.execution(id: execID)
        XCTAssertEqual(execution?.currentNode, "write")
    }

    func testHandleEventRejectsWrongNode() async throws {
        let engine = WorkflowEngine()
        let graph = twoNodeGraph()
        await engine.register(graph: graph)
        let execID = try await engine.start(graphID: "test-graph", initialState: [:])

        let event = WorkflowEvent(
            executionID: execID,
            nodeID: "write",  // wrong — execution is at "research"
            agentID: "writer",
            type: .nodeCompleted
        )

        do {
            _ = try await engine.handleEvent(event)
            XCTFail("Expected correlation error")
        } catch {
            XCTAssertTrue("\(error)".contains("correlation") || "\(error)".contains("current"))
        }
    }

    func testHandleEventRejectsWrongAgent() async throws {
        let engine = WorkflowEngine()
        let graph = twoNodeGraph()
        await engine.register(graph: graph)
        let execID = try await engine.start(graphID: "test-graph", initialState: [:])

        let event = WorkflowEvent(
            executionID: execID,
            nodeID: "research",
            agentID: "writer",  // wrong agent for this node
            type: .nodeCompleted
        )

        do {
            _ = try await engine.handleEvent(event)
            XCTFail("Expected correlation error")
        } catch {
            XCTAssertTrue("\(error)".contains("agent") || "\(error)".contains("correlation"))
        }
    }

    // MARK: - Terminal Node Completion

    func testTerminalNodeCompletesExecution() async throws {
        let engine = WorkflowEngine()
        let graph = twoNodeGraph()
        await engine.register(graph: graph)
        let execID = try await engine.start(graphID: "test-graph", initialState: [:])

        // Advance to write
        let event1 = WorkflowEvent(executionID: execID, nodeID: "research", agentID: "researcher", type: .nodeCompleted)
        _ = try await engine.handleEvent(event1)

        // Complete write (terminal)
        let event2 = WorkflowEvent(executionID: execID, nodeID: "write", agentID: "writer", type: .nodeCompleted)
        let result = try await engine.handleEvent(event2)

        if case .terminal = result { } else { XCTFail("Expected terminal") }

        let execution = await engine.execution(id: execID)
        XCTAssertEqual(execution?.status, .completed)

        // Agents released after completion
        let researcherMode = await engine.routingMode(for: "researcher")
        if case .freeform = researcherMode { } else { XCTFail("Expected freeform after completion") }
    }

    func testTwoNodeGraphRunsEntryToTerminalRecordingBothSteps() async throws {
        // End-to-end drive of the whole graph: both nodes must be recorded as
        // steps, and state from both must survive into the terminal execution.
        let engine = WorkflowEngine()
        await engine.register(graph: twoNodeGraph())
        let execID = try await engine.start(graphID: "test-graph", initialState: ["topic": .string("testing")])

        _ = try await engine.handleEvent(WorkflowEvent(
            executionID: execID, nodeID: "research", agentID: "researcher",
            type: .nodeCompleted, output: ["findings": .string("data")]
        ))
        _ = try await engine.handleEvent(WorkflowEvent(
            executionID: execID, nodeID: "write", agentID: "writer",
            type: .nodeCompleted, output: ["article": .string("published")]
        ))

        let completed = await engine.execution(id: execID)
        let execution = try XCTUnwrap(completed)
        XCTAssertEqual(execution.status, .completed)
        XCTAssertEqual(execution.currentNode, "write")
        XCTAssertEqual(execution.steps.map(\.nodeID), ["research", "write"])
        XCTAssertEqual(execution.steps.map { $0.agentID }, ["researcher", "writer"])
        // State accumulates across both nodes rather than being replaced.
        XCTAssertEqual(execution.state["topic"], .string("testing"))
        XCTAssertEqual(execution.state["findings"], .string("data"))
        XCTAssertEqual(execution.state["article"], .string("published"))
        // Both agents are released once the graph reaches terminal.
        for agent in ["researcher", "writer"] {
            let mode = await engine.routingMode(for: agent)
            if case .freeform = mode { } else { XCTFail("Expected \(agent) freeform after completion") }
        }
    }

    // MARK: - Human Approval

    func testHumanApprovalEdgePausesExecution() async throws {
        let engine = WorkflowEngine()
        let graph = WorkflowGraph(
            id: "approval-graph", name: "Approval", version: 1,
            nodes: [
                "draft": WorkflowNode(id: "draft", agentID: "writer", prompt: "Write draft"),
                "publish": WorkflowNode(id: "publish", agentID: "publisher", prompt: "Publish")
            ],
            edges: [WorkflowEdge(from: "draft", to: "publish", condition: .humanApproval(question: "Approve draft?", deniedEdge: nil))],
            entryNode: "draft", terminalNodes: ["publish"], metadata: .empty
        )
        await engine.register(graph: graph)
        let execID = try await engine.start(graphID: "approval-graph", initialState: [:])

        let event = WorkflowEvent(executionID: execID, nodeID: "draft", agentID: "writer", type: .nodeCompleted)
        let result = try await engine.handleEvent(event)

        if case .awaitingApproval(let question, _) = result {
            XCTAssertEqual(question, "Approve draft?")
        } else { XCTFail("Expected awaitingApproval, got \(result)") }

        let execution = await engine.execution(id: execID)
        XCTAssertEqual(execution?.status, .awaitingApproval)
    }

    func testHumanApprovalPauseHoldsNodeAndReservations() async throws {
        // Pausing must be a real hold: the execution stays parked on the node
        // that raised the gate and keeps its agents reserved, so nothing else
        // can grab them and no further work is attributed past the gate.
        let engine = WorkflowEngine()
        let graph = WorkflowGraph(
            id: "approval-graph", name: "Approval", version: 1,
            nodes: [
                "draft": WorkflowNode(id: "draft", agentID: "writer", prompt: "Write draft"),
                "publish": WorkflowNode(id: "publish", agentID: "publisher", prompt: "Publish")
            ],
            edges: [WorkflowEdge(from: "draft", to: "publish", condition: .humanApproval(question: "Approve?", deniedEdge: nil))],
            entryNode: "draft", terminalNodes: ["publish"], metadata: .empty
        )
        await engine.register(graph: graph)
        let execID = try await engine.start(graphID: "approval-graph", initialState: [:])

        _ = try await engine.handleEvent(WorkflowEvent(
            executionID: execID, nodeID: "draft", agentID: "writer",
            type: .nodeCompleted, output: ["draft": .string("v1")]
        ))

        let gated = await engine.execution(id: execID)
        let paused = try XCTUnwrap(gated)
        XCTAssertEqual(paused.status, .awaitingApproval)
        XCTAssertEqual(paused.currentNode, "draft", "must stay on the gating node until resolved")
        // Agents stay reserved while parked — the graph still owns them.
        for agent in ["writer", "publisher"] {
            let mode = await engine.routingMode(for: agent)
            if case .graphControlled = mode { } else { XCTFail("Expected \(agent) still reserved while paused") }
        }

        // Resolving releases the hold and moves the execution forward.
        _ = try await engine.resolveHumanApproval(executionID: execID, edgeIndex: 0, approved: true, reason: nil)
        let resumed = await engine.execution(id: execID)
        XCTAssertEqual(resumed?.currentNode, "publish")
        XCTAssertEqual(resumed?.status, .running)
    }

    func testResolveHumanApprovalRejectsExecutionNotAwaiting() async throws {
        let engine = WorkflowEngine()
        await engine.register(graph: twoNodeGraph())
        let execID = try await engine.start(graphID: "test-graph", initialState: [:])

        // Execution is .running, never gated — resolution must not force it forward.
        do {
            _ = try await engine.resolveHumanApproval(executionID: execID, edgeIndex: 0, approved: true, reason: nil)
            XCTFail("Expected notAwaitingApproval")
        } catch WorkflowEngineError.notAwaitingApproval {
            // expected
        }
        let execution = await engine.execution(id: execID)
        XCTAssertEqual(execution?.currentNode, "research")
        XCTAssertEqual(execution?.status, .running)
    }

    func testResolveHumanApprovalRejectsOutOfRangeEdgeIndex() async throws {
        let engine = WorkflowEngine()
        let graph = WorkflowGraph(
            id: "approval-graph", name: "Approval", version: 1,
            nodes: [
                "draft": WorkflowNode(id: "draft", agentID: "writer", prompt: "Write draft"),
                "publish": WorkflowNode(id: "publish", agentID: "publisher", prompt: "Publish")
            ],
            edges: [WorkflowEdge(from: "draft", to: "publish", condition: .humanApproval(question: "Approve?", deniedEdge: nil))],
            entryNode: "draft", terminalNodes: ["publish"], metadata: .empty
        )
        await engine.register(graph: graph)
        let execID = try await engine.start(graphID: "approval-graph", initialState: [:])
        _ = try await engine.handleEvent(WorkflowEvent(executionID: execID, nodeID: "draft", agentID: "writer", type: .nodeCompleted))

        do {
            _ = try await engine.resolveHumanApproval(executionID: execID, edgeIndex: 7, approved: true, reason: nil)
            XCTFail("Expected invalidEdgeIndex")
        } catch WorkflowEngineError.invalidEdgeIndex {
            // expected
        }
        // The gate survives a bad resolution attempt and can still be resolved.
        let execution = await engine.execution(id: execID)
        XCTAssertEqual(execution?.status, .awaitingApproval)
        XCTAssertEqual(execution?.currentNode, "draft")
    }

    func testResolveHumanApprovalDeniedWithoutDeniedEdgeFails() async throws {
        // No deniedEdge to fall back to — denial must settle the execution as
        // failed and release its agents rather than leaving it parked.
        let engine = WorkflowEngine()
        let graph = WorkflowGraph(
            id: "approval-graph", name: "Approval", version: 1,
            nodes: [
                "draft": WorkflowNode(id: "draft", agentID: "writer", prompt: "Write draft"),
                "publish": WorkflowNode(id: "publish", agentID: "publisher", prompt: "Publish")
            ],
            edges: [WorkflowEdge(from: "draft", to: "publish", condition: .humanApproval(question: "Approve?", deniedEdge: nil))],
            entryNode: "draft", terminalNodes: ["publish"], metadata: .empty
        )
        await engine.register(graph: graph)
        let execID = try await engine.start(graphID: "approval-graph", initialState: [:])
        _ = try await engine.handleEvent(WorkflowEvent(executionID: execID, nodeID: "draft", agentID: "writer", type: .nodeCompleted))

        let result = try await engine.resolveHumanApproval(executionID: execID, edgeIndex: 0, approved: false, reason: "Not shippable")

        if case .noMatchingEdge = result { } else { XCTFail("Expected noMatchingEdge, got \(result)") }
        let execution = await engine.execution(id: execID)
        XCTAssertEqual(execution?.status, .failed)
        for agent in ["writer", "publisher"] {
            let mode = await engine.routingMode(for: agent)
            if case .freeform = mode { } else { XCTFail("Expected \(agent) released after failed approval") }
        }
    }

    func testResolveHumanApprovalApproved() async throws {
        let engine = WorkflowEngine()
        let graph = WorkflowGraph(
            id: "approval-graph", name: "Approval", version: 1,
            nodes: [
                "draft": WorkflowNode(id: "draft", agentID: "writer", prompt: "Write draft"),
                "publish": WorkflowNode(id: "publish", agentID: "publisher", prompt: "Publish")
            ],
            edges: [WorkflowEdge(from: "draft", to: "publish", condition: .humanApproval(question: "Approve?", deniedEdge: nil))],
            entryNode: "draft", terminalNodes: ["publish"], metadata: .empty
        )
        await engine.register(graph: graph)
        let execID = try await engine.start(graphID: "approval-graph", initialState: [:])

        let event = WorkflowEvent(executionID: execID, nodeID: "draft", agentID: "writer", type: .nodeCompleted)
        _ = try await engine.handleEvent(event)

        let result = try await engine.resolveHumanApproval(executionID: execID, edgeIndex: 0, approved: true, reason: "Looks good")

        if case .transitioned(let toNode) = result {
            XCTAssertEqual(toNode, "publish")
        } else { XCTFail("Expected transitioned after approval") }

        let execution = await engine.execution(id: execID)
        XCTAssertEqual(execution?.status, .running)
        XCTAssertEqual(execution?.currentNode, "publish")
    }

    func testResolveHumanApprovalDenied() async throws {
        let engine = WorkflowEngine()
        let graph = WorkflowGraph(
            id: "approval-graph", name: "Approval", version: 1,
            nodes: [
                "draft": WorkflowNode(id: "draft", agentID: "writer", prompt: "Write draft"),
                "publish": WorkflowNode(id: "publish", agentID: "publisher", prompt: "Publish"),
                "revise": WorkflowNode(id: "revise", agentID: "writer", prompt: "Revise")
            ],
            edges: [
                WorkflowEdge(from: "draft", to: "publish", condition: .humanApproval(question: "Approve?", deniedEdge: "revise")),
                WorkflowEdge(from: "revise", to: "draft", condition: .always)
            ],
            entryNode: "draft", terminalNodes: ["publish"], metadata: .empty
        )
        await engine.register(graph: graph)
        let execID = try await engine.start(graphID: "approval-graph", initialState: [:])

        let event = WorkflowEvent(executionID: execID, nodeID: "draft", agentID: "writer", type: .nodeCompleted)
        _ = try await engine.handleEvent(event)

        let result = try await engine.resolveHumanApproval(executionID: execID, edgeIndex: 0, approved: false, reason: "Needs revision")

        if case .transitioned(let toNode) = result {
            XCTAssertEqual(toNode, "revise")
        } else { XCTFail("Expected transitioned to denied edge") }
    }

    // MARK: - State Carry-Forward

    func testStateCarryForwardOnTransition() async throws {
        let engine = WorkflowEngine()
        let graph = twoNodeGraph()
        await engine.register(graph: graph)
        let execID = try await engine.start(graphID: "test-graph", initialState: ["topic": .string("testing")])

        let event = WorkflowEvent(
            executionID: execID,
            nodeID: "research",
            agentID: "researcher",
            type: .nodeCompleted,
            output: ["findings": .string("important data")]
        )
        _ = try await engine.handleEvent(event)

        let execution = await engine.execution(id: execID)
        // Original state preserved
        XCTAssertEqual(execution?.state["topic"], .string("testing"))
        // Output merged into state
        XCTAssertEqual(execution?.state["findings"], .string("important data"))
    }

    // MARK: - mergeState

    /// The seam `BacklogAutopilot`'s `nodeActivationGate` writes through: a
    /// caller that has computed something before a node's own turn produces
    /// output to merge in the ordinary way.
    func testMergeStateWritesIntoARunningExecution() async throws {
        let engine = WorkflowEngine()
        let graph = twoNodeGraph()
        await engine.register(graph: graph)
        let execID = try await engine.start(graphID: "test-graph", initialState: ["topic": .string("testing")])

        await engine.mergeState(executionID: execID, updates: ["injected": .string("fresh")])

        let execution = await engine.execution(id: execID)
        XCTAssertEqual(execution?.state["injected"], .string("fresh"))
        // Nothing else already in state is disturbed by the merge.
        XCTAssertEqual(execution?.state["topic"], .string("testing"))
    }

    func testMergeStateOverwritesAnExistingKey() async throws {
        let engine = WorkflowEngine()
        let graph = twoNodeGraph()
        await engine.register(graph: graph)
        let execID = try await engine.start(graphID: "test-graph", initialState: ["topic": .string("testing")])

        await engine.mergeState(executionID: execID, updates: ["topic": .string("replaced")])

        let execution = await engine.execution(id: execID)
        XCTAssertEqual(execution?.state["topic"], .string("replaced"))
    }

    /// An execution that has already ended, or an id nobody started, is a
    /// no-op — the same as every other query here keyed by an id that may not
    /// resolve, not a crash or a silently created execution.
    func testMergeStateOnAnUnknownExecutionIsANoOp() async {
        let engine = WorkflowEngine()
        await engine.mergeState(executionID: "does-not-exist", updates: ["foo": .string("bar")])
        let execution = await engine.execution(id: "does-not-exist")
        XCTAssertNil(execution)
    }
}
