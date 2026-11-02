import Foundation

/// The bounded worker round that rebases a stale item sitting at the approval
/// gate — merging the base into the branch, resolving conflicts and re-running
/// the item's own `verify:` — without moving the item out of
/// `awaiting-approval` and without asking the reviewer to look again. The
/// merge carries no new intent, so the item's `verify:` is what stands in for
/// review on this round.
///
/// Pure: the prompt and the outcome an of one round are strings and an enum,
/// so they can be asserted without a repository or a running autopilot. How
/// many rounds an item gets and what retirement writes is `RetryCeiling`'s
/// job, not a second ledger — a failed round is recorded on the same
/// `TaskMetricRecord` history a pickup refusal is, under `failedOutcome`,
/// which is what lets `RetryCeiling.evaluate` count it and retire the item
/// with the note it already writes for every other kind of no-work streak.
enum GateRefresh {

    /// One round's outcome, once the worker has run and the branch has been
    /// re-checked.
    enum Outcome: Equatable {
        case fresh
        case failed(note: String)
    }

    /// The `TaskMetricRecord.outcome` a failed round is filed under —
    /// `did-not-run:` prefixed like a pickup refusal, because a refresh round
    /// is the same shape of fact: the item was attempted, nothing about its
    /// diff changed, and it left no execution for duration/cost averages to
    /// blend in. `RetryCeiling.evaluate` counts it anyway, the same way it
    /// counts a pickup refusal — through `changedFileCount == 0`, not through
    /// this string.
    static let failedOutcome = TaskMetricRecord.didNotRunPrefix + "gate-refresh-failed"

    /// The worker's whole instruction for one round. `base` is named, not
    /// assumed to be "main" — a project's default branch is whatever its
    /// checkout's `HEAD` names.
    static func prompt(base: String, branch: String, verify: String) -> String {
        var instruction = "merge \(base) into this branch, resolve every conflict keeping "
            + "both sides' intent, "
        instruction += verify.isEmpty
            ? "re-run the item's checks, "
            : "run the item's verify (`\(verify)`), "
        instruction += "commit; change nothing else."
        return instruction
    }
}
