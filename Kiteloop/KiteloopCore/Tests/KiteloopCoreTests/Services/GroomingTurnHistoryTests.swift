import XCTest
@testable import KiteloopCore

/// What the groomer is told about the worker it sizes for: the turn budget,
/// and what this project's runs of each declared size took.
final class GroomingTurnHistoryTests: XCTestCase {

    private func sample(_ size: String, _ turns: Int, cutShort: Bool = false) -> GroomingTurnHistory.Sample {
        GroomingTurnHistory.Sample(size: size, turns: turns, cutShort: cutShort)
    }

    // MARK: - Rows

    func testEachDeclaredSizeGetsOneRowWithItsCountMedianMostAndCutShort() {
        let history = GroomingTurnHistory(samples: [
            sample("M", 50, cutShort: true), sample("S", 31), sample("M", 44),
            sample("S", 12), sample("S", 48), sample("M", 50, cutShort: true), sample("M", 20),
        ], budget: 50)

        XCTAssertEqual(history.budget, 50)
        XCTAssertEqual(history.rows, [
            GroomingTurnHistory.Row(size: "S", runs: 3, median: 31, most: 48, cutShort: 0),
            GroomingTurnHistory.Row(size: "M", runs: 4, median: 47, most: 50, cutShort: 2),
        ])
    }

    func testRowsFollowItemSizeOrderWhateverOrderTheRunsCameIn() {
        let history = GroomingTurnHistory(samples: [sample("M", 40), sample("XS", 5), sample("S", 20)],
                                          budget: 50)
        XCTAssertEqual(history.rows.map(\.size), ["XS", "S", "M"])
    }

    func testAnEvenNumberOfRunsTakesTheMeanOfTheMiddleTwoRoundedDown() {
        let history = GroomingTurnHistory(samples: [sample("S", 10), sample("S", 15)], budget: 50)
        XCTAssertEqual(history.rows.first?.median, 12)
    }

    func testASingleRunIsItsOwnMedianAndMost() {
        let history = GroomingTurnHistory(samples: [sample("S", 23, cutShort: true)], budget: 50)
        XCTAssertEqual(history.rows, [GroomingTurnHistory.Row(size: "S", runs: 1, median: 23, most: 23,
                                                              cutShort: 1)])
    }

    func testASizeSpelledInLowerCaseJoinsItsRowAndAnUnknownSizeJoinsNone() {
        let history = GroomingTurnHistory(samples: [sample("s", 10), sample("S", 30), sample("huge", 99)],
                                          budget: 50)
        XCTAssertEqual(history.rows, [GroomingTurnHistory.Row(size: "S", runs: 2, median: 20, most: 30,
                                                              cutShort: 0)])
    }

    func testNoSamplesMakeNoRows() {
        XCTAssertTrue(GroomingTurnHistory(samples: [], budget: 50).rows.isEmpty)
    }

    // MARK: - The prompt section

    func testTheSectionStatesTheBudgetEachRowAndTheSplitInstruction() {
        let section = GroomingTurnHistory(samples: [
            sample("S", 31), sample("S", 12), sample("S", 48), sample("M", 51, cutShort: true),
        ], budget: 51).promptSection

        XCTAssertTrue(section.contains("A worker gets 51 turns on one item"), section)
        XCTAssertTrue(section.contains("S: 3 runs, median 31, most 48, 0 cut short at the turn limit"), section)
        XCTAssertTrue(section.contains("M: 1 run, median 51, most 51, 1 cut short at the turn limit"), section)
        XCTAssertTrue(section.contains("Size the item to what a worker finishes inside that budget"), section)
        XCTAssertTrue(section.contains("propose a first slice that does"), section)
        XCTAssertTrue(section.contains("list the rest under Out of Scope"), section)
        XCTAssertFalse(section.contains("no measured runs"), section)
    }

    func testWithNoRowsTheSectionStillStatesTheBudgetAndSaysNothingIsMeasured() {
        let section = GroomingTurnHistory(samples: [], budget: 50).promptSection

        XCTAssertTrue(section.contains("A worker gets 50 turns on one item"), section)
        XCTAssertTrue(section.contains("no measured runs yet"), section)
        XCTAssertTrue(section.contains("list the rest under Out of Scope"), section)
    }
}
