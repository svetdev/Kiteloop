import Foundation

/// What the collapsed HISTORY box, and the collapsed rows inside it, say.
///
/// History is the bottom third of the Autopilot console's left column, and it
/// held that third open for work that had already finished — a list nobody reads
/// while a run is in flight, directly under the Execution box, which is the only
/// part of the column that changes minute to minute. So the box collapses to its
/// header by default and the header has to earn its row: how much has finished,
/// and how much of it went wrong. Expanding restores the full list, and the
/// choice is remembered.
///
/// The rows the expanded list shows have the same problem one level down, and
/// `recordLabel(for:)` is their answer to it — see there.
@MainActor
enum AutopilotHistorySummary {

    /// What the collapsed row counts. `runs` is past runs on record; `passed` and
    /// `failed` are items, and include the run in flight, whose finished items
    /// aren't a record yet.
    struct Summary: Equatable {
        let runs: Int
        let passed: Int
        let failed: Int

        /// Nothing has finished yet — the row reads as the box's old empty state
        /// rather than as a run that scored zero.
        var isEmpty: Bool { passed == 0 && failed == 0 }

        /// e.g. `12 passed · 1 failed · 3 runs`. A clause is dropped rather than
        /// shown as zero: "0 failed" is noise in a 280pt column, and a run count
        /// of zero would be wrong rather than merely noisy — the items it would
        /// be counting belong to the run in flight.
        var text: String {
            guard !isEmpty else { return "No completed runs" }
            var parts = ["\(passed) passed"]
            if failed > 0 { parts.append("\(failed) failed") }
            if runs > 0 { parts.append("\(runs) run\(runs == 1 ? "" : "s")") }
            return parts.joined(separator: " · ")
        }
    }

    /// An item the agents finished as asked. Parked for approval counts as a pass
    /// — the agent's work is done, the human's isn't — which is the rule the
    /// expanded rows and the run badge already use.
    ///
    /// A run that changed nothing and said, with evidence, that the item was
    /// already built is a pass on the same reading: the agent did what it was
    /// asked to do and the item is parked for a human. Counting it as a failure
    /// would be the defect this ending exists to fix, one surface further along
    /// — an agent following CLAUDE.md's own instruction, filed as a failure.
    ///
    /// `nonisolated` because it is the app's one definition of a pass and is read
    /// off the main actor too — `ItemRunHistory` asks it rather than restating
    /// the rule, which is how a row could otherwise be a pass on the item page
    /// and a failure in the history box.
    nonisolated static func isPass(_ outcome: String) -> Bool {
        outcome == "done" || outcome == "awaiting-approval"
            || outcome == TaskMetricRecord.alreadyImplementedOutcome
            || outcome == TaskMetricRecord.investigationOutcome
    }

    static func isPass(_ outcome: BacklogAutopilot.ItemResult.Outcome) -> Bool {
        switch outcome {
        case .done, .awaitingApproval, .alreadyImplemented, .investigation: return true
        case .blocked, .cancelled, .usageLimitParked: return false
        }
    }

    /// - Parameters:
    ///   - liveResults: items the run in flight has already finished. Empty when
    ///     nothing is running, matching the expanded list, which only shows them
    ///     mid-run — once the run ends they arrive again as a record, and
    ///     counting both would double them.
    ///   - runHistory: past runs, newest first.
    static func make(
        liveResults: [BacklogAutopilot.ItemResult],
        runHistory: [BacklogAutopilot.RunRecord]
    ) -> Summary {
        var passed = liveResults.filter { isPass($0.outcome) }.count
        var failed = liveResults.count - passed
        for record in runHistory {
            let recordPassed = record.items.filter { isPass($0.outcome) }.count
            passed += recordPassed
            failed += record.items.count - recordPassed
        }
        return Summary(runs: runHistory.count, passed: passed, failed: failed)
    }

    // MARK: - A record's collapsed row

    /// What one run record's collapsed row names, and what it opens.
    struct RecordLabel: Equatable {
        /// The row's text, in place of the bare count it used to carry.
        let text: String
        /// The item the row's click opens, when the record holds exactly one.
        /// Nil for a record holding several — that row's click still expands —
        /// and for one holding none, which has nothing to open.
        let opensItem: String?
    }

    /// The collapsed row for a run record.
    ///
    /// The scheduler and the headless harness start one item per run, so nearly
    /// every record holds exactly one — and History rendered as a wall of
    /// identical "1 passed · 1 items" rows that named nothing and, at the level
    /// the operator actually sees, led nowhere: the titles and the click-through
    /// were both one level down, on the expanded item lines. So a lone item's
    /// row carries its title and opens its page, and a record holding several
    /// names the first plus how many more it is hiding. No new derivation — the
    /// titles are already on the record.
    ///
    /// An item whose title is blank falls back to its id: a row that names
    /// nothing is the defect this exists to end, and an id names something.
    static func recordLabel(
        for items: [BacklogAutopilot.RunRecord.ItemRecord]
    ) -> RecordLabel {
        guard let first = items.first else {
            return RecordLabel(text: "No items", opensItem: nil)
        }
        let title = displayTitle(of: first)
        guard items.count > 1 else {
            return RecordLabel(text: title, opensItem: first.id)
        }
        return RecordLabel(text: "\(title) +\(items.count - 1) more", opensItem: nil)
    }

    private static func displayTitle(of item: BacklogAutopilot.RunRecord.ItemRecord) -> String {
        let trimmed = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? item.id : trimmed
    }
}
