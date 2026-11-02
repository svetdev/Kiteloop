import ActivityKit
import Foundation

/// The Live Activity for a turn sent from the phone: started with the message,
/// moved on by the chat's own stream while the app is open, and by the Mac's
/// pushes once it is not — which is why its push token goes to the Mac.
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    private var activities: [String: Activity<AgentActivityAttributes>] = [:]

    /// Starts the activity for `agentID`, unless one is already running for it.
    func start(agentID: String, agentName: String, project: String, client: ControlClient) {
        guard activities[agentID] == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = AgentActivityAttributes.ContentState(working: true, status: "Working", line: "")
        do {
            let activity = try Activity.request(
                attributes: AgentActivityAttributes(agentName: agentName, project: project),
                content: ActivityContent(state: state, staleDate: nil), pushType: .token)
            activities[agentID] = activity
            Task {
                for await token in activity.pushTokenUpdates {
                    _ = try? await client.post("/v1/devices/activity", [
                        "token": PushRegistration.hex(token), "environment": PushRegistration.environment,
                        "project": project, "agent": agentID,
                    ])
                }
            }
        } catch {
            // Live Activities switched off, or too many running: the chat still works.
        }
    }

    /// The state an event from the agent's stream implies; nil when it changes nothing.
    nonisolated static func state(after event: AgentEvent, current: AgentActivityAttributes.ContentState)
        -> AgentActivityAttributes.ContentState? {
        if let working = event.working, working != current.working {
            return .init(working: working, status: working ? "Working" : "Done", line: current.line)
        }
        guard let message = event.message, let text = message.text, !text.isEmpty else { return nil }
        switch message.kind {
        case "question": return .init(working: false, status: "Waiting for your answer", line: text)
        case "plan": return .init(working: false, status: "Plan ready for you", line: String(text.prefix(120)))
        case "text" where message.sender != "you", "tool":
            return .init(working: current.working, status: current.status, line: String(text.prefix(120)))
        default: return nil
        }
    }

    /// Applies an event from the open chat's stream; a finished turn ends the activity.
    func apply(_ event: AgentEvent, agentID: String) {
        guard let activity = activities[agentID],
              let next = Self.state(after: event, current: activity.content.state) else { return }
        let content = ActivityContent(state: next, staleDate: nil)
        let finished = next.status == "Done"
        if finished { activities[agentID] = nil }
        Task {
            if finished {
                await activity.end(content, dismissalPolicy: .after(.now.addingTimeInterval(15 * 60)))
            } else {
                await activity.update(content)
            }
        }
    }
}
