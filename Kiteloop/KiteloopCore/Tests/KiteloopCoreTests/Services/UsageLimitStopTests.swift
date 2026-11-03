import XCTest
@testable import KiteloopCore

final class UsageLimitStopTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_600_000)
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func reading(_ status: String, resetsIn: TimeInterval?) -> AgentActivityEvent.RateLimitInfo {
        .init(status: status, window: "five_hour", resetsAt: resetsIn.map { now.addingTimeInterval($0) }, utilization: 1)
    }

    func testARefusedReadingIsAStopUntilItsOwnReset() throws {
        let stop = try XCTUnwrap(UsageLimitStop.stop(from: reading("rejected", resetsIn: 3_600), now: now))
        XCTAssertEqual(stop.resetsAt, now.addingTimeInterval(3_600))
        XCTAssertEqual(stop.window, "five_hour")
        XCTAssertTrue(stop.resetReported)
        XCTAssertTrue(stop.stands(at: now))
        XCTAssertFalse(stop.stands(at: now.addingTimeInterval(3_600)))
    }

    func testAReadingThatStillLetsCallsThroughIsNoStop() {
        XCTAssertNil(UsageLimitStop.stop(from: reading("allowed", resetsIn: 3_600), now: now))
        XCTAssertNil(UsageLimitStop.stop(from: reading("allowed_warning", resetsIn: 3_600), now: now))
    }

    /// No reset time, or one already past, stands for the session window and
    /// says the time was not the CLI's.
    func testARefusalWithoutAUsableResetStandsForTheSessionWindow() throws {
        for resetsIn in [nil, -60.0] as [TimeInterval?] {
            let stop = try XCTUnwrap(UsageLimitStop.stop(from: reading("rejected", resetsIn: resetsIn), now: now))
            XCTAssertEqual(stop.resetsAt, now.addingTimeInterval(UsageLimitStop.sessionWindow))
            XCTAssertFalse(stop.resetReported)
        }
    }

    func testTheResumeTimeNamesTheDayOnlyWhenItIsNotToday() {
        let today = UsageLimitStop(resetsAt: now.addingTimeInterval(3_600), window: nil, resetReported: true)
        let later = UsageLimitStop(resetsAt: now.addingTimeInterval(3 * 86_400), window: nil, resetReported: true)
        XCTAssertEqual(today.resumeText(now: now, calendar: utc).count, 5, today.resumeText(now: now, calendar: utc))
        XCTAssertEqual(later.resumeText(now: now, calendar: utc).split(separator: " ").count, 2)
    }
}
