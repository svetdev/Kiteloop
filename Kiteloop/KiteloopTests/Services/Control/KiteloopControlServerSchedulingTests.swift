import XCTest
@testable import Kiteloop

/// `GET`/`PUT /v1/coordinator/scheduling` — the autonomous run scheduler's kill
/// switch, its per-project holds, and the record of what it started.
///
/// The properties worth covering are the ones a night depends on: the shipped
/// state is off, turning it on is explicit and persisted, turning it off is a
/// single call that reaches the loop, and a caller can read back what the loop
/// has been doing rather than guessing from an empty screen.
///
/// Exercised over a real loopback socket, like the other control-API tests.
@MainActor
final class KiteloopControlServerSchedulingTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var globalConfigStore: GlobalConfigStore!
    private var queueRefill: CoordinatorQueueRefill!
    private var scheduler: CoordinatorRunScheduler!
    private var harness: ControlServerHarness!
    /// Extra servers a test started (e.g. one with no scheduler), stopped in teardown.
    private var extraHarnesses: [ControlServerHarness] = []
    private let token = "control-scheduling-token-" + UUID().uuidString

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-scheduling")
        registry = ControlSessionRegistry()
        // Every store points at the temp directory so a test never reads or
        // writes the developer's real ~/.kiteloop.
        globalConfigStore = GlobalConfigStore(storageURL: tempDir.appendingPathComponent("global.json"))
        queueRefill = CoordinatorQueueRefill(ledgerURL: tempDir.appendingPathComponent("refill.jsonl"))
        scheduler = CoordinatorRunScheduler(logURL: tempDir.appendingPathComponent("starts.jsonl"))
        scheduler.configure(registry: registry, globalConfigStore: globalConfigStore)
        harness = try await startServer(scheduler: scheduler)
    }

    override func tearDown() async throws {
        harness?.stop()
        extraHarnesses.forEach { $0.stop() }
        extraHarnesses = []
        harness = nil
        scheduler?.stop()
        scheduler = nil
        queueRefill?.stop()
        queueRefill = nil
        registry = nil
        globalConfigStore = nil
    }

    // MARK: - Reading

    /// What a fresh install reports. Off, nothing held, nothing started — and
    /// the endpoint must not dress that up as anything else.
    func testReportsTheShippedDefaults() async throws {
        let (status, body) = try await harness.get("/v1/coordinator/scheduling")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["enabled"] as? Bool, false)
        XCTAssertNil(body["mode"], "advisory mode retired — the reply no longer claims one")
        XCTAssertEqual(body["startInFlight"] as? Bool, false)
        XCTAssertEqual((body["breaker"] as? [String: Any])?["open"] as? Bool, false)
        XCTAssertEqual(body["count"] as? Int, 0)
        XCTAssertEqual((body["starts"] as? [Any])?.count, 0)
        XCTAssertNil(body["proposal"], "the scheduler never proposes — it starts or holds")
    }

    /// The budget the loop is bounded by is the portfolio-wide one, so a driver
    /// can tell "quiet because the day is spent" from "quiet because it's off".
    func testReportsTheDaysBudget() async throws {
        globalConfigStore.setDailyBudgetUSD(15)

        let (status, body) = try await harness.get("/v1/coordinator/scheduling")

        XCTAssertEqual(status, 200)
        let budget = try XCTUnwrap(body["budget"] as? [String: Any])
        XCTAssertEqual(budget["budgetUSD"] as? Double, 15)
        XCTAssertEqual(budget["exhausted"] as? Bool, false)
    }

    /// A hold is state a human may have to clear, so its reason has to be
    /// readable without opening the app — and it has to say which project,
    /// because it is no longer a claim about the fleet.
    func testReportsAHeldProjectAndItsReason() async throws {
        holdAProject()

        let (status, body) = try await harness.get("/v1/coordinator/scheduling")

        XCTAssertEqual(status, 200)
        let breaker = try XCTUnwrap(body["breaker"] as? [String: Any])
        XCTAssertEqual(breaker["open"] as? Bool, true)
        XCTAssertTrue((breaker["reason"] as? String)?.contains("alpha-0") ?? false)
        let holds = try XCTUnwrap(breaker["holds"] as? [[String: Any]])
        XCTAssertEqual(holds.count, 1)
        XCTAssertEqual(holds.first?["project"] as? String, "alpha")
        XCTAssertEqual(holds.first?["failures"] as? Int, RetryCeiling.limit)
        XCTAssertEqual(holds.first?["systemic"] as? Bool, false)
    }

    /// `/health` is unauthenticated and is what a watcher polls. Until now a
    /// held fleet was visible only on the sidebar of a window nobody was in
    /// front of.
    func testHealthListsActiveHoldsAndIsEmptyWithoutThem() async throws {
        let (_, before) = try await harness.get("/health", bearer: nil)
        XCTAssertEqual((before["holds"] as? [Any])?.count, 0,
                       "an unheld fleet says so rather than omitting the field")

        holdAProject()

        let (status, body) = try await harness.get("/health", bearer: nil)
        XCTAssertEqual(status, 200)
        let holds = try XCTUnwrap(body["holds"] as? [[String: Any]])
        XCTAssertEqual(holds.count, 1)
        XCTAssertEqual(holds.first?["project"] as? String, "alpha")
        XCTAssertTrue((holds.first?["reason"] as? String)?.contains("alpha-0") ?? false)
    }

    // MARK: - Writing

    /// The switch reaches the loop *and* the config file — a driver that turned
    /// it on has turned it on for the next launch too.
    func testEnablingReachesTheLoopAndIsPersisted() async throws {
        let (status, body) = try await harness.put("/v1/coordinator/scheduling",
                                           ["enabled": true, "dailyBudgetUSD": 100])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["enabled"] as? Bool, true)
        XCTAssertTrue(scheduler.enabled)
        XCTAssertEqual(globalConfigStore.config.coordinatorSchedulingEnabled, true)
    }

    /// The kill switch: one call, and the timer is gone rather than left to wake
    /// up and refuse.
    func testDisablingStopsTheTimer() async throws {
        scheduler.start()
        _ = try await harness.put("/v1/coordinator/scheduling", ["enabled": true, "dailyBudgetUSD": 100])
        XCTAssertTrue(scheduler.isTimerRunning)

        let (status, body) = try await harness.put("/v1/coordinator/scheduling",
                                           ["enabled": false])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["enabled"] as? Bool, false)
        XCTAssertFalse(scheduler.isTimerRunning)
    }

    func testResetBreakerClearsEveryHold() async throws {
        holdAProject()

        let (status, body) = try await harness.put("/v1/coordinator/scheduling",
                                           ["resetBreaker": true])

        XCTAssertEqual(status, 200)
        XCTAssertEqual((body["breaker"] as? [String: Any])?["open"] as? Bool, false)
        XCTAssertTrue(scheduler.holds.isEmpty)
    }

    func testAnEmptyBodyChangesNothing() async throws {
        _ = try await harness.put("/v1/coordinator/scheduling", ["enabled": true, "dailyBudgetUSD": 100])
        globalConfigStore.setDailyBudgetUSD(30)

        let (status, body) = try await harness.put("/v1/coordinator/scheduling", [:])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["enabled"] as? Bool, true)
        XCTAssertEqual((body["budget"] as? [String: Any])?["budgetUSD"] as? Double, 30,
                       "an omitted ceiling is left alone, not cleared")
        XCTAssertEqual(globalConfigStore.config.dailyBudgetUSD, 30)
    }

    // MARK: - The portfolio ceiling

    /// The reason this field exists: until now no control-API route set a budget
    /// of any kind, so raising the portfolio ceiling meant stopping the app and
    /// hand-editing global-config.json. It reaches the store *and* reads back on
    /// the same response.
    func testSettingThePortfolioBudgetReachesTheStoreAndIsPersisted() async throws {
        let (status, body) = try await harness.put("/v1/coordinator/scheduling",
                                           ["dailyBudgetUSD": 150])

        XCTAssertEqual(status, 200)
        XCTAssertEqual((body["budget"] as? [String: Any])?["budgetUSD"] as? Double, 150)
        XCTAssertEqual(globalConfigStore.config.dailyBudgetUSD, 150)
        XCTAssertEqual(scheduler.portfolioDailyBudgetUSD, 150)

        // Persisted, so the next launch is bounded by the same number.
        let saved = try JSONSerialization.jsonObject(
            with: Data(contentsOf: tempDir.appendingPathComponent("global.json"))
        ) as? [String: Any] ?? [:]
        XCTAssertEqual(saved["dailyBudgetUSD"] as? Double, 150)
    }

    /// Explicit null is how a driver removes the ceiling — distinct from omitting
    /// the field, which leaves it alone.
    func testNullClearsThePortfolioBudget() async throws {
        globalConfigStore.setDailyBudgetUSD(20)

        let (status, body) = try await harness.put("/v1/coordinator/scheduling",
                                           ["dailyBudgetUSD": NSNull()])

        XCTAssertEqual(status, 200)
        XCTAssertTrue((body["budget"] as? [String: Any])?["budgetUSD"] is NSNull)
        XCTAssertNil(globalConfigStore.config.dailyBudgetUSD)
        XCTAssertFalse(scheduler.dailyBudget.isExhausted, "no ceiling is not a spent one")
    }

    /// Validated rather than coerced. A ceiling that read a typo as "unbounded"
    /// would silently disable the one thing bounding an unattended night, so junk
    /// is a 400 and the previous ceiling stands.
    func testRejectsANonPositiveOrNonNumericPortfolioBudget() async throws {
        globalConfigStore.setDailyBudgetUSD(40)

        for raw: Any in ["150", 0, -1, true, [String: Any]()] {
            let (status, body) = try await harness.put("/v1/coordinator/scheduling",
                                               ["dailyBudgetUSD": raw])

            XCTAssertEqual(status, 400, "dailyBudgetUSD=\(raw)")
            XCTAssertEqual(body["error"] as? String,
                           "\"dailyBudgetUSD\" must be a positive number or null")
            XCTAssertEqual(globalConfigStore.config.dailyBudgetUSD, 40,
                           "a rejected body changes nothing")
        }
    }

    /// A $1 ceiling is a real ceiling. Worth its own test because JSON hands
    /// booleans and numbers back as the same NSNumber type, and the obvious way
    /// to reject `true` also rejects `1`.
    func testAOneDollarBudgetIsAcceptedEvenThoughBooleansAreNot() async throws {
        let (accepted, body) = try await harness.put("/v1/coordinator/scheduling",
                                             ["dailyBudgetUSD": 1])
        XCTAssertEqual(accepted, 200)
        XCTAssertEqual((body["budget"] as? [String: Any])?["budgetUSD"] as? Double, 1)
        XCTAssertEqual(globalConfigStore.config.dailyBudgetUSD, 1)

        let (rejected, _) = try await harness.put("/v1/coordinator/scheduling",
                                          ["dailyBudgetUSD": true])
        XCTAssertEqual(rejected, 400)
        XCTAssertEqual(globalConfigStore.config.dailyBudgetUSD, 1,
                       "`true` must not be read as the $1 ceiling it bridges to")
    }

    /// The ceiling is written before the switch, so one call can raise the budget
    /// and switch the loop back on — the recovery a headless operator needs after
    /// a night that stopped on an exhausted day.
    /// How many runs at once is a setting on the same endpoint: reported,
    /// written, persisted, and refused outside its range.
    func testRunsAtOnceIsReportedWrittenAndBounded() async throws {
        let (_, before) = try await harness.get("/v1/coordinator/scheduling")
        XCTAssertEqual(before["maxConcurrentRuns"] as? Int, 1)
        XCTAssertEqual(before["startsInFlight"] as? Int, 0)

        let (status, body) = try await harness.put("/v1/coordinator/scheduling", ["maxConcurrentRuns": 3])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["maxConcurrentRuns"] as? Int, 3)
        XCTAssertEqual(scheduler.maxConcurrentRuns, 3)
        XCTAssertEqual(globalConfigStore.config.maxConcurrentRuns, 3)

        let (refused, _) = try await harness.put("/v1/coordinator/scheduling", ["maxConcurrentRuns": 0])
        XCTAssertEqual(refused, 400)
        XCTAssertEqual(scheduler.maxConcurrentRuns, 3, "a refused body changes nothing")
    }

    func testOneCallCanRaiseTheBudgetAndSwitchTheLoopOn() async throws {
        globalConfigStore.setDailyBudgetUSD(10)

        let (status, body) = try await harness.put("/v1/coordinator/scheduling",
                                           ["dailyBudgetUSD": 200, "enabled": true])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["enabled"] as? Bool, true)
        XCTAssertEqual((body["budget"] as? [String: Any])?["budgetUSD"] as? Double, 200)
        XCTAssertTrue(scheduler.enabled)
    }

    /// A rejected ceiling must not leave the switch flipped: the whole body is
    /// refused, not the half of it that parsed.
    func testARejectedBudgetLeavesTheSwitchAlone() async throws {
        let (status, _) = try await harness.put("/v1/coordinator/scheduling",
                                        ["dailyBudgetUSD": -5, "enabled": true])

        XCTAssertEqual(status, 400)
        XCTAssertFalse(scheduler.enabled, "the switch is written after the ceiling, so it never ran")
    }

    /// The portfolio ceiling is the global one — setting it is not a way to
    /// reach into a project's own budget, and vice versa.
    func testThePortfolioBudgetIsNotAProjectSetting() async throws {
        _ = try await harness.put("/v1/coordinator/scheduling", ["dailyBudgetUSD": 99])

        XCTAssertEqual(globalConfigStore.config.dailyBudgetUSD, 99)
        XCTAssertTrue(scheduler.projectDailyBudgets.isEmpty,
                      "no project gained a ceiling of its own from the portfolio write")
    }

    /// A write needs the token like every other one, and a rejected write must
    /// not have changed the ceiling on its way to the 401.
    func testSettingTheBudgetRequiresBearerToken() async throws {
        globalConfigStore.setDailyBudgetUSD(40)

        let (status, _) = try await harness.put("/v1/coordinator/scheduling",
                                        ["dailyBudgetUSD": 500], bearer: nil)

        XCTAssertEqual(status, 401)
        XCTAssertEqual(globalConfigStore.config.dailyBudgetUSD, 40)
    }

    // MARK: - Rejections

    func testRejectsANonBooleanSwitch() async throws {
        let (status, body) = try await harness.put("/v1/coordinator/scheduling",
                                           ["enabled": "yes"])

        XCTAssertEqual(status, 400)
        XCTAssertEqual(body["error"] as? String, "\"enabled\" must be true or false")
        XCTAssertFalse(scheduler.enabled)
    }

    func testRejectsANonBooleanBreakerReset() async throws {
        holdAProject()

        let (status, body) = try await harness.put("/v1/coordinator/scheduling",
                                           ["resetBreaker": 1])

        XCTAssertEqual(status, 400)
        XCTAssertEqual(body["error"] as? String, "\"resetBreaker\" must be true or false")
        XCTAssertFalse(scheduler.holds.isEmpty,
                      "`1` is not a boolean, and must not have cleared the latch on its way to the 400")
    }

    /// The kill switch has the same hole as the reset: JSON hands a boolean and
    /// a number back as the same `NSNumber`, and `as? Bool` accepts both, so
    /// `{"enabled": 0}` switched an unattended loop off — or `1` on — through a
    /// validator that claims to take only `true` or `false`.
    func testRejectsANumericSwitch() async throws {
        for raw: Any in [1, 0] {
            let (status, body) = try await harness.put("/v1/coordinator/scheduling",
                                               ["enabled": raw])

            XCTAssertEqual(status, 400, "enabled=\(raw)")
            XCTAssertEqual(body["error"] as? String, "\"enabled\" must be true or false")
            XCTAssertFalse(scheduler.enabled, "a rejected body changes nothing")
        }
    }

    /// A rejected switch must not have cleared the holds either: both fields are
    /// read before either is applied, so the body is refused whole.
    func testARejectedSwitchLeavesTheHoldsInPlace() async throws {
        holdAProject()

        let (status, _) = try await harness.put("/v1/coordinator/scheduling",
                                        ["resetBreaker": true, "enabled": 1])

        XCTAssertEqual(status, 400)
        XCTAssertFalse(scheduler.holds.isEmpty)
    }

    /// With no scheduler attached there is nothing to switch — say so, rather
    /// than reporting settings that would go nowhere.
    func testUnavailableWhenNoSchedulerIsAttached() async throws {
        let detached = try await startServer(scheduler: nil)
        extraHarnesses.append(detached)

        let (status, body) = try await detached.get("/v1/coordinator/scheduling")

        XCTAssertEqual(status, 503)
        XCTAssertEqual(body["error"] as? String,
                       "Run scheduling is unavailable — no scheduler attached")
    }

    func testRequiresBearerToken() async throws {
        let (status, body) = try await harness.get("/v1/coordinator/scheduling", bearer: nil)

        XCTAssertEqual(status, 401)
        XCTAssertEqual(body["error"] as? String, "Missing or invalid bearer token")
    }

    // MARK: - The same records the drawer shows

    /// The endpoint and the Coordinator drawer report one account of the night,
    /// not two readings of it: `CoordinatorStartsModel` rearranges the same
    /// `startHistory` this endpoint serves, so for a given moment the two must
    /// agree on which runs there were, in which order, and what each said.
    ///
    /// Driven over the real socket against a scheduler seeded from a log, so what
    /// is compared is the shipped endpoint's own JSON rather than a restatement
    /// of it — a second derivation creeping into either side fails here.
    func testTheDrawerSectionMatchesWhatTheEndpointServes() async throws {
        let logURL = tempDir.appendingPathComponent("matching-starts.jsonl")
        let base = Date(timeIntervalSince1970: 1_786_000_000)
        try [
            startLine(at: base, item: "alpha-1", event: "start",
                      outcome: CoordinatorRunScheduler.StartRecord.running),
            startLine(at: base.addingTimeInterval(300), item: "alpha-1", event: "finish",
                      outcome: "done"),
            // A refusal and an interrupted run: the two outcomes the drawer says
            // more about than the bare word, and so the two most likely to drift.
            startLine(at: base.addingTimeInterval(600), item: "alpha-2", event: "start",
                      outcome: CoordinatorRunScheduler.StartRecord.running),
            startLine(at: base.addingTimeInterval(660), item: "alpha-2", event: "finish",
                      outcome: CoordinatorRunScheduler.StartRecord.didNotRun),
            startLine(at: base.addingTimeInterval(900), item: "alpha-3", event: "start",
                      outcome: CoordinatorRunScheduler.StartRecord.running)
        ].joined(separator: "\n").appending("\n")
            .write(to: logURL, atomically: true, encoding: .utf8)

        let seeded = CoordinatorRunScheduler(logURL: logURL, now: base.addingTimeInterval(1_200))
        seeded.configure(registry: registry, globalConfigStore: globalConfigStore)
        let hosted = try await startServer(scheduler: seeded)
        extraHarnesses.append(hosted)

        let (status, body) = try await hosted.get("/v1/coordinator/scheduling")
        let section = try XCTUnwrap(CoordinatorStartsModel.capture(seeded))
        let served = try XCTUnwrap(body["starts"] as? [[String: Any]])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(section.rows.items.count, served.count,
                       "the drawer's bound is above three runs, so both list all of them")
        XCTAssertEqual(section.rows.items.map(\.itemID), served.compactMap { $0["item"] as? String },
                       "newest first on both sides")
        XCTAssertEqual(section.rows.items.map(\.outcome),
                       served.compactMap { $0["outcome"] as? String })
        XCTAssertEqual(section.rows.items.map(\.project),
                       served.compactMap { $0["project"] as? String })
        XCTAssertEqual(section.rows.items.map(\.why), served.compactMap { $0["why"] as? String })
        XCTAssertEqual(section.rows.items.map(\.budgetText),
                       served.compactMap { $0["budget"] as? String })
        XCTAssertEqual(section.rows.items.map(\.itemTitle),
                       served.compactMap { $0["title"] as? String })
    }

    // MARK: - Helpers

    /// One line of `coordinator-starts.jsonl`, in the shape
    /// `CoordinatorRunScheduler` writes it — a `finish` carries `finishedAt` in
    /// the `at` field.
    private func startLine(at: Date, item: String, event: String, outcome: String) -> String {
        let formatter = ISO8601DateFormatter()
        return """
        {"at":"\(formatter.string(from: at))","event":"\(event)","project":"alpha",\
        "item":"\(item)","title":"Ship \(item)","why":"idle 5m, 2 ready",\
        "budget":"$6.40 of $20.00","outcome":"\(outcome)"}
        """
    }

    /// Fold enough failed runs into one project to hold it, the way the loop
    /// does — `RetryCeiling.limit` of them, which is the bound the ordinary
    /// hold borrows rather than restating.
    private func holdAProject() {
        let failed = CoordinatorRunScheduler.Outcome(name: "blocked", detail: "verify failed",
                                                     succeeded: false)
        let target = RunScheduling.Target(project: "alpha", path: "/tmp/alpha", itemID: "alpha-0",
                                          itemTitle: "Item", readyCount: 1, reason: "idle 12m, 1 ready")
        for _ in 0..<RetryCeiling.limit { scheduler.fold(failed, of: target) }
    }

    /// The port is picked at random and probed, since NWListener reports a bind
    /// conflict asynchronously rather than throwing from start().
    private func startServer(scheduler: CoordinatorRunScheduler?) async throws -> ControlServerHarness {
        try await ControlServerHarness.start(token: token) {
            KiteloopControlServer(registry: registry, token: $0,
                                  queueRefill: queueRefill, runScheduler: scheduler)
        }
    }


    /// Arming is gated on the ceiling it will spend against: `enabled: true`
    /// with no running budget anywhere is refused, naming the budget — and the
    /// same call carrying the budget arms. Disarming never needs one.
    func testArmingWithoutABudgetIsRefusedNamingIt() async throws {
        let (status, body) = try await harness.put("/v1/coordinator/scheduling",
                                           ["enabled": true])
        XCTAssertEqual(status, 422)
        XCTAssertEqual((body["error"] as? String)?.contains("daily autonomy budget"), true)
        XCTAssertFalse(scheduler.enabled, "a refused arming must not arm")

        let (armed, _) = try await harness.put("/v1/coordinator/scheduling",
                                       ["enabled": true, "dailyBudgetUSD": 150])
        XCTAssertEqual(armed, 200)
        XCTAssertTrue(scheduler.enabled)

        let (disarmed, _) = try await harness.put("/v1/coordinator/scheduling",
                                          ["enabled": false])
        XCTAssertEqual(disarmed, 200)
        XCTAssertFalse(scheduler.enabled, "the way out is never gated")
    }
}
