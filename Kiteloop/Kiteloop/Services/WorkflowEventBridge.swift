import Foundation
import KiteloopCore

final class WorkflowEventBridge: Sendable {
    private let eventBus: EventBusProtocol

    init(eventBus: EventBusProtocol) {
        self.eventBus = eventBus
    }

    func workflowStarted(executionID: String, graphID: String) async {
        let event = KiteloopEvent(
            source: "WorkflowEngine",
            type: .workflowStarted,
            payload: ["executionID": executionID, "graphID": graphID]
        )
        await eventBus.publish(event)
    }

    func workflowTransitioned(executionID: String, from: String, to: String) async {
        let event = KiteloopEvent(
            source: "WorkflowEngine",
            type: .workflowTransitioned,
            payload: ["executionID": executionID, "from": from, "to": to]
        )
        await eventBus.publish(event)
    }

    func workflowCompleted(executionID: String, graphID: String) async {
        let event = KiteloopEvent(
            source: "WorkflowEngine",
            type: .workflowCompleted,
            payload: ["executionID": executionID, "graphID": graphID]
        )
        await eventBus.publish(event)
    }

    func workflowFailed(executionID: String, reason: String) async {
        let event = KiteloopEvent(
            source: "WorkflowEngine",
            type: .workflowFailed,
            payload: ["executionID": executionID, "reason": reason]
        )
        await eventBus.publish(event)
    }

    func workflowCancelled(executionID: String) async {
        let event = KiteloopEvent(
            source: "WorkflowEngine",
            type: .workflowCancelled,
            payload: ["executionID": executionID]
        )
        await eventBus.publish(event)
    }

    func workflowApprovalRequired(executionID: String, question: String, nodeID: String) async {
        let event = KiteloopEvent(
            source: "WorkflowEngine",
            type: .workflowApprovalRequired,
            payload: ["executionID": executionID, "question": question, "nodeID": nodeID]
        )
        await eventBus.publish(event)
    }

    func workflowApprovalResolved(executionID: String, approved: Bool, reason: String?) async {
        var payload = ["executionID": executionID, "approved": String(approved)]
        if let reason { payload["reason"] = reason }
        let event = KiteloopEvent(
            source: "WorkflowEngine",
            type: .workflowApprovalResolved,
            payload: payload
        )
        await eventBus.publish(event)
    }
}

// MARK: - Inbound Bridge (KiteloopEvent → WorkflowEngine)

extension WorkflowEventBridge {
    func startInboundBridge(engine: WorkflowEngine) async {
        let allTypes = Set(KiteloopEvent.EventType.allCases.filter { !$0.rawValue.hasPrefix("workflow_") })
        let stream = await eventBus.subscribe(agentID: "_workflow_bridge", types: allTypes)

        Task {
            for await kiteloopEvent in stream {
                await self.routeInboundEvent(kiteloopEvent, engine: engine)
            }
        }
    }

    private func routeInboundEvent(_ event: KiteloopEvent, engine: WorkflowEngine) async {
        let mode = await engine.routingMode(for: event.source)
        guard case .graphControlled(let execID) = mode else { return }
        guard let execution = await engine.execution(id: execID) else { return }

        var output: [String: AnyCodable] = [:]
        for (key, value) in event.payload {
            output[key] = .string(value)
        }
        output["_eventType"] = .string(event.type.rawValue)

        let workflowEvent = WorkflowEvent(
            executionID: execID,
            nodeID: execution.currentNode,
            agentID: event.source,
            type: .eventEmitted,
            output: output
        )
        _ = try? await engine.handleEvent(workflowEvent)
    }
}
