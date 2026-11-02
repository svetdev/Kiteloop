import Foundation
import KiteloopCore

/// Folds recorded merge outcomes onto the runs that produced the work.
///
/// The two facts are measured at different times. A run's `TaskMetricRecord` is
/// appended when the run ends; whether its branch reached main is decided
/// afterwards, at the gate. The ledger is append-only — no path rewrites a line
/// that has been written — so the outcome arrives as its own event and is joined
/// to the run on the way back out: here for `TaskMetricStore`'s in-memory
/// records, and in SQL for `MetricIndex`'s `runs.merged` column.
///
/// **Which run an event describes**, in order:
///
/// 1. An event naming an `executionID` describes *that* run and no other. The
///    autopilot's auto-merge runs inside the run, before its metric row exists,
///    so the id is the only thing that can join them — and falling back to a
///    time comparison would attach the outcome to the item's *previous* run,
///    which is the one wrong answer worth ruling out. An id naming no run yet
///    simply doesn't fold; it does once the row lands.
/// 2. An event naming none describes the item's most recent run that had already
///    finished when the event was recorded. That is the human gate: the run
///    ended, its row was written, and someone resolved the gate later.
/// 3. An event matching neither folds onto nothing. `merged` stays nil, and nil
///    means unknown — the distinction that stops a missing outcome from becoming
///    a wrong one.
///
/// Events are applied in the order they were recorded, so the last one wins: a
/// merge that failed and was later retried by hand reads as merged.
enum MergeOutcomeFold {

    /// `runs` with `merged` filled in wherever an event says what happened.
    ///
    /// Only ever *writes* an outcome — a run no event describes is handed back
    /// untouched, so folding an empty log, or folding twice, changes nothing.
    static func apply(_ events: [ItemMergeEvent], to runs: [TaskMetricRecord]) -> [TaskMetricRecord] {
        guard !events.isEmpty, !runs.isEmpty else { return runs }
        var folded = runs
        for event in events {
            guard let index = index(of: event, in: folded) else { continue }
            folded[index].merged = event.merged
        }
        return folded
    }

    /// Where in `runs` this event's outcome belongs, or nil when nothing in the
    /// list is the run it describes.
    static func index(of event: ItemMergeEvent, in runs: [TaskMetricRecord]) -> Int? {
        let project = KiteloopProject.canonicalPath(event.projectPath)
        let candidates = runs.indices.filter { index in
            runs[index].itemID == event.itemID
                && KiteloopProject.canonicalPath(runs[index].projectPath) == project
                // A refusal at pickup produced no branch, so no merge outcome
                // can be about it — and rule 2 below picks the item's most
                // recent *finished* row, which a refusal recorded between the
                // run and the gate would otherwise be. The work's own row would
                // then keep `merged: nil` while the answer sat on a row for an
                // attempt that never ran.
                && !runs[index].didNotRun
        }

        if let executionID = event.executionID, !executionID.isEmpty {
            return candidates.first { runs[$0].executionID == executionID }
        }

        // The item's most recent run that had finished when this was recorded.
        // A run still in flight is not it: the gate being resolved belongs to
        // work that already ended.
        var latest: Int?
        for index in candidates where runs[index].completedAt <= event.at {
            if let latest, runs[latest].completedAt > runs[index].completedAt { continue }
            latest = index
        }
        return latest
    }
}
