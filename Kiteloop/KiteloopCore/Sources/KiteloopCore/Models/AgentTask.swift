import Foundation

package struct AgentTask: Identifiable, Codable {
    package let id: String
    package var subject: String
    package var description: String
    package var status: TaskStatus
    package var agentID: String
    package var createdAt: Date
    package var updatedAt: Date

    /// The memberwise init, spelled out: a `package` struct's synthesised one
    /// is internal to the package, and the app constructs this.
    package init(id: String, subject: String, description: String, status: TaskStatus,
                 agentID: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.subject = subject
        self.description = description
        self.status = status
        self.agentID = agentID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    package enum TaskStatus: String, Codable {
        case pending
        case inProgress = "in_progress"
        case completed
    }
}
