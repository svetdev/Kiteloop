import XCTest
import KiteloopCore
@testable import Kiteloop

/// The budget's job is to stop autonomous spend running away, so the tests that
/// matter are the ones where a bug would *silently disable* it: an unknown cost
/// counting as zero, or a refusal that also blocks the human.
final class DailyBudgetTests: XCTestCase {

    // MARK: - What an unknown cost is charged

    func testMeasuredCostIsChargedAsMeasured() {
        let charge = DailySpendLedger.resolveCharge(costUSD: 3.25, estimateUSD: 1.0)
        XCTAssertEqual(charge.amountUSD, 3.25, accuracy: 0.001)
        XCTAssertEqual(charge.basis, .measured)
        XCTAssertFalse(charge.wasUnknown)
    }

    /// Worktree runs report `costUSD = 0` when their spend was never attributed.
    /// Counting that as free is the one outcome that disables the ceiling, so it
    /// falls back to the item's own estimate.
    func testZeroCostFallsBackToTheEstimate() {
        let charge = DailySpendLedger.resolveCharge(costUSD: 0, estimateUSD: 4.5)
        XCTAssertEqual(charge.amountUSD, 4.5, accuracy: 0.001)
        XCTAssertEqual(charge.basis, .predicted)
        XCTAssertTrue(charge.wasUnknown)
    }

    func testUnknownCostWithNoEstimateIsChargedTheAssumedAmountNotZero() {
        let charge = DailySpendLedger.resolveCharge(costUSD: nil, estimateUSD: nil)
        XCTAssertEqual(charge.basis, .assumed)
        XCTAssertGreaterThan(charge.amountUSD, 0, "an unknown cost must never be charged as zero")
        XCTAssertEqual(charge.amountUSD, DailySpendLedger.assumedUnknownRunCostUSD, accuracy: 0.001)
    }

    func testAnUnknownChargeExplainsItself() {
        XCTAssertNil(DailySpendLedger.resolveCharge(costUSD: 2, estimateUSD: nil).note)
        XCTAssertNotNil(DailySpendLedger.resolveCharge(costUSD: 0, estimateUSD: 3).note)
        XCTAssertNotNil(DailySpendLedger.resolveCharge(costUSD: nil, estimateUSD: nil).note)
        XCTAssertNotNil(DailySpendLedger.resolveCharge(costUSD: nil, estimateUSD: 3,
                                                       evidence: .noBranch).note,
                        "a run charged nothing should say why, or the day's total can't be read back")
    }

    // MARK: - What a run that produced nothing is charged

    /// The defect this exists for: a dead session leaves no branch, no commits
    /// and an unchanged worktree, and used to be charged its prediction anyway.
    func testARunGitSaysProducedNothingIsChargedNothing() {
        for verdict: RunWorkEvidence.Verdict in [.noBranch, .noCommits, .emptyDiff, .noChanges] {
            let charge = DailySpendLedger.resolveCharge(costUSD: 0, estimateUSD: 3.35,
                                                       evidence: verdict)
            XCTAssertEqual(charge.amountUSD, 0, accuracy: 0.001,
                           "\(verdict) is evidence the run spent nothing")
            XCTAssertEqual(charge.basis, .noWork)
            XCTAssertFalse(charge.wasUnknown, "a no-work charge is a fact, not a stand-in")
        }
    }

    /// The case the stand-in was written for, and the one it keeps: work landed,
    /// the cost never arrived. That run really did consume something.
    func testARunThatProducedWorkButReportedNoCostStillChargesTheStandIn() {
        let predicted = DailySpendLedger.resolveCharge(costUSD: 0, estimateUSD: 4.5,
                                                       evidence: .produced)
        XCTAssertEqual(predicted.amountUSD, 4.5, accuracy: 0.001)
        XCTAssertEqual(predicted.basis, .predicted)

        let assumed = DailySpendLedger.resolveCharge(costUSD: nil, estimateUSD: nil,
                                                     evidence: .produced)
        XCTAssertEqual(assumed.amountUSD, DailySpendLedger.assumedUnknownRunCostUSD, accuracy: 0.001)
        XCTAssertEqual(assumed.basis, .assumed)
    }

    /// `.unknown` is "nobody could tell", not "nothing was produced" — a
    /// live-tree run, a missing project root, git unreadable. Charging those
    /// nothing is the direction that fails open, so they keep the stand-in.
    func testEvidenceThatCannotBeDeterminedStillChargesTheStandIn() {
        XCTAssertEqual(DailySpendLedger.resolveCharge(costUSD: 0, estimateUSD: 3.35,
                                                      evidence: .unknown).basis, .predicted)
        XCTAssertEqual(DailySpendLedger.resolveCharge(costUSD: 0, estimateUSD: nil,
                                                      evidence: .unknown).basis, .assumed)
        XCTAssertEqual(DailySpendLedger.resolveCharge(costUSD: 0, estimateUSD: nil,
                                                      evidence: nil).basis, .assumed,
                       "no evidence at all reads like unreadable evidence, not like an empty run")
    }

    /// Evidence only decides what an *unreported* cost is worth. A run that
    /// really burned tokens burned them whether or not it committed anything.
    func testMeasuredSpendIsChargedEvenWhenTheRunProducedNothing() {
        let charge = DailySpendLedger.resolveCharge(costUSD: 3.25, estimateUSD: 3.35,
                                                    evidence: .noBranch)
        XCTAssertEqual(charge.amountUSD, 3.25, accuracy: 0.001)
        XCTAssertEqual(charge.basis, .measured)
    }

    // MARK: - The day this was found

    /// 2026-08-08 replayed: 31 real runs measured at $244.99, and ~230 dead
    /// sessions of one item that each produced nothing and each reported $0.
    /// The ledger read $1,016.11 that day — three quarters of it phantom — which
    /// exhausted a $150 ceiling and left seven ready items unstarted.
    @MainActor
    func testReplayingTheDayLandsOnWhatWasActuallySpent() throws {
        let dir = try makeTemporaryDirectory(prefix: "daily-spend")

        let ledger = DailySpendLedger(storageURL: dir.appendingPathComponent("spend.json"))
        let measured = 244.99
        let deadSessions = 230
        let predictionPerRun = 3.35

        // The real runs, as the metrics measured them.
        for _ in 0..<31 { ledger.charge(costUSD: measured / 31) }
        // And the dead ones: no cost reported, and git says no branch at all.
        for _ in 0..<deadSessions {
            ledger.charge(costUSD: 0, estimateUSD: predictionPerRun, evidence: .noBranch)
        }

        XCTAssertEqual(ledger.spentTodayUSD, measured, accuracy: 0.5,
                       "the day should total what it actually cost")
        let phantom = Double(deadSessions) * predictionPerRun
        XCTAssertLessThan(ledger.spentTodayUSD, measured + phantom / 2,
                          "the phantom $\(phantom) is what exhausted the ceiling")
        XCTAssertEqual(ledger.today.unknownRuns, 0,
                       "none of these charges was a stand-in for an unreported cost")
    }

    /// The consequence, not just the number: with the day's real spend inside a
    /// $150 ceiling, an autonomous start is still allowed after a burst of dead
    /// sessions. Before, ~45 of them alone would have closed the day.
    @MainActor
    func testABurstOfDeadSessionsDoesNotHoldTheNextAutonomousStart() throws {
        let dir = try makeTemporaryDirectory(prefix: "daily-spend")

        let ledger = DailySpendLedger(storageURL: dir.appendingPathComponent("spend.json"))
        ledger.charge(costUSD: 40)
        for _ in 0..<100 {
            ledger.charge(costUSD: 0, estimateUSD: 3.35, evidence: .noChanges)
        }

        let budget = ledger.budget(150)
        XCTAssertEqual(budget.spentUSD, 40, accuracy: 0.001)
        XCTAssertFalse(budget.isExhausted)
        XCTAssertEqual(budget.decision(for: .autonomous), .allow,
                       "dead sessions must not deny service to the runs that would fix them")
    }

    // MARK: - Who the ceiling stops

    func testExhaustedBudgetRefusesAutonomousButNotHuman() {
        let budget = DailyBudget(budgetUSD: 10, spentUSD: 12)
        XCTAssertTrue(budget.isExhausted)

        guard case .refuse(let refusal) = budget.decision(for: .autonomous) else {
            return XCTFail("an exhausted budget must refuse an autonomous start")
        }
        XCTAssertEqual(refusal.budgetUSD, 10, accuracy: 0.001)
        XCTAssertEqual(refusal.spentUSD, 12, accuracy: 0.001)
        XCTAssertTrue(refusal.logLine.contains("10"), "the refusal should name the budget")

        XCTAssertEqual(budget.decision(for: .human), .allow,
                       "the cap governs autonomy, not the person at the keyboard")
    }

    func testBudgetWithHeadroomAllowsBoth() {
        let budget = DailyBudget(budgetUSD: 10, spentUSD: 4)
        XCTAssertFalse(budget.isExhausted)
        XCTAssertEqual(budget.decision(for: .autonomous), .allow)
        XCTAssertEqual(budget.decision(for: .human), .allow)
        XCTAssertEqual(budget.remainingUSD ?? 0, 6, accuracy: 0.001)
    }

    /// No budget set is "unlimited", not "zero remaining" — otherwise enabling
    /// the feature would stop every run for anyone who hadn't configured it.
    func testNoBudgetMeansNoCeiling() {
        let budget = DailyBudget(budgetUSD: nil, spentUSD: 999)
        XCTAssertFalse(budget.isExhausted)
        XCTAssertEqual(budget.decision(for: .autonomous), .allow)
        XCTAssertNil(budget.remainingUSD)
    }

    // MARK: - Two ceilings

    /// The project's own ceiling is a real bound, not a suggestion: spent, it
    /// refuses even though the portfolio has plenty left.
    func testAProjectOverItsOwnBudgetIsRefusedWhileThePortfolioHasRoom() {
        let gate = ProjectDailyBudget(
            project: DailyBudget(budgetUSD: 5, spentUSD: 6, scope: .project("alpha")),
            portfolio: DailyBudget(budgetUSD: 100, spentUSD: 6))

        guard case .refuse(let refusal) = gate.decision(for: .autonomous) else {
            return XCTFail("a project past its own ceiling must be refused")
        }
        XCTAssertEqual(refusal.scope, .project("alpha"),
                       "the refusal has to name the ceiling that stopped it")
        XCTAssertTrue(refusal.logLine.contains("alpha"), refusal.logLine)
        XCTAssertTrue(refusal.eventReason.contains("alpha"), refusal.eventReason)
    }

    /// The other direction, and the one a generous per-project number must not
    /// buy its way out of: the portfolio ceiling bounds the bill.
    func testAProjectUnderItsOwnBudgetIsStillRefusedByThePortfolioCeiling() {
        let gate = ProjectDailyBudget(
            project: DailyBudget(budgetUSD: 500, spentUSD: 20, scope: .project("alpha")),
            portfolio: DailyBudget(budgetUSD: 100, spentUSD: 100))

        guard case .refuse(let refusal) = gate.decision(for: .autonomous) else {
            return XCTFail("the portfolio ceiling applies on top of a project's own")
        }
        XCTAssertEqual(refusal.scope, .portfolio)
        XCTAssertFalse(refusal.eventReason.contains("alpha"),
                       "this refusal is the portfolio's, and saying otherwise sends the "
                           + "operator to raise the wrong number")
    }

    /// No ceiling of its own is not a licence: the portfolio's still governs it.
    func testAProjectWithNoBudgetOfItsOwnIsGovernedByThePortfolioCeiling() {
        let none = ProjectDailyBudget(
            project: DailyBudget(budgetUSD: nil, spentUSD: 90, scope: .project("alpha")),
            portfolio: DailyBudget(budgetUSD: 100, spentUSD: 40))
        XCTAssertEqual(none.decision(for: .autonomous), .allow,
                       "an uncapped project under the portfolio ceiling still runs")

        let spent = ProjectDailyBudget(
            project: DailyBudget(budgetUSD: nil, spentUSD: 90, scope: .project("alpha")),
            portfolio: DailyBudget(budgetUSD: 100, spentUSD: 100))
        guard case .refuse(let refusal) = spent.decision(for: .autonomous) else {
            return XCTFail("no ceiling of its own means the portfolio's governs it")
        }
        XCTAssertEqual(refusal.scope, .portfolio)
    }

    /// The whole point of the gate, restated for the pair: neither ceiling ever
    /// stops the person at the keyboard.
    func testNeitherCeilingRefusesAHumanStart() {
        let gate = ProjectDailyBudget(
            project: DailyBudget(budgetUSD: 5, spentUSD: 50, scope: .project("alpha")),
            portfolio: DailyBudget(budgetUSD: 10, spentUSD: 100))

        XCTAssertEqual(gate.decision(for: .human), .allow,
                       "the ceiling governs autonomy, not the person")
        XCTAssertNotEqual(gate.decision(for: .autonomous), .allow)
    }

    // MARK: - Per-project spend

    @MainActor
    private func makeLedger(_ dir: URL) -> DailySpendLedger {
        DailySpendLedger(storageURL: dir.appendingPathComponent("spend.json"))
    }

    @MainActor
    private func temporaryDirectory() throws -> URL {
        try makeTemporaryDirectory(prefix: "daily-spend")
    }

    /// A per-project ceiling can only be enforced against a total somebody
    /// attributes — and the portfolio total has to stay the sum, or the two
    /// ceilings would be measuring different days.
    @MainActor
    func testPerProjectTotalsSumToThePortfolioTotal() throws {
        let ledger = makeLedger(try temporaryDirectory())

        ledger.charge(costUSD: 4, project: "/code/alpha")
        ledger.charge(costUSD: 6, project: "/code/alpha")
        ledger.charge(costUSD: 2.5, project: "/code/beta")

        XCTAssertEqual(ledger.spentTodayUSD(inProject: "/code/alpha"), 10, accuracy: 0.001)
        XCTAssertEqual(ledger.spentTodayUSD(inProject: "/code/beta"), 2.5, accuracy: 0.001)
        XCTAssertEqual(ledger.spentTodayUSD, 12.5, accuracy: 0.001,
                       "the portfolio total is the sum of what each project spent")
        XCTAssertEqual(ledger.today.byProject.values.reduce(0, +), ledger.spentTodayUSD,
                       accuracy: 0.001)
    }

    /// Spend nobody could attribute still counts against the portfolio: a
    /// ceiling that stopped bounding the moment attribution failed would be no
    /// ceiling at all.
    @MainActor
    func testUnattributedSpendStillCountsAgainstThePortfolio() throws {
        let ledger = makeLedger(try temporaryDirectory())

        ledger.charge(costUSD: 3, project: "/code/alpha")
        ledger.charge(costUSD: 7)

        XCTAssertEqual(ledger.spentTodayUSD, 10, accuracy: 0.001)
        XCTAssertEqual(ledger.spentTodayUSD(inProject: "/code/alpha"), 3, accuracy: 0.001,
                       "unattributed spend belongs to no project in particular")
    }

    /// A project that hasn't run today has spent nothing today — not "unknown",
    /// which a caller would have to decide how to read.
    @MainActor
    func testAProjectThatHasNotRunHasSpentNothing() throws {
        let ledger = makeLedger(try temporaryDirectory())
        ledger.charge(costUSD: 9, project: "/code/alpha")

        XCTAssertEqual(ledger.spentTodayUSD(inProject: "/code/beta"), 0, accuracy: 0.001)
        XCTAssertEqual(ledger.spentTodayUSD(inProject: ""), 0, accuracy: 0.001,
                       "an empty path is not a project with a budget")
    }

    /// The rule the portfolio total already followed, now per project: yesterday
    /// must not roll into today's ceiling. Same day-keyed record, so it can't.
    @MainActor
    func testAStoredTotalFromAnEarlierDayReadsAsZeroPerProject() throws {
        let dir = try temporaryDirectory()
        let url = dir.appendingPathComponent("spend.json")
        var day = Date(timeIntervalSince1970: 1_800_000_000)

        let yesterday = DailySpendLedger(storageURL: url, clock: { day })
        yesterday.charge(costUSD: 40, project: "/code/alpha")
        XCTAssertEqual(yesterday.spentTodayUSD(inProject: "/code/alpha"), 40, accuracy: 0.001)

        // Same file, read a day later.
        day = day.addingTimeInterval(24 * 60 * 60)
        let today = DailySpendLedger(storageURL: url, clock: { day })
        XCTAssertEqual(today.spentTodayUSD(inProject: "/code/alpha"), 0, accuracy: 0.001,
                       "yesterday's project total must not bound today")
        XCTAssertEqual(today.spentTodayUSD, 0, accuracy: 0.001)

        // And the first charge of the new day starts from zero for both.
        today.charge(costUSD: 5, project: "/code/alpha")
        XCTAssertEqual(today.spentTodayUSD(inProject: "/code/alpha"), 5, accuracy: 0.001)
        XCTAssertEqual(today.spentTodayUSD, 5, accuracy: 0.001)
    }

    /// A file written before per-project totals existed still has to load. If it
    /// didn't, the day would silently reset to zero mid-day on the upgrade and
    /// the ceiling would stop bounding anything until midnight.
    @MainActor
    func testADayFileWithoutPerProjectTotalsStillLoads() throws {
        let dir = try temporaryDirectory()
        let url = dir.appendingPathComponent("spend.json")
        let today = DailySpendLedger.dayKey(Date(), calendar: .current)
        try #"{"day":"\#(today)","spentUSD":37.5,"unknownRuns":2}"#
            .data(using: .utf8)!.write(to: url)

        let ledger = DailySpendLedger(storageURL: url)

        XCTAssertEqual(ledger.spentTodayUSD, 37.5, accuracy: 0.001,
                       "an older day file must keep bounding the day it was written for")
        XCTAssertEqual(ledger.today.unknownRuns, 2)
        XCTAssertEqual(ledger.spentTodayUSD(inProject: "/code/alpha"), 0, accuracy: 0.001,
                       "spend written before attribution existed belongs to no project")
    }

    /// The ledger's own convenience for building a project's half of the gate.
    @MainActor
    func testProjectBudgetJoinsTheProjectsOwnCeilingWithItsOwnSpend() throws {
        let ledger = makeLedger(try temporaryDirectory())
        ledger.charge(costUSD: 8, project: "/code/alpha")
        ledger.charge(costUSD: 30, project: "/code/beta")

        let alpha = ledger.budget(10, inProject: "/code/alpha", named: "alpha")
        XCTAssertEqual(alpha.spentUSD, 8, accuracy: 0.001,
                       "a project is measured against its own spend, not the portfolio's")
        XCTAssertFalse(alpha.isExhausted)
        XCTAssertEqual(alpha.scope, .project("alpha"))

        let beta = ledger.budget(10, inProject: "/code/beta", named: "beta")
        XCTAssertTrue(beta.isExhausted)
    }

    // MARK: - A day file the decoder refuses

    /// The files the ledger moved aside, beside the one it was reading.
    @MainActor
    private func quarantined(besides url: URL) throws -> [URL] {
        let prefix = "\(url.lastPathComponent).unreadable-"
        return try FileManager.default
            .contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
    }

    /// The defect: a `daily-spend.json` that will not decode read exactly like no
    /// file at all, so the day came up at zero mid-day and the ceiling stopped
    /// bounding anything until midnight. It has to say so, and the bytes that
    /// said otherwise have to survive.
    @MainActor
    func testAnUnreadableDayFileIsReportedAndItsBytesKept() throws {
        let dir = try temporaryDirectory()
        let url = dir.appendingPathComponent("spend.json")
        let original = Data(#"{"day":"2026-08-21","spentU"#.utf8)  // truncated mid-key
        try original.write(to: url)

        let ledger = DailySpendLedger(storageURL: url,
                                      reporter: StoreProblemReporter(notifications: nil))

        XCTAssertNotNil(ledger.loadProblem,
                        "a day that could not be read is not a day on which nothing was spent")
        let aside = try quarantined(besides: url)
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(aside.first)), original,
                       "the bytes have to survive for anyone to work out what the day cost")
    }

    /// The second half of the loss: the file was not only misread, it was written
    /// over by the very next charge.
    @MainActor
    func testAChargeAfterAnUnreadableLoadDoesNotDestroyThePreservedBytes() throws {
        let dir = try temporaryDirectory()
        let url = dir.appendingPathComponent("spend.json")
        let original = Data("not json at all".utf8)
        try original.write(to: url)

        let ledger = DailySpendLedger(storageURL: url,
                                      reporter: StoreProblemReporter(notifications: nil))
        ledger.charge(costUSD: 3)

        let aside = try quarantined(besides: url)
        XCTAssertEqual(aside.count, 1, "the charge must not have taken the preserved copy with it")
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(aside.first)), original)
        XCTAssertEqual(ledger.spentTodayUSD, 3, accuracy: 0.001,
                       "the ledger still records what this process spends")
    }

    /// A fresh day is not an error: every one of these files is created by its
    /// first save, so the ordinary first-launch state has to stay silent — and
    /// stay startable.
    @MainActor
    func testNoDayFileAtAllIsAFreshDayNotAProblem() throws {
        let dir = try temporaryDirectory()
        let ledger = DailySpendLedger(storageURL: dir.appendingPathComponent("spend.json"),
                                      reporter: StoreProblemReporter(notifications: nil))

        XCTAssertNil(ledger.loadProblem)
        XCTAssertEqual(ledger.spentTodayUSD, 0, accuracy: 0.001)
        XCTAssertEqual(ledger.budget(20).decision(for: .autonomous), .allow,
                       "a day nobody has spent anything on must still start runs")
    }

    /// Unknown is never free — the rule `resolveCharge` already follows, applied
    /// to the day as a whole. The ceiling cannot be enforced against a number
    /// nobody can vouch for, so autonomy waits; the person at the keyboard does not.
    func testSpendThatCouldNotBeReadRefusesAutonomousButNotHuman() {
        let budget = DailyBudget(budgetUSD: 20, spentUSD: 0, spendUnknown: true)
        XCTAssertFalse(budget.isExhausted, "unknown is not the same as spent")

        guard case .refuse(let refusal) = budget.decision(for: .autonomous) else {
            return XCTFail("an unreadable day must not lift the ceiling")
        }
        XCTAssertEqual(refusal.cause, .spendUnknown)
        XCTAssertTrue(refusal.logLine.contains("could not be read"), refusal.logLine)
        XCTAssertTrue(refusal.eventReason.contains("could not be read"), refusal.eventReason)
        XCTAssertFalse(refusal.logLine.contains("spent ($"),
                       "an unread day must not be reported as an exhausted one: \(refusal.logLine)")

        XCTAssertEqual(budget.decision(for: .human), .allow,
                       "the ceiling governs autonomy, not the person at the keyboard")
    }

    /// Nobody who never set a ceiling should be stopped by one going unread.
    func testSpendThatCouldNotBeReadStillAllowsAnUncappedStart() {
        XCTAssertEqual(DailyBudget(budgetUSD: nil, spentUSD: 0, spendUnknown: true)
            .decision(for: .autonomous), .allow)
        XCTAssertEqual(DailyBudget(budgetUSD: 0, spentUSD: 0, spendUnknown: true)
            .decision(for: .autonomous), .allow,
                       "a non-positive budget is no budget, here as everywhere else")
    }

    /// End to end through the ledger, and through both ceilings: the file the
    /// decoder refused holds the portfolio total and every project's share, so
    /// neither of them can be vouched for.
    @MainActor
    func testAnUnreadableDayFileRefusesThroughBothCeilings() throws {
        let dir = try temporaryDirectory()
        let url = dir.appendingPathComponent("spend.json")
        try Data("not json at all".utf8).write(to: url)

        let ledger = DailySpendLedger(storageURL: url,
                                      reporter: StoreProblemReporter(notifications: nil))
        let gate = ProjectDailyBudget(
            project: ledger.budget(50, inProject: "/code/alpha", named: "alpha"),
            portfolio: ledger.budget(200))

        guard case .refuse(let refusal) = gate.decision(for: .autonomous) else {
            return XCTFail("an unreadable day must not lift either ceiling")
        }
        XCTAssertEqual(refusal.cause, .spendUnknown)
        XCTAssertEqual(refusal.scope, .project("alpha"),
                       "the narrower ceiling is still the one named first")
        XCTAssertEqual(gate.decision(for: .human), .allow)
    }

    // MARK: - A charge that never reaches disk

    /// A regular file where the ledger's directory should be: `AtomicFileWriter`
    /// cannot create the directory, so every save from here on fails with no
    /// permissions games.
    @MainActor
    private func blockedDirectory(in dir: URL) throws -> URL {
        let blocker = dir.appending(path: "blocked")
        try Data("not a directory".utf8).write(to: blocker)
        return blocker
    }

    @MainActor
    func testAChargeWhoseWriteFailsLeavesTheSaveProblemNonNil() throws {
        let dir = try temporaryDirectory()
        let storageURL = try blockedDirectory(in: dir).appending(path: "spend.json")
        let ledger = DailySpendLedger(storageURL: storageURL,
                                      reporter: StoreProblemReporter(notifications: nil))
        XCTAssertNil(ledger.saveProblem, "a fresh ledger has not tried to save yet")

        ledger.charge(costUSD: 3)

        XCTAssertNotNil(ledger.saveProblem,
                        "a charge that never reached disk must not be silent")
    }

    /// A day of failing autosaves is one inbox row, not one per charge — the same
    /// dedup the read side already gets from `StoreProblemReporter`.
    @MainActor
    func testAFailingSaveIsReportedOnceThroughTheReporterAcrossRepeatedCharges() async throws {
        let dir = try temporaryDirectory()
        let storageURL = try blockedDirectory(in: dir).appending(path: "spend.json")
        let inbox = NotificationStore(notificationsURL: dir.appending(path: "inbox.log"))
        let reporter = StoreProblemReporter(notifications: inbox)
        let ledger = DailySpendLedger(storageURL: storageURL, reporter: reporter)

        ledger.charge(costUSD: 3)
        ledger.charge(costUSD: 4)
        ledger.charge(costUSD: 5)
        await reporter.drain()

        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 1,
                       "repeated failing charges must refresh one row, not file many")
        XCTAssertEqual(pending.first?.title, "Could not write Daily spend")
        XCTAssertEqual(pending.first?.body.contains(storageURL.path(percentEncoded: false)), true)
    }

    /// While the write is failing, neither ceiling can be enforced against a
    /// number nobody could save — the write-side twin of the unreadable-file case.
    @MainActor
    func testWhileTheSaveProblemStandsBothBudgetReadersReportSpendUnknown() throws {
        let dir = try temporaryDirectory()
        let storageURL = try blockedDirectory(in: dir).appending(path: "spend.json")
        let ledger = DailySpendLedger(storageURL: storageURL,
                                      reporter: StoreProblemReporter(notifications: nil))

        ledger.charge(costUSD: 3, project: "/code/alpha")

        let portfolio = ledger.budget(20)
        let project = ledger.budget(20, inProject: "/code/alpha", named: "alpha")
        XCTAssertTrue(portfolio.spendUnknown)
        XCTAssertTrue(project.spendUnknown)

        guard case .refuse(let refusal) = portfolio.decision(for: .autonomous) else {
            return XCTFail("a save failure must not lift the ceiling")
        }
        XCTAssertEqual(refusal.cause, .spendUnknown)
        XCTAssertEqual(portfolio.decision(for: .human), .allow,
                       "the ceiling governs autonomy, not the person at the keyboard")
    }

    /// A save that later succeeds clears the problem — the ceiling starts
    /// bounding again rather than staying tripped forever.
    @MainActor
    func testASubsequentSuccessfulSaveClearsTheProblem() throws {
        let dir = try temporaryDirectory()
        let blocker = try blockedDirectory(in: dir)
        let storageURL = blocker.appending(path: "spend.json")
        let ledger = DailySpendLedger(storageURL: storageURL,
                                      reporter: StoreProblemReporter(notifications: nil))
        ledger.charge(costUSD: 3)
        XCTAssertNotNil(ledger.saveProblem)

        try FileManager.default.removeItem(at: blocker)
        ledger.charge(costUSD: 4)

        XCTAssertNil(ledger.saveProblem)
        XCTAssertFalse(ledger.budget(20).spendUnknown,
                       "a save that now succeeds must let the ceiling bound again")
    }

    // MARK: - Day boundaries

    func testDayKeyRollsOverOnLocalMidnightNotUTC() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Pacific/Honolulu")!
        // 2026-08-06 23:30 local is already 2026-08-07 in UTC.
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 6
        components.hour = 23; components.minute = 30
        let lateLocalEvening = calendar.date(from: components)!

        XCTAssertEqual(DailySpendLedger.dayKey(lateLocalEvening, calendar: calendar), "2026-08-06",
                       "spend should roll over at local midnight, not UTC")
    }
}
