import XCTest
import KiteloopCore
@testable import Kiteloop

final class WorkflowEngineCircuitBreakerTests: XCTestCase {
    func testMaxTurnsEnforcementOnNodeCompletion() async throws {
        let engine = WorkflowEngine()
        let graph = WorkflowGraph(
            id: "cb-graph", name: "CB", version: 1,
            nodes: [
                "n1": WorkflowNode(id: "n1", agentID: "agent-a", prompt: "p", maxTurns: 2),
                "n2": WorkflowNode(id: "n2", agentID: "agent-b", prompt: "p")
            ],
            edges: [WorkflowEdge(from: "n1", to: "n2", condition: .always)],
            entryNode: "n1", terminalNodes: ["n2"], metadata: .empty
        )
        await engine.register(graph: graph)
        let execID = try await engine.start(graphID: "cb-graph", initialState: [:])

        // Record turns exceeding maxTurns
        await engine.recordTurn(executionID: execID)
        await engine.recordTurn(executionID: execID)
        await engine.recordTurn(executionID: execID)

        let breaker = await engine.checkCircuitBreaker(executionID: execID)
        XCTAssertEqual(breaker, .maxTurnsExceeded)
    }

    func testGlobalTimeoutCheck() async throws {
        let engine = WorkflowEngine()
        let graph = WorkflowGraph(
            id: "timeout-graph", name: "TO", version: 1,
            nodes: ["n1": WorkflowNode(id: "n1", agentID: "a1", prompt: "p")],
            edges: [], entryNode: "n1", terminalNodes: ["n1"],
            metadata: .empty, globalTimeout: 1
        )
        await engine.register(graph: graph)
        let execID = try await engine.start(graphID: "timeout-graph", initialState: [:])

        // Wait past the global timeout
        try await eventually(
            "the breaker to trip on the global timeout"
        ) { await engine.checkCircuitBreaker(executionID: execID) == .timeoutExceeded }

        let breaker = await engine.checkCircuitBreaker(executionID: execID)
        XCTAssertEqual(breaker, .timeoutExceeded)
    }

    func testCancelExecution() async throws {
        let engine = WorkflowEngine()
        let graph = WorkflowGraph(
            id: "cancel-graph", name: "C", version: 1,
            nodes: ["n1": WorkflowNode(id: "n1", agentID: "a1", prompt: "p")],
            edges: [], entryNode: "n1", terminalNodes: ["n1"], metadata: .empty
        )
        await engine.register(graph: graph)
        let execID = try await engine.start(graphID: "cancel-graph", initialState: [:])

        await engine.cancel(executionID: execID)

        let execution = await engine.execution(id: execID)
        XCTAssertEqual(execution?.status, .cancelled)

        // Agent should be released
        let mode = await engine.routingMode(for: "a1")
        if case .freeform = mode { } else { XCTFail("Expected freeform after cancel") }
    }

    // MARK: - Caps enforced on the path the engine actually runs

    /// `a` loops through `b` and back, so the same node is entered repeatedly —
    /// the shape the autopilot's worker/reviewer graph has. `again` on `b`'s
    /// output is what sends the run round again.
    private func makeLoopGraph(
        id: String,
        aMaxTurns: Int? = nil,
        aTimeout: Int? = nil,
        bMaxTurns: Int? = nil,
        bTimeout: Int? = nil,
        globalTimeout: Int? = nil
    ) -> WorkflowGraph {
        WorkflowGraph(
            id: id, name: "Loop", version: 1,
            nodes: [
                "a": WorkflowNode(id: "a", agentID: "agent-a", prompt: "p",
                                  maxTurns: aMaxTurns, timeoutSeconds: aTimeout),
                "b": WorkflowNode(id: "b", agentID: "agent-b", prompt: "p",
                                  maxTurns: bMaxTurns, timeoutSeconds: bTimeout),
                "end": WorkflowNode(id: "end", prompt: "")
            ],
            edges: [
                WorkflowEdge(from: "a", to: "b", condition: .always, priority: 0),
                WorkflowEdge(from: "b", to: "a", condition: .outputMatch(key: "again", value: "yes"), priority: 0),
                WorkflowEdge(from: "b", to: "end", condition: .always, priority: 1),
            ],
            entryNode: "a", terminalNodes: ["end"], metadata: .empty,
            globalTimeout: globalTimeout
        )
    }

    private func completion(_ execID: String, _ nodeID: String, again: Bool = false) -> WorkflowEvent {
        WorkflowEvent(
            executionID: execID,
            nodeID: nodeID,
            agentID: nodeID == "a" ? "agent-a" : "agent-b",
            type: .nodeCompleted,
            output: again ? ["again": .string("yes")] : [:]
        )
    }

    func testNodeMaxTurnsEndsExecution() async throws {
        let engine = WorkflowEngine()
        await engine.register(graph: makeLoopGraph(id: "turns-graph", aMaxTurns: 2))
        let execID = try await engine.start(graphID: "turns-graph", initialState: [:])

        // Two turns on `a`, each returning through `b`. A counter keyed by
        // execution alone would already stand at 3 here and end the run.
        for _ in 0..<2 {
            _ = try await engine.handleEvent(completion(execID, "a"))
            _ = try await engine.handleEvent(completion(execID, "b", again: true))
        }
        var execution = await engine.execution(id: execID)
        XCTAssertEqual(execution?.status, .running)
        XCTAssertEqual(execution?.currentNode, "a")

        // The third turn on `a` is one past its declared cap.
        let result = try await engine.handleEvent(completion(execID, "a"))
        guard case .terminal = result else {
            return XCTFail("Expected the execution to end on the exceeded turn cap")
        }
        execution = await engine.execution(id: execID)
        XCTAssertEqual(execution?.status, .failed)
        XCTAssertEqual(execution?.state["_failureReason"]?.stringValue,
                       "Max turns (2) exceeded for node 'a'")
    }

    func testMaxTurnsIsCountedPerNodeNotPerExecution() async throws {
        let engine = WorkflowEngine()
        // The small cap sits on `b`, the way the reviewer's 20 sits beside the
        // worker's 50. It must be judged against `b`'s own turns.
        await engine.register(graph: makeLoopGraph(id: "per-node-graph", aMaxTurns: 50, bMaxTurns: 3))
        let execID = try await engine.start(graphID: "per-node-graph", initialState: [:])

        // Two turns each. The execution has now taken four, one more than `b`'s
        // cap — a counter keyed by execution alone would have ended it here.
        for _ in 0..<2 {
            _ = try await engine.handleEvent(completion(execID, "a"))
            _ = try await engine.handleEvent(completion(execID, "b", again: true))
        }
        var execution = await engine.execution(id: execID)
        XCTAssertEqual(execution?.status, .running)
        XCTAssertEqual(execution?.currentNode, "a")
        var aTurns = await engine.turns(executionID: execID, nodeID: "a")
        var bTurns = await engine.turns(executionID: execID, nodeID: "b")
        XCTAssertEqual(aTurns, 2)
        XCTAssertEqual(bTurns, 2)

        // A third turn each keeps both inside their own caps.
        _ = try await engine.handleEvent(completion(execID, "a"))
        _ = try await engine.handleEvent(completion(execID, "b", again: true))
        execution = await engine.execution(id: execID)
        XCTAssertEqual(execution?.status, .running)

        // `b`'s fourth turn is one past `b`'s cap — and `a`, on four turns
        // against a cap of 50, is what the run is not ended for.
        _ = try await engine.handleEvent(completion(execID, "a"))
        let result = try await engine.handleEvent(completion(execID, "b", again: true))
        guard case .terminal = result else {
            return XCTFail("Expected b's own turn cap to end the execution")
        }
        aTurns = await engine.turns(executionID: execID, nodeID: "a")
        bTurns = await engine.turns(executionID: execID, nodeID: "b")
        XCTAssertEqual(aTurns, 4)
        XCTAssertEqual(bTurns, 4)
        execution = await engine.execution(id: execID)
        XCTAssertEqual(execution?.state["_failureReason"]?.stringValue,
                       "Max turns (3) exceeded for node 'b'")
    }

    func testNodeTimeoutMeasuredFromNodeEntryNotExecutionStart() async throws {
        let engine = WorkflowEngine()
        // `b` declares 1 second and is entered into an execution already older
        // than that. Measured from `startedAt` it would trip immediately.
        await engine.register(graph: makeLoopGraph(id: "node-timeout-fresh", bTimeout: 1))
        let execID = try await engine.start(graphID: "node-timeout-fresh", initialState: [:])

        try await Task.sleep(for: .seconds(1.3))

        _ = try await engine.handleEvent(completion(execID, "a"))
        let onB = await engine.execution(id: execID)
        XCTAssertEqual(onB?.currentNode, "b")
        XCTAssertEqual(onB?.status, .running, "a declares no timeout, so nothing should have tripped")

        let result = try await engine.handleEvent(completion(execID, "b"))
        guard case .terminal = result else {
            return XCTFail("Expected b to route on to the terminal node")
        }
        let execution = await engine.execution(id: execID)
        XCTAssertEqual(execution?.status, .completed)
        XCTAssertNil(execution?.state["_failureReason"])
    }

    func testNodeTimeoutEndsExecutionWhenTheNodeItselfRunsLong() async throws {
        let engine = WorkflowEngine()
        await engine.register(graph: makeLoopGraph(id: "node-timeout-long", bTimeout: 1))
        let execID = try await engine.start(graphID: "node-timeout-long", initialState: [:])

        _ = try await engine.handleEvent(completion(execID, "a"))
        try await Task.sleep(for: .seconds(1.3))

        let result = try await engine.handleEvent(completion(execID, "b"))
        guard case .terminal = result else {
            return XCTFail("Expected the execution to end on the exceeded node timeout")
        }
        let execution = await engine.execution(id: execID)
        XCTAssertEqual(execution?.status, .timedOut)
        XCTAssertEqual(execution?.state["_failureReason"]?.stringValue,
                       "Node timeout (1s) exceeded for node 'b'")
    }

    func testGlobalTimeoutStillMeasuredFromExecutionStart() async throws {
        let engine = WorkflowEngine()
        // Each node's own budget is generous; only the sum of them is not, which
        // is what a global timeout is for.
        await engine.register(graph: makeLoopGraph(
            id: "global-timeout-graph", aTimeout: 60, bTimeout: 60, globalTimeout: 2
        ))
        let execID = try await engine.start(graphID: "global-timeout-graph", initialState: [:])

        try await Task.sleep(for: .seconds(1.2))
        _ = try await engine.handleEvent(completion(execID, "a"))
        try await Task.sleep(for: .seconds(1.2))

        let result = try await engine.handleEvent(completion(execID, "b"))
        guard case .terminal = result else {
            return XCTFail("Expected the execution to end on the exceeded global timeout")
        }
        let execution = await engine.execution(id: execID)
        XCTAssertEqual(execution?.status, .timedOut)
        XCTAssertEqual(execution?.state["_failureReason"]?.stringValue,
                       "Global timeout (2s) exceeded")
    }

    /// A node with `timeoutFallback` set — the reviewer's follow-up ask,
    /// asking the reviewer to restate a verdict already formed — plus two
    /// answering nodes reachable only by what `passed` reads: `done` for
    /// `true`, `worker` for anything else, and `blocked` behind an `.always`
    /// fallback that a resolved timeout must never reach.
    private func makeFallbackGraph(id: String, clarifyTimeout: Int) -> WorkflowGraph {
        WorkflowGraph(
            id: id, name: "Fallback", version: 1,
            nodes: [
                "clarify": WorkflowNode(
                    id: "clarify", agentID: "reviewer-agent", prompt: "p",
                    timeoutSeconds: clarifyTimeout,
                    timeoutFallback: .init(key: "passed", trueValue: "true", falseValue: "false",
                                           note: "clarify timed out after \(clarifyTimeout)s",
                                           feedbackKey: "previousFeedback")
                ),
                "done": WorkflowNode(id: "done", prompt: ""),
                "worker": WorkflowNode(id: "worker", prompt: ""),
                "blocked": WorkflowNode(id: "blocked", prompt: ""),
            ],
            edges: [
                WorkflowEdge(from: "clarify", to: "done", condition: .outputMatch(key: "passed", value: "true"), priority: 0),
                WorkflowEdge(from: "clarify", to: "worker", condition: .outputMatch(key: "passed", value: "false"), priority: 1),
                WorkflowEdge(from: "clarify", to: "blocked", condition: .always, priority: 10),
            ],
            entryNode: "clarify", terminalNodes: ["done", "blocked"], metadata: .empty
        )
    }

    func testTimeoutFallbackRoutesToRejectionWhenNoVerdictIsOnRecord() async throws {
        let engine = WorkflowEngine()
        await engine.register(graph: makeFallbackGraph(id: "fallback-reject", clarifyTimeout: 1))
        let execID = try await engine.start(graphID: "fallback-reject", initialState: [:])

        try await eventually("clarify's own clock to run out") {
            await engine.checkCircuitBreaker(executionID: execID) == .timeoutExceeded
        }
        // The late turn that finally arrives after the clock ran out — the
        // trip pre-empts routing on whatever it says, exactly as an ordinary
        // node timeout does (`testNodeTimeoutEndsExecutionWhenTheNodeItselfRunsLong`).
        let result = try await engine.handleEvent(WorkflowEvent(
            executionID: execID, nodeID: "clarify", agentID: "reviewer-agent",
            type: .nodeCompleted, output: [:]
        ))
        guard case .transitioned(let toNode) = result else {
            return XCTFail("Expected the timeout fallback to transition, not end the execution")
        }
        XCTAssertEqual(toNode, "worker", "no readable verdict defaults to the rejection branch, never blocked")

        let execution = await engine.execution(id: execID)
        XCTAssertEqual(execution?.currentNode, "worker")
        XCTAssertNotEqual(execution?.status, .timedOut)
        XCTAssertNil(execution?.state["_failureReason"], "a resolved timeout is not a failure")
        XCTAssertEqual(execution?.state["passed"]?.stringValue, "false")
        XCTAssertEqual(execution?.state["_timeoutFallbackNote"]?.stringValue, "clarify timed out after 1s")
        XCTAssertEqual(execution?.state["previousFeedback"]?.stringValue, "clarify timed out after 1s",
                       "the rejection hands the next round a reason instead of a stale or empty one")
    }

    func testTimeoutFallbackRoutesToApprovalWhenAPassingVerdictIsOnRecord() async throws {
        let engine = WorkflowEngine()
        await engine.register(graph: makeFallbackGraph(id: "fallback-approve", clarifyTimeout: 1))
        let execID = try await engine.start(graphID: "fallback-approve", initialState: ["passed": .string("true")])

        try await eventually("clarify's own clock to run out") {
            await engine.checkCircuitBreaker(executionID: execID) == .timeoutExceeded
        }
        let result = try await engine.handleEvent(WorkflowEvent(
            executionID: execID, nodeID: "clarify", agentID: "reviewer-agent",
            type: .nodeCompleted, output: [:]
        ))
        guard case .terminal = result else {
            return XCTFail("Expected the timeout fallback to reach the agentless terminal node")
        }

        let execution = await engine.execution(id: execID)
        XCTAssertEqual(execution?.currentNode, "done")
        XCTAssertEqual(execution?.status, .completed)
        XCTAssertNil(execution?.state["_failureReason"])
        XCTAssertEqual(execution?.state["passed"]?.stringValue, "true")
        XCTAssertNil(execution?.state["previousFeedback"], "an approval needs no explanation handed forward")
    }

    func testExecutionInsideBothCapsReachesItsTerminalNode() async throws {
        let engine = WorkflowEngine()
        await engine.register(graph: makeLoopGraph(
            id: "within-caps-graph", aMaxTurns: 5, aTimeout: 60, bMaxTurns: 5, bTimeout: 60
        ))
        let execID = try await engine.start(graphID: "within-caps-graph", initialState: [:])

        _ = try await engine.handleEvent(completion(execID, "a"))
        let result = try await engine.handleEvent(completion(execID, "b"))
        guard case .terminal = result else { return XCTFail("Expected terminal") }

        let execution = await engine.execution(id: execID)
        XCTAssertEqual(execution?.currentNode, "end")
        XCTAssertEqual(execution?.status, .completed)
        XCTAssertNil(execution?.state["_failureReason"])
    }

    func testBreakerEndReleasesReservationsPublishesAndCheckpoints() async throws {
        let busURL = FileManager.default.temporaryDirectory
            .appending(path: "cb-events-\(UUID().uuidString).jsonl")
        let bus = EventBus(eventsURL: busURL)
        let bridge = WorkflowEventBridge(eventBus: bus)
        let storeDir = try makeTemporaryDirectory(prefix: "cb-checkpoints")
        let store = WorkflowCheckpointStore(baseURL: storeDir)

        let engine = WorkflowEngine(queueTimeout: 5.0, eventBridge: bridge)
        await engine.setCheckpointStore(store)
        await engine.register(graph: makeLoopGraph(id: "cb-end-graph", aMaxTurns: 1))
        let execID = try await engine.start(graphID: "cb-end-graph", initialState: [:])

        let stream = await bus.subscribe(agentID: "observer", types: [.workflowFailed])

        _ = try await engine.handleEvent(completion(execID, "a"))
        _ = try await engine.handleEvent(completion(execID, "b", again: true))
        _ = try await engine.handleEvent(completion(execID, "a"))

        var published: KiteloopEvent?
        for await event in stream {
            published = event
            break
        }
        XCTAssertEqual(published?.type, .workflowFailed)
        XCTAssertEqual(published?.payload["executionID"], execID)
        XCTAssertEqual(published?.payload["reason"], "max_turns")

        for agent in ["agent-a", "agent-b"] {
            let mode = await engine.routingMode(for: agent)
            if case .freeform = mode { } else {
                XCTFail("Expected \(agent) to be released after the breaker ended the run")
            }
        }

        let checkpoint = try await store.latestCheckpoint(executionID: execID)
        XCTAssertEqual(checkpoint?.reason, .failed)
        XCTAssertEqual(checkpoint?.executionSnapshot.status, .failed)
        XCTAssertEqual(checkpoint?.executionSnapshot.state["_failureReason"]?.stringValue,
                       "Max turns (1) exceeded for node 'a'")
    }

    func testLoadGraphsFromDirectory() async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "engine-load")

        let json = """
        {
            "id": "file-graph", "name": "FG", "version": 1,
            "entryNode": "n1", "terminalNodes": ["n1"],
            "metadata": {"description": ""},
            "nodes": {"n1": {"id": "n1", "agentID": "file-agent", "prompt": "p"}},
            "edges": []
        }
        """
        try json.data(using: .utf8)!.write(to: tempDir.appending(path: "fg.workflow.json"))

        let engine = WorkflowEngine()
        await engine.loadGraphs(from: tempDir)

        let loaded = await engine.registeredGraph(id: "file-graph")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.name, "FG")
    }
}
