import Foundation

/// Tells the auto-merge/gate-retry loop's own churn apart from a reopen a
/// person made — shared by `TaskMetricStore.escapedDefectRate` (success metric
/// #3b) and `EscapedDefectReader` (the refill's escaped-defect signal), so a
/// bounce collapsed for one reads the same way to the other.
///
/// The evidence: on 2026-09-05 `signal-drafts-push-a-pass-past-its-own-cap`
/// bounced `done` → `active` → `done` four times in thirteen minutes — the
/// merged-tree verify's own retries, each a few minutes — with the same
/// approval standing the whole time. `EscapedDefectTracker.observe` read every
/// bounce out of `done` as a reopen with no regard for what put it back, and
/// the 06:00 refill filed one "Escaped defect" item per run caught in the
/// churn. Nothing had escaped review: a reopen the loop re-approves within its
/// own retry window is one attempt, not a new one.
package enum MergeRetryChurn {
    /// Generous next to the observed cascade (four bounces in thirteen
    /// minutes) and tiny next to the escaped-defect window itself (seven
    /// days), so nothing this collapses could have read as a genuine, later
    /// reopen either way.
    package static let window: TimeInterval = 30 * 60

    /// One approval/reopen transition, generic in what a caller wants back —
    /// `payload` round-trips whatever richer object it came from, so this can
    /// run over `TaskMetricStore`'s `ItemApprovalEvent` on one side of the
    /// package boundary and `EscapedDefectReader`'s own decoded ledger line on
    /// the other without either depending on the other's type.
    package struct Moment<Payload> {
        /// Groups moments that belong to the same reopen/approve history — an
        /// item id alone is only unique inside one project, so a caller
        /// spanning several folds the project path in.
        package let key: String
        package let isReopen: Bool
        package let at: Date
        package let payload: Payload

        package init(key: String, isReopen: Bool, at: Date, payload: Payload) {
            self.key = key
            self.isReopen = isReopen
            self.at = at
            self.payload = payload
        }
    }

    /// `moments`, with every reopen the loop re-approved within `window`
    /// dropped along with the approval that closed it — the approval it
    /// interrupted still stands, so neither is a new fact worth reporting.
    /// Everything else — a reopen nothing re-approved in time, a person's own
    /// reopen, every ordinary approval — passes through unchanged. Order
    /// within a key is restored by `at`; order across keys is not meaningful
    /// to either caller, both of which only count or group what comes back.
    package static func genuine<Payload>(_ moments: [Moment<Payload>]) -> [Moment<Payload>] {
        Dictionary(grouping: moments, by: \.key).values.flatMap { coalesce($0.sorted { $0.at < $1.at }) }
    }

    /// One key's own timeline: a reopen immediately followed by an approval
    /// inside `window` is the loop finishing what it started, so both are
    /// skipped; anything else is kept as itself.
    private static func coalesce<Payload>(_ moments: [Moment<Payload>]) -> [Moment<Payload>] {
        var kept: [Moment<Payload>] = []
        var index = 0
        while index < moments.count {
            let moment = moments[index]
            if moment.isReopen, index + 1 < moments.count {
                let next = moments[index + 1]
                if !next.isReopen, next.at.timeIntervalSince(moment.at) <= window {
                    index += 2
                    continue
                }
            }
            kept.append(moment)
            index += 1
        }
        return kept
    }
}
