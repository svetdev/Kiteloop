import XCTest
import KiteloopCore
@testable import Kiteloop

/// Covers how the autopilot decides what an item is *allowed* to cost.
///
/// Two pieces, tested together because a wrong answer in either one ends a
/// legitimate run early (item → blocked):
/// - `predictedCostUSD` — the precedence chain: the item's own recent actuals,
///   then a stored estimate, then the size's measured band, then nothing;
/// - `effectiveCostCap` — the project's p95 run cost plus half again, with the
///   prediction as the floor; the prediction plus half again before then.
@MainActor
final class BacklogAutopilotCostPredictionTests: XCTestCase {

    private let projectPath = "/tmp/proj"
    private var tempDir: URL!
    private var store: TaskMetricStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try makeTemporaryDirectory(prefix: "autopilot-cost")
        store = TaskMetricStore(
            metricsURL: tempDir.appendingPathComponent("task-metrics.jsonl"),
            estimatesURL: tempDir.appendingPathComponent("task-estimates.jsonl")
        )
    }

    // MARK: - Fixtures

    /// An autopilot wired to the temp metric store. `configURL: nil` keeps
    /// config load/save off disk.
    private func makeAutopilot(metricStore: TaskMetricStore?, projectPath: String?) -> BacklogAutopilot {
        let autopilot = BacklogAutopilot()
        autopilot.configure(
            orchestrator: Orchestrator(runtime: MockAgentRuntime()),
            backlogViewModel: BacklogViewModel(
                globalConfigStore: GlobalConfigStore(storageURL: tempDir.appendingPathComponent("global-config.json"))
            ),
            configURL: nil,
            metricStore: metricStore,
            projectPath: projectPath,
            projectName: "proj"
        )
        return autopilot
    }

    private func item(id: String = "t-1", size: ItemSize? = .m) -> BacklogItem {
        BacklogItem(id: id, title: "Task \(id)", verify: nil, status: .ready, type: .local, size: size)
    }

    private func record(itemID: String, cost: Double, size: String? = "M", project: String? = nil) -> TaskMetricRecord {
        let start = Date()
        return TaskMetricRecord(
            projectPath: project ?? projectPath, projectName: "proj", itemID: itemID,
            title: "Task \(itemID)", epic: nil, declaredSize: size, startedAt: start,
            completedAt: start.addingTimeInterval(300), durationSeconds: 300,
            costUSD: cost, reviewerRetries: 0, outcome: "done",
            workerAgent: "worker", reviewerAgent: "reviewer", executionID: "e-1"
        )
    }

    /// Enough runs of one size for it to have a measured band. The size rung is
    /// deliberately silent below `SizeCalibration.minimumSamples`, so a test
    /// about that rung has to put real evidence behind it.
    private func calibrate(size: String, costs: [Double]) {
        for (index, cost) in costs.enumerated() {
            store.append(record(itemID: "\(size.lowercased())-\(index)", cost: cost, size: size))
        }
    }

    private func calibrate(size: String, cost: Double,
                           samples: Int = SizeCalibration.minimumSamples) {
        calibrate(size: size, costs: Array(repeating: cost, count: samples))
    }

    private func estimate(itemID: String, cost: Double?, project: String? = nil) -> TaskEstimate {
        TaskEstimate(
            itemID: itemID, projectPath: project ?? projectPath, createdAt: Date(), estimatedSize: "M",
            predictedDurationSeconds: 300, predictedCostUSD: cost, predictedRetries: 0,
            confidence: 0.5, source: "hybrid", rationale: "test"
        )
    }

    // MARK: - Precedence: own history wins

    func testOwnHistoryAveragesTheLastThreeRuns() {
        store.append(record(itemID: "t-1", cost: 9.00))  // older than the window
        store.append(record(itemID: "t-1", cost: 1.00))
        store.append(record(itemID: "t-1", cost: 2.00))
        store.append(record(itemID: "t-1", cost: 3.00))

        let autopilot = makeAutopilot(metricStore: store, projectPath: projectPath)
        XCTAssertEqual(autopilot.predictedCostUSD(for: item()) ?? 0, 2.00, accuracy: 0.0001)
    }

    func testOwnHistoryBeatsStoredEstimateAndSizeClass() {
        // All three sources available — the item's own actuals must win, since a
        // stale estimate is exactly what under-predicts pricey items.
        store.append(record(itemID: "t-1", cost: 4.00))
        store.append(record(itemID: "other", cost: 0.10))
        store.appendEstimate(estimate(itemID: "t-1", cost: 0.20))

        let autopilot = makeAutopilot(metricStore: store, projectPath: projectPath)
        XCTAssertEqual(autopilot.predictedCostUSD(for: item()) ?? 0, 4.00, accuracy: 0.0001)
    }

    func testOtherItemsHistoryDoesNotCountAsOwnHistory() {
        // Only "other" has actuals; t-1 must fall through to its estimate.
        store.append(record(itemID: "other", cost: 5.00))
        store.appendEstimate(estimate(itemID: "t-1", cost: 0.30))

        let autopilot = makeAutopilot(metricStore: store, projectPath: projectPath)
        XCTAssertEqual(autopilot.predictedCostUSD(for: item()) ?? 0, 0.30, accuracy: 0.0001)
    }

    func testZeroCostRunsAreIgnoredInOwnHistory() {
        // A run that recorded no cost carries no signal — averaging it in would
        // halve the prediction and cap the next run too tightly.
        store.append(record(itemID: "t-1", cost: 0))
        store.append(record(itemID: "t-1", cost: 3.00))

        let autopilot = makeAutopilot(metricStore: store, projectPath: projectPath)
        XCTAssertEqual(autopilot.predictedCostUSD(for: item()) ?? 0, 3.00, accuracy: 0.0001)
    }

    func testAllZeroCostHistoryFallsThroughToEstimate() {
        store.append(record(itemID: "t-1", cost: 0))
        store.appendEstimate(estimate(itemID: "t-1", cost: 0.75))

        let autopilot = makeAutopilot(metricStore: store, projectPath: projectPath)
        XCTAssertEqual(autopilot.predictedCostUSD(for: item()) ?? 0, 0.75, accuracy: 0.0001)
    }

    // MARK: - Precedence: stored estimate, then size class

    func testStoredEstimateUsedWhenNoOwnHistory() {
        // A measured band exists too; the item-specific estimate outranks it.
        calibrate(size: "M", cost: 1.00)
        store.appendEstimate(estimate(itemID: "t-1", cost: 0.50))

        let autopilot = makeAutopilot(metricStore: store, projectPath: projectPath)
        XCTAssertEqual(autopilot.predictedCostUSD(for: item()) ?? 0, 0.50, accuracy: 0.0001)
    }

    func testLatestEstimateWins() {
        store.appendEstimate(estimate(itemID: "t-1", cost: 0.20))
        store.appendEstimate(estimate(itemID: "t-1", cost: 0.90))

        let autopilot = makeAutopilot(metricStore: store, projectPath: projectPath)
        XCTAssertEqual(autopilot.predictedCostUSD(for: item()) ?? 0, 0.90, accuracy: 0.0001)
    }

    func testNonPositiveEstimateFallsThroughToTheSizeBand() {
        store.appendEstimate(estimate(itemID: "t-1", cost: 0))
        calibrate(size: "M", costs: [1, 2, 3, 3, 3, 3, 4, 5])  // p50 = 3

        let autopilot = makeAutopilot(metricStore: store, projectPath: projectPath)
        XCTAssertEqual(autopilot.predictedCostUSD(for: item()) ?? 0, 3.00, accuracy: 0.0001)
    }

    func testSizeBandUsedWhenNoOwnHistoryOrEstimate() {
        calibrate(size: "M", costs: [1, 1, 2, 2, 2, 3, 3, 4])  // p50 = 2
        calibrate(size: "XL", cost: 20.00)                     // wrong size class

        let autopilot = makeAutopilot(metricStore: store, projectPath: projectPath)
        XCTAssertEqual(autopilot.predictedCostUSD(for: item(size: .m)) ?? 0, 2.00, accuracy: 0.0001)
    }

    func testTooFewRunsOfASizeLeaveTheItemUncapped() {
        // The cold start: one run below the minimum is the difference between a
        // band and no band, and with no band and no measured runs there is
        // nothing to set a ceiling from — the project's budget still bounds it.
        calibrate(size: "M", cost: 4.00, samples: SizeCalibration.minimumSamples - 1)

        let autopilot = makeAutopilot(metricStore: store, projectPath: projectPath)
        XCTAssertNil(autopilot.predictedCostUSD(for: item()))
        XCTAssertNil(autopilot.effectiveCostCap(for: item()))

        // Once the band exists its p50 is the prediction, plus the shared headroom.
        store.append(record(itemID: "one-more", cost: 4.00, size: "M"))
        XCTAssertEqual(autopilot.predictedCostUSD(for: item()) ?? 0, 4.00, accuracy: 0.0001)
        XCTAssertEqual(autopilot.effectiveCostCap(for: item()) ?? 0, 6.00, accuracy: 0.0001)
    }

    func testSizelessItemHasNoSizeBandFallback() {
        calibrate(size: "M", cost: 1.00)

        let autopilot = makeAutopilot(metricStore: store, projectPath: projectPath)
        XCTAssertNil(autopilot.predictedCostUSD(for: item(size: nil)))
    }

    func testSizeBandFallbackNeedsAProjectPath() {
        calibrate(size: "M", cost: 1.00)

        let autopilot = makeAutopilot(metricStore: store, projectPath: nil)
        XCTAssertNil(autopilot.predictedCostUSD(for: item()))
    }

    // MARK: - Precedence: one project at a time

    /// An item id is unique inside a backlog, not across the machine — a copied
    /// epic puts the same id in two projects, and `~/.kiteloop/task-metrics.jsonl`
    /// holds every project's runs in one file.
    func testOwnHistoryAveragesOnlyThisProjectsRuns() {
        store.append(record(itemID: "t-1", cost: 1.00))
        store.append(record(itemID: "t-1", cost: 3.00))
        store.append(record(itemID: "t-1", cost: 90.00, project: "/tmp/elsewhere"))

        let autopilot = makeAutopilot(metricStore: store, projectPath: projectPath)
        XCTAssertEqual(autopilot.predictedCostUSD(for: item()) ?? 0, 2.00, accuracy: 0.0001)
    }

    func testAnotherProjectsRunsAreNotOwnHistory() {
        // Only /tmp/elsewhere has run t-1; this project falls through to its
        // own estimate rather than inheriting a $90 ceiling.
        store.append(record(itemID: "t-1", cost: 90.00, project: "/tmp/elsewhere"))
        store.appendEstimate(estimate(itemID: "t-1", cost: 0.30))

        let autopilot = makeAutopilot(metricStore: store, projectPath: projectPath)
        let prediction = autopilot.predictedCost(for: item())
        XCTAssertEqual(prediction?.source, .storedEstimate)
        XCTAssertEqual(prediction?.usd ?? 0, 0.30, accuracy: 0.0001)
    }

    func testAnotherProjectsRunsLeaveNoPredictionAtAll() {
        // Nothing else to fall through to: no estimate here, and one run is far
        // short of a size band.
        store.append(record(itemID: "t-1", cost: 90.00, project: "/tmp/elsewhere"))

        let autopilot = makeAutopilot(metricStore: store, projectPath: projectPath)
        XCTAssertNil(autopilot.predictedCost(for: item()))
    }

    func testAnotherProjectsStoredEstimateIsNotUsed() {
        store.appendEstimate(estimate(itemID: "t-1", cost: 12.00, project: "/tmp/elsewhere"))

        let autopilot = makeAutopilot(metricStore: store, projectPath: projectPath)
        XCTAssertNil(autopilot.predictedCost(for: item()))
    }

    func testThisProjectsEstimateWinsOverALaterOneElsewhere() {
        store.appendEstimate(estimate(itemID: "t-1", cost: 0.40))
        store.appendEstimate(estimate(itemID: "t-1", cost: 12.00, project: "/tmp/elsewhere"))

        let autopilot = makeAutopilot(metricStore: store, projectPath: projectPath)
        XCTAssertEqual(autopilot.predictedCostUSD(for: item()) ?? 0, 0.40, accuracy: 0.0001)
    }

    /// Two projects, one item id, opposite readings — each governor sees only
    /// what its own project spent.
    func testEachProjectPredictsFromItsOwnRuns() {
        store.append(record(itemID: "t-1", cost: 1.00))
        store.append(record(itemID: "t-1", cost: 8.00, project: "/tmp/elsewhere"))

        let here = makeAutopilot(metricStore: store, projectPath: projectPath)
        let there = makeAutopilot(metricStore: store, projectPath: "/tmp/elsewhere")
        XCTAssertEqual(here.predictedCostUSD(for: item()) ?? 0, 1.00, accuracy: 0.0001)
        XCTAssertEqual(there.predictedCostUSD(for: item()) ?? 0, 8.00, accuracy: 0.0001)
    }

    /// Nothing to scope to means nothing is excluded: a governor with no project
    /// keeps the portfolio-wide reading it has always had.
    func testWithoutAProjectPathThePredictionStaysPortfolioWide() {
        store.append(record(itemID: "t-1", cost: 8.00, project: "/tmp/elsewhere"))

        let autopilot = makeAutopilot(metricStore: store, projectPath: nil)
        let prediction = autopilot.predictedCost(for: item())
        XCTAssertEqual(prediction?.source, .ownHistory)
        XCTAssertEqual(prediction?.usd ?? 0, 8.00, accuracy: 0.0001)
    }

    func testWithoutAProjectPathAStoredEstimateAnywhereStillCounts() {
        store.appendEstimate(estimate(itemID: "t-1", cost: 0.60, project: "/tmp/elsewhere"))

        let autopilot = makeAutopilot(metricStore: store, projectPath: nil)
        let prediction = autopilot.predictedCost(for: item())
        XCTAssertEqual(prediction?.source, .storedEstimate)
        XCTAssertEqual(prediction?.usd ?? 0, 0.60, accuracy: 0.0001)
    }

    // MARK: - No prediction at all

    func testNoPredictionWithoutAMetricStore() {
        let autopilot = makeAutopilot(metricStore: nil, projectPath: projectPath)
        XCTAssertNil(autopilot.predictedCostUSD(for: item()))
    }

    func testNoPredictionWhenStoreIsEmpty() {
        let autopilot = makeAutopilot(metricStore: store, projectPath: projectPath)
        XCTAssertNil(autopilot.predictedCostUSD(for: item()))
    }

    // MARK: - Effective cap: the project's runs, the prediction as the floor

    func testEffectiveCapIsThePredictionPlusHeadroomBeforeTheProjectIsMeasured() {
        store.append(record(itemID: "t-1", cost: 3.00))

        let autopilot = makeAutopilot(metricStore: store, projectPath: projectPath)
        XCTAssertEqual(autopilot.runTimeouts.itemCost.source, .default)
        XCTAssertEqual(autopilot.effectiveCostCap(for: item()) ?? 0, 4.50, accuracy: 0.0001)
    }

    func testEffectiveCapIsTheProjectsP95PlusHalfAgainOnceFiveRunsLanded() {
        for (index, cost) in [1.00, 2.00, 3.00, 4.00, 6.00].enumerated() {
            var landed = record(itemID: "landed-\(index)", cost: cost, size: nil)
            landed.workerPhaseSeconds = 600
            store.append(landed)
        }

        let autopilot = makeAutopilot(metricStore: store, projectPath: projectPath)
        XCTAssertEqual(autopilot.runTimeouts.itemCost, RunTimeouts.CostBound(usd: 9.00, source: .derived))
        XCTAssertEqual(autopilot.effectiveCostCap(for: item()) ?? 0, 9.00, accuracy: 0.0001)
    }

    // MARK: - Which rung produced the prediction

    func testPredictionSourceIsOwnHistory() {
        store.append(record(itemID: "t-1", cost: 3.00))
        store.appendEstimate(estimate(itemID: "t-1", cost: 0.20))

        let autopilot = makeAutopilot(metricStore: store, projectPath: projectPath)
        XCTAssertEqual(autopilot.predictedCost(for: item())?.source, .ownHistory)
    }

    func testPredictionSourceIsStoredEstimate() {
        store.appendEstimate(estimate(itemID: "t-1", cost: 0.50))

        let autopilot = makeAutopilot(metricStore: store, projectPath: projectPath)
        XCTAssertEqual(autopilot.predictedCost(for: item())?.source, .storedEstimate)
    }

    func testPredictionSourceIsTheSizeBand() {
        calibrate(size: "M", cost: 4.00)

        let autopilot = makeAutopilot(metricStore: store, projectPath: projectPath)
        XCTAssertEqual(autopilot.predictedCost(for: item())?.source, .sizeBand)
    }

    // MARK: - The cap log line

    func testLogLineNamesTheCapAndItsSourceWhenThePredictionWins() {
        store.append(record(itemID: "t-1", cost: 3.00))

        let autopilot = makeAutopilot(metricStore: store, projectPath: projectPath)
        XCTAssertEqual(
            autopilot.costCapLogLine(for: item()),
            "Cost cap: $4.50 (own history $3.00 × 1.5 headroom)"
        )
    }

    func testLogLineReportsNoCapWithNothingToSetOne() {
        let autopilot = makeAutopilot(metricStore: store, projectPath: projectPath)
        XCTAssertEqual(
            autopilot.costCapLogLine(for: item()),
            "Cost cap: none (too few landed runs and no cost prediction)"
        )
    }

    // MARK: - The panel's cost readout

    private func readout(
        itemSpend: Double = 0, itemCap: Double? = nil,
        sessionSpend: Double = 0, sessionCap: Double? = nil
    ) -> BacklogAutopilot.CostReadout {
        BacklogAutopilot.CostReadout(
            itemSpendUSD: itemSpend, itemCapUSD: itemCap,
            sessionSpendUSD: sessionSpend, sessionCapUSD: sessionCap
        )
    }

    func testReadoutShowsSpendAgainstItsCap() {
        let r = readout(itemSpend: 0.42, itemCap: 4.50, sessionSpend: 3.10, sessionCap: 10)
        XCTAssertEqual(r.itemText, "$0.42 of $4.50")
        XCTAssertEqual(r.sessionText, "$3.10 of $10.00")
    }

    func testReadoutShowsSpendAloneWhenUncapped() {
        // "of $0.00" would read as a cap of zero — an uncapped budget has no
        // ceiling to name, so only the spend is shown.
        let r = readout(itemSpend: 0.42, itemCap: nil, sessionSpend: 3.10, sessionCap: nil)
        XCTAssertEqual(r.itemText, "$0.42")
        XCTAssertEqual(r.sessionText, "$3.10")
    }

    func testReadoutWarnsOnlyOnceSpendIsNearACap() {
        XCTAssertFalse(readout(itemSpend: 3.00, itemCap: 4.50).isItemNearCap)   // 67%
        XCTAssertTrue(readout(itemSpend: 3.60, itemCap: 4.50).isItemNearCap)    // 80%
        XCTAssertTrue(readout(itemSpend: 5.00, itemCap: 4.50).isItemNearCap)    // over
        XCTAssertTrue(readout(sessionSpend: 8.00, sessionCap: 10).isSessionNearCap)
        XCTAssertFalse(readout(sessionSpend: 1.00, sessionCap: 10).isSessionNearCap)
    }

    func testReadoutNeverWarnsWithoutACap() {
        // No ceiling means nothing to be near, however much has been spent.
        let r = readout(itemSpend: 99, itemCap: nil, sessionSpend: 99, sessionCap: nil)
        XCTAssertFalse(r.isItemNearCap)
        XCTAssertFalse(r.isSessionNearCap)
    }

    func testUtilizationIsNilWithoutAUsableCap() {
        XCTAssertNil(BacklogAutopilot.CostReadout.utilization(spend: 1, cap: nil))
        XCTAssertNil(BacklogAutopilot.CostReadout.utilization(spend: 1, cap: 0))
        XCTAssertEqual(
            BacklogAutopilot.CostReadout.utilization(spend: 1, cap: 4) ?? 0,
            0.25, accuracy: 0.0001
        )
    }

    func testReadoutStartsEmptyAndCarriesTheSessionCap() {
        let autopilot = makeAutopilot(metricStore: store, projectPath: projectPath)
        autopilot.budgetUSD = 10.00

        let r = autopilot.costReadout
        XCTAssertEqual(r.itemSpendUSD, 0)
        XCTAssertNil(r.itemCapUSD, "no item is in flight, so there is no effective cap yet")
        XCTAssertEqual(r.sessionSpendUSD, 0)
        XCTAssertEqual(r.sessionCapUSD ?? 0, 10.00, accuracy: 0.0001)
        XCTAssertEqual(r.sessionText, "$0.00 of $10.00")
    }
}
