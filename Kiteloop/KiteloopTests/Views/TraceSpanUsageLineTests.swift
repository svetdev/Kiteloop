import KiteloopCore
import XCTest
@testable import Kiteloop

/// The caption under a turn in the Traces detail pane: what the turn sent, what
/// it wrote, how much of its prompt the cache served, and which model ran it.
final class TraceSpanUsageLineTests: XCTestCase {

    private func turn(_ metadata: [String: String]) -> TraceSpan {
        TraceSpan(agentID: "a1", sessionID: "s1", type: .turn, metadata: metadata)
    }

    /// The prompt figure is the whole prompt — uncached input plus cache reads —
    /// not `inputTokens` alone, which would read 1.2k here.
    func testCountersAndModelReadAsOneLine() {
        let span = turn([
            TraceSpan.MetadataKey.inputTokens: "1200",
            TraceSpan.MetadataKey.cacheReadTokens: "8800",
            TraceSpan.MetadataKey.outputTokens: "450",
            TraceSpan.MetadataKey.model: "claude-sonnet-5",
        ])
        XCTAssertEqual(TraceDetailView.usageLine(for: span),
                       "10.0k in · 450 out · cache 88% · claude-sonnet-5")
    }

    /// A span written before the counters existed says nothing — not `0 in`,
    /// and not `cache not measured`.
    func testSpanWithoutCountersHasNoLine() {
        XCTAssertNil(TraceDetailView.usageLine(for: turn([:])))
        XCTAssertNil(TraceDetailView.usageLine(for: turn([TraceSpan.MetadataKey.model: "claude-sonnet-5"])))
    }

    func testCountersWithoutModelEndWithoutASeparator() {
        let span = turn([
            TraceSpan.MetadataKey.inputTokens: "1200",
            TraceSpan.MetadataKey.cacheReadTokens: "8800",
            TraceSpan.MetadataKey.outputTokens: "450",
        ])
        XCTAssertEqual(TraceDetailView.usageLine(for: span), "10.0k in · 450 out · cache 88%")
    }

    /// The shared formatter `TaskInsightsView` also reads through.
    func testCompactCountFormatsAsBefore() {
        XCTAssertEqual(TokenUsage.compactCount(999), "999")
        XCTAssertEqual(TokenUsage.compactCount(1_000), "1.0k")
        XCTAssertEqual(TokenUsage.compactCount(3_400_000), "3.4M")
    }

    // MARK: - Duration

    func testASpanOfAMinuteOrMoreReadsOnTheHeadersScale() {
        XCTAssertEqual(TraceDetailView.spanDurationLabel(243.17), "4m 3s")
        XCTAssertEqual(TraceDetailView.spanDurationLabel(3725), "1h 2m")
    }

    /// Under a minute keeps its fractions — not rounded to "0s" or up to "1m 0s".
    func testASpanUnderAMinuteKeepsFractionalSeconds() {
        XCTAssertEqual(TraceDetailView.spanDurationLabel(0.31), "0.31s")
        XCTAssertEqual(TraceDetailView.spanDurationLabel(59.5), "59.50s")
    }

    // MARK: - Start time

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let locale = Locale(identifier: "en_US")

    private func date(day: Int, hour: Int, minute: Int = 0) -> Date {
        utcCalendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute))!
    }

    private func startLabel(_ date: Date, now: Date) -> String {
        TraceDetailView.startTimeLabel(for: date, now: now, calendar: utcCalendar, locale: locale)
    }

    func testATurnFromAnEarlierDayShowsTheDateAndTheTime() {
        let label = startLabel(date(day: 2, hour: 14, minute: 2), now: date(day: 5, hour: 15))
        XCTAssertTrue(label.contains("Mar 2"), label)
        XCTAssertTrue(label.contains("2:02"), label)
    }

    func testATurnFromTodayShowsTheTimeAlone() {
        let turn = date(day: 5, hour: 14, minute: 2)
        let timeOnly = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
                                        calendar: utcCalendar, timeZone: utcCalendar.timeZone)
        XCTAssertEqual(startLabel(turn, now: date(day: 5, hour: 15)), timeOnly.format(turn))
    }

    /// Twenty minutes ago, but on the other side of midnight: the calendar day
    /// decides, not a 24-hour window.
    func testATurnJustBeforeMidnightReadAfterItGetsADate() {
        let label = startLabel(date(day: 4, hour: 23, minute: 50), now: date(day: 5, hour: 0, minute: 10))
        XCTAssertTrue(label.contains("Mar 4"), label)
    }

    /// The header shows the whole id — no prefix, no ellipsis — so it can be
    /// copied into `claude --resume`.
    func testSessionLabelShowsTheWholeID() {
        let id = "1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d"
        XCTAssertEqual(TraceDetailView.sessionLabel(for: id), "Session: \(id)")
    }

    func testSessionLabelSaysWhenNoIDWasRecorded() {
        XCTAssertEqual(TraceDetailView.sessionLabel(for: "unknown"), "No session id recorded")
        XCTAssertEqual(TraceDetailView.sessionLabel(for: ""), "No session id recorded")
    }
}
