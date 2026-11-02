import XCTest
@testable import Kiteloop

/// When a message was sent, as the chat shows it: the hover text on a bubble
/// and the day marker above the first message of each calendar day. Kiteloop
/// runs for days, and a reply from last night used to look the same as one
/// from a minute ago.
final class ChatMessageTimeTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let locale = Locale(identifier: "en_US")

    /// 2026-03-05 15:00 UTC.
    private var now: Date { date(day: 5, hour: 15) }

    private func date(day: Int, hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute))!
    }

    private func marker(_ date: Date, previous: Date?) -> String? {
        ChatView.dayMarkerLabel(for: date, previous: previous, now: now, calendar: calendar, locale: locale)
    }

    // MARK: - Day marker

    func testTheFirstMessageOfTodayIsMarkedToday() {
        XCTAssertEqual(marker(date(day: 5, hour: 9), previous: nil), "Today")
        XCTAssertEqual(marker(date(day: 5, hour: 0), previous: date(day: 4, hour: 23)), "Today")
    }

    func testTheFirstMessageOfYesterdayIsMarkedYesterday() {
        XCTAssertEqual(marker(date(day: 4, hour: 22), previous: date(day: 3, hour: 8)), "Yesterday")
    }

    func testAnOlderDayIsMarkedWithItsDate() {
        let label = marker(date(day: 2, hour: 10), previous: nil)
        XCTAssertEqual(label, "March 2, 2026")
    }

    func testAMessageOnTheSameDayAsTheOneBeforeItHasNoMarker() {
        XCTAssertNil(marker(date(day: 5, hour: 14), previous: date(day: 5, hour: 9)))
        XCTAssertNil(marker(date(day: 2, hour: 23), previous: date(day: 2, hour: 0)))
    }

    // MARK: - Hover time

    func testAMessageFromTodayShowsTheTimeAlone() {
        let label = MessageBubble.sentTimeLabel(
            for: date(day: 5, hour: 9, minute: 41), now: now, calendar: calendar, locale: locale
        )
        XCTAssertTrue(label.contains("9:41"), label)
        XCTAssertFalse(label.contains("Mar"), label)
        XCTAssertFalse(label.contains("2026"), label)
    }

    func testAMessageFromAnEarlierDayShowsTheDateAndTheTime() {
        let label = MessageBubble.sentTimeLabel(
            for: date(day: 4, hour: 21, minute: 7), now: now, calendar: calendar, locale: locale
        )
        XCTAssertTrue(label.contains("9:07"), label)
        XCTAssertTrue(label.contains("Mar 4"), label)
        XCTAssertTrue(label.contains("2026"), label)
    }
}
