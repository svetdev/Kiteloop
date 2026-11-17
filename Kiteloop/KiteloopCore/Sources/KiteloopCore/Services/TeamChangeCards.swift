import Foundation

/// The cards an agent's own `hire_agent` and `fire_agent` calls wait on
/// (`GlobalConfig.agentChangesNeedingApproval`): which messages are one, how a
/// card is marked with what became of it, and the line `ConfigChangeLog`
/// keeps of it.
package enum TeamChangeCards {

    /// Whether `request` is a team change's card rather than any other approval.
    package static func isTeamChange(_ request: Message.ApprovalRequest) -> Bool {
        request.tool == "hire_agent" || request.tool == "fire_agent"
    }

    /// Marks the card `cardID` with `status` and returns it as marked — nil
    /// when the chat holds no such card, as after it was cleared.
    @discardableResult
    package static func mark(_ cardID: String, _ status: Message.ApprovalRequest.ApprovalStatus,
                             in messages: inout [Message]) -> Message.ApprovalRequest? {
        for at in messages.indices.reversed() {
            guard case .approval(var request) = messages[at].content, request.id == cardID else { continue }
            request.status = status
            messages[at].content = .approval(request)
            return request
        }
        return nil
    }

    /// Marks every team change's card still pending as abandoned and returns
    /// them, oldest first. For a chat read back from disk: whatever call a
    /// card waited on belonged to a session that is gone, so none of them can
    /// be answered and each is owed its line in the log — once, which the
    /// mark is what ensures.
    package static func abandonPending(in messages: inout [Message]) -> [Message.ApprovalRequest] {
        var abandoned: [Message.ApprovalRequest] = []
        for at in messages.indices {
            guard case .approval(var request) = messages[at].content,
                  isTeamChange(request), request.status == .pending else { continue }
            request.status = .abandoned
            messages[at].content = .approval(request)
            abandoned.append(request)
        }
        return abandoned
    }

    /// The log's line for a change: who asked, the tool, the team before and
    /// the team asked for, the project it is in, and what was decided.
    package static func record(tool: String, before: String, after: String, requestedBy: String,
                               project: String, decision: ConfigChangeLog.Decision,
                               at: Date) -> ConfigChangeLog.Record {
        ConfigChangeLog.Record(requestedBy: requestedBy, kind: "team", tool: tool, before: before,
                               after: after, decision: decision, at: at, project: project)
    }
}
