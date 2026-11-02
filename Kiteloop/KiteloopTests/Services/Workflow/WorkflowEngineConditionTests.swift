import XCTest
import KiteloopCore
@testable import Kiteloop

/// The edge conditions a node's result is routed by: an emitted event of the
/// named type, and conditions combined with `allOf` and `anyOf` — every one
/// met, at least one met, and an approval inside either holding the run.
final class WorkflowEngineConditionTests: XCTestCase {

    /// One edge from `worker` to `next` under `condition`; `next` carries an
    /// agent, so a satisfied edge transitions rather than finalizing.
    private func route(_ condition: EdgeCondition, type: WorkflowEventType = .nodeCompleted,
                       output: [String: AnyCodable] = [:],
                       state: [String: AnyCodable] = [:]) async throws -> TransitionResult {
        let engine = WorkflowEngine()
        await engine.register(graph: WorkflowGraph(
            id: "conditions", name: "Conditions", version: 1,
            nodes: ["worker": WorkflowNode(id: "worker", agentID: "w", prompt: "work"),
                    "next": WorkflowNode(id: "next", agentID: "n", prompt: "next")],
            edges: [WorkflowEdge(from: "worker", to: "next", condition: condition)],
            entryNode: "worker", terminalNodes: ["next"],
            metadata: WorkflowGraph.GraphMetadata(description: "test")))
        let execID = try await engine.start(graphID: "conditions", initialState: state)
        return try await engine.handleEvent(WorkflowEvent(
            executionID: execID, nodeID: "worker", agentID: "w", type: type, output: output))
    }

    private func assertTransitions(_ result: TransitionResult, file: StaticString = #filePath, line: UInt = #line) {
        guard case .transitioned(let node) = result, node == "next" else {
            return XCTFail("expected a transition to next, got \(result)", file: file, line: line)
        }
    }

    private func assertHolds(_ result: TransitionResult, file: StaticString = #filePath, line: UInt = #line) {
        guard case .noMatchingEdge = result else {
            return XCTFail("expected no matching edge, got \(result)", file: file, line: line)
        }
    }

    func testAnEmittedEventOfTheNamedTypeFollowsTheEdgeAndAnotherTypeDoesNot() async throws {
        assertTransitions(try await route(.eventType("review"), type: .eventEmitted,
                                          output: ["_eventType": .string("review")]))
        assertHolds(try await route(.eventType("review"), type: .eventEmitted,
                                    output: ["_eventType": .string("deploy")]))
    }

    func testAnOutputMatchReadsTheStateWhenTheEventDoesNotCarryTheKey() async throws {
        assertTransitions(try await route(.outputMatch(key: "result", value: "pass"),
                                          state: ["result": .string("pass")]))
        assertHolds(try await route(.outputMatch(key: "result", value: "pass"),
                                    output: ["result": .string("fail")]))
    }

    func testAllOfNeedsEveryConditionAndAnyOfNeedsOne() async throws {
        let pass: EdgeCondition = .outputMatch(key: "result", value: "pass")
        let ok: EdgeCondition = .outputMatch(key: "lint", value: "ok")
        let output: [String: AnyCodable] = ["result": .string("pass"), "lint": .string("dirty")]

        assertHolds(try await route(.allOf([pass, ok]), output: output))
        assertTransitions(try await route(.allOf([pass, .always]), output: output))
        assertTransitions(try await route(.anyOf([ok, pass]), output: output))
        assertHolds(try await route(.anyOf([ok]), output: output))
    }

    func testAnApprovalInsideACombinationHoldsTheRunForAPerson() async throws {
        let approval: EdgeCondition = .humanApproval(question: "Ship it?", deniedEdge: nil)
        for condition in [EdgeCondition.allOf([.always, approval]), .anyOf([.outputMatch(key: "x", value: "y"), approval])] {
            guard case .awaitingApproval(let question, _) = try await route(condition) else {
                return XCTFail("\(condition) did not wait for approval")
            }
            XCTAssertEqual(question, "Ship it?")
        }
    }
}
