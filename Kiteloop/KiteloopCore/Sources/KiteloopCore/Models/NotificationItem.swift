import Foundation

package struct NotificationItem: Codable, Identifiable, Sendable {
    package let id: String
    package let timestamp: Date
    package let agentID: String
    package let type: NotificationType
    package let title: String
    package let body: String
    package var status: Status
    package var resolvedAt: Date?
    /// Why this notice stopped needing a human, when something other than a
    /// click ended it: "approved via API", "auto-approved", "the item is no
    /// longer at the approval gate". Nil for a row a person resolved by hand —
    /// they know what they did — and for one still pending.
    package var resolution: String?
    /// The live state this notice is a view of, when it is one. Two notices
    /// sharing a key are two readings of the same thing, so filing the newer
    /// resolves the older: an autopilot run driving twenty turns in a background
    /// project leaves one "finished" row rather than twenty.
    ///
    /// Nil for a notice that reports an event rather than a state — a person
    /// asked an agent something and the agent answered, and each answer is its
    /// own row.
    package var rollUpKey: String?
    /// The backlog item this notice is about, when it is about one. Carried as a
    /// field rather than left inside `body`'s prose so the row can open the
    /// item's page: an approval gate names the item that is waiting, and reading
    /// the id back out of a sentence is guesswork.
    ///
    /// Optional, and written by `Codable` synthesis — a notification recorded
    /// before this existed decodes with both nil and simply doesn't link.
    package var itemID: String?
    /// The project that item lives in, by root path.
    package var projectPath: String?

    package enum NotificationType: String, Codable, Sendable {
        case approval
        case question
        case complete
        case error
        case event

        /// Whether a human has to *do* something about it. Actionable types go
        /// to the badged inbox; the rest are ambient activity — useful to watch
        /// while a run is going, but they must never compete with a blocked
        /// agent for attention.
        package var isActionable: Bool {
            switch self {
            case .approval, .question, .error: return true
            case .complete, .event: return false
            }
        }
    }

    package enum Status: String, Codable, Sendable {
        case pending
        case resolved
        case dismissed
    }

    package var isActionable: Bool { type.isActionable }

    /// The roll-up key for the "agents finished" notice a project posts while
    /// autopilot is driving it. One live row per project, replaced by the next.
    package static func runFinishedRollUpKey(projectID: String) -> String {
        "run-finished|\(projectID)"
    }

    package init(agentID: String, type: NotificationType, title: String, body: String,
         itemID: String? = nil, projectPath: String? = nil, rollUpKey: String? = nil) {
        self.id = UUID().uuidString
        self.timestamp = Date()
        self.agentID = agentID
        self.type = type
        self.title = title
        self.body = body
        self.status = .pending
        self.resolvedAt = nil
        self.itemID = itemID
        self.projectPath = projectPath
        self.rollUpKey = rollUpKey
    }
}

/// Why an item's approval notice resolved itself — the sentence the row carries
/// once the gate behind it has closed.
///
/// An approval notice is not a record that something happened; it is the gate,
/// shown somewhere else. So it has no business outliving the gate, and when it
/// does resolve it has to say which surface closed it: "done" and "somebody
/// approved this over the API while you were asleep" are different mornings.
package enum GateClosure: String, Codable, Sendable, CaseIterable {
    /// A person approved it in the app — the item page, the fleet view, the panel.
    case approved
    /// A caller approved it over the control API.
    case approvedViaAPI
    /// `approveReviewPassedRuns` cleared the gate with nobody looking.
    case autoApproved
    /// Sent back for rework, from whichever surface.
    case rejected
    /// Nobody resolved this one while the app was running: the backfill found the
    /// item no longer at the gate when the project next loaded.
    case noLongerAtTheGate
    /// A newer reading of the same live state replaced this one.
    case superseded
    /// The question this notice raised was answered in the chat.
    case answered

    package var reason: String {
        switch self {
        case .approved: return "approved"
        case .approvedViaAPI: return "approved via API"
        case .autoApproved: return "auto-approved"
        case .rejected: return "rejected"
        case .noLongerAtTheGate: return "the item is no longer at the approval gate"
        case .superseded: return "replaced by a newer notice"
        case .answered: return "answered"
        }
    }
}
