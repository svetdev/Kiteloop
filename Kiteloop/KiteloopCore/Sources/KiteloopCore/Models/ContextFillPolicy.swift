import Foundation

/// When an agent compacts itself as its context fills: once the window is at
/// or past a share the person chose. Reads the one `ContextOccupancy` figure
/// the chat header and `/context` read, never a second one.
package struct ContextFillPolicy: Equatable, Sendable {
    /// The lowest and highest threshold a person can set.
    package static let thresholdRange = 50...95

    /// The share of the window, 50–95, at which the agent compacts.
    package let thresholdPercent: Int

    /// A threshold outside 50–95 is clamped into it.
    package init(thresholdPercent: Int) {
        self.thresholdPercent = min(max(thresholdPercent, Self.thresholdRange.lowerBound), Self.thresholdRange.upperBound)
    }

    /// Whether to compact now: only while `armed` — one crossing compacts
    /// once — and only when the window's size is known and the occupancy is
    /// at or above the threshold.
    package func shouldCompact(_ occupancy: ContextOccupancy, armed: Bool) -> Bool {
        guard armed, let percent = occupancy.percent else { return false }
        return percent >= Double(thresholdPercent)
    }
}
