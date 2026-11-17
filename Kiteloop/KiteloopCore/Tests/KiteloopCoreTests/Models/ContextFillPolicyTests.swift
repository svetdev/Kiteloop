import XCTest
@testable import KiteloopCore

final class ContextFillPolicyTests: XCTestCase {
    private func occupancy(_ tokens: Int, of window: Int?) -> ContextOccupancy {
        ContextOccupancy(inputTokens: tokens, cacheReadTokens: 0, cacheCreationTokens: 0, windowSize: window)
    }

    func testFiresAtOrAboveTheThreshold() {
        let policy = ContextFillPolicy(thresholdPercent: 80)
        XCTAssertTrue(policy.shouldCompact(occupancy(80_000, of: 100_000), armed: true))
        XCTAssertTrue(policy.shouldCompact(occupancy(95_000, of: 100_000), armed: true))
    }

    func testDoesNotFireBelowTheThreshold() {
        let policy = ContextFillPolicy(thresholdPercent: 80)
        XCTAssertFalse(policy.shouldCompact(occupancy(79_999, of: 100_000), armed: true))
    }

    func testDoesNotFireWhenTheWindowSizeIsUnknown() {
        let policy = ContextFillPolicy(thresholdPercent: 50)
        XCTAssertFalse(policy.shouldCompact(occupancy(900_000, of: nil), armed: true))
    }

    func testDoesNotFireWhenNotArmed() {
        let policy = ContextFillPolicy(thresholdPercent: 80)
        XCTAssertFalse(policy.shouldCompact(occupancy(99_000, of: 100_000), armed: false))
    }

    func testTheThresholdIsClampedTo50Through95() {
        XCTAssertEqual(ContextFillPolicy(thresholdPercent: 10).thresholdPercent, 50)
        XCTAssertEqual(ContextFillPolicy(thresholdPercent: 120).thresholdPercent, 95)
        XCTAssertEqual(ContextFillPolicy(thresholdPercent: 70).thresholdPercent, 70)
    }
}
