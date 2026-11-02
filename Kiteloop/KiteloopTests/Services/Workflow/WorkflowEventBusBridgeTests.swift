import XCTest
import KiteloopCore
@testable import Kiteloop

final class WorkflowEventBusBridgeTests: XCTestCase {

    private func makeEventBus() -> EventBus {
        let url = FileManager.default.temporaryDirectory.appending(path: "inbound-bridge-\(UUID()).jsonl")
        return EventBus(eventsURL: url)
    }

    func testInboundEventTriggersTransition() async throws {
        let bus = makeEventBus()
        let bridge = WorkflowEventBridge(eventBus: bus)
        let engine = WorkflowEngine(queueTimeout: 5.0, eventBridge: bridge)

        let graph = WorkflowGraph(
            id: "event-graph", name: "Event-Driven", version: 1,
            nodes: [
                "research": WorkflowNode(id: "research", agentID: "researcher", prompt: "Research"),
                "write": WorkflowNode(id: "write", agentID: "writer", prompt: "Write")
            ],
            edges: [WorkflowEdge(from: "research", to: "write", condition: .eventType("research_complete"))],
            entryNode: "research", terminalNodes: ["write"], metadata: .empty
        )
        await engine.register(graph: graph)
        let execID = try await engine.start(graphID: "event-graph", initialState: [:])

        // Start the inbound listener
        await bridge.startInboundBridge(engine: engine)

        // Researcher publishes a KiteloopEvent
        let kiteloopEvent = KiteloopEvent(source: "researcher", type: .researchComplete, payload: ["summary": "findings"])
        await bus.publish(kiteloopEvent)

        // Give bridge time to process
        try await eventually("the bridge routed the event into a transition") {
            await engine.execution(id: execID)?.currentNode == "write"
        }

        let execution = await engine.execution(id: execID)
        XCTAssertEqual(execution?.currentNode, "write")
        XCTAssertEqual(execution?.status, .running)
    }

    func testNonMatchingEventDoesNotTransition() async throws {
        let bus = makeEventBus()
        let bridge = WorkflowEventBridge(eventBus: bus)
        let engine = WorkflowEngine(queueTimeout: 5.0, eventBridge: bridge)

        let graph = WorkflowGraph(
            id: "event-graph", name: "Event-Driven", version: 1,
            nodes: [
                "research": WorkflowNode(id: "research", agentID: "researcher", prompt: "Research"),
                "write": WorkflowNode(id: "write", agentID: "writer", prompt: "Write")
            ],
            edges: [WorkflowEdge(from: "research", to: "write", condition: .eventType("research_complete"))],
            entryNode: "research", terminalNodes: ["write"], metadata: .empty
        )
        await engine.register(graph: graph)
        let execID = try await engine.start(graphID: "event-graph", initialState: [:])

        await bridge.startInboundBridge(engine: engine)

        // Wrong event type
        let kiteloopEvent = KiteloopEvent(source: "researcher", type: .prReady, payload: [:])
        await bus.publish(kiteloopEvent)

        try await Task.sleep(for: .milliseconds(100))

        let execution = await engine.execution(id: execID)
        XCTAssertEqual(execution?.currentNode, "research") // Unchanged
    }

    func testInboundEventCarriesPayloadIntoState() async throws {
        let bus = makeEventBus()
        let bridge = WorkflowEventBridge(eventBus: bus)
        let engine = WorkflowEngine(queueTimeout: 5.0, eventBridge: bridge)

        let graph = WorkflowGraph(
            id: "event-graph", name: "Event-Driven", version: 1,
            nodes: [
                "research": WorkflowNode(id: "research", agentID: "researcher", prompt: "Research"),
                "write": WorkflowNode(id: "write", agentID: "writer", prompt: "Write")
            ],
            edges: [WorkflowEdge(from: "research", to: "write", condition: .eventType("research_complete"))],
            entryNode: "research", terminalNodes: ["write"], metadata: .empty
        )
        await engine.register(graph: graph)
        let execID = try await engine.start(graphID: "event-graph", initialState: [:])

        await bridge.startInboundBridge(engine: engine)

        let kiteloopEvent = KiteloopEvent(source: "researcher", type: .researchComplete, payload: ["summary": "key findings"])
        await bus.publish(kiteloopEvent)

        try await eventually("the payload landed in the execution state") {
            await engine.execution(id: execID)?.state["summary"]?.stringValue == "key findings"
        }

        let execution = await engine.execution(id: execID)
        XCTAssertEqual(execution?.state["summary"]?.stringValue, "key findings")
    }
}
