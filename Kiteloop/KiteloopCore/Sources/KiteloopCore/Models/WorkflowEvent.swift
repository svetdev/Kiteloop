import Foundation

package struct WorkflowEvent: Sendable {
    package let executionID: String
    package let nodeID: WorkflowGraph.NodeID
    package let agentID: String
    package let type: WorkflowEventType
    package let output: [String: AnyCodable]?

    package init(
        executionID: String,
        nodeID: WorkflowGraph.NodeID,
        agentID: String,
        type: WorkflowEventType,
        output: [String: AnyCodable]? = nil
    ) {
        self.executionID = executionID
        self.nodeID = nodeID
        self.agentID = agentID
        self.type = type
        self.output = output
    }
}

package enum WorkflowEventType: String, Sendable {
    case nodeCompleted
    case nodeFailed
    case eventEmitted
    case timedOut
    case subWorkflowCompleted
}

package enum TransitionResult: Sendable {
    case transitioned(toNode: WorkflowGraph.NodeID)
    case awaitingApproval(question: String, edgeID: Int)
    case noMatchingEdge
    case terminal
}
