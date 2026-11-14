import XCTest
@testable import KiteloopCore

/// When a routine falls and what it owes, on a fixed calendar: 2026-11-16 is
/// a Monday.
final class RoutineScheduleTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)) ?? .distantPast
    }

    private func schedule(_ trigger: Routine.Trigger) throws -> RoutineSchedule {
        try RoutineSchedule.parse(trigger).get()
    }

    // MARK: - Parsing

    func testATimeOfDayParsesToItsMinute() throws {
        XCTAssertEqual(try schedule(.init(at: "07:05")).kind, .at(minute: 425))
    }

    func testAnIntervalDefaultsToTheWholeDay() throws {
        XCTAssertEqual(try schedule(.init(every: 30)).kind, .every(minutes: 30, from: 0, until: 1439))
    }

    func testDaysAreReadAsWeekdaysInAnyCase() throws {
        XCTAssertEqual(try schedule(.init(at: "08:00", days: ["Mon", "fri"])).weekdays, [2, 6])
    }

    func testATriggerWithNeitherOrBothIsRefused() {
        for trigger in [Routine.Trigger(), Routine.Trigger(at: "07:00", every: 5)] {
            guard case .failure(let refusal) = RoutineSchedule.parse(trigger) else { return XCTFail("parsed") }
            XCTAssertEqual(refusal.problems, ["the trigger takes either \"at\" or \"every\""])
        }
    }

    func testWhatIsNotATimeOrADayIsNamed() {
        let cases: [(Routine.Trigger, String)] = [
            (.init(at: "7am"), "\"at\" is a time of day as HH:mm"),
            (.init(at: "24:00"), "\"at\" is a time of day as HH:mm"),
            (.init(at: "07:5"), "\"at\" is a time of day as HH:mm"),
            (.init(every: 0), "\"every\" is a number of minutes above zero"),
            (.init(every: 10, from: "18:00", until: "08:00"),
             "\"from\" and \"until\" are times of day as HH:mm, \"from\" the earlier"),
            (.init(every: 10, from: "soon"), "\"from\" and \"until\" are times of day as HH:mm, \"from\" the earlier"),
            (.init(at: "07:00", days: ["monday"]), "\"days\" takes one or more of sun, mon, tue, wed, thu, fri, sat"),
            (.init(at: "07:00", days: []), "\"days\" takes one or more of sun, mon, tue, wed, thu, fri, sat")
        ]
        for (trigger, problem) in cases {
            guard case .failure(let refusal) = RoutineSchedule.parse(trigger) else { return XCTFail("parsed \(trigger)") }
            XCTAssertEqual(refusal.problems, [problem])
        }
    }

    // MARK: - Occurrences

    func testADailyTimeFallsTodayOnceItHasPassedAndYesterdayBefore() throws {
        let daily = try schedule(.init(at: "07:00"))

        XCTAssertEqual(daily.latestOccurrence(atOrBefore: date(16, 7), calendar: calendar), date(16, 7))
        XCTAssertEqual(daily.latestOccurrence(atOrBefore: date(16, 6, 59), calendar: calendar), date(15, 7))
        XCTAssertEqual(daily.nextOccurrence(after: date(16, 7), calendar: calendar), date(17, 7))
        XCTAssertEqual(daily.nextOccurrence(after: date(16, 6), calendar: calendar), date(16, 7))
    }

    func testAWeekdayPatternSkipsTheDaysItDoesNotName() throws {
        let monday = try schedule(.init(at: "08:00", days: ["mon"]))

        XCTAssertEqual(monday.latestOccurrence(atOrBefore: date(18, 12), calendar: calendar), date(16, 8))
        XCTAssertEqual(monday.nextOccurrence(after: date(16, 8), calendar: calendar), date(23, 8))
        XCTAssertEqual(monday.latestOccurrence(atOrBefore: date(16, 7), calendar: calendar), date(9, 8))
    }

    func testAnIntervalStepsFromItsStartAndStopsAtItsEnd() throws {
        let poll = try schedule(.init(every: 30, from: "08:00", until: "09:00"))

        XCTAssertEqual(poll.latestOccurrence(atOrBefore: date(16, 8, 45), calendar: calendar), date(16, 8, 30))
        XCTAssertEqual(poll.nextOccurrence(after: date(16, 8, 45), calendar: calendar), date(16, 9))
        XCTAssertEqual(poll.nextOccurrence(after: date(16, 9), calendar: calendar), date(17, 8))
        XCTAssertEqual(poll.latestOccurrence(atOrBefore: date(16, 23), calendar: calendar), date(16, 9))
    }

    // MARK: - What is owed

    func testADailyRoutineMissedOvernightIsStillOwedWhenTheMacWakes() throws {
        let daily = try schedule(.init(at: "07:00"))

        XCTAssertEqual(daily.owed(at: date(16, 15), handledThrough: date(15, 7), calendar: calendar), date(16, 7))
    }

    func testAnOccurrenceAlreadyHandledIsNotOwedAgain() throws {
        let daily = try schedule(.init(at: "07:00"))

        XCTAssertNil(daily.owed(at: date(16, 15), handledThrough: date(16, 7), calendar: calendar))
    }

    func testSeveralMissedDaysOweOnlyTheLatest() throws {
        let daily = try schedule(.init(at: "07:00"))

        XCTAssertEqual(daily.owed(at: date(18, 9), handledThrough: date(14, 7), calendar: calendar), date(18, 7))
    }

    func testAPollIsOwedOnlyUntilTheNextOneWouldHaveCome() throws {
        let poll = try schedule(.init(every: 30, from: "08:00", until: "18:00"))

        XCTAssertEqual(poll.owed(at: date(16, 8, 40), handledThrough: date(16, 8), calendar: calendar), date(16, 8, 30))
        XCTAssertNil(poll.owed(at: date(16, 22), handledThrough: date(16, 8), calendar: calendar))
    }

    // MARK: - In words

    func testAPatternReadsAsAPersonWouldSayIt() throws {
        XCTAssertEqual(try schedule(.init(at: "07:00")).words, "Daily at 07:00")
        XCTAssertEqual(try schedule(.init(at: "08:00", days: ["mon", "tue", "wed", "thu", "fri"])).words,
                       "Weekdays at 08:00")
        XCTAssertEqual(try schedule(.init(at: "16:30", days: ["sun", "fri"])).words, "Fri Sun at 16:30")
        XCTAssertEqual(try schedule(.init(every: 30)).words, "Every 30 min")
        XCTAssertEqual(try schedule(.init(every: 15, from: "08:00", until: "18:00", days: ["mon"])).words,
                       "Every 15 min, 08:00–18:00, Mon")
    }
}
