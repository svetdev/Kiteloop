import XCTest
@testable import KiteloopCore

/// A budget's window over the spend ledger's rows, where spend leaves it, and
/// a budget read from a request body. 2026-11-17 is the day it is.
final class SpendBudgetTests: XCTestCase {

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    private func date(_ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour)) ?? .distantPast
    }

    private func row(_ month: Int, _ day: Int, _ cost: Double, routine: String? = "brief") -> SpendRow {
        let at = date(month, day)
        return SpendRow(at: at, day: DayKey.string(for: at, timeZone: calendar.timeZone), source: .routine,
                        routine: routine, costUSD: cost, basis: .usd)
    }

    private var rows: [SpendRow] {
        [row(11, 17, 1), row(11, 17, 2), row(11, 17, 4, routine: "other"), row(11, 17, 8, routine: nil),
         row(11, 16, 16), row(11, 1, 32), row(10, 31, 64), row(10, 17, 128)]
    }

    private func budget(_ period: SpendBudget.Period, ceiling: Double = 10) -> SpendBudget {
        SpendBudget(ceilingUSD: ceiling, period: period, consequence: .refuse)
    }

    // MARK: - The window

    func testADaySumsOnlyTheMatchingRowsOfTheCurrentLocalDay() {
        let spent = budget(.day).spent(in: rows, now: date(11, 17, 23), calendar: calendar) { $0.routine == "brief" }

        XCTAssertEqual(spent, 3, "yesterday's 16 and the other routine's 4 are not in it")
    }

    func testAMonthSumsOnlyTheMatchingRowsOfTheCurrentCalendarMonth() {
        let spent = budget(.month).spent(in: rows, now: date(11, 17), calendar: calendar) { $0.routine == "brief" }

        XCTAssertEqual(spent, 51, "1 + 2 + 16 + 32: last month's 64 and 128 are not in it")
    }

    func testTheDayIsTheCalendarsOwn() throws {
        var east = calendar
        east.timeZone = try XCTUnwrap(TimeZone(identifier: "Pacific/Auckland"))
        // 12:00 UTC on the 17th is already the 18th in Auckland.
        let spent = budget(.day).spent(in: rows, now: date(11, 17), calendar: east) { _ in true }

        XCTAssertEqual(spent, 0)
    }

    func testNoRowsSpendNothing() {
        XCTAssertEqual(budget(.month).spent(in: [], now: date(11, 17), calendar: calendar) { _ in true }, 0)
    }

    // MARK: - Standing

    func testStandingIsUnderBelowTheWarningPointWarningFromItAndAtLimitFromTheCeiling() {
        let budget = budget(.day)

        XCTAssertEqual(budget.warnAtFraction, SpendBudget.defaultWarnAtFraction)
        XCTAssertEqual(budget.standing(spentUSD: 0), .under)
        XCTAssertEqual(budget.standing(spentUSD: 7.99), .under)
        XCTAssertEqual(budget.standing(spentUSD: 8), .warning)
        XCTAssertEqual(budget.standing(spentUSD: 9.99), .warning)
        XCTAssertEqual(budget.standing(spentUSD: 10), .atLimit)
        XCTAssertEqual(budget.standing(spentUSD: 12), .atLimit)
    }

    func testAWarningPointOfItsOwnMovesTheWarning() {
        let budget = SpendBudget(ceilingUSD: 10, period: .day, warnAtFraction: 0.5, consequence: .refuse)

        XCTAssertEqual(budget.standing(spentUSD: 4.99), .under)
        XCTAssertEqual(budget.standing(spentUSD: 5), .warning)
    }

    // MARK: - On file

    func testABudgetReadsBackAsWrittenAndOneWithNoWarningPointWarnsAtTheDefault() throws {
        let budget = SpendBudget(ceilingUSD: 40, period: .month, warnAtFraction: 0.9, consequence: .refuse)
        let data = try JSONEncoder().encode(budget)
        XCTAssertEqual(try JSONDecoder().decode(SpendBudget.self, from: data), budget)

        let bare = Data(#"{"ceilingUSD":5,"period":"day","consequence":"refuse"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(SpendBudget.self, from: bare), self.budget(.day, ceiling: 5))
    }

    // MARK: - From a request

    func testABodyWithOnlyACeilingIsADailyBudgetThatRefuses() {
        let parsed = SpendBudget.parse(["ceilingUSD": 5])

        XCTAssertEqual(parsed.value, budget(.day, ceiling: 5))
        XCTAssertEqual(parsed.problems, [])
    }

    func testABodySaysEveryField() {
        let parsed = SpendBudget.parse(["ceilingUSD": 40.5, "period": "month", "warnAtFraction": 1,
                                        "consequence": "pause"])

        XCTAssertEqual(parsed.value, SpendBudget(ceilingUSD: 40.5, period: .month, warnAtFraction: 1,
                                                 consequence: .pause))
    }

    func testEveryProblemWithABudgetIsNamedAtOnce() {
        let parsed = SpendBudget.parse(["ceilingUSD": 0, "period": "week", "warnAtFraction": 1.5,
                                        "consequence": "shrug"])

        XCTAssertNil(parsed.value)
        XCTAssertEqual(parsed.problems, [
            "\"budget.ceilingUSD\" is above zero",
            "\"budget.warnAtFraction\" is above 0 and at most 1",
            "\"budget.period\" is one of \"day\", \"month\"",
            "\"budget.consequence\" is one of \"ask\", \"pause\", \"refuse\""
        ])
    }

    func testACeilingAndAWarningPointOutOfRangeAreProblems() {
        XCTAssertEqual(SpendBudget.parse([:]).problems, ["\"budget.ceilingUSD\" is above zero"])
        XCTAssertEqual(SpendBudget.parse(["ceilingUSD": -1]).problems, ["\"budget.ceilingUSD\" is above zero"])
        XCTAssertEqual(SpendBudget.parse(["ceilingUSD": "5"]).problems, ["\"budget.ceilingUSD\" is above zero"])
        for fraction in [0, -0.1, 1.01] {
            XCTAssertEqual(SpendBudget.parse(["ceilingUSD": 5, "warnAtFraction": fraction]).problems,
                           ["\"budget.warnAtFraction\" is above 0 and at most 1"], "\(fraction)")
        }
    }

    func testTheJSONCarriesEveryField() {
        let json = budget(.month, ceiling: 40).json

        XCTAssertEqual(json["ceilingUSD"] as? Double, 40)
        XCTAssertEqual(json["period"] as? String, "month")
        XCTAssertEqual(json["warnAtFraction"] as? Double, 0.8)
        XCTAssertEqual(json["consequence"] as? String, "refuse")
    }
}
