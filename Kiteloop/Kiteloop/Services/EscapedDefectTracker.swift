import Foundation
import KiteloopCore
import os.log

private let escapedDefectLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "escaped-defects")

/// Watches a project's backlog for the two transitions success metric #3b is
/// measured from: an item reaching `done` (approved) and an approved item coming
/// back to `ready`, `blocked`, `active`, or `in-review` (reopened — a defect
/// that escaped review).
///
/// It reads *changes*, not statuses. An item found in `ready` says nothing about
/// whether it was ever approved, so the first look at a backlog only seeds the
/// baseline; every later look compares against what was there before. The one
/// thing the first look can still say comes off disk rather than off the
/// backlog — see `recordReopensMissedWhileClosed`.
///
/// The distinction the metric lives or dies on: a reviewer bouncing an item back
/// to `ready` *from* `active`/`in-review` never passed it, so that transition is
/// a first-pass failure (metric #3a) — only a return *out of `done`* is recorded
/// here, whichever status it lands on, including `active`/`in-review` themselves
/// when an item picked back up is never re-observed at `ready`/`blocked` first.
@MainActor
final class EscapedDefectTracker {
    /// Where a reopen can land. `draft` is not one: sending an item back to
    /// grooming un-files it rather than reporting a defect against shipped work.
    /// `awaitingApproval` is also not one: an item returning there may be an
    /// auto-merge refusal bouncing it back rather than a defect that escaped
    /// review, and telling the two apart needs the merge path read.
    private static let reopenStatuses: Set<BacklogItemStatus> = [.ready, .blocked, .active, .inReview]

    private let store: TaskMetricStore
    private let projectPath: String
    private let projectName: String

    /// Status per item id as of the last observation. Empty until seeded.
    private var lastSeen: [String: BacklogItemStatus] = [:]
    private var seeded = false

    init(store: TaskMetricStore, projectPath: String, projectName: String) {
        self.store = store
        self.projectPath = projectPath
        self.projectName = projectName
    }

    /// Compares the backlog against the previous observation and records any
    /// approval or reopen it finds. Safe to call on every read and every
    /// write-back: an unchanged backlog produces nothing.
    func observe(_ file: BacklogFile?, at now: Date = Date()) {
        guard let file else { return }
        let current = Dictionary(file.sections.flatMap(\.items).map { ($0.id, $0.status) },
                                 uniquingKeysWith: { first, _ in first })
        defer {
            lastSeen = current
            seeded = true
        }
        guard seeded else {
            recordReopensMissedWhileClosed(current, at: now)
            return
        }

        for (itemID, status) in current {
            guard let previous = lastSeen[itemID], previous != status else { continue }
            if status == .done {
                record(.approved, itemID: itemID, at: now, approvedAt: nil, toStatus: nil)
            } else if previous == .done, Self.reopenStatuses.contains(status) {
                guard let approval = store.latestApproval(itemID: itemID, projectPath: projectPath) else {
                    // Approved before this app ever watched the item (or before
                    // the metric existed). Without an approval time the 7-day
                    // window can't be applied, and a guess would be worse than
                    // the gap — backfilling history is deliberately not done.
                    escapedDefectLog.info(
                        "\(itemID, privacy: .public) left done with no recorded approval — not counted as a reopen")
                    continue
                }
                record(.reopened, itemID: itemID, at: now,
                       approvedAt: approval.at, toStatus: status.rawValue)
            }
        }
    }

    /// Catches up on reopens that happened while nobody was watching.
    ///
    /// `lastSeen` lives only in memory, so every project open — and so every app
    /// launch — starts from a fresh baseline. Left at that, an item that read
    /// `done` when the app quit and reads `ready` when it comes back is seen as
    /// a state rather than a transition, and the escape is lost: the metric ends
    /// up measuring escapes that happened to occur while the app was running.
    ///
    /// The durable half of the transition is already on disk. An item now in a
    /// reopen status with an approval on record, and nothing recorded against
    /// that approval since, went out of `done` unobserved — so it is recorded
    /// through the same path a live reopen takes, measured off the same
    /// `approvedAt`. `at` is when the return was noticed rather than when it
    /// happened, which is the most the approval log can say.
    ///
    /// That "nothing since" test is also what makes this idempotent: re-opening
    /// the project, or relaunching the app, finds its own event already there
    /// and adds nothing.
    private func recordReopensMissedWhileClosed(_ current: [String: BacklogItemStatus], at now: Date) {
        // Sorted so several items caught by one seed are written in a stable
        // order rather than the dictionary's.
        for (itemID, status) in current.sorted(by: { $0.key < $1.key })
        where Self.reopenStatuses.contains(status) {
            // No approval on record is the ordinary case here — most of a
            // backlog is `ready` and always has been — so unlike the live path
            // this one passes over it silently rather than logging every item.
            guard let approval = store.latestApproval(itemID: itemID, projectPath: projectPath),
                  !store.hasReopen(itemID: itemID, projectPath: projectPath, onOrAfter: approval.at)
            else { continue }
            record(.reopened, itemID: itemID, at: now,
                   approvedAt: approval.at, toStatus: status.rawValue)
        }
    }

    private func record(_ kind: ItemApprovalEvent.Kind, itemID: String, at: Date,
                        approvedAt: Date?, toStatus: String?) {
        store.appendApprovalEvent(ItemApprovalEvent(
            projectPath: projectPath,
            projectName: projectName,
            itemID: itemID,
            kind: kind,
            at: at,
            approvedAt: approvedAt,
            toStatus: toStatus
        ))
        if kind == .reopened, let approvedAt {
            let days = at.timeIntervalSince(approvedAt) / 86_400
            escapedDefectLog.info(
                "\(itemID, privacy: .public) reopened \(String(format: "%.1f", days), privacy: .public) days after approval")
        }
    }
}

extension MergeRetryChurn {
    /// `moments` folded through `genuine` and counted — the one definition of
    /// #3b shared by `TaskMetricStore` (walking `ItemApprovalEvent` in memory)
    /// and `MetricIndex` (walking rows read back out of SQL), so the two
    /// payload shapes cannot drift on what the fold means.
    static func escapedDefectRate<Payload>(
        _ moments: [Moment<Payload>],
        window: TimeInterval,
        kind: (Payload) -> ItemApprovalEvent.Kind,
        approvedAt: (Payload) -> Date?
    ) -> EscapedDefectRate {
        var approvals = 0
        var reopened = 0
        var lateReopened = 0
        for moment in genuine(moments) {
            switch kind(moment.payload) {
            case .approved:
                approvals += 1
            case .reopened:
                guard let approvedAt = approvedAt(moment.payload) else { continue }
                let elapsed = moment.at.timeIntervalSince(approvedAt)
                if elapsed >= 0 && elapsed <= window { reopened += 1 } else { lateReopened += 1 }
            }
        }
        return EscapedDefectRate(approvals: approvals, reopened: reopened, lateReopened: lateReopened,
                                 windowDays: Int((window / 86_400).rounded()))
    }
}
