import XCTest
import KiteloopCore
@testable import Kiteloop

final class WorkflowPhase2DIntegrationTests: XCTestCase {

    private func makeEventBus() -> EventBus {
        let url = FileManager.default.temporaryDirectory.appending(path: "phase2d-e2e-\(UUID()).jsonl")
        return EventBus(eventsURL: url)
    }

    func testFullQueueAndEventBridgeFlow() async throws {
        let bus = makeEventBus()
        let bridge = WorkflowEventBridge(eventBus: bus)
        let engine = WorkflowEngine(queueTimeout: 5.0, eventBridge: bridge)

        let graph = WorkflowGraph(
            id: "pipeline", name: "Pipeline", version: 1,
            nodes: [
                "start": WorkflowNode(id: "start", agentID: "worker", prompt: "Work"),
                "end": WorkflowNode(id: "end", agentID: "reviewer", prompt: "Review")
            ],
            edges: [WorkflowEdge(from: "start", to: "end", condition: .always)],
            entryNode: "start", terminalNodes: ["end"], metadata: .empty
        )
        await engine.register(graph: graph)

        // Subscribe an observer for lifecycle events
        // Appended on the collector's task, read back on the test's.
        let receivedEvents = EventRecorder()
        let lifecycleTypes: Set<KiteloopEvent.EventType> = [.workflowStarted, .workflowTransitioned, .workflowCompleted]
        let stream = await bus.subscribe(agentID: "lifecycle-observer", types: lifecycleTypes)
        let collectTask = Task {
            for await event in stream {
                receivedEvents.record(event.type)
                if event.type == .workflowCompleted { break }
            }
        }

        // Start first execution
        let exec1 = try await engine.start(graphID: "pipeline", initialState: [:])

        // Start second (overlapping) — queues
        let queuedTask = Task<String, Error> {
            try await engine.start(graphID: "pipeline", initialState: [:])
        }

        try await Task.sleep(for: .milliseconds(50))

        // Complete first execution
        let ev1 = WorkflowEvent(executionID: exec1, nodeID: "start", agentID: "worker", type: .nodeCompleted)
        _ = try await engine.handleEvent(ev1)
        let ev2 = WorkflowEvent(executionID: exec1, nodeID: "end", agentID: "reviewer", type: .nodeCompleted)
        _ = try await engine.handleEvent(ev2)

        // Wait for lifecycle collection
        await collectTask.value

        // Verify lifecycle events received
        XCTAssertTrue(receivedEvents.values.contains(.workflowStarted))
        XCTAssertTrue(receivedEvents.values.contains(.workflowTransitioned))
        XCTAssertTrue(receivedEvents.values.contains(.workflowCompleted))

        // Second execution should have started after first completed
        let exec2 = try await queuedTask.value
        let execution2 = await engine.execution(id: exec2)
        XCTAssertEqual(execution2?.status, .running)
        XCTAssertEqual(execution2?.currentNode, "start")
    }

    func testEventDrivenTransitionViaEventBus() async throws {
        let bus = makeEventBus()
        let bridge = WorkflowEventBridge(eventBus: bus)
        let engine = WorkflowEngine(queueTimeout: 5.0, eventBridge: bridge)

        let graph = WorkflowGraph(
            id: "event-driven", name: "Event-Driven", version: 1,
            nodes: [
                "research": WorkflowNode(id: "research", agentID: "researcher", prompt: "Research"),
                "write": WorkflowNode(id: "write", agentID: "writer", prompt: "Write")
            ],
            edges: [WorkflowEdge(from: "research", to: "write", condition: .eventType("research_complete"))],
            entryNode: "research", terminalNodes: ["write"], metadata: .empty
        )
        await engine.register(graph: graph)
        let execID = try await engine.start(graphID: "event-driven", initialState: [:])

        // Start inbound bridge
        await bridge.startInboundBridge(engine: engine)

        // Simulate agent publishing event to bus
        let kiteloopEvent = KiteloopEvent(source: "researcher", type: .researchComplete, payload: ["findings": "important"])
        await bus.publish(kiteloopEvent)

        try await eventually("the bridge routed the event into a transition") {
            await engine.execution(id: execID)?.currentNode == "write"
        }

        // Verify the engine transitioned
        let execution = await engine.execution(id: execID)
        XCTAssertEqual(execution?.currentNode, "write")
        XCTAssertEqual(execution?.state["findings"]?.stringValue, "important")
    }

    private final class EventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [KiteloopEvent.EventType] = []

        func record(_ type: KiteloopEvent.EventType) {
            lock.lock(); defer { lock.unlock() }
            events.append(type)
        }

        var values: [KiteloopEvent.EventType] {
            lock.lock(); defer { lock.unlock() }
            return events
        }
    }

}
