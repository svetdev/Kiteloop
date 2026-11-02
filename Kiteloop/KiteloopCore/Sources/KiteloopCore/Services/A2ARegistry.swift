import Foundation

@MainActor @Observable
package final class A2ARegistry {
    package private(set) var messageLog: [A2AMessage] = []
    package private(set) var responseLog: [A2AResponse] = []

    private let maxLogEntries = 200

    // MARK: - Message Recording

    package func record(message: A2AMessage) {
        messageLog.append(message)
        if messageLog.count > maxLogEntries {
            messageLog.removeFirst(messageLog.count - maxLogEntries)
        }
    }

    package func record(response: A2AResponse) {
        responseLog.append(response)
        if responseLog.count > maxLogEntries {
            responseLog.removeFirst(responseLog.count - maxLogEntries)
        }
    }

    // MARK: - Query

    package func history(between senderID: String, and targetID: String, limit: Int = 20) -> [A2AMessage] {
        messageLog.filter { msg in
            (msg.sender.id == senderID && msg.target.id == targetID) ||
            (msg.sender.id == targetID && msg.target.id == senderID)
        }.suffix(limit).reversed()
    }

    package func recentMessages(for agentID: String, limit: Int = 10) -> [A2AMessage] {
        messageLog.filter { $0.sender.id == agentID || $0.target.id == agentID }
            .suffix(limit)
            .reversed()
    }

    package func response(for messageID: String) -> A2AResponse? {
        responseLog.first { $0.messageID == messageID }
    }

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(messageLog: [A2AMessage] = [], responseLog: [A2AResponse] = []) {
        self.messageLog = messageLog
        self.responseLog = responseLog
    }
}
