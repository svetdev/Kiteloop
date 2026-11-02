import Foundation

/// How many Agent-tool launches each agent's current turn made that haven't
/// reported back yet — set by `ChatViewModel` as it tracks its own turn (see
/// `PendingAgentLaunch`), read by the autopilot's stall watchdog so a
/// deferred hand-off can say why it is still waiting.
///
/// A type of its own, held by `Orchestrator` as a single small property,
/// rather than the dictionary and its accessors living directly on
/// `Orchestrator` — that class's own file already carries more than the
/// complexity ratchet's baseline recorded on adoption day, and one more
/// property line there fails it; this file's accessors change nothing there.
final class PendingAgentLaunchTracker {
    private var counts: [String: Int] = [:]

    func set(_ count: Int, for agentID: String) {
        if count > 0 {
            counts[agentID] = count
        } else {
            counts.removeValue(forKey: agentID)
        }
    }

    /// Zero for an agent nobody launched a background agent for, which is
    /// every agent outside this one turn shape.
    func count(for agentID: String) -> Int {
        counts[agentID] ?? 0
    }
}

extension Orchestrator {
    func setPendingBackgroundAgentCount(_ count: Int, for agentID: String) {
        pendingAgentLaunches.set(count, for: agentID)
    }

    func pendingBackgroundAgentCount(for agentID: String) -> Int {
        pendingAgentLaunches.count(for: agentID)
    }
}
