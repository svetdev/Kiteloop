import XCTest
@testable import KiteloopCore

/// A budget on a routine, an agent or a project: which ledger rows count
/// against each, the one refusal all three share, the reading the API gives
/// and the line a chat says once. 2026-11-17 is the day it is.
final class OwnedSpendBudgetTests: XCTestCase {

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    private func date(_ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour)) ?? .distantPast
    }

    private var now: Date { date(11, 17) }

    private func row(_ month: Int, _ day: Int, _ cost: Double, source: SpendRow.Source = .chat,
                     project: String? = "/work/vault", agent: String? = "a-1", routine: String? = nil) -> SpendRow {
        let at = date(month, day)
        return SpendRow(at: at, day: DayKey.string(for: at, timeZone: calendar.timeZone), source: source,
                        project: project, agent: agent, routine: routine, costUSD: cost, basis: .usd)
    }

    /// Today: 1 chat and 2 routine for a-1 in vault, 4 autopilot for a-2 in
    /// vault, 8 planner in vault with no agent, 16 chat for a-1 in another
    /// project. Earlier this month: 32 for a-1 in vault. Last month: 64.
    private var rows: [SpendRow] {
        [row(11, 17, 1),
         row(11, 17, 2, source: .routine, routine: "brief"),
         row(11, 17, 4, source: .autopilot, agent: "a-2"),
         row(11, 17, 8, source: .planner, agent: nil),
         row(11, 17, 16, project: "/work/other"),
         row(11, 3, 32),
         row(10, 31, 64)]
    }

    private func budget(_ ceiling: Double, _ period: SpendBudget.Period = .day) -> SpendBudget {
        SpendBudget(ceilingUSD: ceiling, period: period, consequence: .refuse)
    }

    private func agent(_ ceiling: Double, _ period: SpendBudget.Period = .day, id: String = "a-1") -> OwnedSpendBudget {
        OwnedSpendBudget(owner: .agent(id: id, name: "Dev"), budget: budget(ceiling, period))
    }

    private func project(_ ceiling: Double, _ period: SpendBudget.Period = .day,
                         path: String = "/work/vault") -> OwnedSpendBudget {
        OwnedSpendBudget(owner: .project(path: path, name: "vault"), budget: budget(ceiling, period))
    }

    private func routine(_ ceiling: Double, _ period: SpendBudget.Period = .day) -> OwnedSpendBudget {
        OwnedSpendBudget(owner: .routine("brief"), budget: budget(ceiling, period))
    }

    private func spent(_ owned: OwnedSpendBudget) -> Double {
        owned.spent(in: rows, now: now, calendar: calendar)
    }

    // MARK: - Which rows count

    func testAnAgentsWindowIsEveryRowFiledUnderItWhateverTheSourceOrProject() {
        XCTAssertEqual(spent(agent(10)), 19, "1 chat + 2 routine + 16 in the other project")
        XCTAssertEqual(spent(agent(10, .month)), 51, "and the 32 from the 3rd; last month's 64 is not in it")
        XCTAssertEqual(spent(agent(10, id: "a-2")), 4)
        XCTAssertEqual(spent(agent(10, id: "nobody")), 0)
    }

    func testAProjectsWindowIsEverySourceInItAndNoOtherProject() {
        XCTAssertEqual(spent(project(10)), 15, "chat 1 + routine 2 + autopilot 4 + planner 8")
        XCTAssertEqual(spent(project(10, .month)), 47)
        XCTAssertEqual(spent(project(10, path: "/work/other")), 16)
    }

    func testAProjectIsTheSameFolderWithOrWithoutItsClosingSlash() {
        XCTAssertEqual(spent(project(10, path: "/work/vault/")), 15)
        let slashed = [row(11, 17, 5, project: "/work/vault/")]
        XCTAssertEqual(project(10).spent(in: slashed, now: now, calendar: calendar), 5)
        XCTAssertEqual(project(10, path: "/work/vaults").spent(in: rows, now: now, calendar: calendar), 0)
    }

    func testARowNobodyAttributedCountsAgainstNoProject() {
        let unfiled = [row(11, 17, 5, project: nil)]
        XCTAssertEqual(project(10).spent(in: unfiled, now: now, calendar: calendar), 0)
    }

    func testARoutinesWindowIsItsOwnTurns() {
        XCTAssertEqual(spent(routine(10)), 2)
    }

    // MARK: - The refusal, one for all three

    func testEachLevelRefusesFromItsCeilingAndNotBelowIt() {
        for owned in [agent(10), project(10), routine(10)] {
            XCTAssertNil(owned.refusal(spentUSD: 0), "\(owned.owner)")
            XCTAssertNil(owned.refusal(spentUSD: 9.99), "\(owned.owner)")
            XCTAssertNotNil(owned.refusal(spentUSD: 10), "\(owned.owner)")
            XCTAssertNotNil(owned.refusal(spentUSD: 12), "\(owned.owner)")
        }
    }

    func testTheWarningPointRefusesNothing() {
        let owned = agent(10)
        XCTAssertEqual(owned.budget.standing(spentUSD: 9), .warning)
        XCTAssertNil(owned.refusal(spentUSD: 9))
    }

    func testARefusalNamesWhoseBudgetItIsTheCeilingAndTheSpend() {
        XCTAssertEqual(agent(10).refusal(spentUSD: 19),
                       "Dev's agent budget $10.00 per day exhausted ($19.00 spent today)")
        XCTAssertEqual(project(40, .month).refusal(spentUSD: 47),
                       "vault's project budget $40.00 per month exhausted ($47.00 spent this month)")
        XCTAssertEqual(routine(2).refusal(spentUSD: 2),
                       "routine budget $2.00 per day exhausted ($2.00 spent today)")
    }

    func testARoutinesOwnRefusalIsTheSharedOne() {
        let brief = Routine(id: "brief", name: "Brief", project: "vault", agent: "Dev", prompt: "Go.",
                            trigger: .init(at: "07:00"), budget: budget(2))

        XCTAssertEqual(brief.ownedBudget, routine(2))
        XCTAssertEqual(brief.budgetRefusal(spentUSD: 2), routine(2).refusal(spentUSD: 2))
        XCTAssertNil(brief.budgetRefusal(spentUSD: 1.99))
    }

    // MARK: - Several at once

    private func refusal(among budgets: [OwnedSpendBudget]) -> String? {
        OwnedSpendBudget.refusal(among: budgets, rows: rows, now: now, calendar: calendar)
    }

    func testNoBudgetsRefuseNothing() {
        XCTAssertNil(refusal(among: []))
    }

    func testBudgetsAllUnderTheirCeilingsRefuseNothing() {
        XCTAssertNil(refusal(among: [project(15.01), agent(19.01), routine(2.01)]))
    }

    func testOneSpentBudgetRefusesThoughTheOthersHaveRoom() {
        XCTAssertEqual(refusal(among: [project(100), agent(19), routine(100)]),
                       "Dev's agent budget $19.00 per day exhausted ($19.00 spent today)")
        XCTAssertEqual(refusal(among: [project(15), agent(100)]),
                       "vault's project budget $15.00 per day exhausted ($15.00 spent today)")
        XCTAssertEqual(refusal(among: [project(100), agent(100), routine(2)]),
                       "routine budget $2.00 per day exhausted ($2.00 spent today)")
    }

    func testWhenSeveralAreSpentTheFirstGivenIsTheOneNamed() {
        XCTAssertEqual(refusal(among: [project(1), agent(1)]),
                       "vault's project budget $1.00 per day exhausted ($15.00 spent today)")
        XCTAssertEqual(refusal(among: [agent(1), project(1)]),
                       "Dev's agent budget $1.00 per day exhausted ($19.00 spent today)")
    }

    func testAnAgentWithRoomIsStillRefusedByAnotherAgentsSpentBudget() {
        // An autopilot run's worker and reviewer: either one over stops the run.
        XCTAssertNotNil(refusal(among: [agent(100), agent(4, id: "a-2")]))
        XCTAssertNil(refusal(among: [agent(100), agent(4.01, id: "a-2")]))
    }

    func testAMonthlyBudgetRefusesOnWhatTheMonthCostThoughTodayIsCheap() {
        XCTAssertNil(refusal(among: [agent(50)]))
        XCTAssertNotNil(refusal(among: [agent(50, .month)]))
    }

    // MARK: - The reading

    func testAReadingCarriesTheBudgetWhatWasSpentAndTheStanding() {
        let reading = project(16).reading(in: rows, now: now, calendar: calendar)

        XCTAssertEqual(reading["ceilingUSD"] as? Double, 16)
        XCTAssertEqual(reading["period"] as? String, "day")
        XCTAssertEqual(reading["warnAtFraction"] as? Double, SpendBudget.defaultWarnAtFraction)
        XCTAssertEqual(reading["consequence"] as? String, "refuse")
        XCTAssertEqual(reading["spentUSD"] as? Double, 15)
        XCTAssertEqual(reading["standing"] as? String, "warning", "15 of 16 is past the budget's own 0.8")
    }

    func testAReadingsStandingFollowsTheSpend() {
        let standing = { (owned: OwnedSpendBudget) in
            owned.reading(in: self.rows, now: self.now, calendar: self.calendar)["standing"] as? String
        }

        XCTAssertEqual(standing(project(100)), "under")
        XCTAssertEqual(standing(project(15)), "atLimit")
        XCTAssertEqual(standing(agent(10, id: "nobody")), "under")
    }

    // MARK: - A budget in a request body

    func testAnAbsentBudgetIsKeptNullClearsItAndAnObjectSetsIt() {
        let existing = budget(5)

        XCTAssertEqual(SpendBudget.edit(nil, on: .agent).edit, .keep)
        XCTAssertEqual(SpendBudget.edit(NSNull(), on: .agent).edit, .clear)
        XCTAssertEqual(SpendBudget.edit(["ceilingUSD": 40, "period": "month"], on: .project).edit,
                       .set(budget(40, .month)))
        XCTAssertEqual(SpendBudget.Edit.keep.applied(to: existing), existing)
        XCTAssertNil(SpendBudget.Edit.clear.applied(to: existing))
        XCTAssertEqual(SpendBudget.Edit.set(budget(9)).applied(to: existing), budget(9))
    }

    func testABudgetThatCannotBeKeptIsRefusedInWordsAndChangesNothing() {
        let cases: [(value: Any, holder: SpendBudget.Holder, problem: String)] = [
            ("5", .agent, "\"budget\" is an object, or null to clear it"),
            (["ceilingUSD": 0], .project, "\"budget.ceilingUSD\" is above zero"),
            (["ceilingUSD": 5, "period": "week"], .agent, "\"budget.period\" is one of \"day\", \"month\""),
            (["ceilingUSD": 5, "consequence": "ask"], .agent,
             "\"budget.consequence\" \"ask\" is not yet available for agents: an agent's budget takes \"refuse\""),
            (["ceilingUSD": 5, "consequence": "pause"], .project,
             "\"budget.consequence\" \"pause\" is not yet available for projects: a project's budget takes \"refuse\""),
            (["ceilingUSD": 5, "consequence": "ask"], .routine,
             "\"budget.consequence\" \"ask\" is not yet available for routines: a routine's budget takes \"refuse\"")
        ]
        for testCase in cases {
            let read = SpendBudget.edit(testCase.value, on: testCase.holder)
            XCTAssertEqual(read.edit, .keep, testCase.problem)
            XCTAssertEqual(read.problems, [testCase.problem])
        }
    }

    // MARK: - Saying so once

    func testAnAgentUnderItsBudgetIsSaidNothing() {
        var notice = OverBudgetNotice()

        XCTAssertNil(notice.line(for: agent(19.01), rows: rows, now: now, calendar: calendar))
    }

    func testAnAgentOverItsBudgetIsSaidOnceInADayAndAgainTheNext() throws {
        var notice = OverBudgetNotice()
        let owned = agent(10)

        let line = try XCTUnwrap(notice.line(for: owned, rows: rows, now: now, calendar: calendar))
        XCTAssertTrue(line.contains("Dev's agent budget $10.00 per day exhausted ($19.00 spent today)"), line)
        XCTAssertTrue(line.contains("your own messages still run"), line)
        XCTAssertNil(notice.line(for: owned, rows: rows, now: date(11, 17, 23), calendar: calendar),
                     "the same day: said already")

        let tomorrow = rows + [row(11, 18, 11)]
        XCTAssertNil(notice.line(for: owned, rows: rows, now: date(11, 18), calendar: calendar),
                     "a new day with nothing spent in it")
        XCTAssertNotNil(notice.line(for: owned, rows: tomorrow, now: date(11, 18), calendar: calendar))
        XCTAssertNil(notice.line(for: owned, rows: tomorrow, now: date(11, 18, 20), calendar: calendar))
    }

    func testAMonthlyBudgetIsSaidOnceInTheMonth() {
        var notice = OverBudgetNotice()
        let owned = agent(40, .month)

        XCTAssertNotNil(notice.line(for: owned, rows: rows, now: now, calendar: calendar))
        XCTAssertNil(notice.line(for: owned, rows: rows, now: date(11, 30), calendar: calendar))
    }

    // MARK: - A budget's window by name

    func testADaysWindowIsItsDayKeyAndAMonthsItsMonth() {
        XCTAssertEqual(budget(1).window(now: now, calendar: calendar), "2026-11-17")
        XCTAssertEqual(budget(1, .month).window(now: now, calendar: calendar), "2026-11")
    }

    // MARK: - On a project's settings

    func testAProjectsBudgetReadsBackAsWrittenAndIsAbsentUntilSet() throws {
        var config = ProjectConfig.default
        XCTAssertNil(config.budget)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(config), as: UTF8.self).contains("budget"))

        config.budget = budget(40, .month)
        config.maxBudgetUSD = 3
        let read = try JSONDecoder().decode(ProjectConfig.self, from: JSONEncoder().encode(config))

        XCTAssertEqual(read.budget, budget(40, .month))
        XCTAssertEqual(read.maxBudgetUSD, 3, "the per-session ceiling is its own field, untouched")
    }
}
