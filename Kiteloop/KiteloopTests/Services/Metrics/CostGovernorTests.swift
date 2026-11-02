import XCTest
import KiteloopCore
@testable import Kiteloop

/// Covers `CostGovernor` — the autopilot's whole money model, exercised directly
/// rather than through a run loop.
///
/// Everything here decides whether a run is allowed to keep going, so a wrong
/// answer either ends legitimate work early (item → blocked) or lets a runaway
/// spend past the ceiling someone set. The three parts:
/// - the **prediction chain** — own actuals, then a stored estimate, then the
///   size's measured band (and the flag raised when the two disagree);
/// - the **ceilings** — the project's measured cap, never below the prediction, per item, plus the
///   session budget, and what a breach of each one does;
/// - the **session bookkeeping** — what's in flight vs. what's been charged.
@MainActor
final class CostGovernorTests: XCTestCase {

    private let projectPath = "/tmp/proj"
    private var tempDir: URL!
    private var store: TaskMetricStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try makeTemporaryDirectory(prefix: "cost-governor")
        store = TaskMetricStore(
            metricsURL: tempDir.appendingPathComponent("task-metrics.jsonl"),
            estimatesURL: tempDir.appendingPathComponent("task-estimates.jsonl")
        )
    }

    // MARK: - Fixtures

    /// `perItemCap` stands in for the project's measured cost bound — what five
    /// landed runs would derive; nil is a project too new to have one.
    private func governor(
        perItemCap: Double? = nil,
        sessionCap: Double? = nil,
        metricStore: TaskMetricStore? = nil,
        projectPath: String? = nil
    ) -> CostGovernor {
        var governor = CostGovernor()
        governor.itemCostBound = RunTimeouts.CostBound(usd: perItemCap,
                                                       source: perItemCap == nil ? .default : .derived)
        governor.sessionCapUSD = sessionCap
        governor.metricStore = metricStore
        governor.projectPath = projectPath
        return governor
    }

    private func item(id: String = "t-1", size: ItemSize? = .m) -> BacklogItem {
        BacklogItem(id: id, title: "Task \(id)", verify: nil, status: .ready, type: .local, size: size)
    }

    private func record(itemID: String, cost: Double, size: String? = "M") -> TaskMetricRecord {
        let start = Date()
        var record = TaskMetricRecord(
            projectPath: projectPath, projectName: "proj", itemID: itemID,
            title: "Task \(itemID)", epic: nil, declaredSize: size, startedAt: start,
            completedAt: start.addingTimeInterval(300), durationSeconds: 300,
            costUSD: cost, reviewerRetries: 0, outcome: "done",
            workerAgent: "worker", reviewerAgent: "reviewer", executionID: "e-1"
        )
        record.changedFileCount = 4
        return record
    }

    /// A size class with enough evidence behind it to have a band — the size
    /// rung is deliberately silent below `SizeCalibration.minimumSamples`.
    private func calibrate(size: String, costs: [Double]) {
        for (index, cost) in costs.enumerated() {
            store.append(record(itemID: "\(size.lowercased())-\(index)", cost: cost, size: size))
        }
    }

    private func calibrate(size: String, cost: Double,
                           samples: Int = SizeCalibration.minimumSamples) {
        calibrate(size: size, costs: Array(repeating: cost, count: samples))
    }

    private func estimate(itemID: String, cost: Double?) -> TaskEstimate {
        TaskEstimate(
            itemID: itemID, projectPath: projectPath, createdAt: Date(), estimatedSize: "M",
            predictedDurationSeconds: 300, predictedCostUSD: cost, predictedRetries: 0,
            confidence: 0.5, source: "hybrid", rationale: "test"
        )
    }

    // MARK: - Prediction chain

    func testOwnHistoryAveragesTheMostRecentRunsOnly() {
        store.append(record(itemID: "t-1", cost: 9.00))  // older than the window
        store.append(record(itemID: "t-1", cost: 1.00))
        store.append(record(itemID: "t-1", cost: 2.00))
        store.append(record(itemID: "t-1", cost: 3.00))

        let g = governor(metricStore: store, projectPath: projectPath)
        XCTAssertEqual(g.predictedCost(for: item()), .init(usd: 2.00, source: .ownHistory))
    }

    func testOwnHistoryOutranksTheOtherRungs() {
        // All three sources available. A stale estimate is exactly what
        // under-predicts a pricey item, so the item's own actuals must win.
        store.append(record(itemID: "t-1", cost: 4.00))
        store.append(record(itemID: "other", cost: 0.10))
        store.appendEstimate(estimate(itemID: "t-1", cost: 0.20))

        let g = governor(metricStore: store, projectPath: projectPath)
        XCTAssertEqual(g.predictedCost(for: item()), .init(usd: 4.00, source: .ownHistory))
    }

    func testZeroCostRunsCarryNoSignal() {
        // Averaging a $0 run in would halve the prediction and cap the next run
        // too tightly.
        store.append(record(itemID: "t-1", cost: 0))
        store.append(record(itemID: "t-1", cost: 3.00))

        let g = governor(metricStore: store, projectPath: projectPath)
        XCTAssertEqual(g.predictedCost(for: item()), .init(usd: 3.00, source: .ownHistory))
    }

    func testFallsThroughToTheLatestStoredEstimate() {
        store.appendEstimate(estimate(itemID: "t-1", cost: 0.20))
        store.appendEstimate(estimate(itemID: "t-1", cost: 0.90))

        let g = governor(metricStore: store, projectPath: projectPath)
        XCTAssertEqual(g.predictedCost(for: item()), .init(usd: 0.90, source: .storedEstimate))
    }

    func testFallsThroughToTheSizeBandsMeasuredMiddle() {
        store.appendEstimate(estimate(itemID: "t-1", cost: 0))  // non-positive ⇒ no signal
        calibrate(size: "M", costs: [1, 2, 3, 3, 3, 3, 4, 5])   // p50 = 3
        calibrate(size: "XL", cost: 20.00)                      // wrong size class

        let g = governor(metricStore: store, projectPath: projectPath)
        XCTAssertEqual(g.predictedCost(for: item(size: .m)), .init(usd: 3.00, source: .sizeBand))
    }

    func testTheSizeBandIgnoresRunsThatProducedNothing() {
        // A band that counts $0 and no-diff runs predicts the pipeline's
        // failures rather than the work, and every ceiling from it comes out
        // too low.
        calibrate(size: "M", cost: 4.00)
        for index in 0..<12 {
            var dead = record(itemID: "dead-\(index)", cost: 0, size: "M")
            dead.changedFileCount = 0
            store.append(dead)
        }

        let g = governor(metricStore: store, projectPath: projectPath)
        XCTAssertEqual(g.predictedCost(for: item(size: .m)), .init(usd: 4.00, source: .sizeBand))
    }

    func testTooFewRunsOfASizeMeanNoPredictionRatherThanAConfidentOne() {
        // The cold start: below the minimum there is no band, so the caller
        // keeps the project's measured cap instead of a p50 derived from three runs.
        calibrate(size: "M", cost: 4.00, samples: SizeCalibration.minimumSamples - 1)

        var g = governor(perItemCap: 2.00, metricStore: store, projectPath: projectPath)
        XCTAssertNil(g.predictedCost(for: item(size: .m)))
        XCTAssertEqual(g.effectiveItemCap(for: item(size: .m)), 2.00)
        XCTAssertEqual(g.capLogLine(for: item(size: .m)),
                       "Cost cap: $2.00 (project p95 run cost × 1.5 headroom)")
        XCTAssertEqual(g.beginItem(item(size: .m)), 2.00)
    }

    func testSizeBandFallbackNeedsBothASizeAndAProject() {
        calibrate(size: "M", cost: 1.00)

        XCTAssertNil(governor(metricStore: store, projectPath: projectPath).predictedCost(for: item(size: nil)))
        XCTAssertNil(governor(metricStore: store, projectPath: nil).predictedCost(for: item()))
    }

    // MARK: - Does the label match the work?

    func testAnItemPredictedAboveItsSizeBandIsFlagged() {
        // The case this exists for: an item sized S whose own runs cost what an
        // M costs. Its own history outranks the band as a prediction — the flag
        // is what says the two disagree.
        calibrate(size: "S", costs: [0.9, 1.2, 1.6, 1.9, 2.0, 2.1, 2.6, 3.1, 3.8, 4.2])
        store.append(record(itemID: "escaped-defect-tracking", cost: 13.27, size: "S"))

        let g = governor(metricStore: store, projectPath: projectPath)
        let flagged = item(id: "escaped-defect-tracking", size: .s)
        XCTAssertEqual(g.predictedCost(for: flagged)?.source, .ownHistory)
        XCTAssertEqual(g.sizeFlag(for: flagged)?.edge, .above)
    }

    func testAnItemPredictedInsideItsSizeBandIsNotFlagged() {
        calibrate(size: "S", costs: [0.9, 1.2, 1.6, 1.9, 2.0, 2.1, 2.6, 3.1, 3.8, 4.2])
        store.append(record(itemID: "t-1", cost: 2.00, size: "S"))

        let g = governor(metricStore: store, projectPath: projectPath)
        XCTAssertNil(g.sizeFlag(for: item(size: .s)))
    }

    func testNothingIsFlaggedBeforeASizeHasBeenMeasured() {
        // Cold start: no band, so no opinion about the label.
        store.append(record(itemID: "t-1", cost: 13.27, size: "S"))

        let g = governor(metricStore: store, projectPath: projectPath)
        XCTAssertNil(g.sizeBand(for: item(size: .s)))
        XCTAssertNil(g.sizeFlag(for: item(size: .s)))
    }

    func testAPredictionFromTheBandItselfIsNeverFlagged() {
        calibrate(size: "M", costs: [1, 2, 3, 3, 3, 3, 4, 5])

        let g = governor(metricStore: store, projectPath: projectPath)
        XCTAssertEqual(g.predictedCost(for: item(size: .m))?.source, .sizeBand)
        XCTAssertNil(g.sizeFlag(for: item(size: .m)))
    }

    func testNoPredictionWithoutHistoryToPredictFrom() {
        XCTAssertNil(governor(metricStore: nil, projectPath: projectPath).predictedCost(for: item()))
        XCTAssertNil(governor(metricStore: store, projectPath: projectPath).predictedCost(for: item()))
    }

    // MARK: - The per-item ceiling

    func testUncappedWithNeitherMeasuredRunsNorAPrediction() {
        let g = governor(perItemCap: nil, metricStore: store, projectPath: projectPath)
        XCTAssertNil(g.effectiveItemCap(for: item()), "nothing to measure the ceiling from")
    }

    func testBeforeMeasuringThePredictionPlusHeadroomIsTheCeiling() {
        store.append(record(itemID: "t-1", cost: 3.00))

        let g = governor(perItemCap: nil, metricStore: store, projectPath: projectPath)
        XCTAssertEqual(g.effectiveItemCap(for: item()) ?? 0, 4.50, accuracy: 0.0001)
    }

    func testTheMeasuredCapStandsAboveACheapPrediction() {
        store.append(record(itemID: "t-1", cost: 0.10))

        let g = governor(perItemCap: 2.00, metricStore: store, projectPath: projectPath)
        XCTAssertEqual(g.effectiveItemCap(for: item()) ?? 0, 2.00, accuracy: 0.0001)
    }

    func testThePredictionIsTheFloorUnderTheMeasuredCap() {
        store.append(record(itemID: "t-1", cost: 3.00))

        let g = governor(perItemCap: 2.00, metricStore: store, projectPath: projectPath)
        XCTAssertEqual(g.effectiveItemCap(for: item()) ?? 0, 3.00, accuracy: 0.0001)
    }

    func testTheMeasuredCapAppliesWhenNothingIsPredicted() {
        let g = governor(perItemCap: 2.00, metricStore: store, projectPath: projectPath)
        XCTAssertEqual(g.effectiveItemCap(for: item()) ?? 0, 2.00, accuracy: 0.0001)
    }

    // MARK: - The cap log line

    func testLogLineNamesThePredictionThatSetTheCap() {
        store.append(record(itemID: "t-1", cost: 3.00))

        let g = governor(perItemCap: nil, metricStore: store, projectPath: projectPath)
        XCTAssertEqual(g.capLogLine(for: item()), "Cost cap: $4.50 (own history $3.00 × 1.5 headroom)")
    }

    func testLogLineSaysWhetherTheProjectsRunsOrThePredictionWon() {
        store.appendEstimate(estimate(itemID: "t-1", cost: 0.10))
        let measured = governor(perItemCap: 2.00, metricStore: store, projectPath: projectPath)
        XCTAssertEqual(measured.capLogLine(for: item()),
                       "Cost cap: $2.00 (project p95 run cost × 1.5 headroom)")

        store.append(record(itemID: "t-1", cost: 3.00))
        let predicted = governor(perItemCap: 2.00, metricStore: store, projectPath: projectPath)
        XCTAssertEqual(predicted.capLogLine(for: item()),
                       "Cost cap: $3.00 (own history $3.00 above the project's runs)")
    }

    func testLogLineSaysWhenThereIsNoCap() {
        let noCap = governor(perItemCap: nil, metricStore: store, projectPath: projectPath)
        XCTAssertEqual(noCap.capLogLine(for: item()),
                       "Cost cap: none (too few landed runs and no cost prediction)")
    }

    // MARK: - Item lifecycle

    func testBeginItemFixesTheCeilingTheItemIsMeasuredAgainst() {
        store.append(record(itemID: "t-1", cost: 3.00))

        var g = governor(perItemCap: nil, metricStore: store, projectPath: projectPath)
        XCTAssertNil(g.currentItemCapUSD, "nothing in flight yet")
        XCTAssertEqual(g.beginItem(item()) ?? 0, 4.50, accuracy: 0.0001)
        XCTAssertEqual(g.currentItemCapUSD ?? 0, 4.50, accuracy: 0.0001)
    }

    func testBeginItemHoldsTheForecastTheRunWillBeRecordedAgainst() {
        // What makes the forecast improvable: the run records this beside what
        // it actually cost. Held rather than re-derived at the end, because by
        // then this run is itself the first rung of the chain.
        store.append(record(itemID: "t-1", cost: 3.00))

        var g = governor(perItemCap: 2.00, metricStore: store, projectPath: projectPath)
        XCTAssertNil(g.currentItemPrediction, "nothing in flight yet")

        g.beginItem(item())
        XCTAssertEqual(g.currentItemPrediction, .init(usd: 3.00, source: .ownHistory))

        // Still there once the item's spend has been charged — the run records
        // the metric after that.
        g.chargeItem(3.20)
        XCTAssertEqual(g.currentItemPrediction?.usd, 3.00)

        g.endItem()
        XCTAssertNil(g.currentItemPrediction)
    }

    func testAnItemWithNothingToPredictFromHoldsNoForecast() {
        var g = governor(perItemCap: 2.00, metricStore: store, projectPath: projectPath)
        g.beginItem(item())
        XCTAssertNil(g.currentItemPrediction, "no prediction is not a prediction of $0")
        XCTAssertEqual(g.currentItemCapUSD, 2.00)
    }

    func testChargingAnItemMovesItsSpendOutOfFlight() {
        // The readout adds the two figures, so an item counted in both would show
        // its cost twice until the next sample cleared it.
        var g = governor(sessionCap: 10)
        g.beginItem(item())
        _ = g.sample(itemSpendUSD: 1.25)
        XCTAssertEqual(g.currentItemSpendUSD, 1.25, accuracy: 0.0001)

        g.chargeItem(1.40)
        XCTAssertEqual(g.spentThisSession, 1.40, accuracy: 0.0001)
        XCTAssertEqual(g.currentItemSpendUSD, 0, accuracy: 0.0001)
        XCTAssertEqual(g.readout.sessionSpendUSD, 1.40, accuracy: 0.0001)
    }

    func testEndItemClearsTheInFlightFiguresButKeepsTheSessionSpend() {
        var g = governor(perItemCap: 5)
        g.beginItem(item())
        _ = g.sample(itemSpendUSD: 2.00)
        g.chargeItem(2.00)
        g.endItem()

        XCTAssertEqual(g.currentItemSpendUSD, 0, accuracy: 0.0001)
        XCTAssertNil(g.currentItemCapUSD)
        XCTAssertEqual(g.spentThisSession, 2.00, accuracy: 0.0001)
    }

    func testStartSessionClearsTheSpendButKeepsTheConfiguredCaps() {
        var g = governor(perItemCap: 2, sessionCap: 10)
        g.beginItem(item())
        _ = g.sample(itemSpendUSD: 1)
        g.chargeItem(10.00)
        XCTAssertNotNil(g.sessionPause, "the session budget is spent")

        g.startSession()
        XCTAssertEqual(g.spentThisSession, 0, accuracy: 0.0001)
        XCTAssertEqual(g.currentItemSpendUSD, 0, accuracy: 0.0001)
        XCTAssertNil(g.currentItemCapUSD)
        XCTAssertNil(g.sessionPause, "a fresh session must not inherit the last one's spend")
        XCTAssertEqual(g.itemCostBound.usd, 2)
        XCTAssertEqual(g.sessionCapUSD, 10)
    }

    /// Every driver starts one item per run, so a run that zeroed the ledger made
    /// each item its own session and the session cap bounded a single item. Two
    /// runs are one sitting until somebody says otherwise.
    func testStartRunKeepsWhatTheRunsBeforeItSpent() {
        var g = governor(perItemCap: 2, sessionCap: 10)
        g.beginItem(item())
        _ = g.sample(itemSpendUSD: 4.00)
        g.chargeItem(4.00)
        g.endItem()

        g.startRun()
        g.beginItem(item(id: "t-2"))
        _ = g.sample(itemSpendUSD: 3.00)

        XCTAssertEqual(g.spentThisSession, 4.00, accuracy: 0.0001, "the first run's item is still charged")
        XCTAssertEqual(g.readout.sessionSpendUSD, 7.00, accuracy: 0.0001,
                       "the session is both runs, the one in flight included")
    }

    /// What a run does clear: the item in flight, its ceiling and its forecast,
    /// none of which mean anything to the next run.
    func testStartRunClearsTheItemBookkeeping() {
        var g = governor(perItemCap: 2, sessionCap: 10)
        g.beginItem(item())
        _ = g.sample(itemSpendUSD: 1.50)

        g.startRun()

        XCTAssertEqual(g.currentItemSpendUSD, 0, accuracy: 0.0001)
        XCTAssertNil(g.currentItemCapUSD)
        XCTAssertNil(g.currentItemPrediction)
    }

    /// And the cap is enforced against the accumulated figure: two runs that are
    /// each affordable on their own can still spend the session's budget between
    /// them, which is the whole point of a ceiling on the sitting.
    func testTheSessionCapIsMeasuredAgainstEveryRunOfTheSession() {
        var g = governor(sessionCap: 10.00)
        g.beginItem(item())
        g.chargeItem(6.00)
        g.endItem()
        XCTAssertNil(g.sessionPause, "still room after the first run")

        g.startRun()
        g.beginItem(item(id: "t-2"))
        XCTAssertEqual(g.sample(itemSpendUSD: 4.50), .session(cap: 10.00, spent: 10.50),
                       "the second run's spend lands on top of the first one's")
        g.chargeItem(4.50)
        XCTAssertEqual(g.takeSessionPause(), .init(capUSD: 10.00, spentUSD: 10.50))
    }

    // MARK: - Breaches

    func testSampleRecordsSpendAndReportsNoBreachInsideTheCeilings() {
        var g = governor(perItemCap: 5, sessionCap: 10)
        g.beginItem(item())

        XCTAssertNil(g.sample(itemSpendUSD: 4.99))
        XCTAssertEqual(g.currentItemSpendUSD, 4.99, accuracy: 0.0001)
    }

    func testSampleReportsAnItemBreachPastTheItemCeiling() {
        var g = governor(perItemCap: 2.00)
        g.beginItem(item())  // no prediction ⇒ the measured cap is the ceiling

        XCTAssertEqual(g.sample(itemSpendUSD: 2.01), .item(cap: 2.00, spent: 2.01))
        XCTAssertNil(g.takeSessionPause(), "one expensive item must not stop the whole queue")
    }

    func testSampleMeasuresAgainstTheEffectiveCeilingNotTheFlatCap() {
        // The prediction set the ceiling at 4.50; spending past the 3.00
        // predicted is legitimate work, not a breach.
        store.append(record(itemID: "t-1", cost: 3.00))
        var g = governor(perItemCap: nil, metricStore: store, projectPath: projectPath)
        g.beginItem(item())

        XCTAssertNil(g.sample(itemSpendUSD: 3.00))
        XCTAssertEqual(g.sample(itemSpendUSD: 4.51), .item(cap: 4.50, spent: 4.51))
    }

    func testSessionBreachOutranksTheItemBreachAndPausesTheQueue() {
        // One item blowing the session budget has to stop the whole run, so the
        // more severe breach is the one reported — and remembered.
        var g = governor(perItemCap: 2.00, sessionCap: 10.00)
        g.chargeItem(9.00)
        g.beginItem(item())

        XCTAssertEqual(g.sample(itemSpendUSD: 2.50), .session(cap: 10.00, spent: 11.50))
        g.chargeItem(2.50)
        XCTAssertEqual(g.takeSessionPause(), .init(capUSD: 10.00, spentUSD: 11.50))
    }

    func testTakeSessionPauseIsReportedOnce() {
        var g = governor(sessionCap: 10.00)
        g.beginItem(item())
        _ = g.sample(itemSpendUSD: 10.01)
        g.chargeItem(0)  // the flag alone must be enough to pause

        XCTAssertNotNil(g.takeSessionPause())
        XCTAssertNil(g.takeSessionPause(), "the flag is cleared as it's reported")
    }

    func testUncappedRunsNeverBreachHoweverMuchTheySpend() {
        var g = governor(perItemCap: nil, sessionCap: nil)
        g.beginItem(item())

        XCTAssertNil(g.sample(itemSpendUSD: 500))
        g.chargeItem(500)
        XCTAssertNil(g.sessionPause)
        XCTAssertNil(g.takeSessionPause())
    }

    func testSessionPauseFiresOnceTheBudgetIsSpent() {
        var g = governor(sessionCap: 10.00)
        g.chargeItem(9.75)
        XCTAssertNil(g.sessionPause, "still room to start another item")

        g.chargeItem(0.25)
        XCTAssertEqual(g.sessionPause, .init(capUSD: 10.00, spentUSD: 10.00),
                       "exactly spent counts as spent — there is no budget left")
    }

    func testBreachAndPauseWording() {
        XCTAssertEqual(
            CostGovernor.breachReason(.item(cap: 4.50, spent: 4.61), node: "worker"),
            "cost cap $4.50 exceeded ($4.61) on worker"
        )
        XCTAssertEqual(
            CostGovernor.breachReason(.session(cap: 10, spent: 11.5), node: "reviewer"),
            "session cost cap $10.00 exceeded ($11.50) on reviewer"
        )

        let pause = CostGovernor.SessionPause(capUSD: 10, spentUSD: 11.5)
        XCTAssertEqual(
            pause.logLine,
            "Session cost cap $10.00 reached ($11.50) — pausing autopilot; "
            + "resume to keep going on a fresh session budget"
        )
        // The way out the pause names is the one that exists: resuming opens the
        // next session, and pointing at the cap instead would send an operator to
        // change a setting they don't have to.
        XCTAssertEqual(
            pause.resumeLine,
            "Session cost cap $10.00 reached ($11.50) — resuming on a fresh session budget"
        )
        XCTAssertEqual(pause.eventReason, "session cost cap $10.00 reached")
        XCTAssertEqual(pause.spentText, "11.50")
    }

    // MARK: - The near-cap warning

    func testNearCapWarningFiresOnceSpendCrossesTheThreshold() {
        var g = governor(perItemCap: 10.00)
        g.beginItem(item())

        XCTAssertNil(g.nearCapWarning(itemSpendUSD: 7.99), "below the 80% threshold")
        XCTAssertEqual(g.nearCapWarning(itemSpendUSD: 8.00), .init(capUSD: 10.00, spentUSD: 8.00))
        XCTAssertNil(g.nearCapWarning(itemSpendUSD: 9.50), "already warned this item")
    }

    func testNearCapWarningIsMeasuredAgainstTheEffectiveCeilingNotTheFlatCap() {
        // As `testSampleMeasuresAgainstTheEffectiveCeilingNotTheFlatCap`: the
        // prediction set the ceiling at 4.50, so the warning is read against
        // that, not the 3.00 predicted.
        store.append(record(itemID: "t-1", cost: 3.00))
        var g = governor(perItemCap: nil, metricStore: store, projectPath: projectPath)
        g.beginItem(item())

        XCTAssertNil(g.nearCapWarning(itemSpendUSD: 3.00), "under 4.50's threshold")
        XCTAssertEqual(g.nearCapWarning(itemSpendUSD: 3.60), .init(capUSD: 4.50, spentUSD: 3.60))
    }

    func testNearCapWarningResetsAtTheItemBoundary() {
        var g = governor(perItemCap: 10.00)
        g.beginItem(item())
        _ = g.nearCapWarning(itemSpendUSD: 8.00)
        g.endItem()

        g.beginItem(item(id: "t-2"))
        XCTAssertEqual(g.nearCapWarning(itemSpendUSD: 8.00), .init(capUSD: 10.00, spentUSD: 8.00),
                       "a new item gets its own warning")
    }

    func testNearCapWarningIsNilWhenUncapped() {
        var g = governor(perItemCap: nil)
        g.beginItem(item())

        XCTAssertNil(g.nearCapWarning(itemSpendUSD: 1_000_000))
    }

    func testNearCapWarningDoesNotSuppressTheBreachThatFollowsIt() {
        // A run that lingers above the threshold, then goes over the cap
        // outright, reports both — the warning once, then the breach.
        var g = governor(perItemCap: 10.00)
        g.beginItem(item())

        XCTAssertEqual(g.nearCapWarning(itemSpendUSD: 8.00), .init(capUSD: 10.00, spentUSD: 8.00))
        XCTAssertNil(g.sample(itemSpendUSD: 8.00))
        XCTAssertNil(g.nearCapWarning(itemSpendUSD: 10.01), "already warned")
        XCTAssertEqual(g.sample(itemSpendUSD: 10.01), .item(cap: 10.00, spent: 10.01))
    }

    func testNearCapWarningLogLine() {
        let warning = CostGovernor.NearCapWarning(capUSD: 10.00, spentUSD: 8.00)
        XCTAssertEqual(warning.logLine, "80% of cost cap $10.00 spent ($8.00)")
    }

    // MARK: - The panel's readout

    func testReadoutShowsBothSpendsAgainstTheirCeilings() {
        store.append(record(itemID: "t-1", cost: 3.00))
        // Unmeasured, so the ceiling ($3.00 predicted × 1.5) differs from the prediction.
        var g = governor(perItemCap: nil, sessionCap: 10,
                         metricStore: store, projectPath: projectPath)
        g.chargeItem(3.10)
        g.beginItem(item())
        _ = g.sample(itemSpendUSD: 0.42)

        let r = g.readout
        XCTAssertEqual(r.itemText, "$0.42 of $4.50", "the effective ceiling, not the prediction")
        XCTAssertEqual(r.sessionText, "$3.52 of $10.00", "in-flight spend counts toward the session")
    }

    func testReadoutShowsSpendAloneWhenUncapped() {
        // "of $0.00" would read as a cap of zero — an uncapped budget has no
        // ceiling to name.
        var g = governor()
        g.chargeItem(3.10)
        g.beginItem(item())
        _ = g.sample(itemSpendUSD: 0.42)

        XCTAssertEqual(g.readout.itemText, "$0.42")
        XCTAssertEqual(g.readout.sessionText, "$3.52")
    }

    func testReadoutWarnsOnlyOnceSpendIsNearACeiling() {
        func readout(itemSpend: Double = 0, itemCap: Double? = nil,
                     sessionSpend: Double = 0, sessionCap: Double? = nil) -> CostGovernor.Readout {
            .init(itemSpendUSD: itemSpend, itemCapUSD: itemCap,
                  sessionSpendUSD: sessionSpend, sessionCapUSD: sessionCap)
        }

        XCTAssertFalse(readout(itemSpend: 3.00, itemCap: 4.50).isItemNearCap)   // 67%
        XCTAssertTrue(readout(itemSpend: 3.60, itemCap: 4.50).isItemNearCap)    // 80%
        XCTAssertTrue(readout(itemSpend: 5.00, itemCap: 4.50).isItemNearCap)    // over
        XCTAssertTrue(readout(sessionSpend: 8.00, sessionCap: 10).isSessionNearCap)
        XCTAssertFalse(readout(sessionSpend: 1.00, sessionCap: 10).isSessionNearCap)
        // No ceiling means nothing to be near, however much has been spent.
        let uncapped = readout(itemSpend: 99, sessionSpend: 99)
        XCTAssertFalse(uncapped.isItemNearCap)
        XCTAssertFalse(uncapped.isSessionNearCap)
    }

    func testUtilizationIsNilWithoutAUsableCap() {
        XCTAssertNil(CostGovernor.Readout.utilization(spend: 1, cap: nil))
        XCTAssertNil(CostGovernor.Readout.utilization(spend: 1, cap: 0))
        XCTAssertEqual(CostGovernor.Readout.utilization(spend: 1, cap: 4) ?? 0, 0.25, accuracy: 0.0001)
    }

    // MARK: - Reading and writing the settings

    func testParsingWhatTheCapFieldsAccept() {
        for text in ["", "   ", "abc", "0", "-1", "$0"] {
            XCTAssertNil(CostGovernor.parseCapUSD(text), "expected no cap for \(text.debugDescription)")
        }
        XCTAssertEqual(CostGovernor.parseCapUSD("5"), 5)
        XCTAssertEqual(CostGovernor.parseCapUSD("$12.50"), 12.50)
        XCTAssertEqual(CostGovernor.parseCapUSD("  $ 7.25  "), 7.25)
    }

    func testFormattingRoundTripsThroughParsing() {
        XCTAssertEqual(CostGovernor.formatCapUSD(nil), "")
        XCTAssertEqual(CostGovernor.formatCapUSD(12.5), "12.50")
        for value in [0.01, 1, 2.5, 99.99] {
            XCTAssertEqual(CostGovernor.parseCapUSD(CostGovernor.formatCapUSD(value)), value)
        }
    }

    func testANewGovernorIsUncappedUntilTheProjectsRunsAreMeasured() {
        let g = CostGovernor()
        XCTAssertEqual(g.itemCostBound, RunTimeouts.CostBound(usd: nil, source: .default))
        XCTAssertNil(g.sessionCapUSD)
        XCTAssertEqual(g.spentThisSession, 0)
    }
}
