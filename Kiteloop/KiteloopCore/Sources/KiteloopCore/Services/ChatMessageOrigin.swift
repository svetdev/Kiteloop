import Foundation

/// Where the text an agent is sent came from. A chat runs what it is sent as
/// typed — slash commands included — so the commands that only a person may
/// give are decided on this, and so is who may start an agent the person
/// stopped (`StoppedAgents`).
package enum ChatMessageOrigin: Equatable, Sendable {
    /// The person: the app's input box, a card they answered, or a message
    /// sent with their own control token or from a paired phone.
    case person
    /// A routine's prompt, whatever fired it — its schedule, a webhook, an
    /// event, a watched folder, or Run now from the app or any token.
    case routine
    /// Text the app's own machinery sends: a workflow node's prompt, or an
    /// event the agent subscribes to.
    case automation
    /// Another agent on the team: `message_agent`, a broadcast, a `/delegate`
    /// hand-over or a debate turn.
    case teammate

    /// The key an `.agentSummoned` notification carries the origin under, so
    /// a specialist summoned by a message is sent it on that message's terms.
    package static let notificationKey = "messageOrigin"

    /// How a refusal names the sender.
    private var sender: String {
        switch self {
        case .person: return "you"
        case .routine: return "a routine"
        case .automation: return "a workflow or an event"
        case .teammate: return "another agent"
        }
    }

    /// Why `text` is not run as a command when it comes from here, or nil
    /// when it is. `/mode <name>` moves the agent to another permission mode,
    /// which decides whether it asks before acting at all, so it is run only
    /// for the person; bare `/mode` only reports the mode and runs for anyone.
    /// No other chat command loosens a guard.
    package func commandRefusal(of text: String) -> String? {
        guard self != .person, ControlAccess.switchesPermissionMode(text) else { return nil }
        return "A permission-mode change needs you: this `/mode` command came from \(sender), so it was not run. "
            + "Type it in this chat yourself."
    }
}
