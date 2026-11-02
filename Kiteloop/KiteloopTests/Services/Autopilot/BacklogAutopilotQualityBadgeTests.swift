import XCTest
@testable import Kiteloop

/// Covers the quality-score badge the run list shows: how a judge score becomes
/// a figure and a colour band, how a whole run is summarised from its items, and
/// that history written before scores existed still decodes.
///
/// The score is advisory — it never gated anything — so the rules that matter
/// here are the ones that stop the badge lying: an unscored item must not read
/// as a zero, and an out-of-range answer must not render as "140".
@MainActor
final class BacklogAutopilotQualityBadgeTests: XCTestCase {

    private typealias Badge = BacklogAutopilot.QualityBadge

    // MARK: - Figure

    func testScoreRendersAsARoundedPercentage() {
        XCTAssertEqual(Badge(score: 0.925).text, "93")
        XCTAssertEqual(Badge(score: 0.5).text, "50")
        XCTAssertEqual(Badge(score: 1).text, "100")
        XCTAssertEqual(Badge(score: 0).text, "0")
    }

    func testOutOfRangeScoresAreClamped() {
        // A judge that answers 1.4 or -0.2 shouldn't paint "140" on the row.
        XCTAssertEqual(Badge(score: 1.4).text, "100")
        XCTAssertEqual(Badge(score: -0.2).text, "0")
    }

    // MARK: - Band

    func testBandsSplitAtTheRubricThresholds() {
        XCTAssertEqual(Badge(score: 0.80).band, .good)
        XCTAssertEqual(Badge(score: 0.79).band, .fair)
        XCTAssertEqual(Badge(score: 0.50).band, .fair)
        XCTAssertEqual(Badge(score: 0.49).band, .poor)
    }

    // MARK: - Averaging a run

    func testAverageSkipsUnscoredItems() {
        // Counting a nil as 0 would drag a good run down for the judge being off.
        let badge = Badge.average(of: [0.9, nil, 0.7])
        XCTAssertEqual(badge?.score ?? 0, 0.8, accuracy: 0.0001)
        XCTAssertEqual(badge?.text, "80")
    }

    func testAverageIsNilWhenNothingWasScored() {
        XCTAssertNil(Badge.average(of: [nil, nil]))
        XCTAssertNil(Badge.average(of: []))
    }

    func testRunRecordSummarisesItsScoredItems() {
        let record = runRecord(scores: [1.0, 0.6, nil])
        XCTAssertEqual(record.qualityBadge?.score ?? 0, 0.8, accuracy: 0.0001)
        XCTAssertEqual(record.qualityBadge?.band, .good)
    }

    func testRunRecordHasNoBadgeWhenNoItemWasJudged() {
        XCTAssertNil(runRecord(scores: [nil, nil]).qualityBadge)
    }

    // MARK: - Persistence

    func testHistoryWrittenBeforeScoresExistedStillDecodes() throws {
        // Run history is kept on disk across releases; a record with no
        // `qualityScore` key must load as unscored rather than failing the whole
        // history file.
        let json = """
        {"id":"i-1","title":"Task","outcome":"done","duration":12.5}
        """
        let item = try JSONDecoder().decode(
            BacklogAutopilot.RunRecord.ItemRecord.self, from: Data(json.utf8)
        )
        XCTAssertNil(item.qualityScore)
    }

    func testScoreSurvivesARoundTripThroughHistory() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode([runRecord(scores: [0.42])])
        let decoded = try decoder.decode([BacklogAutopilot.RunRecord].self, from: data)
        XCTAssertEqual(decoded.first?.items.first?.qualityScore ?? 0, 0.42, accuracy: 0.0001)
        XCTAssertEqual(decoded.first?.qualityBadge?.text, "42")
    }

    // MARK: - Fixtures

    private func runRecord(scores: [Double?]) -> BacklogAutopilot.RunRecord {
        BacklogAutopilot.RunRecord(
            id: "run-1",
            startedAt: Date(),
            completedAt: nil,
            items: scores.enumerated().map { index, score in
                BacklogAutopilot.RunRecord.ItemRecord(
                    id: "i-\(index)", title: "Task \(index)", outcome: "done",
                    duration: 10, executionID: "e-\(index)", qualityScore: score
                )
            },
            workerAgentName: "worker",
            reviewerAgentName: "reviewer"
        )
    }
}
