import XCTest
@testable import KiteloopCore

final class SpendForecastTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    /// Noon on a day of a 30-day month: November 2026.
    private func november(_ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: 12)) ?? .distantPast
    }

    private var now: Date { november(10) }

    private func row(_ cost: Double, source: SpendRow.Source = .routine, project: String? = "/p/a",
                     routine: String? = "brief", basis: SpendRow.Basis = .usd, at: Date? = nil) -> SpendRow {
        SpendRow(at: at ?? now, source: source, project: project, routine: routine, costUSD: cost, basis: basis)
    }

    // MARK: - A routine's next run

    func testARoutineIsForecastFromTheMedianAndRangeOfItsRuns() {
        let forecast = SpendForecast.routines(rows: [10, 1, 4, 2, 3].map { row($0) })

        XCTAssertEqual(forecast, [SpendForecast.Routine(routine: "brief", runs: 5, expectedUSD: 3,
                                                        lowUSD: 1, highUSD: 10, basis: .usd)])
    }

    func testAnEvenNumberOfRunsTakesTheMeanOfTheMiddleTwo() {
        let forecast = SpendForecast.routines(rows: [1, 2, 4, 9].map { row($0) })

        XCTAssertEqual(forecast.first?.expectedUSD, 3)
    }

    func testOnlyTheLatestTwentyRunsAreRead() {
        // Written newest first, so "latest" is by `at`, not by position: runs
        // 1…5 are the oldest and cost 100, the twenty after them cost 1…20.
        let rows = (1...25).reversed().map { run in
            row(run <= 5 ? 100 : Double(run - 5), at: now.addingTimeInterval(Double(run) * 60))
        }

        let forecast = SpendForecast.routines(rows: rows)

        XCTAssertEqual(forecast.first?.runs, 20)
        XCTAssertEqual(forecast.first?.lowUSD, 1)
        XCTAssertEqual(forecast.first?.highUSD, 20)
        XCTAssertEqual(forecast.first?.expectedUSD, 10.5)
    }

    func testTwoRunsAreTooFewToForecastAndSaySo() {
        let forecast = SpendForecast.routines(rows: [row(1), row(5)])

        XCTAssertEqual(forecast, [SpendForecast.Routine(routine: "brief", runs: 2, expectedUSD: nil,
                                                        lowUSD: nil, highUSD: nil, basis: .usd)])
    }

    func testThreeRunsAreEnough() {
        let forecast = SpendForecast.routines(rows: [row(1), row(5), row(2)])

        XCTAssertEqual(forecast.first?.expectedUSD, 2)
    }

    func testOnlyRoutineRowsWithARoutineAreForecast() {
        let rows = [row(1, source: .chat), row(1, source: .autopilot), row(1, source: .planner),
                    row(1, routine: nil), row(1, routine: "")]

        XCTAssertEqual(SpendForecast.routines(rows: rows), [])
    }

    func testRoutinesAreCostliestFirstWithTheUnforecastLast() {
        let costs: [(id: String, cost: Double, runs: Int)] = [("cheap", 1, 3), ("dear", 5, 3),
                                                              ("also-dear", 5, 3), ("new", 9, 1)]
        let rows = costs.flatMap { routine in (0..<routine.runs).map { _ in row(routine.cost, routine: routine.id) } }

        XCTAssertEqual(SpendForecast.routines(rows: rows).map(\.routine), ["also-dear", "dear", "cheap", "new"])
    }

    // MARK: - A project's month

    func testTheMonthIsProjectedInAStraightLineFromItsDaysSoFar() {
        let rows = [row(12, at: november(2)), row(8, source: .chat, routine: nil),
                    row(50, at: november(1).addingTimeInterval(-86_400))]

        let forecast = SpendForecast.monthEnd(rows: rows, now: now, calendar: calendar)

        XCTAssertEqual(forecast, [SpendForecast.Project(project: "/p/a", monthToDateUSD: 20, daysElapsed: 10,
                                                        daysInMonth: 30, projectedMonthEndUSD: 60, basis: .usd)])
    }

    func testARowAfterNowIsNotSpentYet() {
        let forecast = SpendForecast.monthEnd(rows: [row(1), row(9, at: november(11))], now: now, calendar: calendar)

        XCTAssertEqual(forecast.map(\.monthToDateUSD), [1])
    }

    func testTheFirstOfTheMonthCountsAsOneDay() {
        let first = november(1)

        let forecast = SpendForecast.monthEnd(rows: [row(2, at: first)], now: first, calendar: calendar)

        XCTAssertEqual(forecast.first?.daysElapsed, 1)
        XCTAssertEqual(forecast.first?.projectedMonthEndUSD, 60)
    }

    func testAProjectsBasisIsItsRowsOwn() {
        let rows = [row(1, project: "/p/sub", basis: .tokenEquivalent),
                    row(2, project: "/p/sub", basis: .tokenEquivalent),
                    row(1, project: "/p/both", basis: .tokenEquivalent), row(1, project: "/p/both", basis: .usd)]

        let forecast = SpendForecast.monthEnd(rows: rows, now: now, calendar: calendar)

        XCTAssertEqual(forecast.map(\.project), ["/p/sub", "/p/both"])
        XCTAssertEqual(forecast.map(\.basis), [.tokenEquivalent, .mixed])
    }

    func testSpendNobodyCouldAttributeIsProjectedUnderUnknown() {
        let forecast = SpendForecast.monthEnd(rows: [row(1, project: nil), row(2, project: "")],
                                              now: now, calendar: calendar)

        XCTAssertEqual(forecast.map(\.project), [SpendBreakdown.unknownKey])
        XCTAssertEqual(forecast.first?.monthToDateUSD, 3)
    }

    func testProjectsAreHighestProjectionFirstWithTiesByName() {
        let rows = [row(1, project: "/p/b"), row(1, project: "/p/a"), row(4, project: "/p/c")]

        let forecast = SpendForecast.monthEnd(rows: rows, now: now, calendar: calendar)

        XCTAssertEqual(forecast.map(\.project), ["/p/c", "/p/a", "/p/b"])
    }

    // MARK: - Both together

    func testTheForecastNamesItsMonth() {
        let forecast = SpendForecast.make(rows: [row(1), row(2), row(3)], now: now, calendar: calendar)

        XCTAssertEqual(forecast.month, "2026-11")
        XCTAssertEqual(forecast.projects.map(\.project), ["/p/a"])
        XCTAssertEqual(forecast.routines.map(\.routine), ["brief"])
    }
}
