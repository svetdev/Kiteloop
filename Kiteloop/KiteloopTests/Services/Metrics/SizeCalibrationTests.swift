import XCTest
@testable import Kiteloop

/// Covers `SizeCalibration` — what a size class is measured to cost, and what
/// counts as a measurement.
///
/// Three things can go wrong here, and each one has a consequence:
/// - **the wrong runs counted.** A band computed over $0 runs and runs that
///   changed no file describes a broken pipeline, and every ceiling derived from
///   it comes out too low — which ends legitimate work early;
/// - **too few runs counted.** A p90 over three samples moves by more than the
///   band is wide when one freak run lands, so below the minimum there must be
///   no band at all and the caller keeps its fixed cap;
/// - **the arithmetic.** The percentiles are what a flag is judged against, so
///   they're pinned against hand-computed values.
final class SizeCalibrationTests: XCTestCase {

    private let projectPath = "/tmp/proj"
    /// Fixed so the window is a stable distance from every fixture's date.
    private let now = Date(timeIntervalSince1970: 1_786_000_000)

    // MARK: - Fixtures

    private func record(
        itemID: String = "t-1",
        size: String? = "S",
        cost: Double = 3.00,
        durationSeconds: Double = 300,
        outcome: String = "done",
        changedFiles: Int? = 4,
        project: String? = nil,
        daysAgo: Double = 1
    ) -> TaskMetricRecord {
        let completed = now.addingTimeInterval(-daysAgo * 86_400)
        var record = TaskMetricRecord(
            projectPath: project ?? projectPath, projectName: "proj", itemID: itemID,
            title: "Task \(itemID)", epic: nil, declaredSize: size,
            startedAt: completed.addingTimeInterval(-durationSeconds),
            completedAt: completed, durationSeconds: durationSeconds,
            costUSD: cost, reviewerRetries: 0, outcome: outcome,
            workerAgent: "worker", reviewerAgent: "reviewer", executionID: "e-1"
        )
        record.changedFileCount = changedFiles
        return record
    }

    /// `count` interchangeable evidence records, so a test that's about the
    /// minimum-sample rule doesn't have to spell out ten fixtures.
    private func filler(_ count: Int, size: String = "S", cost: Double = 3.00) -> [TaskMetricRecord] {
        (0..<count).map { record(itemID: "filler-\($0)", size: size, cost: cost) }
    }

    // MARK: - Percentiles

    func testPercentilesInterpolateBetweenNeighbouringSamples() {
        // 1…10: p10 lands on 1.9, p50 between 5 and 6, p90 on 9.1 — the same
        // answer numpy.percentile and a spreadsheet give.
        let p = SizeCalibration.percentiles(of: (1...10).map(Double.init))
        XCTAssertEqual(p.p10, 1.9, accuracy: 0.0001)
        XCTAssertEqual(p.p50, 5.5, accuracy: 0.0001)
        XCTAssertEqual(p.p90, 9.1, accuracy: 0.0001)
    }

    func testPercentilesOfADegenerateSample() {
        XCTAssertEqual(SizeCalibration.percentiles(of: []), .init(p10: 0, p50: 0, p90: 0))
        XCTAssertEqual(SizeCalibration.percentiles(of: [7]), .init(p10: 7, p50: 7, p90: 7))
    }

    func testPercentilesDoNotDependOnInputOrder() {
        XCTAssertEqual(
            SizeCalibration.percentiles(of: [9, 1, 5, 3, 7]),
            SizeCalibration.percentiles(of: [1, 3, 5, 7, 9])
        )
    }

    // MARK: - What counts as evidence

    func testRunsThatChangedNoFileAreNotEvidence() {
        // Four of thirty-one runs on 2026-08-08 produced no diff at all.
        // Counting them says an S costs whatever a dead session costs.
        XCTAssertFalse(SizeCalibration.isEvidence(record(changedFiles: 0)))
        XCTAssertTrue(SizeCalibration.isEvidence(record(changedFiles: 1)))
    }

    func testUnattributedCostIsNotEvidence() {
        // Nine runs recorded $0 for reasons that had nothing to do with size.
        XCTAssertFalse(SizeCalibration.isEvidence(record(cost: 0)))
        XCTAssertFalse(SizeCalibration.isEvidence(record(cost: -1)))
    }

    func testRecordsWithoutAFileCountFallBackToTheirOutcome() {
        // The ~280 records written before file counts existed still carry a
        // signal: an empty run says so in its blocked reason.
        XCTAssertTrue(record(outcome: "done", changedFiles: nil).producedWork)
        XCTAssertTrue(record(outcome: "awaiting-approval", changedFiles: nil).producedWork)
        XCTAssertTrue(record(outcome: "blocked:review did not pass", changedFiles: nil).producedWork)
        XCTAssertFalse(record(outcome: "cancelled", changedFiles: nil).producedWork)
        XCTAssertFalse(
            record(outcome: "blocked:\(RunWorkEvidence.Verdict.emptyDiff.missingSignal ?? "")",
                   changedFiles: nil).producedWork
        )
        // An outcome that says nothing either way is not evidence. A run that
        // sat for twenty minutes says nothing about what an S costs, and the
        // words in its blocked reason are not a measurement.
        XCTAssertFalse(
            record(outcome: "blocked:stalled: no progress for 20 min on worker",
                   changedFiles: nil).producedWork
        )
    }

    func testAFileCountOutranksTheOutcomeFallback() {
        // A run that committed files is evidence whatever its review said, and a
        // run that committed none is not, however cleanly it ended.
        XCTAssertTrue(record(outcome: "blocked:review did not pass", changedFiles: 6).producedWork)
        XCTAssertFalse(record(outcome: "done", changedFiles: 0).producedWork)
    }

    func testARunThatReachedNoVerdictIsNotEvidenceEvenWithFiles() {
        // The one outcome that outranks the count instead. Nobody ever said
        // whether those six files were the item, so the run is not a
        // measurement of what an S costs — the same reading the retry ceiling
        // takes, off the same value, so the two cannot disagree about one run.
        let run = record(outcome: "blocked:\(BacklogAutopilot.unreadableVerdictReason)",
                         changedFiles: 6)

        XCTAssertEqual(run.workEvidence, .unknown)
        XCTAssertFalse(run.producedWork)
        XCTAssertFalse(SizeCalibration.isEvidence(run))
    }

    // MARK: - Which records a band is built from

    func testTheBandIsBuiltOnlyFromEvidence() {
        var records = filler(8, cost: 4.00)
        records.append(record(itemID: "empty", cost: 4.00, changedFiles: 0))
        records.append(record(itemID: "free", cost: 0, changedFiles: 9))

        let band = SizeCalibration.band(forSize: "S", records: records,
                                        projectPath: projectPath, now: now)
        XCTAssertEqual(band?.sampleCount, 8)
        XCTAssertEqual(band?.costUSD.p50, 4.00)
    }

    func testOtherSizesAndOtherProjectsAreNotPooledIn() {
        var records = filler(8, cost: 2.00)
        records += (0..<8).map { record(itemID: "m-\($0)", size: "M", cost: 20.00) }
        records += (0..<8).map { record(itemID: "x-\($0)", cost: 20.00, project: "/tmp/other") }

        let band = SizeCalibration.band(forSize: "S", records: records,
                                        projectPath: projectPath, now: now)
        XCTAssertEqual(band?.sampleCount, 8)
        XCTAssertEqual(band?.costUSD.p90, 2.00)
    }

    func testRunsOlderThanTheWindowAreNotCounted() {
        var records = filler(8, cost: 2.00)
        records += (0..<8).map {
            record(itemID: "ancient-\($0)", cost: 50.00,
                   daysAgo: Double(SizeCalibration.windowDays) + 1)
        }

        let band = SizeCalibration.band(forSize: "S", records: records,
                                        projectPath: projectPath, now: now)
        XCTAssertEqual(band?.sampleCount, 8)
        XCTAssertEqual(band?.costUSD.p90, 2.00)
    }

    // MARK: - Cold start

    func testTooFewSamplesProduceNoBandAtAll() {
        // Deliberately nil rather than a band over three runs: the caller falls
        // back to its fixed cap, which is the honest answer at a cold start.
        let records = filler(SizeCalibration.minimumSamples - 1)
        XCTAssertNil(SizeCalibration.band(forSize: "S", records: records,
                                          projectPath: projectPath, now: now))

        let enough = filler(SizeCalibration.minimumSamples)
        XCTAssertNotNil(SizeCalibration.band(forSize: "S", records: enough,
                                             projectPath: projectPath, now: now))
    }

    func testASizeWhoseRecordsAreAllExcludedHasNoBand() {
        let records = (0..<20).map { record(itemID: "dead-\($0)", cost: 0, changedFiles: 0) }
        XCTAssertNil(SizeCalibration.band(forSize: "S", records: records,
                                          projectPath: projectPath, now: now))
    }

    func testBandsAreReportedSmallestSizeFirst() {
        let records = filler(8, size: "M") + filler(8, size: "S") + filler(8, size: "XS")
        let bands = SizeCalibration.bands(records: records, projectPath: projectPath, now: now)
        XCTAssertEqual(bands.map(\.size), ["XS", "S", "M"])
    }

    // MARK: - Duration as well as cost

    func testDurationIsBandedAlongsideCost() {
        let records = (1...10).map {
            record(itemID: "d-\($0)", durationSeconds: Double($0) * 60)
        }
        let band = SizeCalibration.band(forSize: "S", records: records,
                                        projectPath: projectPath, now: now)
        XCTAssertEqual(band?.durationSeconds.p10 ?? 0, 114, accuracy: 0.001)   // 1.9 min
        XCTAssertEqual(band?.durationSeconds.p50 ?? 0, 330, accuracy: 0.001)   // 5.5 min
        XCTAssertEqual(band?.durationSeconds.p90 ?? 0, 546, accuracy: 0.001)   // 9.1 min
    }

    // MARK: - The flag

    func testAPredictionInsideTheBandIsNotFlagged() {
        let band = SizeCalibration.band(forSize: "S", records: filler(8, cost: 3.00),
                                        projectPath: projectPath, now: now)
        XCTAssertNil(SizeCalibration.flag(predictedCostUSD: 3.00, band: band))
    }

    func testAPredictionAboveTheBandIsFlagged() {
        let records = (1...10).map { record(itemID: "s-\($0)", cost: Double($0)) }
        let band = SizeCalibration.band(forSize: "S", records: records,
                                        projectPath: projectPath, now: now)
        let flag = SizeCalibration.flag(predictedCostUSD: 13.27, band: band)
        XCTAssertEqual(flag?.edge, .above)
        XCTAssertEqual(flag?.predictedCostUSD, 13.27)
    }

    func testAPredictionBelowTheBandIsFlagged() {
        let records = (1...10).map { record(itemID: "s-\($0)", cost: Double($0)) }
        let band = SizeCalibration.band(forSize: "S", records: records,
                                        projectPath: projectPath, now: now)
        XCTAssertEqual(SizeCalibration.flag(predictedCostUSD: 0.10, band: band)?.edge, .below)
    }

    func testTheBandEdgesThemselvesAreInside() throws {
        let records = (1...10).map { record(itemID: "s-\($0)", cost: Double($0)) }
        let band = try XCTUnwrap(SizeCalibration.band(forSize: "S", records: records,
                                                     projectPath: projectPath, now: now))
        // p90 is the ninetieth-percentile run, not an outlier.
        XCTAssertNil(SizeCalibration.flag(predictedCostUSD: band.costUSD.p90, band: band))
        XCTAssertNil(SizeCalibration.flag(predictedCostUSD: band.costUSD.p10, band: band))
    }

    func testNothingIsFlaggedWithoutABandToJudgeAgainst() {
        // A size nobody has measured yet has nothing to say about this item.
        XCTAssertNil(SizeCalibration.flag(predictedCostUSD: 99.00, band: nil))
    }

    func testTheFlagNamesTheNumberTheEdgeAndTheEvidence() {
        let records = (1...10).map { record(itemID: "s-\($0)", cost: Double($0)) }
        let band = SizeCalibration.band(forSize: "S", records: records,
                                        projectPath: projectPath, now: now)
        let summary = SizeCalibration.flag(predictedCostUSD: 13.27, band: band)?.summary ?? ""
        XCTAssertTrue(summary.contains("$13.27"), summary)
        XCTAssertTrue(summary.contains("above the S band's p90 ($9.10)"), summary)
        XCTAssertTrue(summary.contains("n=10"), summary)
    }

    // MARK: - The case that motivated all of this

    func testAnSSizedRunThatCostLikeAnMIsOutsideTheSBand() {
        // Kiteloop's own S runs on 2026-08-08: a median around $2 and a p90
        // around $4. `escaped-defect-tracking` was sized S and cost $13.27 over
        // 14.5 minutes — 3.4× the mean S — and was capped as an S the whole way.
        let costs: [Double] = [0.9, 1.2, 1.6, 1.9, 2.0, 2.1, 2.6, 3.1, 3.8, 4.2]
        let records = costs.enumerated().map { record(itemID: "s-\($0.offset)", cost: $0.element) }
        let band = SizeCalibration.band(forSize: "S", records: records,
                                        projectPath: projectPath, now: now)

        let escaped = record(itemID: "escaped-defect-tracking", cost: 13.27,
                             durationSeconds: 870, changedFiles: 12)
        XCTAssertTrue(SizeCalibration.isEvidence(escaped))
        XCTAssertFalse(band?.contains(costUSD: escaped.costUSD) ?? true)
        XCTAssertEqual(SizeCalibration.flag(predictedCostUSD: escaped.costUSD, band: band)?.edge, .above)
        XCTAssertGreaterThan(escaped.durationSeconds, band?.durationSeconds.p90 ?? .infinity)
    }
}
