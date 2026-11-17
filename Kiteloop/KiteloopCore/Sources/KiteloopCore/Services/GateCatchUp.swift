import Foundation

/// What a gate-refresh round does when the base moved again while the round
/// was running: the branch the worker just rebased reads behind once more,
/// though nothing about it was refused. Rather than leave the item at the
/// approval gate for a person, the app merges the base into the branch itself
/// — a mechanical merge, no worker turn — and asks again, at most `limit`
/// times. A merge that does not go cleanly, or a base that is still ahead
/// after the last merge, ends the catch-up with the reason; the round then
/// fails exactly as it did before there was a catch-up.
///
/// Pure: staleness and the merge are the caller's closures, so the loop's
/// bound and its three endings are asserted without a repository.
package enum GateCatchUp {

    /// How the catch-up ended.
    package enum Result: Equatable, Sendable {
        /// The branch contains the base. `merges` is how many catch-up merges
        /// it took — zero when the round itself left the branch fresh.
        case caughtUp(merges: Int)
        /// A catch-up merge did not go cleanly and was abandoned.
        case conflicted
        /// The branch is still behind after `merges` catch-up merges — the
        /// bound was reached, or it was zero and none was allowed.
        case stillBehind(merges: Int)
    }

    /// Merges the base in while the branch reads stale, up to `limit` times.
    /// `mergeBase` answers whether its merge went cleanly.
    package static func run(
        limit: Int,
        isStale: @Sendable () async -> Bool,
        mergeBase: @Sendable () async -> Bool
    ) async -> Result {
        var merges = 0
        while await isStale() {
            guard merges < limit else { return .stillBehind(merges: merges) }
            guard await mergeBase() else { return .conflicted }
            merges += 1
        }
        return .caughtUp(merges: merges)
    }

    /// The note a round that could not catch up fails with, and `nil` when it
    /// did. A catch-up that was never allowed a merge keeps the wording the
    /// round had before there was one.
    package static func failureNote(for result: Result, branch: String, base: String) -> String? {
        switch result {
        case .caughtUp:
            return nil
        case .conflicted:
            return "merging \(base) into \(branch) conflicted after the base moved during the round"
        case .stillBehind(let merges) where merges == 0:
            return "\(branch) is still behind \(base) after the round"
        case .stillBehind(let merges):
            return "\(branch) is still behind \(base) after \(merges) catch-up "
                + (merges == 1 ? "merge" : "merges") + " — the base keeps moving"
        }
    }
}
