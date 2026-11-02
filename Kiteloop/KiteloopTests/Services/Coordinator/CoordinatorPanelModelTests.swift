import XCTest
import KiteloopCore
@testable import Kiteloop

/// The portfolio screen's Coordinator section, as a value.
///
/// The panel is a container, so what is worth asserting is the container's three
/// promises rather than its pixels: an absent input degrades to one line instead
/// of blocking the panel, every list is bounded and says what the bound cost, and
/// reading the loop cannot make it do anything.
final class CoordinatorPanelModelTests: XCTestCase {

    // MARK: - Fixtures

    private func loop(enabled: Bool = true,
                      isPassing: Bool = false,
                      threshold: Int = 2,
                      budget: QueueRefill.Budget = QueueRefill.Budget(),
                      passes: [CoordinatorPanelModel.Pass] = [])
        -> CoordinatorPanelModel.LoopSnapshot {
        CoordinatorPanelModel.LoopSnapshot(enabled: enabled, isPassing: isPassing,
                                           threshold: threshold, budget: budget,
                                           passes: passes)
    }

    private func pass(_ id: String) -> CoordinatorPanelModel.Pass {
        CoordinatorPanelModel.Pass(id: id, kind: .filed, project: "alpha", summary: "filed \(id)")
    }

    private func input(_ name: String,
                       ready: Int,
                       paused: Bool = false,
                       goal: String? = nil,
                       hasBacklog: Bool = true,
                       queue: QueueHealth = .empty) -> CoordinatorPanelModel.ProjectInput {
        CoordinatorPanelModel.ProjectInput(id: "/tmp/\(name)", name: name, paused: paused,
                                           goal: goal, readyCount: ready, hasBacklog: hasBacklog,
                                           queue: queue)
    }

    private func readyItem(_ id: String) -> BacklogItem {
        BacklogItem(id: id, title: "Item \(id)", verify: "swift build", status: .ready,
                    type: .local, size: .m, detailPath: "backlog/\(id).md")
    }

    private func groomedDetail(_ id: String) -> BacklogItemDetail {
        BacklogItemDetail(id: id, title: "Item \(id)",
                          verifyCommands: [.init(name: "build", cmd: "swift build", expect: nil)],
                          acceptanceCriteria: ["It works"], outOfScope: [],
                          what: "The outcome.", approach: "Touch these files.")
    }

    /// `n` ready items, none of them groomed — a queue nothing can pick up.
    private func stalled(_ n: Int) -> QueueHealth {
        QueueHealth.make(items: (1...n).map { readyItem("i-\($0)") }, detail: { _ in nil })
    }

    /// `n` ready items, every one of them runnable.
    private func clear(_ n: Int) -> QueueHealth {
        QueueHealth.make(items: (1...n).map { readyItem("i-\($0)") },
                         detail: { self.groomedDetail($0.id) })
    }

    private func report() -> PortfolioReport {
        PortfolioReport.make(runs: [], grooming: [],
                             period: .last(hours: 24, endingAt: Date()))
    }

    // MARK: - Degradation

    func testAnUnwiredLoopLeavesTheRestOfThePanelIntact() {
        let model = CoordinatorPanelModel.make(loop: nil,
                                               projects: [input("alpha", ready: 0)],
                                               report: .ready(report()))

        // The loop's four sections say why they're absent...
        for reason in [model.state.unavailableReason,
                       model.passes.unavailableReason, model.budget.unavailableReason] {
            XCTAssertEqual(reason, "The refill loop isn't wired into this window.")
        }
        // ...and the two that don't depend on it still render.
        XCTAssertEqual(model.projects.content?.items.count, 1)
        XCTAssertNotNil(model.report.content)
    }

    func testProjectsStillExplainThemselvesWithoutALoopToSupplyTheThreshold() throws {
        let model = CoordinatorPanelModel.make(loop: nil,
                                               projects: [input("alpha", ready: 0)],
                                               report: .unavailable)
        let row = try XCTUnwrap(model.projects.content?.items.first)
        XCTAssertEqual(row.threshold, QueueRefill.Policy.default.sanitized.threshold)
        XCTAssertEqual(row.standing, .queueLow)
    }

    func testAnEmptyPortfolioIsAnEmptySectionRatherThanAnAbsentOne() {
        let model = CoordinatorPanelModel.make(loop: loop(), projects: [], report: .unavailable)
        XCTAssertEqual(model.projects.content?.items, [])
        XCTAssertNil(model.projects.unavailableReason)
    }

    func testAnUnreadPortfolioIsAbsentRatherThanEmpty() {
        let model = CoordinatorPanelModel.make(loop: loop(), projects: nil, report: .unavailable)
        XCTAssertEqual(model.projects.unavailableReason, "The portfolio hasn't been read here.")
    }

    func testTheReportDistinguishesStillReadingFromNothingToRead() {
        let reading = CoordinatorPanelModel.make(loop: loop(), projects: [], report: .reading)
        XCTAssertEqual(reading.report, .loading)

        let absent = CoordinatorPanelModel.make(loop: loop(), projects: [], report: .unavailable)
        XCTAssertEqual(absent.report.unavailableReason,
                       "No run or grooming ledger is wired into this window.")

        let ready = CoordinatorPanelModel.make(loop: loop(), projects: [], report: .ready(report()))
        XCTAssertNotNil(ready.report.content)
    }

    // MARK: - State

    func testAnOffLoopSaysSoPlainlyRatherThanRenderingAsEmpty() {
        let model = CoordinatorPanelModel.make(loop: loop(enabled: false),
                                               projects: [], report: .unavailable)
        let state = model.state.content
        XCTAssertEqual(state?.headline, "Off")
        XCTAssertEqual(state?.detail.isEmpty, false)
        XCTAssertEqual(state?.detail.contains("isn't grooming"), true)
    }

    func testAnOnLoopHeadlinesOnAndSaysWhatAPassDoes() {
        let model = CoordinatorPanelModel.make(loop: loop(), projects: [], report: .unavailable)
        XCTAssertEqual(model.state.content?.headline, "On")
        XCTAssertEqual(model.state.content?.detail.contains("filed into the backlog"), true)
    }

    func testAPassInFlightIsSaidRatherThanImplied() {
        let model = CoordinatorPanelModel.make(loop: loop(isPassing: true),
                                               projects: [], report: .unavailable)
        XCTAssertEqual(model.state.content?.detail, "A pass is running now.")
    }

    // MARK: - Bounds

    func testPassesAreBounded() {
        let all = (1...CoordinatorPanelModel.passLimit + 2).map { pass("x\($0)") }
        let model = CoordinatorPanelModel.make(loop: loop(passes: all),
                                               projects: [], report: .unavailable)
        XCTAssertEqual(model.passes.content?.items.count, CoordinatorPanelModel.passLimit)
        XCTAssertEqual(model.passes.content?.omitted, 2)
    }

    func testProjectsAreBounded() {
        let all = (1...CoordinatorPanelModel.projectLimit + 1).map { input("p\($0)", ready: 9) }
        let model = CoordinatorPanelModel.make(loop: loop(), projects: all, report: .unavailable)
        XCTAssertEqual(model.projects.content?.items.count, CoordinatorPanelModel.projectLimit)
        XCTAssertEqual(model.projects.content?.omittedLabel, "+1 more")
    }

    func testAListWithinItsBoundSaysNothingWasDropped() {
        let model = CoordinatorPanelModel.make(loop: loop(passes: [pass("p1")]),
                                               projects: [], report: .unavailable)
        XCTAssertEqual(model.passes.content?.omitted, 0)
        XCTAssertNil(model.passes.content?.omittedLabel)
    }

    // MARK: - Ranking

    func testHungryProjectsSortAboveHealthyOnesAndPausedSortsLast() {
        let rows = CoordinatorPanelModel.rank([
            input("paused", ready: 0, paused: true),
            input("healthy", ready: 5),
            input("hungry", ready: 0)
        ], threshold: 2)
        XCTAssertEqual(rows.map(\.name), ["hungry", "healthy", "paused"])
    }

    /// Depth is the whole order among hungry projects now: the emptier queue
    /// leads, and nothing above it can promote the fuller one.
    func testTheEmptierQueueDecidesBetweenTwoHungryProjects() {
        let rows = CoordinatorPanelModel.rank([
            input("fuller", ready: 1),
            input("emptier", ready: 0)
        ], threshold: 2)
        XCTAssertEqual(rows.first?.name, "emptier")
        XCTAssertEqual(rows.first?.isNext, true)
    }

    func testTheEmptierQueueLeadsAndTheNameBreaksTheRest() {
        let byDepth = CoordinatorPanelModel.rank([
            input("fuller", ready: 1),
            input("emptier", ready: 0)
        ], threshold: 2)
        XCTAssertEqual(byDepth.map(\.name), ["emptier", "fuller"])

        let byName = CoordinatorPanelModel.rank([
            input("beta", ready: 0),
            input("alpha", ready: 0)
        ], threshold: 2)
        XCTAssertEqual(byName.map(\.name), ["alpha", "beta"])
    }

    func testExactlyOneProjectIsMarkedNext() {
        let rows = CoordinatorPanelModel.rank([
            input("a", ready: 0), input("b", ready: 0), input("c", ready: 0)
        ], threshold: 2)
        XCTAssertEqual(rows.count { $0.isNext }, 1)
        XCTAssertEqual(rows.first?.isNext, true)
    }

    func testNothingIsNextWhenEveryQueueIsHealthy() {
        let rows = CoordinatorPanelModel.rank([input("a", ready: 5), input("b", ready: 9)],
                                              threshold: 2)
        XCTAssertTrue(rows.allSatisfy { !$0.isNext })
        XCTAssertTrue(rows.allSatisfy { $0.standing == .queueHealthy })
    }

    /// A paused project with an empty queue is the emptiest queue in the
    /// portfolio, so it would lead the list on depth alone. It is never chosen.
    func testAPausedProjectWithAnEmptyQueueIsNeverNext() {
        let rows = CoordinatorPanelModel.rank([
            input("paused", ready: 0, paused: true),
            input("hungry", ready: 1)
        ], threshold: 2)
        XCTAssertEqual(rows.first(where: { $0.isNext })?.name, "hungry")
        XCTAssertEqual(rows.first(where: { $0.name == "paused" })?.standing, .paused)
    }

    /// Likewise a project with no `BACKLOG.md` reads as zero ready items, which
    /// would otherwise make it the hungriest thing on the screen.
    func testAProjectWithoutABacklogIsNotTreatedAsAnEmptyQueue() {
        let rows = CoordinatorPanelModel.rank([
            input("nobacklog", ready: 0, hasBacklog: false),
            input("hungry", ready: 1)
        ], threshold: 2)
        XCTAssertEqual(rows.first(where: { $0.isNext })?.name, "hungry")
        XCTAssertEqual(rows.first(where: { $0.name == "nobacklog" })?.standing, .noBacklog)
    }

    func testEachRowExplainsItsStandingAgainstTheThresholdItWasJudgedBy() {
        let rows = CoordinatorPanelModel.rank([input("a", ready: 1)], threshold: 3)
        XCTAssertEqual(rows.first?.reason, "1 ready — below the threshold of 3.")
    }

    // MARK: - Ranking: a deep queue that cannot run

    /// The defect this row used to embody. Judged on depth alone a queue of 20
    /// items nothing could pick up was the healthiest project on the screen; the
    /// standing now says otherwise, and the reason says why.
    func testADeepQueueThatCannotStartReadsAsStalledRatherThanHealthy() {
        let rows = CoordinatorPanelModel.rank([input("kiteloop", ready: 20, queue: stalled(20))],
                                              threshold: 3)

        XCTAssertEqual(rows.first?.standing, .queueStalled)
        XCTAssertEqual(rows.first?.reason, "20 ready, none can start — 20 not groomed.")
        XCTAssertFalse(rows.first?.isNext ?? true, "the loop tops up on depth, and this is deep")
    }

    /// Stalled outranks healthy: it is the one that needs a human — too deep for
    /// the loop to groom for, too held for anything to run.
    func testAStalledQueueSortsAboveAHealthyOneAndBelowAHungryOne() {
        let rows = CoordinatorPanelModel.rank([
            input("healthy", ready: 5, queue: clear(5)),
            input("stalled", ready: 20, queue: stalled(20)),
            input("hungry", ready: 0)
        ], threshold: 3)

        XCTAssertEqual(rows.map(\.name), ["hungry", "stalled", "healthy"])
        XCTAssertEqual(rows.first(where: { $0.isNext })?.name, "hungry")
    }

    /// Depth is read before runnability on purpose: the loop tops up on depth, so
    /// a shallow queue is still what it would groom for next whether or not the
    /// items in it can run. The row says both rather than misreporting the loop.
    func testAShallowQueueThatCannotStartIsStillTheOneTheLoopWouldGroomFor() {
        let rows = CoordinatorPanelModel.rank([input("a", ready: 1, queue: stalled(1))],
                                              threshold: 3)

        XCTAssertEqual(rows.first?.standing, .queueLow)
        XCTAssertEqual(rows.first?.isNext, true)
        XCTAssertEqual(rows.first?.reason,
                       "1 ready — below the threshold of 3. 1 of them can't start — 1 not groomed.")
    }

    /// A queue that is deep, healthy by the threshold, and only partly held still
    /// says what is going nowhere — the count is right and incomplete on its own.
    func testAHealthyQueueWithSomeItemsHeldSaysHowManyAreGoingNowhere() {
        let queue = QueueHealth.make(items: (1...5).map { readyItem("i-\($0)") },
                                     detail: { $0.id == "i-1" ? groomedDetail($0.id) : nil })
        let rows = CoordinatorPanelModel.rank([input("a", ready: 5, queue: queue)], threshold: 3)

        XCTAssertEqual(rows.first?.standing, .queueHealthy)
        XCTAssertEqual(rows.first?.reason,
                       "5 ready — at or above the threshold of 3. 4 of them can't start — 4 not groomed.")
    }

    /// A caller that hasn't read the queue gets the row it always got. Reporting
    /// a project as stalled on no evidence would be the same defect pointed the
    /// other way.
    func testAnUnreadQueueLeavesTheRowExactlyAsItWas() {
        let rows = CoordinatorPanelModel.rank([input("a", ready: 20)], threshold: 3)

        XCTAssertEqual(rows.first?.standing, .queueHealthy)
        XCTAssertEqual(rows.first?.reason, "20 ready — at or above the threshold of 3.")
    }

    // MARK: - Budget

    func testAnUncappedBudgetHasNoBarToDraw() {
        let model = CoordinatorPanelModel.make(
            loop: loop(budget: QueueRefill.Budget(spentUSD: 1.2)),
            projects: [], report: .unavailable)
        let budget = model.budget.content
        XCTAssertNil(budget?.spendFraction)
        XCTAssertNil(budget?.passFraction)
        XCTAssertEqual(budget?.spendText, "$1.20 · no cap set")
        XCTAssertEqual(budget?.passText, "0 passes · no cap set")
        XCTAssertEqual(budget?.isExhausted, false)
    }

    func testACappedBudgetReportsItsFractionAndItsCeiling() {
        let model = CoordinatorPanelModel.make(
            loop: loop(budget: QueueRefill.Budget(spentUSD: 2.5, capUSD: 10, passes: 3, maxPasses: 12)),
            projects: [], report: .unavailable)
        let budget = model.budget.content
        XCTAssertEqual(budget?.spendFraction ?? 0, 0.25, accuracy: 0.0001)
        XCTAssertEqual(budget?.passFraction ?? 0, 0.25, accuracy: 0.0001)
        XCTAssertEqual(budget?.spendText, "$2.50 of $10.00")
        XCTAssertEqual(budget?.passText, "3 of 12 passes")
    }

    func testAnOverspentBudgetClampsItsBarAndCarriesTheRefusalWording() {
        let model = CoordinatorPanelModel.make(
            loop: loop(budget: QueueRefill.Budget(spentUSD: 30, capUSD: 10)),
            projects: [], report: .unavailable)
        let budget = model.budget.content
        XCTAssertEqual(budget?.spendFraction, 1)
        XCTAssertEqual(budget?.isExhausted, true)
        XCTAssertEqual(budget?.exhaustionReason,
                       QueueRefill.Budget(spentUSD: 30, capUSD: 10).exhaustionReason)
    }

    // MARK: - Passes

    func testEachOutcomeMapsToARowThatSaysWhatHappened() {
        let cases: [(CoordinatorQueueRefill.PassOutcome, CoordinatorPanelModel.Pass.Kind)] = [
            (.filed(project: "alpha", ready: 2, drafts: 1, refused: 0), .filed),
            (.noDrafts(project: "alpha"), .nothing),
            (.held(.queuesHealthy), .held),
            (.disabled, .held)
        ]
        for (outcome, expected) in cases {
            let row = CoordinatorPanelModel.Pass(outcome, index: 0)
            XCTAssertEqual(row.kind, expected)
            XCTAssertEqual(row.summary, outcome.summary)
        }
    }

    func testAHeldPassCarriesItsReasonSoNothingHappeningHasAnAnswer() {
        let row = CoordinatorPanelModel.Pass(.held(.budgetExhausted("daily grooming budget spent")),
                                             index: 0)
        XCTAssertEqual(row.kind, .held)
        XCTAssertTrue(row.summary.contains("daily grooming budget spent"))
    }

    func testTwoIdenticalOutcomesAreTwoRows() {
        let first = CoordinatorPanelModel.Pass(.held(.queuesHealthy), index: 0)
        let second = CoordinatorPanelModel.Pass(.held(.queuesHealthy), index: 1)
        XCTAssertNotEqual(first.id, second.id)
    }

    // MARK: - Reading the loop cannot drive it

    /// The panel's structural guarantee: it reads the live loop through a value
    /// capture, and an unwired loop reports as absent rather than as "off" — two
    /// very different claims about why nothing is being groomed.
    @MainActor
    func testCapturingAnUnwiredLoopYieldsNothingAndStartsNothing() {
        let refill = CoordinatorQueueRefill(
            ledgerURL: FileManager.default.temporaryDirectory
                .appending(path: "coordinator-panel-\(UUID().uuidString).jsonl"))
        refill.enabled = true

        XCTAssertFalse(refill.isConfigured)
        XCTAssertNil(CoordinatorPanelModel.LoopSnapshot.capture(refill))
        // Reading it left the loop exactly as it was — no pass taken.
        XCTAssertNil(refill.lastOutcome)
        XCTAssertEqual(refill.budget.passes, 0)
    }

    // MARK: - Controls

    private func controls(refillWired: Bool = true,
                          schedulerWired: Bool = true,
                          storeWired: Bool = true,
                          runningBudgetUSD: Double? = 20,
                          schedulingEnabled: Bool = false)
        -> CoordinatorPanelModel.Controls {
        CoordinatorPanelModel.Controls(refillWired: refillWired,
                                       schedulerWired: schedulerWired,
                                       storeWired: storeWired,
                                       runningBudgetUSD: runningBudgetUSD,
                                       schedulingEnabled: schedulingEnabled)
    }

    /// Unconfigured is not off: the loop can't run whatever its switch says, so
    /// the switch refuses input and states the reason rather than accepting a
    /// choice that does nothing.
    func testAnUnwiredLoopDisablesItsControlsAndSaysWhy() {
        let controls = controls(refillWired: false)
        XCTAssertFalse(controls.canGroom)
        XCTAssertNotNil(controls.groomingDisabledReason)
    }

    func testAWiredLoopHasOperableGroomingControlsAndNothingToExplain() {
        let controls = controls()
        XCTAssertTrue(controls.canGroom)
        XCTAssertNil(controls.groomingDisabledReason)
    }

    /// The bound this item exists for: unattended *running* is expensive, and a
    /// nil ceiling is no ceiling at all — so the switch that starts runs can't be
    /// turned on before the number that stops them is set.
    func testSchedulingCannotBeSwitchedOnWithoutARunningBudget() {
        let controls = controls(runningBudgetUSD: nil)
        XCTAssertFalse(controls.canEnableScheduling)
        XCTAssertFalse(controls.isSchedulingSwitchOperable)
        XCTAssertEqual(controls.schedulingDisabledReason,
                       AutonomyArming.armScheduling(dailyBudgetUSD: nil)?.message)
    }

    func testARunningBudgetIsAllSchedulingNeedsToBeSwitchable() {
        let controls = controls(runningBudgetUSD: 20)
        XCTAssertTrue(controls.canEnableScheduling)
        XCTAssertTrue(controls.isSchedulingSwitchOperable)
        XCTAssertNil(controls.schedulingDisabledReason)
    }

    /// A kill switch you can be locked out of isn't one: the ceiling rule guards
    /// the way in and never the way out.
    func testSchedulingAlreadyOnCanAlwaysBeSwitchedOff() {
        let controls = controls(runningBudgetUSD: nil, schedulingEnabled: true)
        XCTAssertFalse(controls.canEnableScheduling)
        XCTAssertTrue(controls.isSchedulingSwitchOperable)
        XCTAssertNil(controls.schedulingDisabledReason)
    }

    /// "No scheduler here" and "no ceiling set" are different reasons for the
    /// same disabled switch, and only one of them is fixed by typing a number.
    func testAnUnwiredSchedulerSaysThatRatherThanAskingForABudget() {
        let controls = controls(schedulerWired: false, runningBudgetUSD: 20)
        XCTAssertFalse(controls.canEnableScheduling)
        XCTAssertEqual(controls.schedulingDisabledReason,
                       "Autonomous scheduling isn't wired into this window.")
    }

    /// The running ceiling is the scheduler's bound, not the grooming loop's, so
    /// it stays settable with the grooming loop unwired.
    func testTheRunningBudgetIsSettableWithoutTheGroomingLoop() {
        let controls = controls(refillWired: false, runningBudgetUSD: nil)
        XCTAssertTrue(controls.canSetRunningBudget)
        XCTAssertNil(controls.runningBudgetDisabledReason)
        XCTAssertFalse(controls.canGroom)
    }

    func testWithoutTheStoreTheRunningBudgetSaysSoRatherThanLookingUncapped() {
        let controls = controls(storeWired: false, runningBudgetUSD: nil)
        XCTAssertFalse(controls.canSetRunningBudget)
        XCTAssertNotNil(controls.runningBudgetDisabledReason)
    }

    /// A panel built without controls draws them inert rather than omitting them
    /// — the same degradation the sections above it get.
    func testAPanelBuiltWithoutControlsHasEveryControlInert() {
        let model = CoordinatorPanelModel.make(loop: loop(), projects: [], report: .unavailable)
        XCTAssertEqual(model.controls, .unwired)
        XCTAssertFalse(model.controls.canGroom)
        XCTAssertFalse(model.controls.isSchedulingSwitchOperable)
        XCTAssertNotNil(model.controls.groomingDisabledReason)
        XCTAssertNotNil(model.controls.schedulingDisabledReason)
    }

    /// Capturing what the controls may do reads the live objects and leaves them
    /// alone — no pass, no timer, no start.
    @MainActor
    func testCapturingTheControlsChangesNothing() {
        let refill = CoordinatorQueueRefill(
            ledgerURL: FileManager.default.temporaryDirectory
                .appending(path: "coordinator-controls-\(UUID().uuidString).jsonl"))
        let scheduler = CoordinatorRunScheduler(
            logURL: FileManager.default.temporaryDirectory
                .appending(path: "coordinator-starts-\(UUID().uuidString).jsonl"))

        let captured = CoordinatorPanelModel.Controls.capture(refill: refill,
                                                              scheduler: scheduler,
                                                              store: nil)

        XCTAssertEqual(captured, .unwired)
        XCTAssertNil(refill.lastOutcome)
        XCTAssertFalse(refill.isTimerRunning)
        XCTAssertNil(scheduler.lastDecision)
        XCTAssertFalse(scheduler.isTimerRunning)
    }
}
