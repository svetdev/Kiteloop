import XCTest
@testable import KiteloopCore

final class WorkflowExecutionTests: XCTestCase {
    // MARK: - ExecutionStatus raw values

    /// Raw values are persisted in checkpoint JSON on disk — renaming one
    /// silently orphans every checkpoint written by an earlier build.
    private static let expectedRawValues: [ExecutionStatus: String] = [
        .pending: "pending",
        .running: "running",
        .paused: "paused",
        .awaitingApproval: "awaitingApproval",
        .completed: "completed",
        .failed: "failed",
        .cancelled: "cancelled",
        .timedOut: "timedOut"
    ]

    func testExecutionStatusRawValues() {
        for status in ExecutionStatus.allCases {
            XCTAssertEqual(
                status.rawValue,
                Self.expectedRawValues[status],
                "raw value for \(status) changed — this breaks existing checkpoints"
            )
        }
    }

    func testExecutionStatusCaseCoverage() {
        XCTAssertEqual(
            Set(ExecutionStatus.allCases),
            Set(Self.expectedRawValues.keys),
            "a case was added or removed — classify it as terminal or non-terminal too"
        )
    }

    func testExecutionStatusRoundTripsThroughRawValue() {
        for status in ExecutionStatus.allCases {
            XCTAssertEqual(ExecutionStatus(rawValue: status.rawValue), status)
        }
    }

    func testExecutionStatusDecodesFromRawValue() throws {
        for status in ExecutionStatus.allCases {
            let json = Data("\"\(status.rawValue)\"".utf8)
            let decoded = try JSONDecoder().decode(ExecutionStatus.self, from: json)
            XCTAssertEqual(decoded, status)
        }
    }

    func testExecutionStatusRejectsUnknownRawValue() {
        XCTAssertNil(ExecutionStatus(rawValue: "Completed"))
        XCTAssertNil(ExecutionStatus(rawValue: "timed_out"))
        XCTAssertNil(ExecutionStatus(rawValue: ""))
    }

    // MARK: - Terminal detection

    func testTerminalStatuses() {
        for status in [ExecutionStatus.completed, .failed, .cancelled, .timedOut] {
            XCTAssertTrue(status.isTerminal, "\(status) should be terminal")
        }
    }

    func testNonTerminalStatuses() {
        for status in [ExecutionStatus.pending, .running, .paused, .awaitingApproval] {
            XCTAssertFalse(status.isTerminal, "\(status) should not be terminal")
        }
    }

    func testEveryStatusIsClassified() {
        let terminal = ExecutionStatus.allCases.filter(\.isTerminal)
        let active = ExecutionStatus.allCases.filter { !$0.isTerminal }
        XCTAssertEqual(terminal.count + active.count, ExecutionStatus.allCases.count)
        XCTAssertFalse(terminal.isEmpty)
        XCTAssertFalse(active.isEmpty)
    }

    func testExecutionCreation() {
        let execution = WorkflowExecution(
            id: "exec-1",
            graphID: "graph-1",
            currentNode: "start",
            status: .running,
            state: ["input": .string("hello")]
        )
        XCTAssertEqual(execution.id, "exec-1")
        XCTAssertEqual(execution.graphID, "graph-1")
        XCTAssertEqual(execution.currentNode, "start")
        XCTAssertEqual(execution.status, .running)
        XCTAssertEqual(execution.state["input"], .string("hello"))
        XCTAssertTrue(execution.steps.isEmpty)
    }

    func testExecutionEncodesStatusAsRawValue() throws {
        let execution = WorkflowExecution(
            id: "exec-1",
            graphID: "graph-1",
            currentNode: "start",
            status: .awaitingApproval,
            state: [:]
        )
        let object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(execution)
        ) as? [String: Any]
        XCTAssertEqual(object?["status"] as? String, "awaitingApproval")
    }

    func testExecutionRoundTripsThroughCodable() throws {
        for status in ExecutionStatus.allCases {
            let execution = WorkflowExecution(
                id: "exec-\(status.rawValue)",
                graphID: "graph-1",
                graphVersion: 3,
                traceID: "trace-1",
                currentNode: "review",
                status: status,
                state: ["input": .string("hello")],
                lastCheckpointID: "cp-1",
                parentExecutionID: "parent-1",
                parentNodeID: "spawn"
            )
            let decoded = try JSONDecoder().decode(
                WorkflowExecution.self,
                from: JSONEncoder().encode(execution)
            )
            XCTAssertEqual(decoded.id, execution.id)
            XCTAssertEqual(decoded.graphVersion, 3)
            XCTAssertEqual(decoded.traceID, "trace-1")
            XCTAssertEqual(decoded.currentNode, "review")
            XCTAssertEqual(decoded.status, status)
            XCTAssertEqual(decoded.state["input"], .string("hello"))
            XCTAssertEqual(decoded.lastCheckpointID, "cp-1")
            XCTAssertEqual(decoded.parentExecutionID, "parent-1")
            XCTAssertEqual(decoded.parentNodeID, "spawn")
        }
    }

    func testExecutionStepRecord() {
        var execution = WorkflowExecution(
            id: "exec-1",
            graphID: "graph-1",
            currentNode: "start",
            status: .running,
            state: [:]
        )
        let step = ExecutionStep(
            nodeID: "start",
            agentID: "researcher",
            spanID: nil,
            startedAt: Date(),
            completedAt: Date(),
            output: ["result": .string("done")]
        )
        execution.steps.append(step)
        XCTAssertEqual(execution.steps.count, 1)
        XCTAssertEqual(execution.steps[0].nodeID, "start")
    }

    func testWorkflowEventCreation() {
        let event = WorkflowEvent(
            executionID: "exec-1",
            nodeID: "research",
            agentID: "researcher",
            type: .nodeCompleted,
            output: ["status": .string("done")]
        )
        XCTAssertEqual(event.executionID, "exec-1")
        XCTAssertEqual(event.nodeID, "research")
        XCTAssertEqual(event.agentID, "researcher")
        XCTAssertEqual(event.type, .nodeCompleted)
    }

    func testRoutingModeEnum() {
        let freeform = RoutingMode.freeform
        let controlled = RoutingMode.graphControlled(executionID: "exec-1")

        if case .freeform = freeform { } else { XCTFail("Expected freeform") }
        if case .graphControlled(let id) = controlled {
            XCTAssertEqual(id, "exec-1")
        } else { XCTFail("Expected graphControlled") }
    }

    func testTransitionResult() {
        let success = TransitionResult.transitioned(toNode: "write")
        let awaiting = TransitionResult.awaitingApproval(question: "Deploy?", edgeID: 0)
        let noMatch = TransitionResult.noMatchingEdge
        let terminal = TransitionResult.terminal

        if case .transitioned(let node) = success {
            XCTAssertEqual(node, "write")
        } else { XCTFail("Expected transitioned") }

        if case .awaitingApproval(let q, let idx) = awaiting {
            XCTAssertEqual(q, "Deploy?")
            XCTAssertEqual(idx, 0)
        } else { XCTFail("Expected awaitingApproval") }

        if case .noMatchingEdge = noMatch { } else { XCTFail("Expected noMatchingEdge") }
        if case .terminal = terminal { } else { XCTFail("Expected terminal") }
    }
}
