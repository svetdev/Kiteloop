import Foundation

package struct ChatSession: Identifiable, Codable, Equatable {
    package let id: UUID
    package let agentID: String
    package let createdAt: Date
    package var title: String
    package var lastMessageAt: Date
    package var messageCount: Int
    package var claudeSessionID: String?
    /// The message typed into this chat and not yet sent; nil when the input
    /// is empty. Absent from an index written before drafts were kept.
    package var draft: String?

    package var isUntitled: Bool { title.isEmpty || title == "New Chat" }

    package init(agentID: String, title: String = "New Chat") {
        self.id = UUID()
        self.agentID = agentID
        self.createdAt = .now
        self.title = title
        self.lastMessageAt = .now
        self.messageCount = 0
        self.claudeSessionID = nil
    }


    private init(id: UUID, agentID: String, createdAt: Date, title: String, lastMessageAt: Date, messageCount: Int, claudeSessionID: String?, draft: String?) {
        self.id = id
        self.agentID = agentID
        self.createdAt = createdAt
        self.title = title
        self.lastMessageAt = lastMessageAt
        self.messageCount = messageCount
        self.claudeSessionID = claudeSessionID
        self.draft = draft
    }
}
