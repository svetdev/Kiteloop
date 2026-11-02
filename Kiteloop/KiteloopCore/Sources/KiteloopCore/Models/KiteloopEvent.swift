import Foundation

package struct KiteloopEvent: Codable, Identifiable, Sendable {
    package let id: String
    package let timestamp: Date
    package let source: String
    package let type: EventType
    package let payload: [String: String]
    package var deliveredTo: Set<String>

    package init(source: String, type: EventType, payload: [String: String] = [:]) {
        self.id = UUID().uuidString
        self.timestamp = Date()
        self.source = source
        self.type = type
        self.payload = payload
        self.deliveredTo = []
    }

    package enum EventType: String, Codable, Sendable, CaseIterable {
        case prReady = "pr_ready"
        case reviewComplete = "review_complete"
        case taskComplete = "task_complete"
        case memoryProposed = "memory_proposed"
        case error = "error"
        case custom = "custom"
        case researchComplete = "research_complete"
        case dataComplete = "data_complete"
        case prdComplete = "prd_complete"
        case wireframeComplete = "wireframe_complete"
        case engineeringComplete = "engineering_complete"
        case testComplete = "test_complete"
        case opsComplete = "ops_complete"
        case workflowStarted = "workflow_started"
        case workflowTransitioned = "workflow_transitioned"
        case workflowCompleted = "workflow_completed"
        case workflowFailed = "workflow_failed"
        case workflowCancelled = "workflow_cancelled"
        case workflowApprovalRequired = "workflow_approval_required"
        case workflowApprovalResolved = "workflow_approval_resolved"
        case workflowResumeOffered = "workflow_resume_offered"
        case workflowResumed = "workflow_resumed"
        case knowledgeRecalled = "knowledge_recalled"
        case agentCardGenerated = "agent_card_generated"
        case agentDiscovered = "agent_discovered"
        case templateReloaded = "template_reloaded"
    }
}
