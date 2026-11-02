import XCTest
@testable import KiteloopCore

/// `RunTimeouts` is the one place the worker node's and the merge gate's
/// deadlines are decided. Each edge of the derivation is pinned here: the
/// too-few-runs default, the two floors, the worker's cap, that each deadline
/// reads only the phase it bounds, and that each counts only that phase's
/// samples — so a project whose runs stop at the merge gate measures a worker
/// deadline while its gate one stays on the default.
final class RunTimeoutsTests: XCTestCase {
    /// `count` runs whose phases each took the given number of seconds; nil is
    /// a phase that run never reached.
    private func landed(count: Int, worker: Double?, gate: Double?) -> [RunTimeouts.Sample] {
        (0..<count).map { _ in RunTimeouts.Sample(workerSeconds: worker, gateSeconds: gate) }
    }

    /// Four landed runs is not a distribution — the project stays on the
    /// numbers it ran on before the derivation existed, and says so.
    func testTooFewLandedRunsKeepsTheDefaults() {
        let deadlines = RunTimeouts.deadlines(landed: landed(count: 4, worker: 3_600, gate: 3_600))
        XCTAssertEqual(deadlines, RunTimeouts.Deadlines.defaults)
        XCTAssertEqual(deadlines.worker.source, .default)
        XCTAssertEqual(deadlines.gate.source, .default)
        XCTAssertEqual(deadlines.workerMinutes, 20)
        XCTAssertEqual(deadlines.gateMinutes, 30)
    }

    /// Nothing landed at all is the same answer as too little.
    func testNoLandedRunsKeepsTheDefaults() {
        XCTAssertEqual(RunTimeouts.deadlines(landed: []), RunTimeouts.Deadlines.defaults)
    }

    /// The fifth landed run is where the ledger starts answering.
    func testFiveLandedRunsDerives() {
        let deadlines = RunTimeouts.deadlines(landed: landed(count: 5, worker: 1_800, gate: 1_200))
        XCTAssertEqual(deadlines.worker.source, .derived)
        XCTAssertEqual(deadlines.gate.source, .derived)
        // 1800s × 1.5 = 45 min; 1200s × 1.5 = 30 min.
        XCTAssertEqual(deadlines.workerMinutes, 45)
        XCTAssertEqual(deadlines.gateMinutes, 30)
    }

    /// Ten runs, and the deadline is the slowest of them plus half again — the
    /// p95 of ten samples by nearest rank is the tenth.
    func testP95TakesTheSlowestOfTenRuns() {
        var samples = landed(count: 9, worker: 600, gate: 600)
        samples.append(RunTimeouts.Sample(workerSeconds: 1_800, gateSeconds: 1_200))
        let deadlines = RunTimeouts.deadlines(landed: samples)
        XCTAssertEqual(deadlines.worker.source, .derived)
        XCTAssertEqual(deadlines.workerMinutes, 45)
        XCTAssertEqual(deadlines.gateMinutes, 30)
    }

    /// A fast project does not get a watchdog that fires inside a normal round.
    func testFloorsHoldForAFastProject() {
        let deadlines = RunTimeouts.deadlines(landed: landed(count: 8, worker: 60, gate: 30))
        XCTAssertEqual(deadlines.workerMinutes, RunTimeouts.workerFloorMinutes)
        XCTAssertEqual(deadlines.gateMinutes, RunTimeouts.gateFloorMinutes)
        XCTAssertEqual(deadlines.gate.source, .derived)
    }

    /// Past an hour with no progress a worker is stuck, not slow — the worker's
    /// deadline is capped where the gate's, which runs commands rather than a
    /// model, is not.
    func testWorkerIsCappedAndGateIsNot() {
        let deadlines = RunTimeouts.deadlines(landed: landed(count: 6, worker: 14_400, gate: 14_400))
        XCTAssertEqual(deadlines.workerMinutes, RunTimeouts.workerCapMinutes)
        // 14400s × 1.5 = 360 min, uncapped.
        XCTAssertEqual(deadlines.gateMinutes, 360)
    }

    /// The failure this item exists to prevent: each deadline reads the phase
    /// it bounds. A project with long workers and short gates gets a long
    /// worker deadline and a short gate one, not one number for both.
    func testEachDeadlineReadsOnlyItsOwnPhase() {
        let deadlines = RunTimeouts.deadlines(landed: landed(count: 10, worker: 1_200, gate: 240))
        XCTAssertEqual(deadlines.workerMinutes, 30)
        XCTAssertEqual(deadlines.gateMinutes, RunTimeouts.gateFloorMinutes)
    }

    /// The failure this item exists to fix: a project running under `propose`
    /// parks every passed run at the approval gate, so nothing it does measures
    /// a gate phase. Its worker rounds are still measured — five of them derive
    /// the worker deadline — and the gate keeps the default until the project
    /// lands a run, each saying which it is.
    func testWorkerOnlySamplesDeriveTheWorkerDeadlineAlone() {
        let deadlines = RunTimeouts.deadlines(landed: landed(count: 5, worker: 1_800, gate: nil))
        XCTAssertEqual(deadlines.workerMinutes, 45)
        XCTAssertEqual(deadlines.worker.source, .derived)
        XCTAssertEqual(deadlines.gateMinutes, RunTimeouts.defaultGateMinutes)
        XCTAssertEqual(deadlines.gate.source, .default)
    }

    /// And the other way round: a project whose worker phases went unmeasured
    /// while its gates were measured derives the gate deadline alone.
    func testGateOnlySamplesDeriveTheGateDeadlineAlone() {
        let deadlines = RunTimeouts.deadlines(landed: landed(count: 6, worker: nil, gate: 1_200))
        XCTAssertEqual(deadlines.gateMinutes, 30)
        XCTAssertEqual(deadlines.gate.source, .derived)
        XCTAssertEqual(deadlines.workerMinutes, RunTimeouts.defaultWorkerMinutes)
        XCTAssertEqual(deadlines.worker.source, .default)
    }

    /// The minimum is counted per phase, not per run: five runs carrying a
    /// worker phase and four of them a gate phase measure the worker deadline
    /// and leave the gate on its default.
    func testTheMinimumIsCountedPerPhase() {
        var samples = landed(count: 4, worker: 1_800, gate: 1_200)
        samples.append(RunTimeouts.Sample(workerSeconds: 1_800, gateSeconds: nil))
        let deadlines = RunTimeouts.deadlines(landed: samples)
        XCTAssertEqual(deadlines.workerMinutes, 45)
        XCTAssertEqual(deadlines.worker.source, .derived)
        XCTAssertEqual(deadlines.gate.source, .default)
        XCTAssertEqual(deadlines.gateMinutes, RunTimeouts.defaultGateMinutes)
    }

    /// A run that measured neither phase says nothing about either deadline —
    /// it is not a sample of anything, and five of them are not five samples.
    func testRunsWithNeitherPhaseKeepTheDefaults() {
        XCTAssertEqual(RunTimeouts.deadlines(landed: landed(count: 5, worker: nil, gate: nil)),
                       RunTimeouts.Deadlines.defaults)
    }

    /// A phase's own samples are the ones it counts: the gate's p95 is taken
    /// over the runs that reached it, undiluted by the ones that did not — five
    /// short gates beside five runs that never gated is still a 10-minute
    /// floor, not a percentile pulled toward a zero nothing measured.
    func testAPhasePercentileIgnoresTheRunsThatSkippedIt() {
        var samples = landed(count: 5, worker: 3_600, gate: 240)
        samples += landed(count: 5, worker: 3_600, gate: nil)
        let deadlines = RunTimeouts.deadlines(landed: samples)
        XCTAssertEqual(deadlines.gateMinutes, RunTimeouts.gateFloorMinutes)
        XCTAssertEqual(deadlines.gate.source, .derived)
    }

    /// Nearest rank, so the answer is always a run that actually happened.
    func testP95IsNearestRank() {
        XCTAssertEqual(RunTimeouts.p95([1, 2, 3, 4, 5]), 5)
        XCTAssertEqual(RunTimeouts.p95(Array(1...100).map(Double.init)), 95)
        XCTAssertEqual(RunTimeouts.p95([]), 0)
    }

    /// Order of arrival is not order of duration — the ledger is appended to in
    /// run order, and the percentile sorts for itself.
    func testP95IgnoresArrivalOrder() {
        XCTAssertEqual(RunTimeouts.p95([5, 1, 4, 2, 3]), 5)
    }

    /// Minutes round up: a deadline rounded down fires on the very phase it was
    /// measured from. 1210s × 1.5 = 1815s = 30.25 min → 31.
    func testMinutesRoundUp() {
        let deadlines = RunTimeouts.deadlines(landed: landed(count: 5, worker: 1_210, gate: 1_210))
        XCTAssertEqual(deadlines.workerMinutes, 31)
        XCTAssertEqual(deadlines.gateMinutes, 31)
    }

    // MARK: - The two verifies one gate clock bounds

    /// A run that ran only the pre-review verify contributes exactly what it
    /// measured — the reading a project at `propose` has and used to throw away.
    func testAVerifyOnlyRunContributesItsVerifyReading() {
        XCTAssertEqual(RunTimeouts.gateSeconds(merge: nil, verify: 1_200), 1_200)
    }

    /// …and one that ran only the merge gate's, the same, unchanged.
    func testAMergeOnlyRunContributesItsMergeReading() {
        XCTAssertEqual(RunTimeouts.gateSeconds(merge: 1_200, verify: nil), 1_200)
    }

    /// A run carrying both contributes the larger, whichever way round it
    /// falls: a deadline is only useful if it clears the slowest of the runs it
    /// was measured from, and a warm pre-review tree must not set the clock a
    /// cold merge tree is then killed by.
    func testARunCarryingBothContributesTheLarger() {
        XCTAssertEqual(RunTimeouts.gateSeconds(merge: 1_800, verify: 600), 1_800)
        XCTAssertEqual(RunTimeouts.gateSeconds(merge: 600, verify: 1_800), 1_800)
    }

    /// A run that timed neither is no gate sample at all — nil, never a
    /// stand-in zero that would floor the deadline.
    func testARunThatTimedNeitherVerifyIsNoGateSample() {
        XCTAssertNil(RunTimeouts.gateSeconds(merge: nil, verify: nil))
    }

    /// The whole of this item at the arithmetic's end: five runs whose only
    /// verify reading is the pre-review one derive a gate deadline the same way
    /// five merge-phase runs would — 1200s × 1.5 = 30 minutes, twice the
    /// 15-minute default a cold Rust verify kept dying at — and say it was
    /// measured.
    func testVerifyOnlyRunsDeriveTheGateDeadline() {
        let samples = (0..<5).map { _ in
            RunTimeouts.Sample(workerSeconds: nil,
                               gateSeconds: RunTimeouts.gateSeconds(merge: nil, verify: 1_200))
        }
        let deadlines = RunTimeouts.deadlines(landed: samples)
        XCTAssertEqual(deadlines.gateMinutes, 30)
        XCTAssertEqual(deadlines.gate.source, .derived)
    }

    /// The floor still holds over verify-only readings: a project whose verify
    /// is a fast `swift test` does not get a gate clock that fires inside it.
    func testTheGateFloorHoldsOverVerifyOnlyReadings() {
        let samples = (0..<5).map { _ in
            RunTimeouts.Sample(gateSeconds: RunTimeouts.gateSeconds(merge: nil, verify: 30))
        }
        let deadlines = RunTimeouts.deadlines(landed: samples)
        XCTAssertEqual(deadlines.gateMinutes, RunTimeouts.gateFloorMinutes)
        XCTAssertEqual(deadlines.gate.source, .derived)
    }

    // MARK: - The worker's turn budget

    private func landed(count: Int, turns: Int) -> [RunTimeouts.Sample] {
        (0..<count).map { _ in RunTimeouts.Sample(workerSeconds: 600, workerTurns: turns) }
    }

    /// Five runs carrying a turn count, and the budget is their p95 plus half
    /// again, reported as measured.
    func testFiveRunsWithTurnCountsDeriveTheTurnBudget() {
        var samples = landed(count: 4, turns: 20)
        samples.append(RunTimeouts.Sample(workerSeconds: 600, workerTurns: 60))
        let budget = RunTimeouts.deadlines(landed: samples).workerTurns
        // p95 of five by nearest rank is the fifth: 60 × 1.5 = 90.
        XCTAssertEqual(budget, RunTimeouts.TurnBudget(turns: 90, source: .derived))
    }

    /// Four is too few: the budget stays at 50 and says it is the default.
    func testFewerThanFiveRunsWithTurnCountsKeepFifty() {
        var samples = landed(count: 4, turns: 80)
        samples.append(RunTimeouts.Sample(workerSeconds: 600))
        let budget = RunTimeouts.deadlines(landed: samples).workerTurns
        XCTAssertEqual(budget, RunTimeouts.TurnBudget(turns: 50, source: .default))
        XCTAssertEqual(RunTimeouts.Deadlines.defaults.workerTurns.turns, 50)
    }

    /// A project whose workers finish in a handful of turns is never given
    /// fewer than it ran on before.
    func testTheTurnBudgetIsFlooredAtFifty() {
        let budget = RunTimeouts.deadlines(landed: landed(count: 6, turns: 10)).workerTurns
        XCTAssertEqual(budget, RunTimeouts.TurnBudget(turns: RunTimeouts.workerTurnsFloor, source: .derived))
    }

    /// …nor more than the one ceiling, however long its workers have run.
    func testTheTurnBudgetIsCapped() {
        let budget = RunTimeouts.deadlines(landed: landed(count: 6, turns: 400)).workerTurns
        XCTAssertEqual(budget, RunTimeouts.TurnBudget(turns: RunTimeouts.workerTurnsCap, source: .derived))
    }

    /// A fractional budget rounds up, so the run it was measured from fits.
    func testTheTurnBudgetRoundsUp() {
        let budget = RunTimeouts.deadlines(landed: landed(count: 5, turns: 41)).workerTurns
        XCTAssertEqual(budget.turns, 62)
    }

    // MARK: - The per-item cost cap

    private func costs(_ values: [Double]) -> [RunTimeouts.Sample] {
        values.map { RunTimeouts.Sample(costUSD: $0) }
    }

    /// Five landed runs carrying a cost measure the cap: their p95 plus half again.
    func testFiveLandedRunsDeriveTheCostCapFromTheirP95() {
        let bound = RunTimeouts.deadlines(landed: costs([1, 2, 3, 4, 6])).itemCost
        XCTAssertEqual(bound, RunTimeouts.CostBound(usd: 9, source: .derived))
        XCTAssertEqual(bound.itemCapUSD(predicted: nil), 9)
        XCTAssertEqual(bound.itemCapUSD(predicted: 2), 9)
    }

    /// The item's own prediction is the floor under a measured cap.
    func testAPredictionAboveTheMeasuredCapRaisesIt() {
        let bound = RunTimeouts.deadlines(landed: costs([1, 1, 1, 1, 1])).itemCost
        XCTAssertEqual(bound.itemCapUSD(predicted: 4), 4)
    }

    /// Fewer runs leave the cap to the item's prediction times the shared headroom.
    func testFewerThanFiveCostsCapAtThePredictionPlusHeadroom() {
        let bound = RunTimeouts.deadlines(landed: costs([5, 5, 5, 5])).itemCost
        XCTAssertEqual(bound, RunTimeouts.CostBound(usd: nil, source: .default))
        XCTAssertEqual(bound.itemCapUSD(predicted: 2), 2 * RunTimeouts.headroom)
        XCTAssertNil(bound.itemCapUSD(predicted: nil))
        XCTAssertNil(bound.itemCapUSD(predicted: 0))
    }

    /// A run that recorded no spend is no cost sample.
    func testRunsWithoutACostAreNotCostSamples() {
        var samples = costs([1, 1, 1, 1])
        samples.append(RunTimeouts.Sample(workerSeconds: 600, costUSD: 0))
        samples.append(RunTimeouts.Sample(workerSeconds: 600))
        XCTAssertEqual(RunTimeouts.deadlines(landed: samples).itemCost.source, .default)
    }
}
