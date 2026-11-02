import Foundation

/// The gate on *arming* autonomy: turning unattended work or grooming on is a
/// deliberate act that requires the configuration it will spend against.
///
/// Off-by-default is only half the principle. The other half lives here: a
/// switch that would arm against **no ceiling** is refused, naming what is
/// missing, instead of arming uncapped — which is how a fleet spent $531 in a
/// day against an intended $200 and its owner learned it from a ledger rather
/// than a control (2026-08-13).
///
/// One implementation, two callers: the Coordinator panel's toggles and the
/// control API's `PUT` handlers both ask here, so the refusal reads the same
/// on screen and over the wire. The gate applies to the act of arming only —
/// an install with a stored `true` is already armed and is not re-judged.
package enum AutonomyArming {

    /// Why arming was refused, in the words both surfaces show.
    package struct Refusal: Equatable, Sendable {
        /// The setting that has to exist first, e.g. "daily running budget".
        package let missing: String
        /// The full sentence a surface shows or returns.
        package let message: String

        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(missing: String, message: String) {
            self.missing = missing
            self.message = message
        }
    }

    /// May unattended work be switched on against this portfolio ceiling?
    /// Nil means yes; a `Refusal` names the budget that has to be set first.
    package static func armScheduling(dailyBudgetUSD: Double?) -> Refusal? {
        guard dailyBudgetUSD == nil else { return nil }
        return Refusal(
            missing: "daily autonomy budget",
            message: "Set the daily autonomy budget first — unattended runs "
                + "need a ceiling to stop at.")
    }

    /// May the grooming loop be switched on against this grooming ceiling?
    package static func armGrooming(dailyBudgetUSD: Double?) -> Refusal? {
        guard dailyBudgetUSD == nil else { return nil }
        return Refusal(
            missing: "daily autonomy budget",
            message: "Set the daily autonomy budget first — unattended "
                + "grooming needs a ceiling to stop at.")
    }
}
