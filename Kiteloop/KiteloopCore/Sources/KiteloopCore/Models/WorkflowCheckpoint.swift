import Foundation

package struct WorkflowCheckpoint: Codable, Identifiable, Sendable {
    package let id: String
    package let executionID: String
    package let graphSnapshot: WorkflowGraph
    package let executionSnapshot: WorkflowExecution
    package let checkpointedAt: Date
    package let reason: CheckpointReason
    package let graphName: String
    package let traceID: String

    package init(
        id: String = UUID().uuidString,
        executionID: String,
        graphSnapshot: WorkflowGraph,
        executionSnapshot: WorkflowExecution,
        checkpointedAt: Date = Date(),
        reason: CheckpointReason,
        graphName: String? = nil,
        traceID: String? = nil
    ) {
        self.id = id
        self.executionID = executionID
        self.graphSnapshot = graphSnapshot
        self.executionSnapshot = executionSnapshot
        self.checkpointedAt = checkpointedAt
        self.reason = reason
        self.graphName = graphName ?? graphSnapshot.name
        self.traceID = traceID ?? executionSnapshot.traceID
    }
}

extension WorkflowCheckpoint {
    /// True when the execution behind this checkpoint can no longer make
    /// progress: either its status is terminal, or it is parked on a node the
    /// graph declares terminal (autopilot's `done` and `blocked`). Resuming
    /// either would continue nothing, so a settled execution is never offered
    /// in the resume prompt — and is exactly what pruning may remove.
    package var isSettled: Bool {
        executionSnapshot.status.isTerminal
            || graphSnapshot.terminalNodes.contains(executionSnapshot.currentNode)
    }
}

package enum CheckpointReason: String, Codable, Sendable {
    case started
    case nodeTransition
    case paused
    case completed
    case failed
    case cancelled
}
