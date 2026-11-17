import Foundation

/// What a numbered attempt was decided to be, handed to whoever is waiting for
/// it at the moment it is decided.
///
/// A caller that asks for something to start and then has to answer for it
/// cannot read the answer off a flag after a wait: the wait is a guess about
/// how long deciding takes, and whenever the guess is short the caller answers
/// "don't know". This is the alternative. The caller notes the last attempt
/// number it has seen, asks, and suspends in `decision(afterAttempt:)`; the
/// code that decides calls `decide(attempt:_:)` and every waiter that was owed
/// that attempt is resumed with it. Nothing here reads a clock, so there is no
/// window to run out of — a waiter is resumed when there is a decision, and
/// not before.
///
/// Each attempt is decided once: a second decision for an attempt already
/// decided (or an earlier one) is dropped, so the first thing known about an
/// attempt is the answer every waiter gets.
@MainActor
package final class AttemptDecisions<Decision: Sendable> {

    private struct Waiter {
        let afterAttempt: Int
        let continuation: CheckedContinuation<Decision, Never>
    }

    private var latest: (attempt: Int, decision: Decision)?
    private var waiters: [Waiter] = []

    package init() {}

    /// The newest attempt that has a decision, or 0 when none has.
    package var decidedAttempt: Int { latest?.attempt ?? 0 }

    /// How many callers are suspended waiting for a decision.
    package var waiterCount: Int { waiters.count }

    /// Records the decision for `attempt` and resumes everyone it answers.
    ///
    /// - Returns: `false` when `attempt` was already decided, in which case
    ///   nothing changed.
    @discardableResult
    package func decide(attempt: Int, _ decision: Decision) -> Bool {
        guard attempt > decidedAttempt else { return false }
        latest = (attempt, decision)
        let answered = waiters.filter { $0.afterAttempt < attempt }
        waiters.removeAll { $0.afterAttempt < attempt }
        for waiter in answered { waiter.continuation.resume(returning: decision) }
        return true
    }

    /// The decision for the first attempt past `afterAttempt` — at once when
    /// it is already known, otherwise when it is made.
    ///
    /// Called from the main actor it registers before it suspends, so a
    /// caller that asks first and starts the attempt second cannot miss the
    /// decision.
    package func decision(afterAttempt: Int) async -> Decision {
        if let latest, latest.attempt > afterAttempt { return latest.decision }
        return await withCheckedContinuation { continuation in
            waiters.append(Waiter(afterAttempt: afterAttempt, continuation: continuation))
        }
    }
}
