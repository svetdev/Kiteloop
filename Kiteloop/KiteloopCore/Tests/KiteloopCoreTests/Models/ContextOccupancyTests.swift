import XCTest
@testable import KiteloopCore

final class ContextOccupancyTests: XCTestCase {

    func testTokensAreInputPlusCacheReadPlusCacheCreation() {
        let occupancy = ContextOccupancy(inputTokens: 1_200, cacheReadTokens: 40_000,
                                         cacheCreationTokens: 900, windowSize: 200_000)
        XCTAssertEqual(occupancy.tokens, 42_100)
    }

    /// The initialiser takes no output count at all: output tokens are not in
    /// the window, so a turn's reply never moves the figure.
    func testOutputTokensAreLeftOut() {
        let quiet = ContextOccupancy(inputTokens: 10, cacheReadTokens: 20, cacheCreationTokens: 30, windowSize: nil)
        XCTAssertEqual(quiet.tokens, 60)
    }

    func testPercentIsNilWithoutAWindow() {
        XCTAssertNil(ContextOccupancy(inputTokens: 5, cacheReadTokens: 0, cacheCreationTokens: 0, windowSize: nil).percent)
        XCTAssertNil(ContextOccupancy(inputTokens: 5, cacheReadTokens: 0, cacheCreationTokens: 0, windowSize: 0).percent)
    }

    func testPercentOfAKnownWindow() {
        let occupancy = ContextOccupancy(inputTokens: 50_000, cacheReadTokens: 0,
                                         cacheCreationTokens: 0, windowSize: 200_000)
        XCTAssertEqual(occupancy.percent, 25)
    }

    func testHeaderTextInThousands() {
        let occupancy = ContextOccupancy(inputTokens: 2_100, cacheReadTokens: 40_000,
                                         cacheCreationTokens: 0, windowSize: 200_000)
        XCTAssertEqual(occupancy.headerText, "42.1k / 200k")
    }

    func testHeaderTextAboveOneMillion() {
        let occupancy = ContextOccupancy(inputTokens: 0, cacheReadTokens: 1_250_000,
                                         cacheCreationTokens: 0, windowSize: 2_000_000)
        XCTAssertEqual(occupancy.headerText, "1.3M / 2M")
    }

    func testHeaderTextWithoutAWindowIsTheTokensAlone() {
        let occupancy = ContextOccupancy(inputTokens: 950, cacheReadTokens: 0, cacheCreationTokens: 0, windowSize: nil)
        XCTAssertEqual(occupancy.headerText, "950")
    }

    func testCompactCarriesNearlyAMillionIntoMillions() {
        XCTAssertEqual(ContextOccupancy.compact(999_960), "1M")
    }
}
