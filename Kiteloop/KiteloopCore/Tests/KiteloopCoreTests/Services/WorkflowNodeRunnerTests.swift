import XCTest
@testable import KiteloopCore

final class WorkflowNodeRunnerTests: XCTestCase {
    func testPrepareNodeActivationResolvesPrompt() {
        let node = WorkflowNode(id: "research", agentID: "researcher", prompt: "Research {{state.topic}}")
        let state: [String: AnyCodable] = ["topic": .string("Swift concurrency")]
        let runner = WorkflowNodeRunner()

        let activation = runner.prepareActivation(node: node, state: state, executionID: "exec-1")

        XCTAssertEqual(activation.resolvedPrompt, "Research Swift concurrency")
        XCTAssertEqual(activation.agentID, "researcher")
        XCTAssertEqual(activation.nodeID, "research")
    }

    func testPrepareNodeActivationAppendsUnreferencedState() {
        let node = WorkflowNode(id: "n1", agentID: "a1", prompt: "Do work on {{state.task}}")
        let state: [String: AnyCodable] = ["task": .string("build"), "context": .string("extra info")]
        let runner = WorkflowNodeRunner()

        let activation = runner.prepareActivation(node: node, state: state, executionID: "exec-1")

        XCTAssertTrue(activation.resolvedPrompt.contains("Do work on build"))
        XCTAssertTrue(activation.resolvedPrompt.contains("--- Workflow Context ---"))
        XCTAssertTrue(activation.resolvedPrompt.contains("extra info"))
    }

    func testEffectiveToolScopeWithOverride() {
        let node = WorkflowNode(
            id: "n1", agentID: "a1", prompt: "p",
            toolScopeOverride: ToolScopeHint(allowed: ["Read", "Write"], denied: ["Bash"])
        )
        let profileScope = ProfileToolScope(
            allowed: ["Read", "Write", "Bash", "Edit"],
            denied: [],
            policyVersion: "1"
        )
        let runner = WorkflowNodeRunner()

        let effective = runner.computeEffectiveScope(node: node, profileScope: profileScope)

        XCTAssertTrue(effective.contains("Read"))
        XCTAssertTrue(effective.contains("Write"))
        XCTAssertFalse(effective.contains("Bash"))
        XCTAssertFalse(effective.contains("Edit"))
    }

    func testMaxTurnsExceededReturnsTimedOut() {
        let runner = WorkflowNodeRunner()
        let result = runner.checkCircuitBreaker(turnsElapsed: 11, maxTurns: 10, elapsedSeconds: 5, timeoutSeconds: nil)
        XCTAssertEqual(result, .maxTurnsExceeded)
    }

    func testTimeoutExceededReturnsTimedOut() {
        let runner = WorkflowNodeRunner()
        let result = runner.checkCircuitBreaker(turnsElapsed: 3, maxTurns: nil, elapsedSeconds: 301, timeoutSeconds: 300)
        XCTAssertEqual(result, .timeoutExceeded)
    }

    func testNoCircuitBreakerTriggered() {
        let runner = WorkflowNodeRunner()
        let result = runner.checkCircuitBreaker(turnsElapsed: 5, maxTurns: 10, elapsedSeconds: 100, timeoutSeconds: 300)
        XCTAssertNil(result)
    }
}
