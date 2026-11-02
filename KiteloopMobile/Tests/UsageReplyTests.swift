import XCTest
@testable import KiteloopMobile

/// The Fleet screen's usage: the rate limit worded as the Mac's chat words
/// it, a warning told apart, and the day's spend per project decoded.
final class UsageReplyTests: XCTestCase {

    func testAWarningReadsAsTheMacSaysIt() throws {
        let json = #"{"rateLimit":{"status":"allowed_warning","window":"five_hour","resetsAt":"2026-10-27T14:00:00Z","utilization":0.9},"agentsReporting":2,"spend":null}"#
        let reply = try JSONDecoder().decode(UsageReply.self, from: Data(json.utf8))

        XCTAssertEqual(UsageReply.rateLimitLine(reply.rateLimit, resetTime: { _ in "14:00" }),
                       "Approaching the rate limit (five-hour window) — 90% used, resets 14:00")
        XCTAssertTrue(reply.rateLimit?.isWarning == true)
        XCTAssertNil(reply.spend)
    }

    func testNoReadingSaysNoAgentHasReported() throws {
        let reply = try JSONDecoder().decode(UsageReply.self, from: Data(#"{"rateLimit":null,"agentsReporting":0}"#.utf8))

        XCTAssertEqual(UsageReply.rateLimitLine(reply.rateLimit), "No agent has reported a rate limit since the Mac started")
        XCTAssertFalse(reply.rateLimit?.isWarning == true)
    }

    func testAnAllowanceIsNotAWarningAndARefusalSaysTheLimitIsReached() {
        XCTAssertFalse(UsageReply.RateLimit(status: "allowed").isWarning)
        XCTAssertEqual(UsageReply.rateLimitLine(UsageReply.RateLimit(status: "rejected", window: "seven_day")),
                       "Rate limit reached (seven-day window)")
    }

    func testTheDaysSpendPerProjectDecodes() throws {
        let json = #"{"rateLimit":null,"agentsReporting":0,"spend":{"hours":24,"totalUSD":6.4,"projects":[{"project":"kiteloop","spendUSD":5.1},{"project":"travel","spendUSD":1.3}]}}"#
        let spend = try XCTUnwrap(try JSONDecoder().decode(UsageReply.self, from: Data(json.utf8)).spend)

        XCTAssertEqual(spend.projects?.map(\.project), ["kiteloop", "travel"])
        XCTAssertEqual(spend.totalUSD, 6.4)
    }
}
