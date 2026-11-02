import XCTest
import KiteloopCore
@testable import Kiteloop

/// The autonomous start decision. This is the moment the Coordinator begins
/// spending money unattended, so every bound it is supposed to respect is
/// exercised here as arithmetic — no app, no registry, no autopilot, no clock.
final class RunSchedulingTests: XCTestCase {

    // MARK: - Fixtures

    /// A project with `ready` items named, since a start needs an item to name
    /// and not merely a count.
    private func project(_ name: String,
                         ready: Int,
                         paused: Bool = false,
                         autopilotReady: Bool = true,
                         optedIn: Bool = true,
                         running: Bool = false,
                         awaitingApproval: Int = 0,
                         approveReviewPassedRuns: Bool = false) -> PortfolioSnapshot.Project {
        let items = (0..<max(0, ready)).map {
            PortfolioSnapshot.Item(id: "\(name)-\($0)", title: "Item \($0)", size: "S", lastRun: nil)
        }
        var statusCounts: [BacklogItemStatus: Int] = [:]
        if ready > 0 { statusCounts[.ready] = ready }
        if awaitingApproval > 0 { statusCounts[.awaitingApproval] = awaitingApproval }
        return PortfolioSnapshot.Project(
            name: name,
            path: "/tmp/\(name)",
            autopilotReady: autopilotReady,
            autonomousWorkEnabled: optedIn,
            approveReviewPassedRuns: approveReviewPassedRuns,
            statusCounts: statusCounts,
            readyItems: PortfolioSnapshot.ItemSample(items: items, omitted: 0),
            run: running ? PortfolioSnapshot.RunState(phase: .running, itemID: "x", itemTitle: "x",
                                                      position: 1, total: 1, attempt: nil) : nil,
            recentOutcomes: [],
            paused: paused,
            goal: nil
        )
    }

    private func portfolio(_ projects: [PortfolioSnapshot.Project]) -> PortfolioSnapshot {
        PortfolioSnapshot(projects: projects)
    }

    // MARK: - Starts still in flight

    /// A project whose run this scheduler is still awaiting is taken, even
    /// before its snapshot says so — the next look starts the other project.
    func testAProjectWhoseStartIsInFlightIsNotHandedASecondRun() {
        let alpha = project("alpha", ready: 2)
        let beta = project("beta", ready: 1)
        let decision = RunScheduling.decide(
            portfolio: portfolio([alpha, beta]), enabled: true, budget: DailyBudget(),
            startingPaths: ["/tmp/alpha"])
        XCTAssertEqual(decision.target?.project, "beta")

        let alone = RunScheduling.decide(
            portfolio: portfolio([alpha]), enabled: true, budget: DailyBudget(),
            startingPaths: ["/tmp/alpha"])
        XCTAssertEqual(alone.hold, .allBusy)
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// The everyday case: switched on, budget left, nothing held.
    private func decide(_ projects: [PortfolioSnapshot.Project],
                        enabled: Bool = true,
                        budget: DailyBudget = DailyBudget(budgetUSD: 20, spentUSD: 1),
                        holds: RunScheduling.Holds = RunScheduling.Holds(),
                        refusedItems: Set<String> = [],
                        idleSince: [String: Date] = [:],
                        projectBudgets: [String: DailyBudget] = [:],
                        queueRefillPolicy: QueueRefill.Policy = .default) -> RunScheduling.Decision {
        RunScheduling.decide(portfolio: portfolio(projects), enabled: enabled,
                             budget: budget, holds: holds, refusedItems: refusedItems,
                             idleSince: idleSince,
                             projectBudgets: projectBudgets,
                             queueRefillPolicy: queueRefillPolicy, now: now)
    }

    // MARK: - Hold fixtures

    /// A queue with one runnable item in it, so two evidences can be made to
    /// differ (or not) on purpose.
    private func evidence(_ rows: [String: RunScheduling.QueueEvidence.Row] =
                            ["one": .init(spec: "aaaa", runnable: true)])
        -> RunScheduling.QueueEvidence {
        RunScheduling.QueueEvidence(rows: rows)
    }

    private func failure(item: String, text: String = "blocked: verify failed",
                         evidence: RunScheduling.QueueEvidence? = nil,
                         environment: String = "env-1")
        -> RunScheduling.ProjectHold.Failure {
        RunScheduling.ProjectHold.Failure(itemID: item, text: text,
                                          evidence: evidence ?? self.evidence(),
                                          environment: environment)
    }

    /// `RetryCeiling.limit` failures on one item in one project — an ordinary
    /// hold, formed the way the loop forms one.
    private func heldProject(_ name: String, item: String = "one",
                             text: String = "blocked: verify failed",
                             evidence: RunScheduling.QueueEvidence? = nil)
        -> RunScheduling.Holds {
        var holds = RunScheduling.Holds()
        for _ in 0..<RetryCeiling.limit {
            holds.record(failure(item: item, text: text, evidence: evidence),
                         project: name, path: "/tmp/\(name)")
        }
        return holds
    }

    /// A project's own exhausted ceiling, keyed the way `decide` looks it up.
    private func spentBudget(_ name: String, budgetUSD: Double = 5) -> [String: DailyBudget] {
        ["/tmp/\(name)": DailyBudget(budgetUSD: budgetUSD, spentUSD: budgetUSD + 1,
                                     scope: .project(name))]
    }

    // MARK: - The start

    func testStartsAProjectWithReadyWorkAndNothingInFlight() {
        let decision = decide([project("alpha", ready: 2)])

        let target = decision.target
        XCTAssertEqual(target?.project, "alpha")
        XCTAssertEqual(target?.itemID, "alpha-0", "the next ready item is what runs")
        XCTAssertEqual(target?.readyCount, 2)
        XCTAssertFalse(target?.reason.isEmpty ?? true, "a start has to say why it chose this project")
    }

    // MARK: - The bounds that already existed

    func testPausedProjectIsNeverStartedEvenWhenItIsTheOnlyOneWithWork() {
        let decision = decide([project("paused", ready: 5, paused: true)])

        XCTAssertNil(decision.target)
        XCTAssertEqual(decision.hold, .noEligibleProject)
    }

    func testPausedProjectIsSkippedInFavourOfAnEligibleOne() {
        let decision = decide([
            project("paused", ready: 9, paused: true, running: false),
            project("beta", ready: 1)
        ])

        XCTAssertEqual(decision.target?.project, "beta")
    }

    /// The ceiling governs autonomy, not the person: the same budget that
    /// refuses this start still lets a human start one.
    func testExhaustedDailyBudgetRefusesTheAutonomousStartButNotAHumanOne() {
        let spent = DailyBudget(budgetUSD: 20, spentUSD: 20)

        let decision = decide([project("alpha", ready: 3)], budget: spent)

        XCTAssertNil(decision.target)
        XCTAssertEqual(decision.hold?.kind, "budgetExhausted")
        XCTAssertTrue(decision.hold?.reason.contains("20.00") ?? false,
                      "the refusal carries the budget's own numbers")
        XCTAssertEqual(spent.decision(for: .human), .allow)
    }

    /// The reason this loop has to know about project ceilings at all: without
    /// it, the scheduler would keep picking the exhausted project and get
    /// refused downstream by `BacklogAutopilot.start`, spending the night
    /// rediscovering a ceiling it could have read here.
    func testAProjectOverItsOwnBudgetIsPassedOverForOneWithRoom() {
        let decision = decide([project("alpha", ready: 9),
                               project("beta", ready: 1)],
                              projectBudgets: spentBudget("alpha"))

        XCTAssertEqual(decision.target?.project, "beta",
                       "alpha has spent its allowance; beta still has one")
    }

    /// Every idle project spent means a hold that names the ceilings, not a
    /// start that was going to be refused anyway.
    func testAllIdleProjectsOverTheirOwnBudgetsHoldAndSayWhich() {
        var budgets = spentBudget("alpha", budgetUSD: 5)
        budgets.merge(spentBudget("beta", budgetUSD: 8)) { a, _ in a }

        let decision = decide([project("alpha", ready: 3), project("beta", ready: 2)],
                              projectBudgets: budgets)

        XCTAssertNil(decision.target)
        XCTAssertEqual(decision.hold?.kind, "budgetExhausted")
        let reason = decision.hold?.reason ?? ""
        XCTAssertTrue(reason.contains("alpha"), reason)
        XCTAssertTrue(reason.contains("beta"), reason)
    }

    /// A project with no ceiling of its own is not blocked by the absence of
    /// one — the portfolio ceiling is what governs it.
    func testAProjectWithNoBudgetOfItsOwnStartsNormally() {
        let decision = decide([project("alpha", ready: 2)], projectBudgets: [:])

        XCTAssertEqual(decision.target?.project, "alpha")
    }

    /// The project ceiling is asked after "already running": a busy project over
    /// its budget was never going to spend it, and reporting the budget would
    /// send the operator to raise a number that changes nothing.
    func testABusyProjectOverItsBudgetHoldsAsBusyRatherThanAsExhausted() {
        let decision = decide([project("alpha", ready: 3, running: true)],
                              projectBudgets: spentBudget("alpha"))

        XCTAssertEqual(decision.hold, .allBusy)
    }

    /// The portfolio ceiling is checked before any project is looked at, so an
    /// exhausted day is one hold rather than a per-project list.
    func testAnExhaustedPortfolioCeilingIsReportedAsThePortfolios() {
        let decision = decide([project("alpha", ready: 3)],
                              budget: DailyBudget(budgetUSD: 20, spentUSD: 20),
                              projectBudgets: ["/tmp/alpha": DailyBudget(budgetUSD: 500, spentUSD: 1,
                                                                        scope: .project("alpha"))])

        XCTAssertEqual(decision.hold?.kind, "budgetExhausted")
        XCTAssertFalse(decision.hold?.reason.contains("alpha") ?? true,
                       "a generous project ceiling never licenses a run past the portfolio's")
    }

    func testProjectWithARunInFlightIsNotStartedAgain() {
        let decision = decide([project("alpha", ready: 4, running: true)])

        XCTAssertNil(decision.target)
        XCTAssertEqual(decision.hold, .allBusy)
    }

    func testProjectWithoutAWorkerAndReviewerIsNotStarted() {
        let decision = decide([project("alpha", ready: 4, autopilotReady: false)])

        XCTAssertEqual(decision.hold, .noEligibleProject)
    }

    func testEligibleAndIdleButWithNothingReadyHolds() {
        let decision = decide([project("alpha", ready: 0)])

        XCTAssertEqual(decision.hold, .nothingRunnable)
    }

    // MARK: - The kill switch

    func testSwitchedOffNothingStarts() {
        let decision = decide([project("alpha", ready: 3)], enabled: false)

        XCTAssertNil(decision.target)
        XCTAssertEqual(decision.hold, .disabled)
    }

    /// Off beats everything else, including a portfolio that is otherwise
    /// perfectly startable — the switch is read before anything is.
    func testOffIsCheckedBeforeEveryOtherGate() {
        let decision = decide([project("alpha", ready: 3)], enabled: false,
                              budget: DailyBudget(budgetUSD: 20, spentUSD: 20))

        XCTAssertEqual(decision.hold, .disabled)
    }

    // MARK: - No third verb

    /// Advisory mode retired: a decision is a start or a hold, never a
    /// proposal. Pinned on the type itself — `kind` for every reachable
    /// decision reads "start" or a hold's own tag, so nothing downstream can
    /// meet a "propose" it has no arm for.
    func testADecisionIsAStartOrAHoldAndNothingElse() {
        let started = decide([project("alpha", ready: 2)])
        XCTAssertEqual(started.kind, "start")
        XCTAssertNotNil(started.target)

        let held = decide([])
        XCTAssertNil(held.target)
        XCTAssertNotNil(held.hold, "anything that isn't a start carries the hold that stopped it")
    }

    // MARK: - The approval gate

    /// The bound is a number that already exists: the default policy keeps 3
    /// ready, so a gate holding more than 3 stops new work in that project.
    func testAGateHoldingMoreThanTheReadyFloorRefusesToStartThere() {
        let decision = decide([project("alpha", ready: 2, awaitingApproval: 4)])

        XCTAssertNil(decision.target)
        XCTAssertEqual(decision.hold?.kind, "gateFull")
        let reason = decision.hold?.reason ?? ""
        XCTAssertTrue(reason.contains("alpha"), reason)
        XCTAssertTrue(reason.contains("4"), "the gate's own count: \(reason)")
        XCTAssertTrue(reason.contains("3"), "the ready floor it exceeds: \(reason)")
    }

    /// At or under the floor, the gate is not the reason anything holds — a
    /// project may still be idle for another reason, but not this one.
    func testAGateAtOrUnderTheFloorStartsNormally() {
        let atFloor = decide([project("alpha", ready: 2, awaitingApproval: 3)])
        XCTAssertEqual(atFloor.target?.project, "alpha", "at the floor is not over it")

        let underFloor = decide([project("beta", ready: 2, awaitingApproval: 1)])
        XCTAssertEqual(underFloor.target?.project, "beta")
    }

    /// A project on rung 5 clears its own gate and is never held this way,
    /// however far behind its approval queue runs.
    func testAProjectThatApprovesItsOwnReviewPassedRunsIsNeverGateHeld() {
        let decision = decide([project("alpha", ready: 2, awaitingApproval: 40,
                                       approveReviewPassedRuns: true)])

        XCTAssertEqual(decision.target?.project, "alpha")
    }

    /// The floor is read off the same policy the Planner fills queues by, not
    /// a bound invented here — a caller with a deeper `targetDepth` gets a
    /// deeper floor.
    func testTheFloorIsTheQueueRefillPolicysTargetDepth() {
        let policy = QueueRefill.Policy(threshold: 2, targetDepth: 10, maxItemsPerPass: 3,
                                        maxProjectsPerPass: 3)

        let decision = decide([project("alpha", ready: 2, awaitingApproval: 4)],
                              queueRefillPolicy: policy)

        XCTAssertEqual(decision.target?.project, "alpha", "4 is under a floor of 10")
    }

    /// A hold on one project's gate never withholds a start in another —
    /// the same isolation every other per-project hold gets.
    func testAGateFullProjectNeverWithholdsAStartInAnother() {
        let decision = decide([project("alpha", ready: 3, awaitingApproval: 9),
                               project("beta", ready: 2)])

        XCTAssertEqual(decision.target?.project, "beta",
                       "alpha's gate is not evidence about beta's")
    }

    /// A busy project holds as busy, exactly as an ordinary `ProjectHold`
    /// does — it was never going to start anything, so naming the gate would
    /// send the operator to fix the wrong thing.
    func testABusyProjectOverItsGateHoldsAsBusyRatherThanAsGateFull() {
        let decision = decide([project("alpha", ready: 3, running: true, awaitingApproval: 9)])

        XCTAssertEqual(decision.hold, .allBusy)
    }

    // MARK: - Holds: forming

    func testRepeatedFailuresHoldTheProjectWithTheReasonRecorded() {
        var holds = RunScheduling.Holds()
        for _ in 0..<(RetryCeiling.limit - 1) {
            holds.record(failure(item: "one"), project: "alpha", path: "/tmp/alpha")
        }
        XCTAssertNil(holds.hold(atPath: "/tmp/alpha"),
                     "short of the ceiling the retry ceiling already owns, nothing is withheld")
        XCTAssertNotNil(decide([project("alpha", ready: 3)], holds: holds).target)

        holds.record(failure(item: "one"), project: "alpha", path: "/tmp/alpha")

        let decision = decide([project("alpha", ready: 3)], holds: holds)
        XCTAssertNil(decision.target)
        XCTAssertEqual(decision.hold?.kind, "projectHeld")
        let reason = decision.hold?.reason ?? ""
        XCTAssertTrue(reason.contains("one blocked: verify failed"),
                      "the reason has to name the failure, or the night is a mystery: \(reason)")
        XCTAssertTrue(reason.contains("until its queue changes"),
                      "and what would end it, or the line is unactionable: \(reason)")
    }

    /// The whole point of the item this replaced: on 2026-08-12 one project's
    /// three retries stopped every project in the fleet until an unrelated
    /// relaunch.
    func testAHoldInOneProjectNeverWithholdsAStartInAnother() {
        let decision = decide([project("alpha", ready: 3),
                               project("beta", ready: 2)],
                              holds: heldProject("alpha"))

        XCTAssertEqual(decision.target?.project, "beta",
                       "evidence about alpha's queue is not evidence about beta's")
    }

    /// A hold is *not* a gate over the portfolio: it is a filter over the
    /// candidates, so it only refuses the tick when it has run out of them.
    func testEveryIdleProjectHeldReportsTheHoldsRatherThanStarting() {
        var holds = heldProject("alpha")
        for _ in 0..<RetryCeiling.limit {
            holds.record(failure(item: "two"), project: "beta", path: "/tmp/beta")
        }

        let decision = decide([project("alpha", ready: 3), project("beta", ready: 1)], holds: holds)

        XCTAssertNil(decision.target)
        XCTAssertEqual(decision.hold?.kind, "projectHeld")
        let reason = decision.hold?.reason ?? ""
        XCTAssertTrue(reason.contains("alpha"), reason)
        XCTAssertTrue(reason.contains("beta"), reason)
    }

    /// A busy project holds as busy. It was never going to start anything, and
    /// naming a hold on it would send the operator to fix the wrong thing —
    /// the same reason its own budget is asked after "already running".
    func testABusyHeldProjectHoldsAsBusyRatherThanAsHeld() {
        let decision = decide([project("alpha", ready: 3, running: true)], holds: heldProject("alpha"))

        XCTAssertEqual(decision.hold, .allBusy)
    }

    /// The ceilings are untouched by any of this: the portfolio's is still read
    /// before a project is chosen, so an exhausted day refuses identically
    /// whether or not anything is held.
    func testAnExhaustedDayStillRefusesRegardlessOfHolds() {
        let decision = decide([project("alpha", ready: 3), project("beta", ready: 3)],
                              budget: DailyBudget(budgetUSD: 20, spentUSD: 20),
                              holds: heldProject("alpha"))

        XCTAssertEqual(decision.hold?.kind, "budgetExhausted")
    }

    // MARK: - Holds: expiring

    /// The claim a hold makes is about a particular queue. When that queue is no
    /// longer the queue, the claim stops being asserted — no timer, no cooldown.
    func testAHoldExpiresWhenTheRunnableSetChanges() {
        var holds = heldProject("alpha")
        XCTAssertNotNil(holds.hold(atPath: "/tmp/alpha"))

        // Refill filed something new.
        holds.expire(path: "/tmp/alpha",
                     against: evidence(["one": .init(spec: "aaaa", runnable: true),
                                        "two": .init(spec: "bbbb", runnable: true)]),
                     environment: "env-1")

        XCTAssertNil(holds.hold(atPath: "/tmp/alpha"))
        XCTAssertTrue(holds.isEmpty, "and nothing is left recorded against it either")
    }

    /// Re-grooming is the fix the retirement note asks for, and it keeps the
    /// item's id — so a hold that compared ids alone would survive the very
    /// edit that answers it.
    func testReGroomingTheFailedItemExpiresTheHold() {
        var holds = heldProject("alpha")

        holds.expire(path: "/tmp/alpha",
                     against: evidence(["one": .init(spec: "rewritten", runnable: true)]),
                     environment: "env-1")

        XCTAssertNil(holds.hold(atPath: "/tmp/alpha"))
    }

    /// The retry ceiling retiring the failing item is itself a queue change: the
    /// item leaves the runnable pool and the scheduler moves on. The two bounds
    /// are the same bound, so this is the ordinary way an ordinary hold ends.
    func testTheRetryCeilingRetiringTheItemExpiresTheHold() {
        var holds = heldProject("alpha")

        holds.expire(path: "/tmp/alpha",
                     against: evidence(["one": .init(spec: "aaaa", runnable: false)]),
                     environment: "env-1")

        XCTAssertNil(holds.hold(atPath: "/tmp/alpha"))
    }

    /// A dependency reaching `done` releases the item that was waiting on it.
    /// The waiting item's id and spec are both unchanged; only its runnability
    /// moved, which is why the evidence records that too.
    func testADependencyReachingDoneExpiresTheHold() {
        let before = evidence(["one": .init(spec: "aaaa", runnable: true),
                               "two": .init(spec: "bbbb", runnable: false)])
        var holds = heldProject("alpha", evidence: before)

        holds.expire(path: "/tmp/alpha",
                     against: evidence(["one": .init(spec: "aaaa", runnable: true),
                                        "two": .init(spec: "bbbb", runnable: true)]),
                     environment: "env-1")

        XCTAssertNil(holds.hold(atPath: "/tmp/alpha"))
    }

    /// The failed run's own bookkeeping is not a queue change. The item bounces
    /// back to `ready` with the same spec, its attempt count goes up in the
    /// ledger, and the retirement note lands in its Notes — none of which is in
    /// here, and a hold that expired on them would expire on the tick after it
    /// formed and hold nothing at all.
    func testAFailedRunsOwnBookkeepingDoesNotExpireTheHold() {
        var holds = heldProject("alpha")

        holds.expire(path: "/tmp/alpha", against: evidence(), environment: "env-1")

        XCTAssertNotNil(holds.hold(atPath: "/tmp/alpha"))
        XCTAssertNil(decide([project("alpha", ready: 3)], holds: holds).target)
    }

    /// A queue that moved between two failures retires the first without taking
    /// the second with it — each failure is judged against the queue *it* saw.
    func testOnlyTheFailuresTheQueueHasOvertakenAreDropped() {
        let stale = evidence(["one": .init(spec: "aaaa", runnable: true)])
        let fresh = evidence(["one": .init(spec: "aaaa", runnable: true),
                              "two": .init(spec: "bbbb", runnable: true)])
        var holds = RunScheduling.Holds()
        holds.record(failure(item: "one", evidence: stale), project: "alpha", path: "/tmp/alpha")
        holds.record(failure(item: "one", evidence: fresh), project: "alpha", path: "/tmp/alpha")

        holds.expire(path: "/tmp/alpha", against: fresh, environment: "env-1")

        XCTAssertEqual(holds.recorded(atPath: "/tmp/alpha")?.failures.count, 1)
        XCTAssertNil(holds.hold(atPath: "/tmp/alpha"), "one failure is not yet a hold")
    }

    // MARK: - Holds: the same-cause case

    /// Two *different* items failing with the same words is not a statement
    /// about either item, so it holds on the strength of two — and no queue
    /// edit answers it, because nothing in the queue is what is wrong.
    func testTwoItemsFailingIdenticallyHoldTheProjectAndSurviveTheQueueMoving() {
        var holds = RunScheduling.Holds()
        holds.record(failure(item: "one", text: "blocked: agent session died"),
                     project: "alpha", path: "/tmp/alpha")
        holds.record(failure(item: "two", text: "blocked: agent session died"),
                     project: "alpha", path: "/tmp/alpha")

        XCTAssertNotNil(holds.hold(atPath: "/tmp/alpha"),
                        "two is enough when they are two different items failing the same way")
        XCTAssertTrue(holds.hold(atPath: "/tmp/alpha")?.isSystemic ?? false)

        holds.expire(path: "/tmp/alpha",
                     against: evidence(["three": .init(spec: "cccc", runnable: true)]),
                     environment: "env-1")

        XCTAssertNotNil(holds.hold(atPath: "/tmp/alpha"),
                        "a queue that has moved on says nothing about a failure that wasn't about it")
        XCTAssertTrue(holds.hold(atPath: "/tmp/alpha")?.reason
                        .contains("until its autopilot or the app changes") ?? false)
    }

    /// The same item failing twice is that item's problem, and the retry
    /// ceiling already owns it. Only two *different* items make it systemic.
    func testOneItemFailingTwiceIsNotSameCauseEvidence() {
        var holds = RunScheduling.Holds()
        holds.record(failure(item: "one", text: "blocked: agent session died"),
                     project: "alpha", path: "/tmp/alpha")
        holds.record(failure(item: "one", text: "blocked: agent session died"),
                     project: "alpha", path: "/tmp/alpha")

        XCTAssertFalse(holds.recorded(atPath: "/tmp/alpha")?.isSystemic ?? true)
        XCTAssertNil(holds.hold(atPath: "/tmp/alpha"))
    }

    /// Different failures on different items are two separate problems, not one
    /// systemic one — they hold on repetition like anything else.
    func testTwoItemsFailingDifferentlyIsNotSameCauseEvidence() {
        var holds = RunScheduling.Holds()
        holds.record(failure(item: "one", text: "blocked: verify failed"),
                     project: "alpha", path: "/tmp/alpha")
        holds.record(failure(item: "two", text: "blocked: review did not pass"),
                     project: "alpha", path: "/tmp/alpha")

        XCTAssertFalse(holds.recorded(atPath: "/tmp/alpha")?.isSystemic ?? true)
        XCTAssertNil(holds.hold(atPath: "/tmp/alpha"))
    }

    /// What *does* clear a same-cause hold: something outside those runs. The
    /// autopilot config, the global config, an app relaunch (which clears them
    /// by being in memory), or a human.
    func testAChangeOutsideTheRunsClearsASameCauseHold() {
        var holds = RunScheduling.Holds()
        holds.record(failure(item: "one", text: "blocked: agent session died"),
                     project: "alpha", path: "/tmp/alpha")
        holds.record(failure(item: "two", text: "blocked: agent session died"),
                     project: "alpha", path: "/tmp/alpha")

        holds.expire(path: "/tmp/alpha", against: evidence(), environment: "env-2")

        XCTAssertTrue(holds.isEmpty)
    }

    func testTheHumanOverrideClearsEveryHold() {
        var holds = heldProject("alpha")
        holds.record(failure(item: "two", text: "blocked: agent session died"),
                     project: "beta", path: "/tmp/beta")

        holds.clear()

        XCTAssertTrue(holds.isEmpty)
        XCTAssertNotNil(decide([project("alpha", ready: 3)], holds: holds).target)
    }

    /// A run that got somewhere is the end of the matter — for its project, and
    /// only for its project.
    func testASuccessClearsThatProjectsHoldAndNoOthers() {
        var holds = heldProject("alpha")
        for _ in 0..<RetryCeiling.limit {
            holds.record(failure(item: "two"), project: "beta", path: "/tmp/beta")
        }

        holds.clear(path: "/tmp/alpha")

        XCTAssertNil(holds.hold(atPath: "/tmp/alpha"))
        XCTAssertNotNil(holds.hold(atPath: "/tmp/beta"))
    }

    /// A project that has been closed is not being started from either way, and
    /// a hold nobody can act on is noise in `/health`.
    func testHoldsForProjectsNoLongerOpenAreForgotten() {
        var holds = heldProject("alpha")

        holds.retain(paths: ["/tmp/beta"])

        XCTAssertTrue(holds.isEmpty)
    }

    // MARK: - Holds: reading the queue

    /// The evidence records what an item *asks for*, so a re-groom shows up
    /// even though the id, the title and the status are all unchanged.
    func testEvidenceNoticesAReGroomedItem() {
        let item = readyItem("one")
        let before = RunScheduling.evidence(items: [item], detail: { _ in detail(what: "build X") })
        let after = RunScheduling.evidence(items: [item], detail: { _ in detail(what: "build Y") })

        XCTAssertNotEqual(before, after)
    }

    /// And it records whether autopilot would take it, so a `needs:` clearing
    /// shows up even though nothing about the waiting item changed.
    func testEvidenceNoticesADependencyReachingDone() {
        let waiting = readyItem("two", needs: ["one"])
        func read(_ blockerStatus: BacklogItemStatus) -> RunScheduling.QueueEvidence {
            var blocker = readyItem("one")
            blocker.status = blockerStatus
            return RunScheduling.evidence(items: [blocker, waiting], detail: { _ in detail() })
        }

        let before = read(.ready)
        let after = read(.done)

        XCTAssertEqual(before.rows["two"]?.runnable, false)
        XCTAssertEqual(after.rows["two"]?.runnable, true)
        XCTAssertNotEqual(before, after)
    }

    /// A retired item is not runnable, whatever the Definition-of-Ready says
    /// about it — so the ceiling retiring an item is a change the evidence sees.
    func testEvidenceCountsARetiredItemAsNotRunnable() {
        let item = readyItem("one")

        let free = RunScheduling.evidence(items: [item], detail: { _ in detail() })
        let retired = RunScheduling.evidence(items: [item], detail: { _ in detail() },
                                             isRetired: { _, _ in true })

        XCTAssertEqual(free.rows["one"]?.runnable, true)
        XCTAssertEqual(retired.rows["one"]?.runnable, false)
    }

    /// Only `ready` items are in the queue a start would be made from, so only
    /// they are the evidence — an item going `done` leaves it, which is itself
    /// the change a dependent item is waiting for.
    func testEvidenceCoversOnlyReadyItems() {
        var done = readyItem("two")
        done.status = .done

        let rows = RunScheduling.evidence(items: [readyItem("one"), done],
                                          detail: { _ in detail() }).rows

        XCTAssertEqual(Set(rows.keys), ["one"])
    }

    private func readyItem(_ id: String, needs: [String] = []) -> BacklogItem {
        BacklogItem(id: id, title: "Item \(id)", verify: "make test", status: .ready,
                    type: .local, size: .s, needs: needs)
    }

    private func detail(what: String = "build the thing") -> BacklogItemDetail {
        BacklogItemDetail(id: "one", title: "Item", size: "S",
                          verifyCommands: [.init(name: "verify", cmd: "make test", expect: nil)],
                          acceptanceCriteria: ["it works"], outOfScope: [],
                          what: what, approach: "like this")
    }

    // MARK: - Which project

    /// Fairness is the whole ordering: the project that has been waiting
    /// longest starts, whatever else is true of the two — including a deeper
    /// queue on the other one.
    func testTheProjectIdleLongestStartsEvenWithLessReadyWork() {
        let idleSince = ["alpha": now.addingTimeInterval(-600), "beta": now.addingTimeInterval(-7200)]

        let decision = decide([project("alpha", ready: 3), project("beta", ready: 1)],
                              idleSince: idleSince)

        XCTAssertEqual(decision.target?.project, "beta")
        XCTAssertTrue(decision.target?.reason.contains("idle 2h") ?? false,
                      "why it was chosen is part of the record: \(decision.target?.reason ?? "-")")
    }

    /// And the reason says only what decided it — no rank word survives in
    /// front of the idle clock.
    func testTheReasonReadsAsIdleTimeAndQueueDepthAlone() {
        let idleSince = ["alpha": now.addingTimeInterval(-1200)]

        let decision = decide([project("alpha", ready: 9)], idleSince: idleSince)

        XCTAssertEqual(decision.target?.reason, "idle 20m, 9 ready")
    }

    /// The same ordering as the refill loop, on purpose: two answers to "which
    /// project matters" would drift apart.
    func testChoosesTheSameProjectTheRefillLoopWould() {
        let projects = [
            project("alpha", ready: 1),
            project("beta", ready: 1),
            project("gamma", ready: 1)
        ]
        let idleSince = ["alpha": now.addingTimeInterval(-9000), "gamma": now.addingTimeInterval(-60)]

        let started = RunScheduling.decide(portfolio: portfolio(projects), enabled: true,
                                           budget: DailyBudget(budgetUSD: 20, spentUSD: 0),
                                           idleSince: idleSince, now: now)
        let groomed = QueueRefill.decide(portfolio: portfolio(projects),
                                         idleSince: idleSince, now: now)

        XCTAssertEqual(started.target?.project, groomed.target?.project)
        XCTAssertEqual(started.target?.project, "alpha")
    }

    func testNameBreaksAnOtherwiseCompleteTie() {
        let decision = decide([project("zulu", ready: 1), project("alpha", ready: 1)])

        XCTAssertEqual(decision.target?.project, "alpha",
                       "the same portfolio has to resolve the same way every time")
    }

    // MARK: - Reading it back

    func testIdlePhraseReadsAsSomethingAHumanWouldSay() {
        XCTAssertEqual(RunScheduling.idlePhrase(30), "just idle")
        XCTAssertEqual(RunScheduling.idlePhrase(600), "idle 10m")
        XCTAssertEqual(RunScheduling.idlePhrase(3 * 3600 + 300), "idle 3h 05m")
    }

    func testEveryHoldSaysSomethingDifferent() {
        let holds: [RunScheduling.Hold] = [
            .disabled, .unwired, .projectHeld("held"),
            .budgetExhausted("spent"), .noEligibleProject, .allBusy, .nothingRunnable,
            .itemsRefused("3 items refused as written — edit or release to retry"),
            .gateFull("alpha: gate holds 4, more than 3 kept ready")
        ]
        XCTAssertEqual(Set(holds.map(\.kind)).count, holds.count)
        XCTAssertEqual(Set(holds.map(\.reason)).count, holds.count)
    }
}
