import Foundation

/// Which open backlog items nothing has touched in a while — read-only, and
/// never more than a flag. Deletion, demotion and auto-archive are explicitly
/// not this: a flagged item does not move, and nothing here ever writes to
/// the backlog. Staleness surfaces; a human decides.
///
/// "Touched" is read from the backlog branch's own git history rather than
/// tracked separately — the last commit to reach the item's groomed detail
/// file (`backlog/<id>.md`) against the `.kiteloop/backlog-tree` checkout
/// `BacklogBranch` already owns. An item with no detail file yet, or whose
/// history can't be read, carries no signal and is left out rather than
/// guessed at — the same shape `ItemGitTruth` uses for "nobody could tell".
///
/// Split in two on purpose: `flag` is the pure judgment, so a case can state
/// "an old item, a fresh one, a done one" as three dates and be done; reading
/// those dates off git is the one impure step, kept in `lastTouched` alone.
package enum StaleItemSweep {

    /// How long an open item can sit with no commit touching its detail file
    /// before it is flagged. A constant rather than a setting: nobody has
    /// asked for a different number yet, and the day someone does is the day
    /// this grows a parameter.
    package static let window: TimeInterval = 28 * 24 * 60 * 60

    /// Stages this sweep does not judge — closed by design, not by neglect.
    /// `blocked` already says a human is expected to look; `done` is finished
    /// work. Both age exactly as long as they like.
    package static let openStatuses: Set<BacklogItemStatus> = [
        .draft, .ready, .active, .inReview, .awaitingApproval,
    ]

    /// One open item nothing has touched inside `window`.
    package struct FlaggedItem: Equatable, Sendable, Identifiable {
        package var id: String { itemID }
        package let itemID: String
        package let title: String
        package let status: BacklogItemStatus
        /// When git last saw a commit reach this item's detail file.
        package let lastTouched: Date

        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(itemID: String, title: String, status: BacklogItemStatus, lastTouched: Date) {
            self.itemID = itemID
            self.title = title
            self.status = status
            self.lastTouched = lastTouched
        }
    }

    /// The judgment: which open items' last touch falls outside `window`, as
    /// of `now`. Pure — no filesystem, no git — so it takes `lastTouched`
    /// exactly as a case states it and reads back exactly what the case
    /// expects.
    ///
    /// An item absent from `lastTouched` (no detail file, or an unreadable
    /// history) is skipped rather than treated as infinitely stale: this is a
    /// sweep for items nothing has touched *for a while*, not for items about
    /// which nothing is known.
    package static func flag(items: [BacklogItem], lastTouched: [String: Date], now: Date = Date()) -> [FlaggedItem] {
        items
            .filter { openStatuses.contains($0.status) }
            .compactMap { item -> FlaggedItem? in
                guard let touched = lastTouched[item.id], now.timeIntervalSince(touched) >= window else { return nil }
                return FlaggedItem(itemID: item.id, title: item.title, status: item.status, lastTouched: touched)
            }
    }

    /// Reads each open item's last touch off `checkout`'s own git history —
    /// the one impure half of the sweep. Only `git log`, read-only throughout;
    /// nothing here stages, commits or pushes.
    ///
    /// One call per open item that carries a detail path — gate items are the
    /// only place the sibling `freshnessByItemID` cache pays this cost per
    /// item too, and an open backlog is the same order of size.
    ///
    /// Cancellable between items: the caller that supersedes a sweep — a second
    /// backlog reload arriving while the first is still reading git — cancels
    /// the task this runs in, and the loop stops at the next item rather than
    /// spawning the rest of its `git log`s for a reading nobody will use. The
    /// partial dictionary is still returned; the caller drops it, because it
    /// cancelled it.
    package static func lastTouched(items: [BacklogItem], checkout: URL) -> [String: Date] {
        var out: [String: Date] = [:]
        for item in items where openStatuses.contains(item.status) {
            if Task.isCancelled { return out }
            guard let detailPath = item.detailPath else { continue }
            var env = ProcessInfo.processInfo.environment
            env["GIT_TERMINAL_PROMPT"] = "0"
            let result = SubprocessOutput.runWithDeadline(
                executable: "/usr/bin/git",
                arguments: ["log", "-1", "--format=%ct", "--", detailPath],
                directory: checkout,
                environment: env,
                timeout: 30
            )
            let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.status == 0, let seconds = TimeInterval(trimmed) else { continue }
            out[item.id] = Date(timeIntervalSince1970: seconds)
        }
        return out
    }
}
