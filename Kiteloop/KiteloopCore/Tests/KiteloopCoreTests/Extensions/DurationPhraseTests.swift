import XCTest
@testable import KiteloopCore

final class DurationPhraseTests: XCTestCase {

    /// Under a minute reads in seconds alone.
    func testUnderAMinuteReadsInSeconds() {
        XCTAssertEqual(DurationPhrase.phrase(0), "0s")
        XCTAssertEqual(DurationPhrase.phrase(59), "59s")
    }

    /// Under an hour reads in minutes and seconds.
    func testUnderAnHourReadsInMinutesAndSeconds() {
        XCTAssertEqual(DurationPhrase.phrase(60), "1m 0s")
        XCTAssertEqual(DurationPhrase.phrase(3599), "59m 59s")
    }

    /// From an hour up the minutes roll over into hours.
    func testFromAnHourReadsInHoursAndMinutes() {
        XCTAssertEqual(DurationPhrase.phrase(3600), "1h 0m")
        XCTAssertEqual(DurationPhrase.phrase(28800), "8h 0m")
    }

    /// From a day up the hours roll over into days.
    func testFromADayReadsInDaysAndHours() {
        XCTAssertEqual(DurationPhrase.phrase(90000), "1d 1h")
    }

    /// A negative interval — a clock that stepped back — reads as nothing elapsed.
    func testNegativeReadsZero() {
        XCTAssertEqual(DurationPhrase.phrase(-5), "0s")
    }

    /// The age variant keeps the largest unit and adds " ago".
    func testAgeReadsLargestUnitAgo() {
        XCTAssertEqual(DurationPhrase.age(40), "40s ago")
        XCTAssertEqual(DurationPhrase.age(180), "3m ago")
        XCTAssertEqual(DurationPhrase.age(7200), "2h ago")
    }

    /// The PR-checks message reads long waits in hours through the shared phrase.
    func testPullRequestChecksDurationReadsInHours() {
        XCTAssertEqual(PullRequestChecks.durationPhrase(5700), "1h 35m")
    }
}
