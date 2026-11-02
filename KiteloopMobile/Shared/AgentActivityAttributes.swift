import ActivityKit
import Foundation

/// A turn you started from the phone, on the lock screen and in the Dynamic
/// Island. The app updates it while it is open; the Mac moves it on with
/// live-activity pushes (`APNs.liveActivityPayload`) while the phone sleeps —
/// the `ContentState` keys are the ones that payload carries.
struct AgentActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Whether the agent's turn is still running.
        var working: Bool
        /// One line on where the turn is: "Working", "Waiting for your answer", "Done".
        var status: String
        /// The newest thing the agent said or did.
        var line: String
    }

    var agentName: String
    var project: String
}
