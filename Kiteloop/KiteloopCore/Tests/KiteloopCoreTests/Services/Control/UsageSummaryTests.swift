import XCTest
@testable import KiteloopCore

/// Of the rate-limit readings the agents last reported, the one the phone
/// shows is the one closest to its limit.
final class UsageSummaryTests: XCTestCase {

    private func reading(_ status: String, _ utilization: Double?) -> AgentActivityEvent.RateLimitInfo {
        AgentActivityEvent.RateLimitInfo(status: status, window: "five_hour", resetsAt: nil, utilization: utilization)
    }

    func testARefusalOutranksAWarningAndAWarningOutranksAnAllowance() {
        let refused = reading("rejected", 0.2)
        let warning = reading("allowed_warning", 0.9)
        XCTAssertEqual(UsageSummary.closest([reading("allowed", 0.99), warning, refused]), refused)
        XCTAssertEqual(UsageSummary.closest([reading("allowed", 0.99), warning]), warning)
    }

    func testAmongAllowancesTheHighestShareUsedWins() {
        let high = reading("allowed", 0.7)
        XCTAssertEqual(UsageSummary.closest([reading("allowed", 0.1), high, reading("allowed", nil)]), high)
    }

    func testNoReadingsIsNoAnswer() {
        XCTAssertNil(UsageSummary.closest([]))
    }
}
