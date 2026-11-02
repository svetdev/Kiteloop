import XCTest
@testable import Kiteloop

/// Covers the line the collapsed HISTORY box shows. With the list closed by
/// default this row is the only account of finished work on screen, so the
/// load-bearing assertions are that it never invents a run that hasn't been
/// recorded, never counts the run in flight twice, and reads as empty rather
/// than as a run that scored zero.
@MainActor
final class AutopilotHistorySummaryTests: XCTestCase {

    private func record(_ outcomes: [String], id: String = "run-1") -> BacklogAutopilot.RunRecord {
        BacklogAutopilot.RunRecord(
            id: id,
            startedAt: Date(),
            completedAt: nil,
            items: outcomes.enumerated().map { index, outcome in
                BacklogAutopilot.RunRecord.ItemRecord(
                    id: "\(id)-\(index)", title: "Item \(index)", outcome: outcome,
                    duration: 10, executionID: nil
                )
            },
            workerAgentName: "worker",
            reviewerAgentName: "reviewer"
        )
    }

    private func item(id: String, title: String) -> BacklogAutopilot.RunRecord.ItemRecord {
        BacklogAutopilot.RunRecord.ItemRecord(
            id: id, title: title, outcome: "done", duration: 10, executionID: nil
        )
    }

    private func result(_ outcome: BacklogAutopilot.ItemResult.Outcome) -> BacklogAutopilot.ItemResult {
        BacklogAutopilot.ItemResult(id: "live", title: "Live", outcome: outcome, duration: 5)
    }

    // MARK: - Counting

    func testCountsItemsAcrossRuns() {
        let summary = AutopilotHistorySummary.make(
            liveResults: [],
            runHistory: [record(["done", "blocked"], id: "a"), record(["done"], id: "b")]
        )

        XCTAssertEqual(summary.runs, 2)
        XCTAssertEqual(summary.passed, 2)
        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(summary.text, "2 passed · 1 failed · 2 runs")
    }

    /// The same rule the expanded rows use: the agent's work is done even though
    /// the human's isn't.
    func testAwaitingApprovalCountsAsPassed() {
        XCTAssertTrue(AutopilotHistorySummary.isPass("awaiting-approval"))
        XCTAssertTrue(AutopilotHistorySummary.isPass(.awaitingApproval))
        XCTAssertFalse(AutopilotHistorySummary.isPass("cancelled"))
        XCTAssertFalse(AutopilotHistorySummary.isPass(.blocked("verify failed")))
        XCTAssertFalse(AutopilotHistorySummary.isPass(.cancelled))

        let summary = AutopilotHistorySummary.make(
            liveResults: [], runHistory: [record(["awaiting-approval", "cancelled"])]
        )
        XCTAssertEqual(summary.passed, 1)
        XCTAssertEqual(summary.failed, 1)
    }

    /// The run in flight has no record yet, so its finished items count towards
    /// the totals while the run count stays at the runs actually on record.
    func testLiveResultsCountWithoutAddingARun() {
        let summary = AutopilotHistorySummary.make(
            liveResults: [result(.done), result(.blocked("verify failed"))],
            runHistory: []
        )

        XCTAssertEqual(summary.runs, 0)
        XCTAssertEqual(summary.passed, 1)
        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(summary.text, "1 passed · 1 failed", "No run count when nothing is on record yet")
    }

    // MARK: - Text

    func testEmptyReadsAsNoRunsRatherThanZero() {
        let summary = AutopilotHistorySummary.make(liveResults: [], runHistory: [])

        XCTAssertTrue(summary.isEmpty)
        XCTAssertEqual(summary.text, "No completed runs")
    }

    /// A run whose items are all still queued is on record but has finished
    /// nothing — the row must not claim "0 passed · 1 run".
    func testRecordWithNoItemsStillReadsAsEmpty() {
        let summary = AutopilotHistorySummary.make(liveResults: [], runHistory: [record([])])

        XCTAssertEqual(summary.runs, 1)
        XCTAssertTrue(summary.isEmpty)
        XCTAssertEqual(summary.text, "No completed runs")
    }

    func testCleanRunDropsTheFailureClause() {
        let summary = AutopilotHistorySummary.make(liveResults: [], runHistory: [record(["done", "done"])])

        XCTAssertEqual(summary.text, "2 passed · 1 run", "One run is singular")
    }

    // MARK: - A record's collapsed row

    /// The case nearly every record is: one item per run, so the row that used
    /// to read "1 items" names the item and is the click that opens it.
    func testSingleItemRowNamesTheItemAndOpensIt() {
        let label = AutopilotHistorySummary.recordLabel(
            for: [item(id: "history-rows", title: "History rows name their item")]
        )

        XCTAssertEqual(label.text, "History rows name their item")
        XCTAssertEqual(label.opensItem, "history-rows")
    }

    /// Several items: the first is named and the rest are counted, and the row's
    /// click stays the expansion — there is no one page for it to open.
    func testSeveralItemsNameTheFirstAndCountTheRest() {
        let label = AutopilotHistorySummary.recordLabel(for: [
            item(id: "a", title: "First item"),
            item(id: "b", title: "Second item"),
            item(id: "c", title: "Third item"),
        ])

        XCTAssertEqual(label.text, "First item +2 more")
        XCTAssertNil(label.opensItem)
    }

    /// Two items is the smallest record that is not a single one — the count
    /// must read "+1 more" rather than falling into either neighbouring case.
    func testTwoItemsCountTheOneBeingHidden() {
        let label = AutopilotHistorySummary.recordLabel(for: [
            item(id: "a", title: "First item"),
            item(id: "b", title: "Second item"),
        ])

        XCTAssertEqual(label.text, "First item +1 more")
        XCTAssertNil(label.opensItem)
    }

    /// A run on record that finished nothing has no title to show and no page to
    /// open, and must not read as an item called nothing.
    func testNoItemsSaysSoAndOpensNothing() {
        let label = AutopilotHistorySummary.recordLabel(for: [])

        XCTAssertEqual(label.text, "No items")
        XCTAssertNil(label.opensItem)
    }

    /// A blank title would put the row back where it started — naming nothing —
    /// so the id stands in for it, in both shapes of row.
    func testBlankTitleFallsBackToTheItemID() {
        XCTAssertEqual(
            AutopilotHistorySummary.recordLabel(for: [item(id: "untitled-item", title: "  ")]).text,
            "untitled-item"
        )
        XCTAssertEqual(
            AutopilotHistorySummary.recordLabel(for: [
                item(id: "untitled-item", title: ""),
                item(id: "b", title: "Second item"),
            ]).text,
            "untitled-item +1 more"
        )
    }
}
