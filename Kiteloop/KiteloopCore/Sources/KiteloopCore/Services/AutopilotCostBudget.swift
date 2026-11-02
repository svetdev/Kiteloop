import Foundation

/// Budget arithmetic for the autopilot's cost caps, kept free of the run loop so
/// the decisions ("is this item over its ceiling?", "is the session spent?") are
/// pure and unit-testable.
///
/// Two ceilings, with different consequences:
/// - **per-item** — the item's cap (`RunTimeouts.CostBound`), passed in; ends the current run (item → blocked), the session continues;
/// - **per-session** — pauses autopilot entirely, so the remaining queue is left
///   for a human to resume deliberately.
package struct AutopilotCostBudget: Sendable, Equatable {
    /// Ceiling for the whole autopilot session (USD); nil = no session cap.
    package var sessionCapUSD: Double?
    /// Cost already spent by this session (finished items).
    package var spentThisSession: Double = 0

    /// The memberwise init, spelled out: a `package` struct's synthesised one
    /// is internal to the package, and the app constructs this.
    package init(sessionCapUSD: Double? = nil, spentThisSession: Double = 0) {
        self.sessionCapUSD = sessionCapUSD
        self.spentThisSession = spentThisSession
    }

    package enum Breach: Equatable {
        case item(cap: Double, spent: Double)
        case session(cap: Double, spent: Double)
    }

    /// True when the session has no budget left to start another item.
    package var isSessionExhausted: Bool {
        guard let cap = sessionCapUSD else { return false }
        return spentThisSession >= cap
    }

    /// Evaluates an in-flight item that has spent `itemSpend` so far.
    ///
    /// The session cap outranks the item cap: one item blowing the session budget
    /// has to stop the whole run, not just itself, so the more severe breach is
    /// the one reported.
    package func breach(itemSpend: Double, itemCap: Double?) -> Breach? {
        if let cap = sessionCapUSD, spentThisSession + itemSpend > cap {
            return .session(cap: cap, spent: spentThisSession + itemSpend)
        }
        if let cap = itemCap, itemSpend > cap {
            return .item(cap: cap, spent: itemSpend)
        }
        return nil
    }
}
