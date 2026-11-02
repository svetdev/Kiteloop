import Foundation

package struct WorkflowExecution: Codable, Identifiable, Sendable {
    package let id: String
    package let graphID: String
    package let graphVersion: Int
    package let traceID: String
    package var currentNode: WorkflowGraph.NodeID
    package var status: ExecutionStatus
    package var state: [String: AnyCodable]
    package var steps: [ExecutionStep]
    package let startedAt: Date
    package var lastCheckpointID: String?

    // Cost attribution
    package var totalCostUSD: Double?
    package var costByAgent: [String: Double]?

    // Sub-workflow linkage (nil for top-level executions)
    package let parentExecutionID: String?
    package let parentNodeID: WorkflowGraph.NodeID?

    package init(
        id: String,
        graphID: String,
        graphVersion: Int = 1,
        traceID: String = OTelIDs.newTraceID(),
        currentNode: WorkflowGraph.NodeID,
        status: ExecutionStatus,
        state: [String: AnyCodable],
        steps: [ExecutionStep] = [],
        startedAt: Date = Date(),
        lastCheckpointID: String? = nil,
        totalCostUSD: Double? = nil,
        costByAgent: [String: Double]? = nil,
        parentExecutionID: String? = nil,
        parentNodeID: WorkflowGraph.NodeID? = nil
    ) {
        self.id = id
        self.graphID = graphID
        self.graphVersion = graphVersion
        self.traceID = traceID
        self.currentNode = currentNode
        self.status = status
        self.state = state
        self.steps = steps
        self.startedAt = startedAt
        self.lastCheckpointID = lastCheckpointID
        self.totalCostUSD = totalCostUSD
        self.costByAgent = costByAgent
        self.parentExecutionID = parentExecutionID
        self.parentNodeID = parentNodeID
    }
}

package enum ExecutionStatus: String, Codable, Sendable, CaseIterable {
    case pending
    case running
    case paused
    case awaitingApproval
    case completed
    case failed
    case cancelled
    case timedOut

    /// True once the execution has settled and can no longer make progress.
    /// Terminal executions are never resumed from a checkpoint and never hold
    /// agent reservations.
    package var isTerminal: Bool {
        switch self {
        case .pending, .running, .paused, .awaitingApproval: return false
        case .completed, .failed, .cancelled, .timedOut: return true
        }
    }
}

package struct ExecutionStep: Codable, Sendable {
    package let nodeID: WorkflowGraph.NodeID
    package let agentID: String?
    package let spanID: String?
    package let startedAt: Date
    package var completedAt: Date?
    package var output: [String: AnyCodable]?
    package var transitionEdge: String?

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(nodeID: WorkflowGraph.NodeID, agentID: String?, spanID: String?, startedAt: Date, completedAt: Date? = nil, output: [String: AnyCodable]? = nil, transitionEdge: String? = nil) {
        self.nodeID = nodeID
        self.agentID = agentID
        self.spanID = spanID
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.output = output
        self.transitionEdge = transitionEdge
    }
}
