import XCTest
import KiteloopCore
@testable import Kiteloop

final class WorkflowEventBridgeTests: XCTestCase {

    private func makeEventBus() -> EventBus {
        let url = FileManager.default.temporaryDirectory.appending(path: "bridge-test-\(UUID()).jsonl")
        return EventBus(eventsURL: url)
    }

    func testPublishesWorkflowStarted() async {
        let bus = makeEventBus()
        let bridge = WorkflowEventBridge(eventBus: bus)

        let stream = await bus.subscribe(agentID: "observer", types: [.workflowStarted])
        await bridge.workflowStarted(executionID: "exec-1", graphID: "graph-1")

        var received: KiteloopEvent?
        for await event in stream {
            received = event
            break
        }

        XCTAssertEqual(received?.type, .workflowStarted)
        XCTAssertEqual(received?.payload["executionID"], "exec-1")
        XCTAssertEqual(received?.payload["graphID"], "graph-1")
    }

    func testPublishesWorkflowTransitioned() async {
        let bus = makeEventBus()
        let bridge = WorkflowEventBridge(eventBus: bus)

        let stream = await bus.subscribe(agentID: "observer", types: [.workflowTransitioned])
        await bridge.workflowTransitioned(executionID: "exec-1", from: "nodeA", to: "nodeB")

        var received: KiteloopEvent?
        for await event in stream {
            received = event
            break
        }

        XCTAssertEqual(received?.type, .workflowTransitioned)
        XCTAssertEqual(received?.payload["from"], "nodeA")
        XCTAssertEqual(received?.payload["to"], "nodeB")
    }

    func testPublishesWorkflowCompleted() async {
        let bus = makeEventBus()
        let bridge = WorkflowEventBridge(eventBus: bus)

        let stream = await bus.subscribe(agentID: "observer", types: [.workflowCompleted])
        await bridge.workflowCompleted(executionID: "exec-1", graphID: "graph-1")

        var received: KiteloopEvent?
        for await event in stream {
            received = event
            break
        }

        XCTAssertEqual(received?.type, .workflowCompleted)
        XCTAssertEqual(received?.payload["executionID"], "exec-1")
    }

    func testPublishesWorkflowFailed() async {
        let bus = makeEventBus()
        let bridge = WorkflowEventBridge(eventBus: bus)

        let stream = await bus.subscribe(agentID: "observer", types: [.workflowFailed])
        await bridge.workflowFailed(executionID: "exec-1", reason: "no matching edge")

        var received: KiteloopEvent?
        for await event in stream {
            received = event
            break
        }

        XCTAssertEqual(received?.type, .workflowFailed)
        XCTAssertEqual(received?.payload["reason"], "no matching edge")
    }

    func testPublishesApprovalRequired() async {
        let bus = makeEventBus()
        let bridge = WorkflowEventBridge(eventBus: bus)

        let stream = await bus.subscribe(agentID: "observer", types: [.workflowApprovalRequired])
        await bridge.workflowApprovalRequired(executionID: "exec-1", question: "Deploy?", nodeID: "deploy")

        var received: KiteloopEvent?
        for await event in stream {
            received = event
            break
        }

        XCTAssertEqual(received?.type, .workflowApprovalRequired)
        XCTAssertEqual(received?.payload["question"], "Deploy?")
        XCTAssertEqual(received?.payload["nodeID"], "deploy")
    }

    func testPublishesApprovalResolved() async {
        let bus = makeEventBus()
        let bridge = WorkflowEventBridge(eventBus: bus)

        let stream = await bus.subscribe(agentID: "observer", types: [.workflowApprovalResolved])
        await bridge.workflowApprovalResolved(executionID: "exec-1", approved: true, reason: "LGTM")

        var received: KiteloopEvent?
        for await event in stream {
            received = event
            break
        }

        XCTAssertEqual(received?.type, .workflowApprovalResolved)
        XCTAssertEqual(received?.payload["approved"], "true")
        XCTAssertEqual(received?.payload["reason"], "LGTM")
    }
}
