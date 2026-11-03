import XCTest
import KiteloopCore
@testable import Kiteloop

/// The scheduling loop itself — the half that owns the switch, the timer, the
/// holds and the record. The *decision* is `RunSchedulingTests`; what is
/// covered here is everything a pure function can't be asked: that off is the
/// shipped state, that switching off tears the timer down rather than skipping a
/// tick, that an unwired loop says so instead of pretending to be off, and how a
/// finished run is folded into its project's hold.
@MainActor
final class CoordinatorRunSchedulerTests: XCTestCase {

    private var tempDir: URL!
    private var store: GlobalConfigStore!
    private var registry: ControlSessionRegistry!
    private var refill: CoordinatorQueueRefill!
    private var scheduler: CoordinatorRunScheduler!
    /// Held for the length of a test because the scheduler's reference to it is
    /// weak — a server nobody kept would be gone before the tick.
    private var controlServer: KiteloopControlServer!
    private var recordsURL: URL!
    private var startsURL: URL!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "run-scheduler")
        store = GlobalConfigStore(storageURL: tempDir.appendingPathComponent("global.json"))
        registry = ControlSessionRegistry()
        refill = CoordinatorQueueRefill(ledgerURL: tempDir.appendingPathComponent("refill.jsonl"))
        registry.queueRefill = refill
        startsURL = tempDir.appendingPathComponent("starts.jsonl")
        recordsURL = tempDir.appendingPathComponent("control-runs.jsonl")
        scheduler = CoordinatorRunScheduler(logURL: startsURL)
    }

    override func tearDown() async throws {
        scheduler?.stop()
        scheduler = nil
        refill?.stop()
        refill = nil
        controlServer = nil
        registry = nil
        store = nil
    }

    // MARK: - Off by default

    /// An upgrade must not begin running work. Nothing but a stored `true` ever
    /// switches this on.
    func testOffOnAFreshInstall() {
        scheduler.configure(registry: registry, globalConfigStore: store)

        XCTAssertFalse(scheduler.enabled)
        XCTAssertNil(store.config.coordinatorSchedulingEnabled)
        scheduler.start()
        XCTAssertFalse(scheduler.isTimerRunning, "a switched-off loop shouldn't even cost a wake-up")
    }

    func testTakesTheStoredSwitchAtLaunch() {
        store.setCoordinatorScheduling(enabled: true)

        scheduler.configure(registry: registry, globalConfigStore: store)

        XCTAssertTrue(scheduler.enabled)
    }

    /// Loading what was saved must not immediately save it back — and must not
    /// write a switch a human never set.
    func testLoadingTheStoredSwitchDoesNotRewriteIt() {
        scheduler.configure(registry: registry, globalConfigStore: store)

        XCTAssertNil(store.config.coordinatorSchedulingEnabled)
    }

    func testSwitchingOnPersistsForTheNextLaunch() {
        scheduler.configure(registry: registry, globalConfigStore: store)

        scheduler.enabled = true

        XCTAssertEqual(store.config.coordinatorSchedulingEnabled, true)
    }

    /// The scheduler's switch is its own. Turning grooming on must not turn
    /// running on: filing work and running it are different levels of trust.
    func testItsSwitchIsSeparateFromTheRefillSwitch() {
        scheduler.configure(registry: registry, globalConfigStore: store)
        refill.configure(registry: registry, globalConfigStore: store,
                         runtimeFactory: { MockAgentRuntime() })

        refill.enabled = true

        XCTAssertTrue(refill.enabled)
        XCTAssertFalse(scheduler.enabled)
    }

    // MARK: - The kill switch

    func testSwitchingOffStopsTheTimerRatherThanSkippingATick() {
        scheduler.configure(registry: registry, globalConfigStore: store)
        scheduler.start()
        scheduler.enabled = true
        XCTAssertTrue(scheduler.isTimerRunning)

        scheduler.enabled = false

        XCTAssertFalse(scheduler.isTimerRunning)
        XCTAssertEqual(store.config.coordinatorSchedulingEnabled, false)
    }

    func testATickWhileSwitchedOffStartsNothing() async {
        scheduler.configure(registry: registry, globalConfigStore: store)

        let decision = await scheduler.runTick()

        XCTAssertEqual(decision.hold, .disabled)
        XCTAssertTrue(scheduler.startHistory.isEmpty)
    }

    /// Repeated failed runs hold the project they happened in — through the
    /// loop's own folding of an outcome, not by poking the hold.
    func testRepeatedFailedRunsHoldTheProjectTheyHappenedIn() {
        scheduler.configure(registry: registry, globalConfigStore: store)
        let failed = CoordinatorRunScheduler.Outcome(name: "blocked", detail: "verify failed",
                                                     succeeded: false)

        for _ in 0..<RetryCeiling.limit { scheduler.fold(failed, of: target()) }

        let hold = scheduler.holds.hold(atPath: "/tmp/alpha")
        XCTAssertNotNil(hold)
        XCTAssertEqual(hold?.project, "alpha")
        XCTAssertTrue(hold?.reason.contains("alpha-0 blocked: verify failed") ?? false,
                      "the hold has to name the failure: \(hold?.reason ?? "-")")
        XCTAssertNil(scheduler.holds.hold(atPath: "/tmp/beta"),
                     "and it is evidence about alpha's queue and nobody else's")
    }

    /// A refusal at the pickup gate spends nothing and says nothing about
    /// whether runs fail — grounding, status, an unmet `needs:`, a busy slot.
    /// The fleet-global counter this replaced tripped on three such $0 refusals
    /// on 2026-08-13 and stopped every project.
    func testGateRefusalsContributeToNoHoldHoweverManyOccur() {
        scheduler.configure(registry: registry, globalConfigStore: store)
        let refused = CoordinatorRunScheduler.Outcome(name: CoordinatorRunScheduler.StartRecord.didNotRun,
                                                      detail: nil, succeeded: false)

        for index in 0..<(RetryCeiling.limit * 3) {
            scheduler.fold(refused, of: target(item: "alpha-\(index)"))
        }

        XCTAssertTrue(scheduler.holds.isEmpty)
        XCTAssertNil(scheduler.holds.hold(atPath: "/tmp/alpha"))
    }

    /// A run that got somewhere ends the matter for its project — and
    /// `awaiting-approval` counts, which is what `succeeded` already says.
    func testASuccessfulRunClearsTheProjectsHold() {
        scheduler.configure(registry: registry, globalConfigStore: store)
        let failed = CoordinatorRunScheduler.Outcome(name: "blocked", detail: "verify failed",
                                                     succeeded: false)
        for _ in 0..<RetryCeiling.limit { scheduler.fold(failed, of: target()) }
        XCTAssertNotNil(scheduler.holds.hold(atPath: "/tmp/alpha"))

        scheduler.fold(CoordinatorRunScheduler.Outcome(name: "awaiting-approval", detail: nil,
                                                       succeeded: true),
                       of: target())

        XCTAssertTrue(scheduler.holds.isEmpty)
    }

    /// Flipping the switch is a human saying they've seen the failures, so it
    /// clears every hold — otherwise turning it back on would hold forever.
    func testFlippingTheSwitchClearsEveryHold() {
        scheduler.configure(registry: registry, globalConfigStore: store)
        let failed = CoordinatorRunScheduler.Outcome(name: "cancelled", detail: nil, succeeded: false)
        for _ in 0..<RetryCeiling.limit { scheduler.fold(failed, of: target()) }
        XCTAssertNotNil(scheduler.holds.hold(atPath: "/tmp/alpha"))

        scheduler.enabled = true

        XCTAssertTrue(scheduler.holds.isEmpty)
    }

    func testResetBreakerClearsTheHoldsWithoutTouchingTheSwitch() {
        scheduler.configure(registry: registry, globalConfigStore: store)
        scheduler.enabled = true
        let failed = CoordinatorRunScheduler.Outcome(name: "cancelled", detail: nil, succeeded: false)
        for _ in 0..<RetryCeiling.limit { scheduler.fold(failed, of: target()) }

        scheduler.resetBreaker()

        XCTAssertTrue(scheduler.holds.isEmpty)
        XCTAssertTrue(scheduler.enabled)
    }

    private func target(project: String = "alpha", item: String = "alpha-0") -> RunScheduling.Target {
        RunScheduling.Target(project: project, path: "/tmp/\(project)", itemID: item,
                             itemTitle: "Item", readyCount: 1, reason: "idle 12m, 1 ready")
    }

// MARK: - The approval gate

    /// The scenario itself: a gate holding more than the Planner keeps ready
    /// stops new work in that project — the bound is `QueueRefill.Policy`'s
    /// own `targetDepth` (3, by default), never a number invented here.
    func testAGateOutrunningTheReadyFloorStopsNewWorkInThatProject() async throws {
        try registerProject(named: "alpha", backlog: gateBacklog(waiting: 4, ready: 1))
        armForStarting()

        let decision = await scheduler.runTick()

        XCTAssertNil(decision.target)
        XCTAssertEqual(decision.hold?.kind, "gateFull")
        let reason = decision.hold?.reason ?? ""
        XCTAssertTrue(reason.contains("4") && reason.contains("3"), "both numbers: \(reason)")
        XCTAssertTrue(scheduler.startHistory.isEmpty, "nothing was started")
    }

    /// Once the gate drains to the floor, the very next tick starts work
    /// again — the hold is a live reading, not a latch.
    func testOnceTheGateDrainsToTheFloorTheNextTickStarts() async throws {
        try registerProject(named: "alpha", backlog: gateBacklog(waiting: 3, ready: 1))
        armForStarting()

        let decision = await scheduler.runTick()

        XCTAssertEqual(decision.target?.itemID, "alpha-ready", "3 waiting is at the floor, not over it")
    }

    /// A run parked on the usage limit holds every project — the limit is the
    /// account's — and the first look after the reset starts work again.
    func testAStandingUsageLimitHoldsTheFleetUntilItLifts() async throws {
        try registerProject(named: "alpha", backlog: "- [ ] alpha-1 | Ship the thing | ready")
        armForStarting()
        let now = Date()
        scheduler.recordUsageLimit(UsageLimitStop(resetsAt: now.addingTimeInterval(3_600), window: "five_hour",
                                                  resetReported: true), now: now)

        let held = await scheduler.tick(now: now)
        XCTAssertEqual(held.decision.hold?.kind, "usageLimit")
        XCTAssertTrue(held.decision.hold?.reason.contains("resume") ?? false, held.decision.summary)
        XCTAssertTrue(scheduler.startHistory.isEmpty, "nothing was started")

        let lifted = await scheduler.tick(now: now.addingTimeInterval(3_601))
        XCTAssertEqual(lifted.decision.target?.itemID, "alpha-1")
    }

    /// A project on rung 5 — its own autopilot approves review-passed runs —
    /// clears its own gate and is never held this way.
    func testAProjectThatApprovesItsOwnReviewPassedRunsIsNeverGateHeld() async throws {
        let projectID = try registerProject(named: "alpha", backlog: gateBacklog(waiting: 12, ready: 1))
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        autopilot.approvalGate = .land
        armForStarting()

        let decision = await scheduler.runTick()

        XCTAssertEqual(decision.target?.itemID, "alpha-ready")
    }

    /// `awaiting-approval | ready` lines: `waiting` items parked at the gate
    /// and one item actually runnable, so a start that got past the gate has
    /// something to name.
    private func gateBacklog(waiting: Int, ready: Int) -> String {
        let gated = (0..<waiting).map { "- [ ] alpha-gate-\($0) | Needs sign-off | awaiting-approval" }
        let runnable = (0..<ready).map { _ in "- [ ] alpha-ready | Ship the thing | ready" }
        return (gated + runnable).joined(separator: "\n")
    }

    // MARK: - Paused projects

    /// A project whose own autopilot is holding its queue (`BacklogAutopilot.
    /// pause()`, `POST /v1/autopilot/pause`) is exactly as off limits to a
    /// fresh autonomous start as one a human parked on the fleet board — pausing is
    /// one act now, and `selectableProjects` is where both causes are read.
    func testAProjectWithAHeldAutopilotQueueIsSkippedByTheScheduler() async throws {
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] alpha-1 | Ship the thing | ready")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        autopilot.pause()
        armForStarting()

        let decision = await scheduler.runTick()

        XCTAssertEqual(decision.hold, .noEligibleProject)
        XCTAssertTrue(scheduler.startHistory.isEmpty)
    }

    // MARK: - When it looks

    /// The timer looks before it sleeps. A launch used to sit a whole
    /// `checkInterval` before its first look — the state the `lastDecision`
    /// comment calls out as reading "exactly like a broken one", and eight
    /// relaunches on 2026-08-21 paid five minutes each for it.
    func testALaunchLooksWithoutWaitingOutAnInterval() async throws {
        scheduler.configure(registry: registry, globalConfigStore: store)
        // An hour, so the look this waits for cannot be a second tick arriving.
        scheduler.checkInterval = 3600
        scheduler.enabled = true
        XCTAssertNil(scheduler.lastTickAt)

        scheduler.start()

        try await eventually("the look at launch") { @MainActor in self.scheduler.lastTickAt != nil }
        XCTAssertNotNil(scheduler.lastTickAt,
                        "an armed scheduler has to look at launch, not an interval later")
        XCTAssertEqual(scheduler.lastDecision?.hold, .noEligibleProject)
    }

    /// And it goes on looking on its own. What a finished run announces is an
    /// extra occasion, never a replacement: a hold expiring, an item edited into
    /// `ready` and the budget rolling at local midnight announce nothing at all,
    /// and the clock is the only thing that finds them.
    func testTheTimerGoesOnLookingWithNothingAnnouncingAnything() async throws {
        scheduler.configure(registry: registry, globalConfigStore: store)
        scheduler.checkInterval = 0.05
        scheduler.enabled = true
        scheduler.start()
        try await eventually("the first look") { @MainActor in self.scheduler.lastTickAt != nil }
        let first = scheduler.lastTickAt

        try await eventually("a second look from the timer") { @MainActor in self.scheduler.lastTickAt != first }

        XCTAssertNotEqual(scheduler.lastTickAt, first,
                          "the timer is the backstop for everything nothing announces")
    }

    /// The item itself: a finished run is an occasion to decide, not a wait.
    /// Nothing here starts the timer, so the look under test can only have come
    /// from the announcement.
    func testAFinishedRunLooksWithoutWaitingForTheTimer() async throws {
        try registerProject(named: "alpha", backlog: "- [ ] alpha-1 | Ship the thing | ready")
        armForStarting()
        XCTAssertFalse(scheduler.isTimerRunning,
                       "the announcement has to be the only thing that could have looked")

        await scheduler.runFinished().value

        XCTAssertNotNil(scheduler.lastTickAt)
        XCTAssertEqual(scheduler.startHistory.map(\.itemID), ["alpha-1"],
                       "the run that just ended is what got the next one started")
    }

    /// Through the same gates a timed look goes through. A day that is spent
    /// stays spent — the announcement is a reason to ask, never an answer.
    func testAnAnnouncedLookIsStillBoundedByTheDailyBudget() async throws {
        try registerProject(named: "alpha", backlog: "- [ ] alpha-1 | Ship the thing | ready")
        let ledger = DailySpendLedger(storageURL: tempDir.appendingPathComponent("spend.json"))
        ledger.charge(costUSD: 25)
        store.setDailyBudgetUSD(20)
        scheduler.configure(registry: registry, globalConfigStore: store, spendLedger: ledger)
        scheduler.enabled = true

        await scheduler.runFinished().value

        XCTAssertEqual(scheduler.lastDecision?.hold?.kind, "budgetExhausted")
        XCTAssertTrue(scheduler.startHistory.isEmpty)
    }

    /// And through the switch, which is the bound a second path around the timer
    /// could most easily have lost: the timer is torn down when the switch is
    /// off, and an announcement arrives whether or not one exists.
    func testAnAnnouncedLookStartsNothingWhileTheSwitchIsOff() async throws {
        try registerProject(named: "alpha", backlog: "- [ ] alpha-1 | Ship the thing | ready")
        scheduler.configure(registry: registry, globalConfigStore: store)
        XCTAssertFalse(scheduler.enabled)

        await scheduler.runFinished().value

        XCTAssertEqual(scheduler.lastDecision?.hold, .disabled)
        XCTAssertTrue(scheduler.startHistory.isEmpty)
    }

    /// Two occasions arriving together are one look. This is the normal case
    /// rather than the unlucky one: the autopilot announces the finish from
    /// inside the run a tick is still awaiting, so an announced look and the
    /// tick that caused it overlap by construction — and a second start here
    /// would be two runs in one project.
    func testTwoLooksArrivingTogetherStartOneRun() async throws {
        let projectID = try registerProject(named: "alpha",
                                            backlog: "- [ ] alpha-1 | Ship the thing | ready")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        // A run that got somewhere, so nothing downstream stands in for the
        // guard: the item is left exactly as startable as it was, and a second
        // look really would start it a second time.
        autopilot.stageResultForTesting(
            BacklogAutopilot.ItemResult(id: "alpha-1", title: "Ship the thing",
                                        outcome: .awaitingApproval, duration: 42))
        let records = attachControlServer()
        armForStarting()

        let first = scheduler.runFinished()
        let second = scheduler.runFinished()
        await first.value
        await second.value

        XCTAssertEqual(records.records.count, 1, "one run, however many things announced it")
        XCTAssertEqual(scheduler.startHistory.count, 1)
    }

    // MARK: - Runs at once

    /// One is how the fleet always ran: a look while a run is being awaited
    /// is refused, not held — it did not look.
    func testASecondLookIsRefusedWhileOneRunIsInFlightAtTheDefault() async throws {
        try registerProject(named: "alpha", backlog: "- [ ] alpha-1 | Ship the thing | ready")
        try registerProject(named: "beta", backlog: "- [ ] beta-1 | Ship the other | ready")
        armForStarting()
        scheduler.stageStartsInFlightForTesting(["/tmp/elsewhere"])

        let looked = await scheduler.tick()

        XCTAssertFalse(looked.taken)
        XCTAssertTrue(scheduler.startHistory.isEmpty)
    }

    /// With room for two, a look proceeds beside a run in flight and starts
    /// a project that is not the one being awaited.
    func testWithRoomForTwoALookStartsAnotherProjectBesideTheRunInFlight() async throws {
        let alphaID = try registerProject(named: "alpha", backlog: "- [ ] alpha-1 | Ship the thing | ready")
        try registerProject(named: "beta", backlog: "- [ ] beta-1 | Ship the other | ready")
        armForStarting()
        scheduler.maxConcurrentRuns = 2
        scheduler.stageStartsInFlightForTesting([alphaID])

        let looked = await scheduler.tick()

        XCTAssertTrue(looked.taken)
        XCTAssertEqual(looked.decision.target?.project, "beta", "alpha is taken; beta is the one to start")
    }

    /// With room for two, the two looks that arrive together start two
    /// projects: the first look hands its run to a task of its own and comes
    /// back, so the second finds its project taken and starts the other.
    ///
    /// No result is staged here, unlike the run-at-a-time test above: each run
    /// is refused by the pickup gate, and that refusal is what the follow-up
    /// look a freed slot now takes reads as "nothing left to start". Staging a
    /// result would leave both items exactly as startable as they were, and the
    /// fleet would keep starting them — which is the loop the real thing gets
    /// out of by the run marking its item.
    func testWithRoomForTwoTwoLooksStartTwoProjects() async throws {
        try registerProject(named: "alpha", backlog: "- [ ] alpha-1 | Ship the thing | ready")
        try registerProject(named: "beta", backlog: "- [ ] beta-1 | Ship the other | ready")
        let records = attachControlServer()
        armForStarting()
        scheduler.maxConcurrentRuns = 2

        let first = scheduler.runFinished()
        let second = scheduler.runFinished()
        await first.value
        await second.value
        try await eventually("every started run to have returned") { @MainActor in
            self.scheduler.startsInFlight.isEmpty && self.scheduler.lastDecision?.hold != nil
        }

        XCTAssertEqual(Set(scheduler.startHistory.map(\.project)), ["alpha", "beta"])
        XCTAssertEqual(records.records.count, 2)
    }

    /// The hole this closes: with every slot taken the timer's loop is asleep —
    /// its tick was refused for want of capacity — so the slot a finished run
    /// frees used to sit idle until the clock came round. The run that releases
    /// it now takes the look itself, and the third project starts on that look.
    ///
    /// The timer is never started here, so nothing but the freed slot can be
    /// what started the third one.
    func testAFreedSlotIsFollowedByALookThatStartsTheNextProject() async throws {
        try registerProject(named: "alpha", backlog: "- [ ] alpha-1 | Ship the thing | ready")
        try registerProject(named: "beta", backlog: "- [ ] beta-1 | Ship the other | ready")
        try registerProject(named: "gamma", backlog: "- [ ] gamma-1 | Ship the third | ready")
        let records = attachControlServer()
        armForStarting()
        scheduler.maxConcurrentRuns = 2

        // Two looks fill both slots; a third would be refused while they are
        // held, which is the state the fleet used to idle out.
        let first = scheduler.runFinished()
        let second = scheduler.runFinished()
        await first.value
        await second.value
        try await eventually("the freed slot to have started the third project") { @MainActor in
            self.scheduler.startHistory.count == 3 && self.scheduler.startsInFlight.isEmpty
        }

        XCTAssertEqual(Set(scheduler.startHistory.map(\.project)), ["alpha", "beta", "gamma"])
        XCTAssertEqual(records.records.count, 3)
        XCTAssertFalse(scheduler.isTimerRunning, "no clock elapsed — the freed slot is what looked")
    }

    /// A look and nothing more. The last freed slot looks at a portfolio with
    /// nothing left to start, holds, and stops there — it does not go round
    /// again, which is what would turn a drained fleet into a spin.
    func testAFreedSlotLookWithNothingEligibleHoldsWithoutLoopingAgain() async throws {
        try registerProject(named: "alpha", backlog: "- [ ] alpha-1 | Ship the thing | ready")
        let records = attachControlServer()
        armForStarting()
        scheduler.maxConcurrentRuns = 2

        await scheduler.runFinished().value
        try await eventually("the freed slot's look to have held") { @MainActor in
            self.scheduler.startsInFlight.isEmpty && self.scheduler.lastDecision?.hold != nil
        }

        XCTAssertEqual(scheduler.startHistory.count, 1, "one run, and nothing started after it")
        XCTAssertEqual(records.records.count, 1)
        let looked = scheduler.lastTickAt
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(scheduler.lastTickAt, looked, "the look that held did not raise another")
    }

    /// The setting is persisted with the switch, clamped to its range, and
    /// read back at launch.
    func testRunsAtOnceIsPersistedClampedAndReadBackAtLaunch() {
        scheduler.configure(registry: registry, globalConfigStore: store)
        XCTAssertEqual(scheduler.maxConcurrentRuns, 1)

        scheduler.maxConcurrentRuns = 3
        XCTAssertEqual(store.config.maxConcurrentRuns, 3)
        scheduler.maxConcurrentRuns = 40
        XCTAssertEqual(scheduler.maxConcurrentRuns, 8, "clamped to the range")

        let fresh = CoordinatorRunScheduler(logURL: startsURL)
        fresh.configure(registry: registry, globalConfigStore: store)
        XCTAssertEqual(fresh.maxConcurrentRuns, 8)
    }

    // MARK: - What a tick reports about itself

    /// `taken` is what the timer reads to decide whether to skip its sleep —
    /// see the loop's own comment in `syncTimer()`. A tick that ran to
    /// completion, colliding with nothing, has to say so.
    func testATickThatRunsToCompletionReportsThatItLooked() async {
        scheduler.configure(registry: registry, globalConfigStore: store)
        scheduler.enabled = true

        let looked = await scheduler.tick()

        XCTAssertTrue(looked.taken)
        XCTAssertEqual(looked.decision.hold, .noEligibleProject)
    }

    /// The same is true of a tick that actually started a run: it looked, and
    /// its own decision is the one it reports.
    func testATickThatStartsARunReportsThatItLooked() async throws {
        try registerProject(named: "alpha", backlog: "- [ ] alpha-1 | Ship the thing | ready")
        armForStarting()

        let looked = await scheduler.tick()

        XCTAssertTrue(looked.taken)
        XCTAssertEqual(looked.decision.target?.itemID, "alpha-1")
    }

    /// The regression itself: a tick refused because another was already in
    /// flight reports **the other tick's** decision, not a fresh one — and
    /// when that other tick started a run, the refused tick's decision reads
    /// `.start` too. Read as its own by the timer, that `.start` would skip
    /// the sleep and spin the loop for as long as the run the other tick is
    /// awaiting takes, which is exactly what happened on 2026-08-21: the app
    /// sat at 99% CPU with the fleet quiesced. The guard against that is
    /// `taken`, so the refused tick must report `taken == false` even though
    /// its decision says `.start`.
    func testARefusedTickWhoseDecisionIsStartStillReportsThatItDidNotLook() async throws {
        let projectID = try registerProject(named: "alpha",
                                            backlog: "- [ ] alpha-1 | Ship the thing | ready")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        // A run that gets somewhere, so the start really does go all the way
        // through `performStart`'s await — the suspension point the second
        // tick has to land inside for the collision to be real rather than
        // assumed.
        autopilot.stageResultForTesting(
            BacklogAutopilot.ItemResult(id: "alpha-1", title: "Ship the thing",
                                        outcome: .awaitingApproval, duration: 42))
        armForStarting()

        let firstTask = Task { await scheduler.tick() }
        let secondTask = Task { await scheduler.tick() }
        let first = await firstTask.value
        let second = await secondTask.value

        let results = [first, second]
        let taken = results.filter(\.taken)
        let refused = results.filter { !$0.taken }
        XCTAssertEqual(taken.count, 1, "only one tick can actually look")
        XCTAssertEqual(refused.count, 1, "the other collided and did not")
        XCTAssertEqual(taken.first?.decision.target?.itemID, "alpha-1",
                       "the tick that looked is the one that started the run")
        XCTAssertEqual(refused.first?.decision.target?.itemID, "alpha-1",
                       "the refused tick reports the other tick's decision, not its own")
        XCTAssertFalse(refused.first?.taken ?? true,
                       "a decision of .start on a refused tick must not read as having looked")
    }

    // MARK: - Holds

    /// "Nothing is wired to me" and "I'm switched off" are different claims, and
    /// reporting the first as the second would send someone looking at the wrong
    /// switch.
    func testAnUnwiredLoopSaysSoRatherThanReportingItselfOff() async {
        scheduler.enabled = true

        let decision = await scheduler.runTick()

        XCTAssertEqual(decision.hold, .unwired)
        XCTAssertFalse(scheduler.isConfigured)
    }

    func testNoOpenProjectHoldsWithNothingEligible() async {
        scheduler.configure(registry: registry, globalConfigStore: store)
        scheduler.enabled = true

        let decision = await scheduler.runTick()

        XCTAssertEqual(decision.hold, .noEligibleProject)
        XCTAssertTrue(scheduler.startHistory.isEmpty)
    }

    // MARK: - What the arming preview says will run

    /// Three Ready items none of which can start are a project with nothing to
    /// run, and the preview carries the 0 that says so.
    func testArmingPreviewCarriesAStartableCountOfZero() {
        let preview = CoordinatorRunScheduler.ArmingPreview.project(
            threeReady(startable: 0), itemLimit: 3)

        XCTAssertEqual(preview.readyCount, 3)
        XCTAssertEqual(preview.startable, 0)
    }

    func testArmingPreviewCarriesAPartialStartableCountBesideItsTitles() {
        let preview = CoordinatorRunScheduler.ArmingPreview.project(
            threeReady(startable: 1), itemLimit: 3)

        XCTAssertEqual(preview.readyCount, 3)
        XCTAssertEqual(preview.startable, 1)
        XCTAssertEqual(preview.nextItems, ["R1", "R2", "R3"])
    }

    /// A queue nobody measured is not a queue where nothing can start.
    func testArmingPreviewLeavesAnUnmeasuredStartableCountNil() {
        let preview = CoordinatorRunScheduler.ArmingPreview.project(
            threeReady(startable: nil), itemLimit: 2)

        XCTAssertEqual(preview.readyCount, 3)
        XCTAssertNil(preview.startable)
        XCTAssertEqual(preview.nextItems, ["R1", "R2"])
    }

    // MARK: - What the arming popover says under each project

    func testArmingLineSaysOneOfThreeCanStartAboveTheQueueHead() {
        let line = FleetRunControls.armingLine(
            CoordinatorRunScheduler.ArmingPreview.project(threeReady(startable: 1), itemLimit: 3))

        XCTAssertEqual(line, .queue(startable: "1 of 3 ready can start", titles: ["R1", "R2", "R3"]))
    }

    /// Titles nothing will run are not shown as what runs next.
    func testArmingLineWhereNoneCanStartSaysSoAndNamesNoTitles() {
        let line = FleetRunControls.armingLine(
            CoordinatorRunScheduler.ArmingPreview.project(threeReady(startable: 0), itemLimit: 3))

        XCTAssertEqual(line, .noneCanStart(
            "nothing here can start right now (0 of 3 ready) — check the project's queue line"))
    }

    func testArmingLineForAnUnmeasuredQueueShowsTitlesWithNoCount() {
        let line = FleetRunControls.armingLine(
            CoordinatorRunScheduler.ArmingPreview.project(threeReady(startable: nil), itemLimit: 2))

        XCTAssertEqual(line, .queue(startable: nil, titles: ["R1", "R2"]))
    }

    func testArmingLineForAProjectWithNothingReadySaysTheGroomingLoopFeedsIt() {
        let line = FleetRunControls.armingLine(
            .init(name: "alpha", nextItems: [], readyCount: 0, startable: nil))

        XCTAssertEqual(line, .nothingRunnable("nothing runnable right now — the grooming loop feeds it"))
    }

    private func threeReady(startable: Int?) -> PortfolioSnapshot.Project {
        PortfolioSnapshot.project(
            name: "alpha", path: "/tmp/alpha", autopilotReady: true,
            autonomousWorkEnabled: true,
            backlog: BacklogFile(project: "test", repo: nil, verifyDefault: nil, sections: [
                BacklogSection(name: "Epic", items: ["r1", "r2", "r3"].map {
                    BacklogItem(id: $0, title: $0.uppercased(), verify: "true",
                                status: .ready, type: .local, size: .s)
                })
            ]),
            status: .idle, runQueue: [], results: [],
            startable: startable, runnable: startable)
    }

    // MARK: - The budget it is bounded by

    /// The scheduler and `BacklogAutopilot` must read one number, or the gate
    /// here and the gate in `start` would disagree.
    func testReadsThePortfolioCeilingAndTodaysSpend() {
        let ledger = DailySpendLedger(storageURL: tempDir.appendingPathComponent("spend.json"))
        ledger.charge(costUSD: 3)
        store.setDailyBudgetUSD(10)

        scheduler.configure(registry: registry, globalConfigStore: store,
                            spendLedger: ledger)

        XCTAssertEqual(scheduler.dailyBudget.budgetUSD, 10)
        XCTAssertEqual(scheduler.dailyBudget.spentUSD, 3, accuracy: 0.001)
        XCTAssertFalse(scheduler.dailyBudget.isExhausted)
    }

    // MARK: - How a finished run is classified

    func testADoneItemIsASuccess() {
        let outcome = CoordinatorRunScheduler.outcome(itemID: "one", results: [result("one", .done)])

        XCTAssertEqual(outcome.name, "done")
        XCTAssertTrue(outcome.succeeded)
    }

    /// The worker and the reviewer both did their job and a person is the only
    /// thing left — a success of the run, not a failure of it.
    func testAwaitingApprovalIsASuccess() {
        let outcome = CoordinatorRunScheduler.outcome(itemID: "one",
                                                      results: [result("one", .awaitingApproval)])

        XCTAssertEqual(outcome.name, "awaiting-approval")
        XCTAssertTrue(outcome.succeeded)
    }

    func testABlockedItemFailsAndCarriesItsReason() {
        let outcome = CoordinatorRunScheduler.outcome(
            itemID: "one", results: [result("one", .blocked("verify failed"))])

        XCTAssertEqual(outcome.name, "blocked")
        XCTAssertEqual(outcome.detail, "verify failed")
        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(outcome.phrase, "blocked: verify failed")
    }

    /// A start the pickup gates refused leaves no result at all. Counting that
    /// as a failure is the point — a night of them is what the breaker exists
    /// to stop.
    func testARunThatProducedNoResultIsAFailure() {
        let outcome = CoordinatorRunScheduler.outcome(itemID: "one",
                                                      results: [result("other", .done)])

        XCTAssertEqual(outcome.name, "did-not-run")
        XCTAssertFalse(outcome.succeeded)
    }

    /// The item was run once and failed, was targeted again, and the second
    /// start was refused before `resetRunState` could clear the first run's
    /// result. Reading that result as this start's counts one failure twice
    /// toward the breaker — and, when the earlier attempt succeeded, clears a
    /// hold on the strength of a run that already ended.
    func testAStartTheGatesRefusedIsDidNotRunEvenWithAnEarlierResultForTheItem() {
        let outcome = CoordinatorRunScheduler.outcome(
            itemID: "one",
            results: [result("one", .blocked("verify failed"))],
            lastStartOutcome: .init(attempt: 2, refusal: .noRunnableItems,
                                    detail: "item-one: not ready"))

        XCTAssertEqual(outcome.name, "did-not-run")
        XCTAssertEqual(outcome.detail, "item-one: not ready", "and with the gate's own words")
        XCTAssertFalse(outcome.succeeded)
    }

    /// The same for a refusal that is a condition of the moment: still
    /// did-not-run, and still carrying no per-item detail, so `gateRefusals`
    /// remembers nothing about an item nothing was decided about.
    func testARefusalAboutTheMomentIsDidNotRunAndSaysNothingAboutTheItem() {
        let outcome = CoordinatorRunScheduler.outcome(
            itemID: "one",
            results: [result("one", .done)],
            lastStartOutcome: .init(attempt: 2, refusal: .runInFlight, detail: "a run is already going"))

        XCTAssertEqual(outcome.name, "did-not-run")
        XCTAssertNil(outcome.detail)
        XCTAssertFalse(outcome.succeeded)
    }

    /// And the start that was accepted is still read from its result, which is
    /// the whole of the ordinary path.
    func testAnAcceptedStartIsStillClassifiedByItsResult() {
        let outcome = CoordinatorRunScheduler.outcome(
            itemID: "one",
            results: [result("one", .done)],
            lastStartOutcome: .init(attempt: 2, refusal: nil, detail: "1 item queued"))

        XCTAssertEqual(outcome.name, "done")
        XCTAssertTrue(outcome.succeeded)
    }

    /// A refused start is folded as neither a failure nor a success — the rule
    /// `did-not-run` already carries, now reached by the case that used to be
    /// classified from the stale result and counted a second time.
    func testARefusedStartIsFoldedAsNeitherFailureNorSuccess() {
        scheduler.configure(registry: registry, globalConfigStore: store)
        let failed = CoordinatorRunScheduler.Outcome(name: "blocked", detail: "verify failed",
                                                     succeeded: false)
        scheduler.fold(failed, of: target())
        XCTAssertEqual(scheduler.holds.recorded(atPath: "/tmp/alpha")?.failures.count, 1)

        scheduler.fold(CoordinatorRunScheduler.outcome(
            itemID: "alpha-0",
            results: [result("alpha-0", .blocked("verify failed"))],
            lastStartOutcome: .init(attempt: 2, refusal: .noRunnableItems, detail: "alpha-0: not ready")),
                       of: target())

        XCTAssertEqual(scheduler.holds.recorded(atPath: "/tmp/alpha")?.failures.count, 1,
                       "the refused start added no second failure")
        XCTAssertNil(scheduler.holds.hold(atPath: "/tmp/alpha"), "and cleared nothing either")
    }

    private func result(_ id: String,
                        _ outcome: BacklogAutopilot.ItemResult.Outcome) -> BacklogAutopilot.ItemResult {
        BacklogAutopilot.ItemResult(id: id, title: id, outcome: outcome, duration: 1)
    }

    // MARK: - The run record a start leaves

    /// The point of the whole feature: a run nobody asked for over HTTP is still a
    /// run, and it leaves the record every run surface answers from — opened as it
    /// starts and closed by the time the start returns, so nothing is left reading
    /// `running` (or `interrupted`, at the next launch) for work that finished.
    func testAStartWithTheServerAttachedLeavesAClosedRunRecord() async throws {
        let projectID = try registerProject(named: "alpha",
                                            backlog: "- [ ] alpha-1 | Ship the thing | ready")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        // What a finished item leaves behind. Staged rather than run for real: the
        // ending is what a record is written from, and reaching one honestly means
        // a workflow engine and two live agent sessions.
        var landed = BacklogAutopilot.ItemResult(id: "alpha-1", title: "Ship the thing",
                                                outcome: .awaitingApproval, duration: 42)
        landed.branch = "kiteloop/alpha-1"
        landed.pullRequestURL = "https://github.com/acme/kiteloop/pull/42"
        autopilot.stageResultForTesting(landed)
        let records = attachControlServer()
        // The accepted path, driven directly: a tick would refuse alpha-1 at
        // definition-of-ready (no detail file), and a refused start no longer
        // takes a staged result for its own ending.
        let opened = controlServer.openRun(projectID: projectID, itemID: "alpha-1", title: "Ship the thing", startedAt: Date())
        await controlServer.closeRun(opened)
        XCTAssertEqual(records.records.count, 1, "one record per run, opened and closed")
        let record = try XCTUnwrap(records.records.first)
        XCTAssertEqual(record.projectID, projectID)
        XCTAssertEqual(record.itemID, "alpha-1")
        XCTAssertEqual(record.title, "Ship the thing")
        XCTAssertEqual(record.outcome, .awaitingApproval)
        XCTAssertNotNil(record.endedAt, "a run the scheduler has finished awaiting is not still open")
        XCTAssertEqual(record.durationSec, 42)
        // The fields a driver comes back to a finished run for, filled in by the
        // same persist path a control-API run ends through.
        XCTAssertEqual(record.branch, "kiteloop/alpha-1")
        XCTAssertEqual(record.pullRequestURL, "https://github.com/acme/kiteloop/pull/42")
    }

    /// The record survives the process that wrote it, which is the only reason to
    /// write it: the id the night's work is addressed by still answers at the next
    /// launch, with an ending rather than as an interruption.
    func testTheRecordIsReadBackByTheNextLaunchAsFinished() async throws {
        let projectID = try registerProject(named: "alpha",
                                            backlog: "- [ ] alpha-1 | Ship the thing | ready")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        autopilot.stageResultForTesting(
            BacklogAutopilot.ItemResult(id: "alpha-1", title: "Ship the thing",
                                        outcome: .done, duration: 7))
        let records = attachControlServer()
        let runID = controlServer.openRun(projectID: projectID, itemID: "alpha-1", title: "Ship the thing", startedAt: Date())
        await controlServer.closeRun(runID)
        XCTAssertEqual(records.records.first?.runId, runID)

        let reloaded = try XCTUnwrap(RunRecordStore(url: recordsURL).record(runId: runID))
        XCTAssertEqual(reloaded.outcome, .done, "not `interrupted` — this run reached an ending")
        XCTAssertEqual(reloaded.itemID, "alpha-1")
    }

    /// A start that produced no result at all — the pickup gates refused the item,
    /// or no agent session was up — is the case a record is most easily left open
    /// in, since there is no ending to copy. It is closed anyway, and says so —
    /// as `did-not-run` with the gate's own reason, never `blocked`: a refusal
    /// that never reached the item spent nothing and is not a run that got stuck.
    func testAStartThatRecordedNoResultIsStillClosed() async throws {
        try registerProject(named: "alpha", backlog: "- [ ] alpha-1 | Ship the thing | ready")
        let records = attachControlServer()
        armForStarting()

        await scheduler.runTick()

        let record = try XCTUnwrap(records.records.first)
        XCTAssertNotNil(record.endedAt)
        XCTAssertEqual(record.outcome, .didNotRun)
        XCTAssertTrue(record.reason?.contains("alpha-1") ?? false,
                      "the gate's own reason, not the generic fallback text: \(record.reason ?? "-")")
        XCTAssertNotEqual(record.reason, "run ended without a recorded result")
        XCTAssertEqual(scheduler.startHistory.first?.outcome, CoordinatorRunScheduler.StartRecord.didNotRun,
                       "the loop's own account of the same run is unchanged")
    }

    /// Unwired, the loop is exactly what it was: nothing is written where run
    /// records live, and the two records it has always kept are still kept.
    func testWithoutAControlServerNoRunRecordIsWritten() async throws {
        try registerProject(named: "alpha", backlog: "- [ ] alpha-1 | Ship the thing | ready")
        armForStarting()

        await scheduler.runTick()

        XCTAssertFalse(FileManager.default.fileExists(atPath: recordsURL.path(percentEncoded: false)),
                       "an unwired scheduler must not write run records anywhere")
        XCTAssertTrue(RunRecordStore(url: recordsURL).records.isEmpty)
        XCTAssertEqual(scheduler.startHistory.count, 1)
        XCTAssertEqual(scheduler.startHistory.first?.itemID, "alpha-1")
        XCTAssertNotNil(scheduler.startHistory.first?.finishedAt)
        let starts = try String(contentsOf: startsURL, encoding: .utf8)
        XCTAssertTrue(starts.contains("\"item\":\"alpha-1\""), starts)
        XCTAssertTrue(starts.contains("\"event\":\"start\"") && starts.contains("\"event\":\"finish\""), starts)
    }

    // MARK: - The history the durable log is read back into

    /// The point of writing the log at all: the app that ran the night is gone,
    /// and what it ran is still what the scheduler reports.
    func testAFinishedRunIsReadBackFromTheLog() throws {
        let started = logBase
        let finished = started.addingTimeInterval(300)
        try writeLog([
            logLine(at: started, event: "start", outcome: CoordinatorRunScheduler.StartRecord.running),
            logLine(at: finished, event: "finish", outcome: "done")
        ])

        let reloaded = reload(at: finished)

        XCTAssertEqual(reloaded.startHistory.count, 1, "a start and its finish are one run, not two")
        let record = try XCTUnwrap(reloaded.startHistory.first)
        XCTAssertEqual(record.at, started, "the id is built from the start's time, so it has to be the start's")
        XCTAssertEqual(record.finishedAt, finished)
        XCTAssertEqual(record.outcome, "done")
        XCTAssertEqual(record.project, "alpha")
        XCTAssertEqual(record.itemID, "alpha-1")
        XCTAssertEqual(record.itemTitle, "Ship the thing")
        XCTAssertEqual(record.why, "idle 12m, 1 ready")
        XCTAssertEqual(record.budgetText, "$6.40 of $20.00")
    }

    /// A start with no finish belonged to a process that is gone. Reporting it as
    /// `running` would be a claim about something that isn't there — the same
    /// mistake `PersistedRunRecord` avoids by the same name.
    func testAStartWithNoFinishLoadsAsInterrupted() throws {
        try writeLog([logLine(at: logBase, event: "start",
                              outcome: CoordinatorRunScheduler.StartRecord.running)])

        let reloaded = reload(at: logBase.addingTimeInterval(60))

        XCTAssertEqual(reloaded.startHistory.count, 1)
        XCTAssertEqual(reloaded.startHistory.first?.outcome,
                       CoordinatorRunScheduler.StartRecord.interrupted)
        XCTAssertNil(reloaded.startHistory.first?.finishedAt, "nobody watched it end, so there is no end time")
    }

    /// A finish closes the most recent still-open start for its project and item —
    /// the log has no run id, so file order is what pairs them. An item run twice
    /// must not have its second finish land on its first start.
    func testTheSameItemRunTwiceLoadsAsTwoRuns() throws {
        let first = logBase
        let second = first.addingTimeInterval(3_600)
        try writeLog([
            logLine(at: first, event: "start", outcome: CoordinatorRunScheduler.StartRecord.running),
            logLine(at: first.addingTimeInterval(60), event: "finish", outcome: "blocked"),
            logLine(at: second, event: "start", outcome: CoordinatorRunScheduler.StartRecord.running),
            logLine(at: second.addingTimeInterval(60), event: "finish", outcome: "done")
        ])

        let reloaded = reload(at: second.addingTimeInterval(120))

        XCTAssertEqual(reloaded.startHistory.map(\.outcome), ["blocked", "done"],
                       "newest last, and each finish on its own start")
        XCTAssertEqual(reloaded.startHistory.map(\.at), [first, second])
    }

    /// Newest last, as the rest of the app reads it: `remember` appends and the
    /// scheduling endpoint reverses the tail to report newest first.
    func testMoreEntriesThanTheCapLoadTheNewestNewestLast() throws {
        let total = CoordinatorRunScheduler.maxStartHistory + 12
        try writeLog(runLines(count: total))

        let reloaded = reload(at: logBase.addingTimeInterval(Double(total) * 600))

        XCTAssertEqual(reloaded.startHistory.count, CoordinatorRunScheduler.maxStartHistory)
        XCTAssertEqual(reloaded.startHistory.first?.itemID, "alpha-12", "the oldest kept, first")
        XCTAssertEqual(reloaded.startHistory.last?.itemID, "alpha-\(total - 1)", "the newest, last")
    }

    /// A half-written line at the tail is what a killed process leaves. It costs
    /// itself and nothing else — the night around it still reads back.
    func testACorruptLineIsSkippedAndTheRestStillLoads() throws {
        let base = logBase
        try writeLog([
            logLine(at: base, item: "alpha-1", event: "start",
                    outcome: CoordinatorRunScheduler.StartRecord.running),
            logLine(at: base.addingTimeInterval(60), item: "alpha-1", event: "finish", outcome: "done"),
            "{\"at\":\"2026-08-07T02:5",
            "not json at all",
            logLine(at: base.addingTimeInterval(600), item: "alpha-2", event: "start",
                    outcome: CoordinatorRunScheduler.StartRecord.running),
            logLine(at: base.addingTimeInterval(660), item: "alpha-2", event: "finish",
                    outcome: "awaiting-approval")
        ])

        let reloaded = reload(at: base.addingTimeInterval(700))

        XCTAssertEqual(reloaded.startHistory.map(\.itemID), ["alpha-1", "alpha-2"])
        XCTAssertEqual(reloaded.startHistory.map(\.outcome), ["done", "awaiting-approval"])
    }

    /// And it costs itself nothing either: the line the decoder refused is still
    /// in the file after the launch that skipped it, and the launch says how many
    /// it found. Skipping a line at load and then erasing it in the compaction
    /// that follows would delete the damaged history at exactly the moment
    /// somebody wants to look at it.
    func testARefusedLineIsStillInTheLogAfterTheLoadThatSkippedIt() throws {
        let base = logBase
        let refused = "{\"at\":\"2026-08-07T02:5"
        try writeLog([
            logLine(at: base, item: "alpha-1", event: "start",
                    outcome: CoordinatorRunScheduler.StartRecord.running),
            logLine(at: base.addingTimeInterval(60), item: "alpha-1", event: "finish", outcome: "done"),
            refused,
            logLine(at: base.addingTimeInterval(600), item: "alpha-2", event: "start",
                    outcome: CoordinatorRunScheduler.StartRecord.running),
            logLine(at: base.addingTimeInterval(660), item: "alpha-2", event: "finish", outcome: "done")
        ])

        let reloaded = reload(at: base.addingTimeInterval(700))

        XCTAssertEqual(reloaded.startHistory.map(\.itemID), ["alpha-1", "alpha-2"])
        XCTAssertEqual(reloaded.undecodableLineCount, 1)
        XCTAssertTrue(logLines().contains(refused), "the refused line, byte for byte")
    }

    /// The compaction itself, which is what used to delete them: a load that
    /// really does rewrite the file — an expired run to drop — puts the refused
    /// line back, after the runs it kept.
    func testARefusedLineSurvivesACompactionThatRewritesTheLog() throws {
        let now = logBase
        let ancient = now.addingTimeInterval(-CoordinatorRunScheduler.retentionAge - 3_600)
        let recent = now.addingTimeInterval(-600)
        let refused = "not json at all"
        try writeLog([
            logLine(at: ancient, item: "alpha-old", event: "start",
                    outcome: CoordinatorRunScheduler.StartRecord.running),
            logLine(at: ancient.addingTimeInterval(60), item: "alpha-old", event: "finish",
                    outcome: "done"),
            refused,
            logLine(at: recent, item: "alpha-new", event: "start",
                    outcome: CoordinatorRunScheduler.StartRecord.running),
            logLine(at: recent.addingTimeInterval(60), item: "alpha-new", event: "finish",
                    outcome: "done")
        ])

        let reloaded = reload(at: now)

        XCTAssertEqual(reloaded.startHistory.map(\.itemID), ["alpha-new"])
        XCTAssertEqual(reloaded.undecodableLineCount, 1)
        let onDisk = logLines()
        XCTAssertFalse(onDisk.contains(where: { $0.contains("alpha-old") }),
                       "the compaction did run — the expired run is gone")
        XCTAssertEqual(onDisk.last, refused, "and the refused line went back, after the kept runs")
        XCTAssertEqual(onDisk.count, 3, "the surviving run's two lines, then the refused one")

        // And it keeps surviving: a second launch reads it, skips it and leaves
        // it alone rather than eroding the file one launch at a time.
        let again = reload(at: now)
        XCTAssertEqual(again.startHistory.map(\.itemID), ["alpha-new"])
        XCTAssertEqual(again.undecodableLineCount, 1)
        XCTAssertEqual(logLines().last, refused)
    }

    /// Nothing refused, nothing counted — the number is what the load actually
    /// found, not a constant.
    func testALogEveryLineOfWhichDecodesRefusesNothing() throws {
        try writeLog(runLines(count: 3))

        XCTAssertEqual(reload(at: logBase.addingTimeInterval(1_800)).undecodableLineCount, 0)
    }

    /// A line cut part-way through a multi-byte character is not UTF-8, and a
    /// whole-file string read used to fail on it — no history, nothing refused,
    /// and the next compaction erased every start on disk. It costs itself now.
    func testALineEndingMidCharacterCostsOnlyItself() throws {
        let base = logBase
        try writeLogBytes(before: [
            logLine(at: base, item: "alpha-1", event: "start",
                    outcome: CoordinatorRunScheduler.StartRecord.running),
            logLine(at: base.addingTimeInterval(60), item: "alpha-1", event: "finish", outcome: "done")
        ], after: [
            logLine(at: base.addingTimeInterval(600), item: "alpha-2", event: "start",
                    outcome: CoordinatorRunScheduler.StartRecord.running),
            logLine(at: base.addingTimeInterval(660), item: "alpha-2", event: "finish", outcome: "done")
        ])

        let reloaded = reload(at: base.addingTimeInterval(700))

        XCTAssertEqual(reloaded.startHistory.map(\.itemID), ["alpha-1", "alpha-2"])
        XCTAssertEqual(reloaded.startHistory.map(\.outcome), ["done", "done"])
        XCTAssertEqual(reloaded.undecodableLineCount, 1)
    }

    /// And a compaction that follows writes the kept runs back with the damaged
    /// line after them, held as the lossy text it decodes to.
    func testALineEndingMidCharacterSurvivesACompaction() throws {
        let now = logBase
        let ancient = now.addingTimeInterval(-CoordinatorRunScheduler.retentionAge - 3_600)
        let recent = now.addingTimeInterval(-600)
        try writeLogBytes(before: [
            logLine(at: ancient, item: "alpha-old", event: "start",
                    outcome: CoordinatorRunScheduler.StartRecord.running),
            logLine(at: ancient.addingTimeInterval(60), item: "alpha-old", event: "finish",
                    outcome: "done")
        ], after: [
            logLine(at: recent, item: "alpha-new", event: "start",
                    outcome: CoordinatorRunScheduler.StartRecord.running),
            logLine(at: recent.addingTimeInterval(60), item: "alpha-new", event: "finish",
                    outcome: "done")
        ])

        let reloaded = reload(at: now)

        XCTAssertEqual(reloaded.startHistory.map(\.itemID), ["alpha-new"])
        XCTAssertEqual(reloaded.undecodableLineCount, 1)
        let onDisk = logLines()
        XCTAssertFalse(onDisk.contains(where: { $0.contains("alpha-old") }),
                       "the compaction did run — the expired run is gone")
        XCTAssertEqual(onDisk.count, 3, "the surviving run's two lines, then the damaged one")
        XCTAssertTrue(onDisk[0].contains("\"item\":\"alpha-new\""))
        XCTAssertEqual(onDisk.last, "{\"at\":\"caf\u{FFFD}", "the damaged line went back, lossily")
    }

    func testNoLogAtAllLoadsAnEmptyHistory() {
        let reloaded = CoordinatorRunScheduler(logURL: startsURL)

        XCTAssertTrue(reloaded.startHistory.isEmpty)
    }

    /// A start appended after the read-back joins the runs already there rather
    /// than replacing them, and the cap still holds.
    func testALoadedHistoryIsStillAppendedToByANewStart() async throws {
        try writeLog([
            logLine(at: logBase, item: "alpha-0", event: "start",
                    outcome: CoordinatorRunScheduler.StartRecord.running),
            logLine(at: logBase.addingTimeInterval(60), item: "alpha-0", event: "finish",
                    outcome: "done")
        ])
        scheduler = reload(at: logBase.addingTimeInterval(120))
        try registerProject(named: "alpha", backlog: "- [ ] alpha-1 | Ship the thing | ready")
        armForStarting()

        await scheduler.runTick()

        XCTAssertEqual(scheduler.startHistory.map(\.itemID), ["alpha-0", "alpha-1"])
    }

    // MARK: - Compaction's durability

    /// `rewrite` goes through `AtomicFileWriter.write` now, not a bare atomic
    /// `Data.write`. Driven directly rather than through `init`, since that is
    /// what the drop from `private` to internal is for.
    func testRewriteWritesOneStartPerRecordAFinishOnlyWhereThereIsOneAndTheUndecodableLinesTrailing() throws {
        let finished = CoordinatorRunScheduler.StartRecord(
            at: logBase, project: "alpha", itemID: "alpha-1", itemTitle: "Ship the thing",
            why: "idle 12m, 1 ready", budgetText: "$6.40 of $20.00", outcome: "done",
            finishedAt: logBase.addingTimeInterval(60))
        let interrupted = CoordinatorRunScheduler.StartRecord(
            at: logBase.addingTimeInterval(600), project: "alpha", itemID: "alpha-2",
            itemTitle: "Ship the other thing", why: "idle 12m, 1 ready",
            budgetText: "$6.40 of $20.00", outcome: CoordinatorRunScheduler.StartRecord.interrupted,
            finishedAt: nil)
        let refused = "not json at all"

        let landed = CoordinatorRunScheduler.rewrite([finished, interrupted], undecodable: [refused],
                                                      to: startsURL)

        XCTAssertTrue(landed)
        let lines = logLines()
        XCTAssertEqual(lines.count, 4,
                       "two lines for the finished run, one for the interrupted one, one undecodable")
        XCTAssertTrue(lines[0].contains("\"item\":\"alpha-1\"") && lines[0].contains("\"event\":\"start\""))
        XCTAssertTrue(lines[1].contains("\"item\":\"alpha-1\"") && lines[1].contains("\"event\":\"finish\""))
        XCTAssertTrue(lines[2].contains("\"item\":\"alpha-2\"") && lines[2].contains("\"event\":\"start\""),
                      "a record with no finishedAt is written back as a start alone")
        XCTAssertFalse(lines.contains { $0.contains("\"item\":\"alpha-2\"") && $0.contains("\"event\":\"finish\"") })
        XCTAssertEqual(lines.last, refused, "the undecodable line trails the kept records, verbatim")
    }

    /// A destination the write cannot reach — a log URL one component below an
    /// existing regular file — is exactly what `AtomicFileWriter.write` refuses:
    /// it cannot create a directory where a file already sits.
    func testRewriteReportsFalseWhenTheDestinationCannotBeWritten() throws {
        let blocker = tempDir.appendingPathComponent("not-a-directory")
        try "occupied".write(to: blocker, atomically: true, encoding: .utf8)
        let unreachable = blocker.appendingPathComponent("starts.jsonl")
        let record = CoordinatorRunScheduler.StartRecord(
            at: logBase, project: "alpha", itemID: "alpha-1", itemTitle: "Ship the thing",
            why: "idle 12m, 1 ready", budgetText: "$6.40 of $20.00", outcome: "done",
            finishedAt: logBase.addingTimeInterval(60))

        let landed = CoordinatorRunScheduler.rewrite([record], undecodable: [], to: unreachable)

        XCTAssertFalse(landed)
    }

    /// A compaction that fails to land must not stop the app from launching with
    /// the account of the night it did manage to read — only the file on disk is
    /// stale, not the in-memory history the app serves. The log itself has to
    /// stay readable for this: made read-only its *directory* (so the read that
    /// loads it still succeeds) rather than the file, which would make the read
    /// fail instead and never reach a rewrite at all.
    func testInitStillBuildsStartHistoryWhenCompactionCannotLand() throws {
        let ancient = logBase.addingTimeInterval(-CoordinatorRunScheduler.retentionAge - 3_600)
        let recent = logBase.addingTimeInterval(-600)
        try writeLog([
            logLine(at: ancient, item: "alpha-old", event: "start",
                    outcome: CoordinatorRunScheduler.StartRecord.running),
            logLine(at: ancient.addingTimeInterval(60), item: "alpha-old", event: "finish",
                    outcome: "done"),
            logLine(at: recent, item: "alpha-new", event: "start",
                    outcome: CoordinatorRunScheduler.StartRecord.running),
            logLine(at: recent.addingTimeInterval(60), item: "alpha-new", event: "finish",
                    outcome: "done")
        ])
        let directory = startsURL.deletingLastPathComponent().path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory) }

        let reloaded = reload(at: logBase)

        XCTAssertEqual(reloaded.startHistory.map(\.itemID), ["alpha-new"],
                       "the in-memory history is built from what was read, whether or not the rewrite lands")
        let onDisk = try String(contentsOf: startsURL, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("alpha-old"),
                      "the write refused, so the file on disk is untouched — still holding the expired run")
    }

    // MARK: - What the log keeps

    /// A file holding more runs than the count bound loads to the newest ones —
    /// and the ones it dropped are gone from disk, not merely from memory. This
    /// is the whole point: the log used to grow for the life of the install and
    /// be re-read in full at every launch.
    func testMoreRunsThanTheRetentionLimitAreTrimmedFromTheFile() throws {
        let total = CoordinatorRunScheduler.retentionLimit + 5
        try writeLog(runLines(count: total))
        let now = logBase.addingTimeInterval(Double(total) * 600)

        let reloaded = reload(at: now)

        XCTAssertEqual(reloaded.startHistory.count, CoordinatorRunScheduler.maxStartHistory,
                       "the in-memory bound is its own, and smaller than the file's")
        XCTAssertEqual(reloaded.startHistory.last?.itemID, "alpha-\(total - 1)")
        // Two lines per finished run, and only for the runs that survived.
        let onDisk = try String(contentsOf: startsURL, encoding: .utf8)
        XCTAssertEqual(onDisk.split(separator: "\n").count,
                       CoordinatorRunScheduler.retentionLimit * 2)
        XCTAssertFalse(onDisk.contains("\"item\":\"alpha-0\""), "the oldest run is gone from the file")
        XCTAssertTrue(onDisk.contains("\"item\":\"alpha-5\""), "the oldest kept run is the 6th")

        // Reading the trimmed file again yields the same history — the trim is
        // durable, not repeated work at every launch.
        let again = reload(at: now)
        XCTAssertEqual(again.startHistory.map(\.id), reloaded.startHistory.map(\.id))
        XCTAssertEqual(again.startHistory.map(\.outcome), reloaded.startHistory.map(\.outcome))
        XCTAssertEqual(try String(contentsOf: startsURL, encoding: .utf8), onDisk,
                       "a file already inside the bounds is not rewritten again")
    }

    /// The age bound, on a run that is complete and simply old. Its neighbour
    /// inside the bound comes back untouched, finish and all.
    func testARunOlderThanTheAgeBoundIsDroppedFromTheFileAndTheHistory() throws {
        let now = logBase
        let ancient = now.addingTimeInterval(-CoordinatorRunScheduler.retentionAge - 3_600)
        let recent = now.addingTimeInterval(-24 * 60 * 60)
        try writeLog([
            logLine(at: ancient, item: "alpha-old", event: "start",
                    outcome: CoordinatorRunScheduler.StartRecord.running),
            logLine(at: ancient.addingTimeInterval(60), item: "alpha-old", event: "finish",
                    outcome: "done"),
            logLine(at: recent, item: "alpha-new", event: "start",
                    outcome: CoordinatorRunScheduler.StartRecord.running),
            logLine(at: recent.addingTimeInterval(60), item: "alpha-new", event: "finish",
                    outcome: "awaiting-approval")
        ])

        let reloaded = reload(at: now)

        XCTAssertEqual(reloaded.startHistory.map(\.itemID), ["alpha-new"])
        XCTAssertEqual(reloaded.startHistory.first?.outcome, "awaiting-approval")
        XCTAssertEqual(reloaded.startHistory.first?.finishedAt, recent.addingTimeInterval(60))
        let onDisk = try String(contentsOf: startsURL, encoding: .utf8)
        XCTAssertFalse(onDisk.contains("alpha-old"), "an expired run is gone from the file too")
        XCTAssertEqual(onDisk.split(separator: "\n").count, 2, "the surviving run, start and finish")
    }

    /// Compaction must not invent an ending. A start with no finish is written
    /// back as a start alone, so it reads `interrupted` again — and keeps reading
    /// `interrupted` however many times the file is loaded.
    func testAnInterruptedStartSurvivesCompactionAsInterrupted() throws {
        let now = logBase
        let ancient = now.addingTimeInterval(-CoordinatorRunScheduler.retentionAge - 3_600)
        let recent = now.addingTimeInterval(-600)
        try writeLog([
            // Expired, so the load has something to trim and does rewrite.
            logLine(at: ancient, item: "alpha-old", event: "start",
                    outcome: CoordinatorRunScheduler.StartRecord.running),
            logLine(at: ancient.addingTimeInterval(60), item: "alpha-old", event: "finish",
                    outcome: "done"),
            logLine(at: recent, item: "alpha-live", event: "start",
                    outcome: CoordinatorRunScheduler.StartRecord.running)
        ])

        let reloaded = reload(at: now)

        XCTAssertEqual(reloaded.startHistory.map(\.itemID), ["alpha-live"])
        XCTAssertEqual(reloaded.startHistory.first?.outcome,
                       CoordinatorRunScheduler.StartRecord.interrupted)
        let onDisk = try String(contentsOf: startsURL, encoding: .utf8)
        XCTAssertEqual(onDisk.split(separator: "\n").count, 1,
                       "no finish was invented for a run nobody watched end")

        let again = reload(at: now)
        XCTAssertEqual(again.startHistory.first?.outcome,
                       CoordinatorRunScheduler.StartRecord.interrupted)
        XCTAssertNil(again.startHistory.first?.finishedAt)
        XCTAssertEqual(again.startHistory.first?.at, recent, "still identified by when it started")
    }

    /// Nothing to trim, nothing written. A launch that finds a healthy log leaves
    /// the bytes exactly as it found them.
    func testALogInsideBothBoundsIsLeftByteIdentical() throws {
        let base = logBase.addingTimeInterval(-3_600)
        try writeLog([
            logLine(at: base, item: "alpha-1", event: "start",
                    outcome: CoordinatorRunScheduler.StartRecord.running),
            logLine(at: base.addingTimeInterval(60), item: "alpha-1", event: "finish", outcome: "done"),
            logLine(at: base.addingTimeInterval(600), item: "alpha-2", event: "start",
                    outcome: CoordinatorRunScheduler.StartRecord.running)
        ])
        let before = try Data(contentsOf: startsURL)

        let reloaded = reload(at: logBase)

        XCTAssertEqual(reloaded.startHistory.map(\.itemID), ["alpha-1", "alpha-2"])
        XCTAssertEqual(try Data(contentsOf: startsURL), before)
    }

    /// And the run recorded *after* the crash keeps its own line. Appending
    /// straight onto the remnant would glue the two into something that decodes
    /// as neither, so the start written after the crash would be lost from the
    /// only account of what ran unattended — and its finish, arriving with no
    /// start to close, would be dropped too.
    func testARunRecordedAfterATruncatedLineIsReadBackOnTheNextLaunch() async throws {
        let earlier = Date().addingTimeInterval(-3_600)
        try writeLog([
            logLine(at: earlier, item: "alpha-0", event: "start",
                    outcome: CoordinatorRunScheduler.StartRecord.running),
            logLine(at: earlier.addingTimeInterval(60), item: "alpha-0", event: "finish",
                    outcome: "done")
        ])
        // The shape a kill mid-append leaves: half a line, no newline after it.
        try appendRaw("{\"at\":\"2026-08-07T02:5", to: startsURL)
        try registerProject(named: "alpha", backlog: "- [ ] alpha-1 | Ship the thing | ready")
        armForStarting()

        await scheduler.runTick()

        let onDisk = try String(contentsOf: startsURL, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("{\"at\":\"2026-08-07T02:5\n"),
                      "the remnant is still there, on its own line, and still skipped by the loader")
        XCTAssertTrue(onDisk.contains("\"item\":\"alpha-1\""), onDisk)

        let reloaded = CoordinatorRunScheduler(logURL: startsURL, now: Date())
        XCTAssertEqual(reloaded.startHistory.map(\.itemID), ["alpha-0", "alpha-1"],
                       "the run recorded after the crash survives")
        XCTAssertEqual(reloaded.startHistory.last?.finishedAt != nil, true,
                       "and its finish landed on its own start rather than being dropped")
    }

    /// The ordinary append is unchanged by the repair: a log already ending in a
    /// newline gains its lines, not a blank one before them.
    func testAppendingIntoALogEndingInANewlineAddsNoBlankLine() async throws {
        let earlier = Date().addingTimeInterval(-3_600)
        try writeLog([
            logLine(at: earlier, item: "alpha-0", event: "start",
                    outcome: CoordinatorRunScheduler.StartRecord.running),
            logLine(at: earlier.addingTimeInterval(60), item: "alpha-0", event: "finish",
                    outcome: "done")
        ])
        try registerProject(named: "alpha", backlog: "- [ ] alpha-1 | Ship the thing | ready")
        armForStarting()

        await scheduler.runTick()

        let onDisk = try String(contentsOf: startsURL, encoding: .utf8)
        XCTAssertFalse(onDisk.contains("\n\n"), "no blank line between the runs")
        XCTAssertEqual(CoordinatorRunScheduler(logURL: startsURL, now: Date()).startHistory.map(\.itemID),
                       ["alpha-0", "alpha-1"])
    }

    /// The log lives beside the coordinator's other state, in a directory a fresh
    /// install has not created yet.
    func testAppendingIntoADirectoryThatDoesNotExistYetStillLands() async throws {
        let directory = tempDir.appendingPathComponent("nested", isDirectory: true)
        let logURL = directory.appendingPathComponent("starts.jsonl")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
        scheduler = CoordinatorRunScheduler(logURL: logURL)
        try registerProject(named: "alpha", backlog: "- [ ] alpha-1 | Ship the thing | ready")
        armForStarting()

        await scheduler.runTick()

        let onDisk = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(onDisk.hasSuffix("\n"), "the lines are newline-terminated")
        XCTAssertEqual(CoordinatorRunScheduler(logURL: logURL, now: Date()).startHistory.map(\.itemID),
                       ["alpha-1"])
    }

    private func appendRaw(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// The instant a fixture log is read at, and what its lines are dated from.
    /// Fixed so the age bound is exercised deliberately rather than by however
    /// long ago the test was written.
    private let logBase = Date(timeIntervalSince1970: 1_770_000_000)

    private func reload(at now: Date) -> CoordinatorRunScheduler {
        CoordinatorRunScheduler(logURL: startsURL, now: now)
    }

    /// `count` finished runs, ten minutes apart from `logBase`, oldest first.
    private func runLines(count: Int) -> [String] {
        (0..<count).flatMap { index -> [String] in
            let at = logBase.addingTimeInterval(Double(index) * 600)
            return [
                logLine(at: at, item: "alpha-\(index)", event: "start",
                        outcome: CoordinatorRunScheduler.StartRecord.running),
                logLine(at: at.addingTimeInterval(60), item: "alpha-\(index)", event: "finish",
                        outcome: "done")
            ]
        }
    }

    /// Everything the log holds about one run. `finish` carries `finishedAt` in
    /// the `at` field — the writer's own shape, which the loader has to read back.
    private func logLine(at: Date,
                         project: String = "alpha",
                         item: String = "alpha-1",
                         event: String,
                         outcome: String) -> String {
        let formatter = ISO8601DateFormatter()
        return """
        {"at":"\(formatter.string(from: at))","event":"\(event)","project":"\(project)",\
        "item":"\(item)","title":"Ship the thing","why":"idle 12m, 1 ready",\
        "budget":"$6.40 of $20.00","outcome":"\(outcome)"}
        """
    }

    private func writeLog(_ lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: startsURL, atomically: true,
                                                         encoding: .utf8)
    }

    /// `before`, then a line whose bytes stop part-way through "é" (0xC3 0xA9),
    /// then `after` — the shape a kill mid-write leaves, and not UTF-8.
    private func writeLogBytes(before: [String], after: [String]) throws {
        var bytes = Data(before.map { $0 + "\n" }.joined().utf8)
        bytes.append(Data("{\"at\":\"caf".utf8) + [0xC3, UInt8(ascii: "\n")])
        bytes.append(Data(after.map { $0 + "\n" }.joined().utf8))
        try bytes.write(to: startsURL)
    }

    /// What the log holds now, a line at a time — the reader's half of
    /// `writeLog`, so a fixture line can be compared with what came back.
    private func logLines() -> [String] {
        guard let content = try? String(contentsOf: startsURL, encoding: .utf8) else { return [] }
        return content.split(separator: "\n").map(String.init)
    }

    // MARK: - Helpers for a real start

    /// Everything short of the tick itself: the scheduler wired, with its
    /// switch on. `RunScheduling` decides the rest from the portfolio.
    private func armForStarting() {
        scheduler.configure(registry: registry, globalConfigStore: store)
        scheduler.enabled = true
    }

    /// A control server over a temp records file — never `RunRecordStore.shared`,
    /// which is the developer's own history. Its token file is temporary too, so
    /// building one doesn't touch the real credential.
    @discardableResult
    private func attachControlServer() -> RunRecordStore {
        let records = RunRecordStore(url: recordsURL)
        controlServer = KiteloopControlServer(
            registry: registry,
            token: "scheduler-test-token",
            tokenURL: tempDir.appendingPathComponent("control-token"),
            runScheduler: scheduler,
            runRecords: records)
        scheduler.attach(controlServer: controlServer)
        return records
    }

    /// A real `ProjectSession` over a throwaway directory with a worker and a
    /// reviewer assigned — what makes the project `autopilotReady`, and so a
    /// project the scheduler may choose. Returns the canonical project id, which is
    /// what a run record is addressed by.
    @discardableResult
    private func registerProject(named name: String, backlog: String) throws -> String {
        let root = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootURL = URL(fileURLWithPath: root.path(percentEncoded: false), isDirectory: false)
        let project = KiteloopProject(rootURL: rootURL)
        try project.ensureDirectoryExists()

        let eventBus = EventBus(eventsURL: project.eventsURL)
        let orchestrator = Orchestrator(
            runtime: MockAgentRuntime(),
            eventBus: eventBus,
            subscriptionEngine: SubscriptionEngine(eventBus: eventBus),
            memoryManager: MemoryManager(project: project)
        )
        let session = ProjectSession(
            project: project,
            projectURL: rootURL,
            orchestrator: orchestrator,
            sessionStore: SessionStore(projectDir: rootURL),
            knowledgeStore: AgentKnowledgeStore(baseURL: project.knowledgeURL),
            knowledgeIndex: KnowledgeIndex(baseURL: project.knowledgeURL),
            context: makeContext()
        )
        session.backlogViewModel.backlogFile = BacklogParser.parse("## Epic: Work\n\n\(backlog)\n")

        let autopilot = BacklogAutopilot()
        // Wired the way `MainWindow` wires a real one. Without this the autopilot
        // holds no orchestrator and no backlog, so `start` refuses at its very
        // first gate — `.notConfigured` — and never reaches the pickup gates at
        // all. A scheduler test that means to exercise what happens to a *chosen*
        // item would then be watching a run that was refused before the item was
        // ever read, and the run record's reason would describe the harness
        // rather than the backlog.
        autopilot.configure(
            orchestrator: orchestrator,
            backlogViewModel: session.backlogViewModel,
            configURL: project.autopilotConfigURL,
            projectPath: rootURL.path(percentEncoded: false),
            projectName: rootURL.lastPathComponent
        )
        // A grooming ledger in the temp directory — never `GroomingLedger.shared`,
        // which writes `~/.kiteloop/grooming.jsonl`, the developer's own history,
        // for the same reason the control server above gets a temp records file.
        //
        // It matters here only because these tests now reach the pickup gates: an
        // unwired autopilot stopped at `.notConfigured` long before anything
        // recorded a verdict, so the default ledger was never written to and the
        // omission cost nothing. Wiring the autopilot made the gates run, and a
        // suite run duly filed 24 refusals about a project called "alpha" into
        // the real ledger, where they showed up in the app's own Last-24h rollup.
        autopilot.groomingLedger = GroomingLedger(
            url: tempDir.appendingPathComponent("grooming.jsonl"))
        autopilot.workerAgentID = "worker"
        autopilot.autonomousWorkEnabled = true
        autopilot.reviewerAgentID = "reviewer"
        registry.register(session: session, autopilot: autopilot)
        return session.project.id
    }

    /// Every store points into the temp directory, so no test reads or writes the
    /// developer's real config.
    private func makeContext() -> ProjectSessionContext {
        ProjectSessionContext(
            runtimeFactory: { MockAgentRuntime() },
            agentCatalogStore: AgentCatalogStore(storageURL: tempDir.appendingPathComponent("catalog.json")),
            packageResolver: nil,
            globalConfigStore: GlobalConfigStore(storageURL: tempDir.appendingPathComponent("global.json")),
            orgManifestLoader: OrgManifestLoader(),
            repoCloneService: RepoCloneService()
        )
    }
}
