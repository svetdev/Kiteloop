import XCTest
import KiteloopCore
@testable import Kiteloop

/// These figures exist to expose a marathon that is spending without producing,
/// so what is worth pinning down is every way the arithmetic could get the answer
/// wrong in *either* direction: delivered work written off as waste because the
/// run that built it ended before the approval landed, unattributed runs read as
/// free work, an average over zero delivered items read as $0, work from another
/// project or another day folded in, and — the other way — a real waste figure
/// buried by parking everything in a bucket that counts as neither.
final class RunEconomicsTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_800_000_000)

    /// Fixed to UTC so "today" is the same window wherever the test runs — with
    /// the machine's calendar, an instant that is mid-morning here is the small
    /// hours somewhere else and the midnight boundary lands in a different place.
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func record(
        itemID: String = "t-1",
        project: String = "/tmp/proj",
        cost: Double,
        outcome: String,
        completedAt: Date? = nil,
        merged: Bool? = nil
    ) -> TaskMetricRecord {
        let end = completedAt ?? day
        var record = TaskMetricRecord(
            projectPath: project, projectName: "proj", itemID: itemID, title: "Task \(itemID)",
            epic: nil, declaredSize: "M", startedAt: end.addingTimeInterval(-600),
            completedAt: end, durationSeconds: 600, costUSD: cost, reviewerRetries: 0,
            outcome: outcome, workerAgent: "worker", reviewerAgent: "reviewer",
            executionID: "e-1", toolErrors: nil
        )
        record.merged = merged
        return record
    }

    private func make(_ records: [TaskMetricRecord],
                      status: [String: BacklogItemStatus],
                      project: String? = "/tmp/proj") -> RunEconomics {
        RunEconomics.make(records: records, projectPath: project, itemStatus: status,
                          from: day.addingTimeInterval(-3600), to: day.addingTimeInterval(3600))
    }

    // MARK: - The two figures

    func testCostPerDeliveredItemIsSpendOnDeliveredItemsOverHowManyShipped() {
        let economics = make([
            record(itemID: "a", cost: 4.00, outcome: "done"),
            record(itemID: "b", cost: 6.00, outcome: "done"),
            record(itemID: "c", cost: 10.00, outcome: "blocked: review did not pass"),
        ], status: ["a": .done, "b": .done, "c": .blocked])

        XCTAssertEqual(economics.deliveredItems, 2)
        XCTAssertEqual(economics.costPerDeliveredItemUSD ?? 0, 5.00, accuracy: 0.001)
        XCTAssertEqual(economics.costPerDeliveredItemText, "$5.00/delivered")
    }

    func testWasteShareIsSpendOnItemsThatHaveNotShipped() {
        let economics = make([
            record(itemID: "a", cost: 7.50, outcome: "done"),
            record(itemID: "b", cost: 2.50, outcome: "blocked: stalled"),
        ], status: ["a": .done, "b": .blocked])

        XCTAssertEqual(economics.wasteShare ?? 0, 0.25, accuracy: 0.001)
        XCTAssertEqual(economics.wasteShareText, "25% wasted")
        XCTAssertEqual(economics.spendUSD, 10.00, accuracy: 0.001)
    }

    /// A run the human stopped bought nothing either — but only if its item is
    /// still sitting there unshipped. That is the item's business, not the run's.
    func testCancelledRunOnAnItemThatNeverShippedIsWaste() {
        let economics = make([
            record(itemID: "a", cost: 3.00, outcome: "done"),
            record(itemID: "b", cost: 1.00, outcome: "cancelled"),
        ], status: ["a": .done, "b": .ready])

        XCTAssertEqual(economics.unshippedSpendUSD, 1.00, accuracy: 0.001)
        XCTAssertEqual(economics.wasteShare ?? 0, 0.25, accuracy: 0.001)
    }

    // MARK: - The item decides, not the frozen outcome

    /// The bug this was written for. A run that ended at the approval gate keeps
    /// that outcome for good; the item it built is approved and merged minutes
    /// later. The spend bought a delivered item and must read as one.
    func testAwaitingApprovalRunWhoseItemHasSinceShippedIsNotWaste() {
        let economics = make([
            record(itemID: "a", cost: 8.00, outcome: "awaiting-approval"),
        ], status: ["a": .done])

        XCTAssertEqual(economics.wasteShare ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(economics.deliveredItems, 1)
        XCTAssertEqual(economics.costPerDeliveredItemUSD ?? 0, 8.00, accuracy: 0.001)
    }

    /// The same for a run a gate returned as blocked whose item was regroomed,
    /// re-run and merged: one attempt was refused, the item shipped.
    func testBlockedRunWhoseItemLaterShippedIsNotWaste() {
        let economics = make([
            record(itemID: "a", cost: 1.70, outcome: "blocked: verify coverage"),
            record(itemID: "a", cost: 4.30, outcome: "done"),
        ], status: ["a": .done])

        XCTAssertEqual(economics.unshippedSpendUSD, 0, accuracy: 0.001)
        XCTAssertEqual(economics.wasteShare ?? -1, 0, accuracy: 0.001)
    }

    /// Attempts are what the delivered item cost — all of them, not just the one
    /// that merged. Dividing by runs would report delivery as cheaper than it was
    /// every time an item needed a second pass.
    func testEveryAttemptAtADeliveredItemCountsTowardsItsCost() {
        let economics = make([
            record(itemID: "a", cost: 2.00, outcome: "blocked: review did not pass"),
            record(itemID: "a", cost: 3.00, outcome: "blocked: review did not pass"),
            record(itemID: "a", cost: 5.00, outcome: "done"),
        ], status: ["a": .done])

        XCTAssertEqual(economics.runs, 3)
        XCTAssertEqual(economics.deliveredItems, 1, "three attempts delivered one item")
        XCTAssertEqual(economics.deliveredSpendUSD, 10.00, accuracy: 0.001)
        XCTAssertEqual(economics.costPerDeliveredItemUSD ?? 0, 10.00, accuracy: 0.001)
    }

    /// And the figure must stay honest the other way: an item that really has not
    /// shipped is still waste, however good the run that spent the money looked.
    func testSpendOnAnItemThatHasNotShippedIsStillCounted() {
        let economics = make([
            record(itemID: "a", cost: 99.00, outcome: "done"),
            record(itemID: "b", cost: 1.00, outcome: "awaiting-approval"),
        ], status: ["a": .done, "b": .blocked])

        XCTAssertEqual(economics.unshippedSpendUSD, 1.00, accuracy: 0.001)
        XCTAssertEqual(economics.wasteShare ?? 0, 0.01, accuracy: 0.0001)
        XCTAssertEqual(economics.wasteShareText, "1% wasted")
    }

    /// An item bounced back to `ready` is unshipped, not "in flight". An item
    /// cycling ready → rejected → ready forever is exactly what this metric is
    /// for, and a bucket that counts as neither would hide it.
    func testAnItemBouncedBackToReadyCountsAsWaste() {
        let economics = make([
            record(itemID: "a", cost: 3.00, outcome: "done"),
            record(itemID: "b", cost: 1.00, outcome: "blocked: review did not pass"),
        ], status: ["a": .done, "b": .ready])

        XCTAssertEqual(economics.unshippedSpendUSD, 1.00, accuracy: 0.001)
        XCTAssertEqual(economics.inFlightSpendUSD, 0, accuracy: 0.001)
    }

    /// The outcome a run froze is not consulted at all — that is what stops a
    /// second answer disagreeing with the backlog's.
    func testTheRunOutcomeAndMergedFlagAreNotConsulted() {
        let byOutcome = make([
            record(itemID: "a", cost: 5.00, outcome: "done", merged: true),
        ], status: ["a": .blocked])

        XCTAssertEqual(byOutcome.deliveredItems, 0,
                       "a `done` outcome on an item the backlog has as blocked delivered nothing")
        XCTAssertEqual(byOutcome.unshippedSpendUSD, 5.00, accuracy: 0.001)

        let byStatus = make([
            record(itemID: "a", cost: 5.00, outcome: "blocked: stalled", merged: false),
        ], status: ["a": .done])

        XCTAssertEqual(byStatus.deliveredItems, 1)
    }

    func testDeliveryClassifiesEveryStatus() {
        XCTAssertEqual(RunEconomics.delivery(of: .done), .delivered)
        XCTAssertEqual(RunEconomics.delivery(of: .active), .inFlight)
        XCTAssertEqual(RunEconomics.delivery(of: .inReview), .inFlight)
        XCTAssertEqual(RunEconomics.delivery(of: .awaitingApproval), .inFlight)
        XCTAssertEqual(RunEconomics.delivery(of: .ready), .unshipped)
        XCTAssertEqual(RunEconomics.delivery(of: .blocked), .unshipped)
        XCTAssertEqual(RunEconomics.delivery(of: .draft), .unshipped)
        XCTAssertEqual(RunEconomics.delivery(of: nil), .unknown)
    }

    // MARK: - Work that has not settled yet

    /// A run that has just finished, with its item still in play, belongs in
    /// neither bucket — otherwise the waste share spikes the moment a run ends
    /// and falls again when the human approves it, moving without anything having
    /// gone right or wrong.
    func testSpendOnAnUnresolvedItemMovesNeitherFigure() {
        let settled = [
            record(itemID: "a", cost: 3.00, outcome: "done"),
            record(itemID: "b", cost: 1.00, outcome: "blocked: stalled"),
        ]
        let before = make(settled, status: ["a": .done, "b": .blocked])
        let after = make(settled + [record(itemID: "c", cost: 40.00, outcome: "awaiting-approval")],
                         status: ["a": .done, "b": .blocked, "c": .awaitingApproval])

        XCTAssertEqual(after.wasteShare ?? 0, before.wasteShare ?? 0, accuracy: 0.001)
        XCTAssertEqual(after.costPerDeliveredItemUSD ?? 0, before.costPerDeliveredItemUSD ?? 0,
                       accuracy: 0.001)
        XCTAssertEqual(after.inFlightSpendUSD, 40.00, accuracy: 0.001)
        XCTAssertEqual(after.runs, 3, "it is still a run that happened, and still spend")
        XCTAssertEqual(after.spendUSD, 44.00, accuracy: 0.001)
        XCTAssertEqual(after.resolvedSpendUSD, 4.00, accuracy: 0.001)
        XCTAssertTrue(after.detail.contains("in flight"), after.detail)
    }

    /// Nothing can say what became of an item the backlog no longer has, so it is
    /// reported rather than guessed at in either direction — guessing "waste" is
    /// how a tidied backlog would re-inflate the figure this fixes.
    func testRunsWhoseItemTheBacklogNoLongerHasAreExcludedAndReported() {
        let economics = make([
            record(itemID: "a", cost: 3.00, outcome: "done"),
            record(itemID: "gone", cost: 9.00, outcome: "blocked: stalled"),
        ], status: ["a": .done])

        XCTAssertEqual(economics.unknownItemSpendUSD, 9.00, accuracy: 0.001)
        XCTAssertEqual(economics.unshippedSpendUSD, 0, accuracy: 0.001)
        XCTAssertEqual(economics.wasteShare ?? -1, 0, accuracy: 0.001)
        XCTAssertTrue(economics.detail.contains("no longer has"), economics.detail)
    }

    // MARK: - Unattributed runs

    /// The failure the first version of this metric was written to avoid: a $0
    /// run is attribution that missed, not a run that was free. Averaged in as
    /// free it makes waste read smaller than it is.
    func testUnattributedRunsAreExcludedAndCounted() {
        let economics = make([
            record(itemID: "a", cost: 8.00, outcome: "done"),
            record(itemID: "b", cost: 2.00, outcome: "blocked: no work produced"),
            record(itemID: "c", cost: 0, outcome: "blocked: no work produced"),
            record(itemID: "d", cost: 0, outcome: "blocked: stalled"),
        ], status: ["a": .done, "b": .blocked, "c": .blocked, "d": .blocked])

        XCTAssertEqual(economics.runs, 2, "only the attributed runs are the population")
        XCTAssertEqual(economics.unattributed, 2)
        XCTAssertEqual(economics.wasteShare ?? 0, 0.2, accuracy: 0.001)
        XCTAssertTrue(economics.text.contains("2 unattributed"),
                      "the exclusion has to be stated, not silent: \(economics.text)")
        XCTAssertTrue(economics.detail.contains("$0"),
                      "the tooltip has to say why they were excluded: \(economics.detail)")
    }

    /// A $0 run on an item that *shipped* is the other half of the same trap:
    /// counted, it would divide the same spend by a bigger number and report
    /// delivery as cheaper than it was.
    func testUnattributedRunDoesNotDeflateCostPerDeliveredItem() {
        let economics = make([
            record(itemID: "a", cost: 6.00, outcome: "done"),
            record(itemID: "b", cost: 0, outcome: "done"),
        ], status: ["a": .done, "b": .done])

        XCTAssertEqual(economics.deliveredItems, 1)
        XCTAssertEqual(economics.costPerDeliveredItemUSD ?? 0, 6.00, accuracy: 0.001)
        XCTAssertEqual(economics.unattributed, 1)
    }

    // MARK: - Attempts that never ran

    /// A pickup refusal is on the same ledger — that is how the retry ceiling
    /// counts it — and it is in neither bucket here. It spawned no session, so
    /// its $0 is what it cost rather than a cost that went missing, and reading
    /// it as unattributed would put "3 runs finished with no cost attributed" on
    /// screen for three runs that never started.
    func testARefusalAtPickupIsNeitherARunNorAnUnattributedOne() {
        let economics = make([
            record(itemID: "a", cost: 6.00, outcome: "done"),
            refusal(itemID: "b"),
            refusal(itemID: "c"),
        ], status: ["a": .done, "b": .ready, "c": .ready])

        XCTAssertEqual(economics.runs, 1)
        XCTAssertEqual(economics.unattributed, 0)
        XCTAssertEqual(economics.costPerDeliveredItemUSD ?? 0, 6.00, accuracy: 0.001,
                       "and it moves no spend")
        XCTAssertFalse(economics.text.contains("unattributed"), economics.text)
    }

    /// And a day of nothing but refusals is a day with no runs, not a day of
    /// broken attribution.
    func testADayOfNothingButRefusalsReadsAsNoRunsAtAll() {
        let economics = make([refusal(itemID: "a"), refusal(itemID: "b")],
                             status: ["a": .ready, "b": .ready])

        XCTAssertTrue(economics.isEmpty)
        XCTAssertEqual(economics.text, "no completed runs yet")
    }

    private func refusal(itemID: String, project: String = "/tmp/proj") -> TaskMetricRecord {
        RetryCeiling.refusalRecord(
            item: BacklogItem(id: itemID, title: "Task \(itemID)", verify: nil, status: .ready,
                              type: .local, size: .m, queries: nil, cost: nil, completedDate: nil,
                              blockedReason: nil, jiraKey: nil, team: nil, detailPath: nil),
            refusal: .notReady, projectPath: project, projectName: "proj", at: day)
    }

    // MARK: - Nothing to divide by

    func testNoRunsSaysSoRatherThanReportingZero() {
        let economics = make([], status: [:])

        XCTAssertTrue(economics.isEmpty)
        XCTAssertNil(economics.costPerDeliveredItemUSD)
        XCTAssertNil(economics.wasteShare)
        XCTAssertEqual(economics.text, "no completed runs yet")
    }

    /// Every run unattributed is not "no runs" — the panel would otherwise
    /// report a busy, broken hour as an idle one.
    func testWindowWithOnlyUnattributedRunsSaysWhatHappened() {
        let economics = make([
            record(itemID: "a", cost: 0, outcome: "blocked: stalled"),
            record(itemID: "b", cost: 0, outcome: "blocked: stalled"),
        ], status: ["a": .blocked, "b": .blocked])

        XCTAssertTrue(economics.isEmpty)
        XCTAssertTrue(economics.text.contains("2 run"), economics.text)
        XCTAssertTrue(economics.text.contains("none with a recorded cost"), economics.text)
    }

    /// An average over zero delivered items is not $0.00 — that reads as free
    /// delivery, which is the most flattering possible lie here.
    func testSpendWithNothingDeliveredIsNotReportedAsFreeDelivery() {
        let economics = make([
            record(itemID: "a", cost: 4.00, outcome: "blocked: review did not pass"),
        ], status: ["a": .blocked])

        XCTAssertFalse(economics.isEmpty)
        XCTAssertNil(economics.costPerDeliveredItemUSD)
        XCTAssertEqual(economics.costPerDeliveredItemText, "nothing delivered")
        XCTAssertEqual(economics.wasteShare ?? 0, 1.0, accuracy: 0.001)
    }

    /// With no backlog loaded there is no source to ask, and the panel says the
    /// ratio is unmeasured rather than calling a day's work wasted for want of a
    /// file.
    func testNoBacklogLeavesTheFiguresUnmeasuredRatherThanWasted() {
        let economics = make([
            record(itemID: "a", cost: 4.00, outcome: "done"),
        ], status: [:])

        XCTAssertFalse(economics.isEmpty)
        XCTAssertNil(economics.wasteShare)
        XCTAssertEqual(economics.wasteShareText, "—% wasted")
        XCTAssertEqual(economics.unknownItemSpendUSD, 4.00, accuracy: 0.001)
    }

    // MARK: - Windows

    func testRunsOutsideTheWindowAreNotCounted() {
        let records = [
            record(itemID: "a", cost: 5.00, outcome: "done"),
            record(itemID: "b", cost: 50.00, outcome: "blocked: stalled",
                   completedAt: day.addingTimeInterval(-2 * 3600)),
        ]
        let economics = RunEconomics.make(records: records, projectPath: "/tmp/proj",
                                          itemStatus: ["a": .done, "b": .blocked],
                                          from: day.addingTimeInterval(-600), to: day)

        XCTAssertEqual(economics.runs, 1)
        XCTAssertEqual(economics.spendUSD, 5.00, accuracy: 0.001,
                       "yesterday's spend must not be charged to this window")
    }

    func testAnotherProjectsSpendIsNotChargedToThisPanel() {
        let records = [
            record(itemID: "a", cost: 5.00, outcome: "done"),
            record(itemID: "b", project: "/tmp/other", cost: 40.00, outcome: "blocked: stalled"),
        ]
        let status: [String: BacklogItemStatus] = ["a": .done, "b": .blocked]

        XCTAssertEqual(make(records, status: status).spendUSD, 5.00, accuracy: 0.001)
        XCTAssertEqual(make(records, status: status, project: nil).spendUSD, 45.00, accuracy: 0.001,
                       "a nil project path is the portfolio-wide figure")
    }

    func testRunWindowIsEmptyUntilARunHasStarted() {
        let records = [record(itemID: "a", cost: 5.00, outcome: "done")]
        let windows = RunEconomics.windows(records: records, projectPath: "/tmp/proj",
                                           itemStatus: ["a": .done],
                                           runStartedAt: nil, now: day.addingTimeInterval(60),
                                           calendar: utc)

        XCTAssertTrue(windows.run.isEmpty, "no run started ⇒ no run figures, not today's borrowed")
        XCTAssertEqual(windows.run.text, "no completed runs yet")
        XCTAssertFalse(windows.today.isEmpty)
    }

    func testRunWindowStartsAtTheRunAndTodayAtMidnight() {
        let now = day.addingTimeInterval(60)
        let records = [
            record(itemID: "a", cost: 5.00, outcome: "done"),
            record(itemID: "b", cost: 3.00, outcome: "done",
                   completedAt: day.addingTimeInterval(-1800)),
        ]
        let windows = RunEconomics.windows(records: records, projectPath: "/tmp/proj",
                                           itemStatus: ["a": .done, "b": .done],
                                           runStartedAt: day.addingTimeInterval(-60), now: now,
                                           calendar: utc)

        XCTAssertEqual(windows.run.deliveredItems, 1, "only the item this run finished")
        XCTAssertEqual(windows.today.deliveredItems, 2, "both, since both finished today")
    }

    // MARK: - The backlog is the one source

    func testBacklogFileAnswersOncePerItem() {
        let file = BacklogFile(project: "proj", repo: nil, verifyDefault: nil, sections: [
            BacklogSection(name: "Epic A", items: [
                BacklogItem(id: "a", title: "A", verify: nil, status: .done, type: .local),
                BacklogItem(id: "b", title: "B", verify: nil, status: .blocked, type: .local),
            ]),
            BacklogSection(name: "Epic B", items: [
                BacklogItem(id: "c", title: "C", verify: nil, status: .awaitingApproval, type: .local),
            ]),
        ])

        XCTAssertEqual(file.statusByItemID, ["a": .done, "b": .blocked, "c": .awaitingApproval])
    }

    // MARK: - The measurement that motivated this

    /// Recomputing over 2026-08-10's records — the day the overstatement was
    /// measured by hand from `GET /v1/metrics` — has to reproduce the case that
    /// was made: 34% reported wasted, of which all but $7.83 belonged to items
    /// that had since shipped, leaving about 1%.
    ///
    /// The fixture is that day's attributed spend collapsed to what moves the
    /// figures: `(cost, outcome, current item status)`. The outcomes are the mix
    /// the day actually ended with — most of the non-`done` spend is on items
    /// that were approved and merged after their run had already been stamped.
    func testTheOverstatementOf20260810IsGone() {
        let items: [(Double, String, BacklogItemStatus)] = [
            (470.68, "done", .done),                    // ran and merged in one pass
            (180.00, "awaiting-approval", .done),       // approved minutes after the run ended
            (55.68, "blocked: verify coverage", .done), // gate refused a pass; item regroomed and merged
            (5.83, "blocked: review did not pass", .ready),
            (2.00, "blocked: stalled", .blocked),
        ]
        let records = items.enumerated().map { index, run in
            record(itemID: "item-\(index)", cost: run.0, outcome: run.1,
                   completedAt: day.addingTimeInterval(Double(index) * 60))
        }
        let status = Dictionary(uniqueKeysWithValues:
            items.enumerated().map { ("item-\($0.offset)", $0.element.2) })

        let old = records.filter { !$0.outcome.hasPrefix("done") }.reduce(0) { $0 + $1.costUSD }
        let economics = RunEconomics.make(records: records, projectPath: nil, itemStatus: status,
                                          from: day, to: day.addingTimeInterval(600))

        XCTAssertEqual(old / economics.spendUSD, 0.34, accuracy: 0.005,
                       "the outcome-based numerator is what reported 34%")
        XCTAssertEqual(economics.unshippedSpendUSD, 7.83, accuracy: 0.01,
                       "only the two items that are still sitting there are waste")
        XCTAssertEqual(economics.wasteShare ?? 0, 0.011, accuracy: 0.002)
        XCTAssertEqual(economics.wasteShareText, "1% wasted")
        XCTAssertEqual(economics.deliveredItems, 3)
    }
}
