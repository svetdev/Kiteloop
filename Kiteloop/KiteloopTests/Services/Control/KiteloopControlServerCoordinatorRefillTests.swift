import XCTest
@testable import Kiteloop

/// `GET`/`PUT /v1/coordinator/refill` — the switch and the day's
/// grooming ceiling for the queue-refill loop. Before these endpoints the loop
/// was constructed and started with no way to turn it on; the property worth
/// covering here is that the way to turn it on is *explicit*, and that the
/// defaults a caller gets by sending nothing are off and advisory.
///
/// Exercised over a real loopback socket, like the other control-API tests.
@MainActor
final class KiteloopControlServerCoordinatorRefillTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var globalConfigStore: GlobalConfigStore!
    private var queueRefill: CoordinatorQueueRefill!
    private var harness: ControlServerHarness!
    /// Extra servers a test started (e.g. one with no loop attached), stopped in teardown.
    private var extraServers: [ControlServerHarness] = []
    private let token = "control-refill-token-" + UUID().uuidString

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-refill")
        registry = ControlSessionRegistry()
        // Every store points at the temp directory so a test never reads or
        // writes the developer's real ~/.kiteloop.
        globalConfigStore = GlobalConfigStore(storageURL: tempDir.appendingPathComponent("global.json"))
        queueRefill = CoordinatorQueueRefill(ledgerURL: tempDir.appendingPathComponent("refill.jsonl"))
        queueRefill.configure(registry: registry,
                              globalConfigStore: globalConfigStore,
                              runtimeFactory: { MockAgentRuntime() })
        harness = try await startServer(queueRefill: queueRefill)
    }

    override func tearDown() async throws {
        harness?.stop()
        extraServers.forEach { $0.stop() }
        extraServers = []
        harness = nil
        queueRefill?.stop()
        queueRefill = nil
        registry = nil
        globalConfigStore = nil
    }

    // MARK: - Reading

    /// What a fresh install reports. Off is the shipped state, and the
    /// endpoint must not dress it up as anything else.
    func testReportsTheShippedDefaults() async throws {
        let (status, body) = try await harness.get("/v1/coordinator/refill")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["enabled"] as? Bool, false)
        XCTAssertNil(body["mode"], "advisory mode retired — the reply no longer claims one")
        // The read side reports the cap nested under `budget` alongside what has
        // been spent against it — `dailyBudgetUSD` is the write side's flat name
        // for the same number, and asserting it here passed only for as long as
        // this file went uncompiled.
        XCTAssertTrue((body["budget"] as? [String: Any])?["capUSD"] is NSNull)
    }

    func testReadsBackWhatWasSet() async throws {
        _ = try await harness.put("/v1/coordinator/refill",
                                  ["enabled": true, "dailyBudgetUSD": 12.5])

        let (status, body) = try await harness.get("/v1/coordinator/refill")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["enabled"] as? Bool, true)
        XCTAssertEqual((body["budget"] as? [String: Any])?["capUSD"] as? Double, 12.5)
    }

    /// An idle loop says so with more than a bare `false`. The flag on its own
    /// was the whole answer once, and on 2026-08-12 it read `true` for 2h22m
    /// beside a budget and a pass count that were both truthfully healthy —
    /// nothing in this reply could be compared against anything, so nothing in
    /// it said grooming had stopped.
    func testAnIdleLoopReportsNoPassAndNoStall() async throws {
        let (status, body) = try await harness.get("/v1/coordinator/refill")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["passInFlight"] as? Bool, false)
        XCTAssertTrue(body["passInFlightSince"] is NSNull)
        XCTAssertTrue(body["passStage"] is NSNull)
        XCTAssertEqual(body["passStalled"] as? Bool, false)
        XCTAssertEqual(body["passDeadlineSeconds"] as? Int,
                       Int(CoordinatorQueueRefill.Defaults.passDeadline))
        // Zero rather than absent: `passStalled` above is a right-now reading
        // and goes back to false the moment a stuck pass is ended, so this is
        // the one field that can say a night hung and recovered.
        XCTAssertEqual((body["budget"] as? [String: Any])?["abandonedPasses"] as? Int, 0)
    }

    /// The count reaches the reply, beside the passes and the spend rather than
    /// folded into them — a driver watching this endpoint overnight could not
    /// otherwise tell a loop that hung four times and self-healed from one that
    /// never hung at all.
    func testTheDaysAbandonedPassesAreReportedBesideThePassesUsed() async throws {
        // A night that spent 20 passes and lost 3 of them to stalls it
        // recovered from, beside ceilings neither of which came near stopping
        // anything — which is exactly how 2026-08-12 read.
        let stalled = CoordinatorQueueRefill(
            ledgerURL: tempDir.appendingPathComponent("stalled.jsonl"),
            budget: QueueRefill.Budget(spentUSD: 52.59, capUSD: 350, passes: 20,
                                       maxPasses: 150, abandonedPasses: 3))
        stalled.configure(registry: registry, globalConfigStore: globalConfigStore,
                          runtimeFactory: { MockAgentRuntime() })
        let detached = try await startServer(queueRefill: stalled)
        extraServers.append(detached)

        let (status, body) = try await detached.get("/v1/coordinator/refill")

        XCTAssertEqual(status, 200)
        let reported = try XCTUnwrap(body["budget"] as? [String: Any])
        XCTAssertEqual(reported["abandonedPasses"] as? Int, 3)
        XCTAssertEqual(reported["passesUsed"] as? Int, 20,
                       "counted beside the passes spent, never folded into them")
        XCTAssertEqual(body["passStalled"] as? Bool, false,
                       "the loop recovered — which is why the count has to say so instead")
    }

    /// The reply is read off what is on record, so a driver polling this
    /// endpoint overnight sees the day rather than the process that happens to
    /// be answering. It used to see neither: the figures lived in a property,
    /// so a relaunch reported `passesUsed: 0` and an empty `passes` list for a
    /// day that had groomed all morning.
    func testTheDaysRecordedPassesAreReportedByARelaunchedLoop() async throws {
        let passes = tempDir.appendingPathComponent("coordinator-passes.jsonl")
        let now = Date()
        // Written the way a pass writes them, through the ledger's own encoder —
        // a hand-rolled line would prove the test could spell JSON, not that the
        // loop can read back what it wrote.
        for entry in [
            CoordinatorQueueRefill.PassLedger.Entry(at: now, event: .passStarted, project: "alpha"),
            .init(at: now, event: .spend, costUSD: 4.37),
            .init(at: now, event: .outcome, project: "alpha",
                  outcome: .filed(project: "alpha", ready: 2, drafts: 1, refused: 0)),
            .init(at: now, event: .passStarted, project: "alpha"),
            .init(at: now, event: .outcome, project: "alpha",
                  outcome: .abandoned(project: "alpha", stage: .drafting,
                                      ranFor: 900, why: .deadline))
        ] {
            CoordinatorQueueRefill.PassLedger.append(entry, to: passes)
        }

        let relaunched = CoordinatorQueueRefill(
            ledgerURL: tempDir.appendingPathComponent("relaunched.jsonl"),
            passLedgerURL: passes,
            budget: QueueRefill.Budget(capUSD: 350, maxPasses: 12))
        relaunched.configure(registry: registry, globalConfigStore: globalConfigStore,
                             runtimeFactory: { MockAgentRuntime() })
        defer { relaunched.stop() }
        let detached = try await startServer(queueRefill: relaunched)
        extraServers.append(detached)

        let (status, body) = try await detached.get("/v1/coordinator/refill")

        XCTAssertEqual(status, 200)
        let reported = try XCTUnwrap(body["budget"] as? [String: Any])
        XCTAssertEqual(reported["passesUsed"] as? Int, 2)
        XCTAssertEqual(try XCTUnwrap(reported["spentUSD"] as? Double), 4.37, accuracy: 0.0001)
        XCTAssertEqual(reported["abandonedPasses"] as? Int, 1)

        // And the passes themselves, newest first, with the counts a `filed`
        // pass carries — which is what a tag-only record could not have said.
        let recent = try XCTUnwrap(body["passes"] as? [[String: Any]])
        XCTAssertEqual(recent.map { $0["outcome"] as? String }, ["abandoned", "filed"])
        XCTAssertEqual(recent.last?["ready"] as? Int, 2)
        XCTAssertEqual(recent.last?["drafts"] as? Int, 1)
        XCTAssertEqual(recent.first?["stage"] as? String, "drafting")
    }

    /// `budget.day` is the local calendar day the counters describe, not the
    /// UTC date of the instant `Budget.day` happens to store — the two disagree
    /// for half of every day, and `passesUsed`/`spentUSD` beside it are already
    /// counting against the local day.
    func testBudgetDayIsReportedAsTheLocalDayNotTheInstantsUTCDate() async throws {
        let originalTZ = ProcessInfo.processInfo.environment["TZ"]
        setenv("TZ", "Asia/Tokyo", 1)
        NSTimeZone.resetSystemTimeZone()
        defer {
            if let originalTZ {
                setenv("TZ", originalTZ, 1)
            } else {
                unsetenv("TZ")
            }
            NSTimeZone.resetSystemTimeZone()
        }

        // 2026-08-19 16:30 UTC is already 2026-08-20 01:30 in Tokyo (UTC+9) —
        // the local day has rolled over while the UTC day hasn't.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 19
        components.hour = 16; components.minute = 30
        let instant = try XCTUnwrap(utc.date(from: components))

        let stamped = CoordinatorQueueRefill(
            ledgerURL: tempDir.appendingPathComponent("stamped.jsonl"),
            budget: QueueRefill.Budget(spentUSD: 1, capUSD: 10, passes: 1, day: instant))
        stamped.configure(registry: registry, globalConfigStore: globalConfigStore,
                          runtimeFactory: { MockAgentRuntime() })
        let detached = try await startServer(queueRefill: stamped)
        extraServers.append(detached)

        let (status, body) = try await detached.get("/v1/coordinator/refill")

        XCTAssertEqual(status, 200)
        let reported = try XCTUnwrap(body["budget"] as? [String: Any])
        XCTAssertEqual(reported["day"] as? String, "2026-08-20",
                       "the Tokyo-local day, not 2026-08-19 which is the instant's UTC date")
    }

    // MARK: - Writing

    /// The switch reaches the loop *and* the config file — a driver that enables
    /// the loop has enabled it for the next launch too, not just this one.
    func testEnablingReachesTheLoopAndIsPersisted() async throws {
        let (status, body) = try await harness.put("/v1/coordinator/refill",
                                                   ["enabled": true, "dailyBudgetUSD": 50])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["enabled"] as? Bool, true)
        XCTAssertTrue(queueRefill.enabled)
        XCTAssertEqual(globalConfigStore.config.coordinatorRefillEnabled, true)
    }

    /// Advisory mode retired: `mode` on the PUT is tolerated and ignored, so a
    /// driver still sending it keeps working — including with a spelling the
    /// old validation would have refused, since a field nothing reads is not
    /// worth failing a whole write over.
    func testAModeFieldIsToleratedAndIgnored() async throws {
        let (status, body) = try await harness.put("/v1/coordinator/refill",
                                                   ["mode": "bounded", "dailyBudgetUSD": 8.0])

        XCTAssertEqual(status, 200)
        XCTAssertNil(body["mode"], "nothing reads it, so nothing reports it")
        XCTAssertEqual(queueRefill.budget.capUSD, 8.0, "the rest of the body still lands")

        let (junkStatus, _) = try await harness.put("/v1/coordinator/refill",
                                                    ["mode": "yolo"])
        XCTAssertEqual(junkStatus, 200, "even a spelling the old validation refused is ignored")
    }

    /// The ceiling set here is the one the loop refuses passes against, so it has
    /// to land on the budget rather than only in the file.
    func testSettingTheCeilingReachesTheBudgetAndIsPersisted() async throws {
        let (status, body) = try await harness.put("/v1/coordinator/refill",
                                                   ["dailyBudgetUSD": 8.0])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["dailyBudgetUSD"] as? Double, 8.0)
        XCTAssertEqual(queueRefill.budget.capUSD, 8.0)
        XCTAssertEqual(globalConfigStore.config.dailyBudgetUSD, 8.0)
    }

    /// An explicit null is how a ceiling is removed — distinct from omitting the
    /// field, which is the next test.
    func testNullClearsTheCeiling() async throws {
        _ = try await harness.put("/v1/coordinator/refill", ["dailyBudgetUSD": 8.0])

        let (status, body) = try await harness.put("/v1/coordinator/refill",
                                                   ["dailyBudgetUSD": NSNull()])

        XCTAssertEqual(status, 200)
        XCTAssertTrue(body["dailyBudgetUSD"] is NSNull)
        XCTAssertNil(queueRefill.budget.capUSD)
        XCTAssertNil(globalConfigStore.config.dailyBudgetUSD)
    }

    func testOmittedFieldsAreLeftAlone() async throws {
        _ = try await harness.put("/v1/coordinator/refill",
                                  ["enabled": true, "dailyBudgetUSD": 3.0,
                                         "maxPasses": 40, "checkIntervalSeconds": 300])

        let (status, body) = try await harness.put("/v1/coordinator/refill",
                                                   ["enabled": false])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["enabled"] as? Bool, false)
        XCTAssertEqual(body["dailyBudgetUSD"] as? Double, 3.0)
        XCTAssertEqual(body["maxPasses"] as? Int, 40)
        XCTAssertEqual(body["checkIntervalSeconds"] as? Int, 300)
        XCTAssertEqual(queueRefill.checkInterval, 300)
    }

    // MARK: - The other ceiling

    /// `maxPasses` on its own, which is how an operator raises the ceiling that
    /// actually binds. Measured on 2026-08-11, three hours into a session: $47.72
    /// of a $250 budget spent against 13 of 60 passes used — so on a 300-second
    /// interval the passes run out in under four hours with $200 unspent, every
    /// queue drains behind the stopped grooming, and raising `dailyBudgetUSD`
    /// changes nothing at all.
    func testSettingThePassCeilingReachesTheBudgetAndIsEchoed() async throws {
        let (status, body) = try await harness.put("/v1/coordinator/refill",
                                                   ["maxPasses": 120])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["maxPasses"] as? Int, 120)
        XCTAssertEqual(queueRefill.budget.maxPasses, 120)
    }

    /// The reply has to carry it, or a 200 for a body that took looks exactly like
    /// a 200 for a body the endpoint ignored — and until this field was declared,
    /// ignoring it is what a reader of the spec would have expected.
    func testTheSettingsReplyCarriesBothCeilings() async throws {
        let (_, body) = try await harness.put("/v1/coordinator/refill",
                                              ["dailyBudgetUSD": 250.0, "maxPasses": 60])

        XCTAssertEqual(body["dailyBudgetUSD"] as? Double, 250.0)
        XCTAssertEqual(body["maxPasses"] as? Int, 60)
    }

    /// Uncapped is a state the loop can be in, and the reply says so with null
    /// rather than by dropping the key — a client reading `maxPasses` must not
    /// have to tell "no ceiling" apart from "this build doesn't have the field".
    func testAnUnsetPassCeilingIsReportedAsNull() async throws {
        queueRefill.setBudgetLimits(maxPasses: .some(nil))

        let (status, body) = try await harness.put("/v1/coordinator/refill",
                                                   [:])

        XCTAssertEqual(status, 200)
        XCTAssertTrue(body["maxPasses"] is NSNull)
    }

    /// Persisted, since 0.4.1: a ceiling the operator tuned used to last one
    /// launch and read as the app forgetting a decision. The PUT lands in
    /// `coordinatorMaxPassesPerDay` and a relaunch loads it back.
    func testThePassCeilingPersists() async throws {
        _ = try await harness.put("/v1/coordinator/refill", ["maxPasses": 120])

        let relaunched = CoordinatorQueueRefill(ledgerURL: tempDir.appendingPathComponent("refill.jsonl"))
        relaunched.configure(registry: registry,
                             globalConfigStore: globalConfigStore,
                             runtimeFactory: { MockAgentRuntime() })
        defer { relaunched.stop() }

        XCTAssertEqual(relaunched.budget.maxPasses, 120)
    }

    /// Zero and negative would each read as a ceiling that is already exhausted,
    /// and a fraction is a caller bug worth a 400 rather than a silent truncation.
    /// There is no null here, unlike `dailyBudgetUSD`: the write side has no way
    /// to clear this ceiling, which is why the field says so.
    func testRejectsANonPositivePassCeiling() async throws {
        let before = queueRefill.budget.maxPasses

        for raw: Any in [0, -5, 60.5, "60", NSNull()] {
            let (status, body) = try await harness.put("/v1/coordinator/refill",
                                                       ["maxPasses": raw])

            XCTAssertEqual(status, 400, "maxPasses=\(raw)")
            XCTAssertEqual(body["error"] as? String,
                           "\"maxPasses\" must be a positive integer",
                           "maxPasses=\(raw)")
            XCTAssertEqual(queueRefill.budget.maxPasses, before,
                           "a rejected value must not have landed: maxPasses=\(raw)")
        }
    }

    // MARK: - The cadence

    /// The knob that decides how fast an emptied queue refills. It was the one
    /// refill setting that needed a rebuild: on 2026-08-11 two projects sat idle
    /// with empty queues having used 2 of 60 passes and $2.46 of $125, so what
    /// was throttling them was this constant rather than either ceiling.
    func testSettingTheIntervalReachesTheLoop() async throws {
        let (status, body) = try await harness.put("/v1/coordinator/refill",
                                                   ["checkIntervalSeconds": 300])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["checkIntervalSeconds"] as? Int, 300)
        XCTAssertEqual(queueRefill.checkInterval, 300)
    }

    /// The shipped cadence, which this item made reachable rather than changed.
    func testTheDefaultIntervalIsStillFifteenMinutes() async throws {
        let (status, body) = try await harness.get("/v1/coordinator/refill")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["checkIntervalSeconds"] as? Int, 900)
        XCTAssertEqual(CoordinatorQueueRefill.Defaults.checkInterval, 900)
    }

    /// Shortening the interval has to take effect now. A loop that keeps its old
    /// cadence until the next tick — up to a quarter of an hour later — is
    /// indistinguishable from one that ignored the setting, which is the whole
    /// complaint being fixed.
    func testChangingTheIntervalRestartsTheTimer() async throws {
        queueRefill.start()
        _ = try await harness.put("/v1/coordinator/refill", ["enabled": true, "dailyBudgetUSD": 50])
        XCTAssertTrue(queueRefill.isTimerRunning)
        let before = queueRefill.timerGeneration

        _ = try await harness.put("/v1/coordinator/refill",
                                  ["checkIntervalSeconds": 120])

        XCTAssertTrue(queueRefill.isTimerRunning)
        XCTAssertGreaterThan(queueRefill.timerGeneration, before,
                             "the sleep in flight should have been cancelled, not waited out")
    }

    /// Setting the interval to what it already is restarts nothing — otherwise a
    /// driver that PUTs its whole config every pass would keep resetting the
    /// countdown and the loop would never reach a tick.
    func testResendingTheSameIntervalLeavesTheTimerAlone() async throws {
        queueRefill.start()
        _ = try await harness.put("/v1/coordinator/refill",
                                  ["enabled": true, "dailyBudgetUSD": 50, "checkIntervalSeconds": 600])
        let before = queueRefill.timerGeneration

        _ = try await harness.put("/v1/coordinator/refill",
                                  ["checkIntervalSeconds": 600])

        XCTAssertEqual(queueRefill.timerGeneration, before)
    }

    /// Not persisted, deliberately: `dailyBudgetUSD` is portfolio state and
    /// survives a launch, while pacing chosen for one session of unattended work
    /// does not — the same call `Budget.maxPasses` makes.
    func testTheIntervalIsNotPersisted() async throws {
        _ = try await harness.put("/v1/coordinator/refill",
                                  ["checkIntervalSeconds": 300])

        let relaunched = CoordinatorQueueRefill(ledgerURL: tempDir.appendingPathComponent("refill.jsonl"))
        relaunched.configure(registry: registry,
                             globalConfigStore: globalConfigStore,
                             runtimeFactory: { MockAgentRuntime() })
        defer { relaunched.stop() }

        XCTAssertEqual(relaunched.checkInterval, CoordinatorQueueRefill.Defaults.checkInterval)
    }

    /// Both ends of the range are taken — the message names them, so a caller
    /// that overshoots learns what would have worked.
    func testAcceptsBothEndsOfTheRange() async throws {
        for seconds in [60, 86_400] {
            let (status, body) = try await harness.put("/v1/coordinator/refill",
                                                       ["checkIntervalSeconds": seconds])
            XCTAssertEqual(status, 200, "checkIntervalSeconds=\(seconds)")
            XCTAssertEqual(body["checkIntervalSeconds"] as? Int, seconds)
        }
    }

    /// Switching off tears the timer down rather than leaving one that wakes to
    /// refuse — the same guarantee the in-app control has.
    func testDisablingStopsTheTimer() async throws {
        queueRefill.start()
        _ = try await harness.put("/v1/coordinator/refill", ["enabled": true, "dailyBudgetUSD": 50])
        XCTAssertTrue(queueRefill.isTimerRunning)

        _ = try await harness.put("/v1/coordinator/refill", ["enabled": false])

        XCTAssertFalse(queueRefill.isTimerRunning)
    }

    // MARK: - The selection policy

    /// The three fields `GET` had always reported and nothing could write. With
    /// them read-only the only lever over a starving fleet was the interval,
    /// which speeds up every project's turn equally and costs a pass each time —
    /// including passes for projects that needed nothing.
    func testSettingThePolicyReachesTheLoopAndIsEchoed() async throws {
        let (status, body) = try await harness.put("/v1/coordinator/refill",
                                                   ["threshold": 4, "targetDepth": 8,
                                                          "maxItemsPerPass": 6, "maxProjectsPerPass": 5])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["policy"] as? [String: Int],
                       ["threshold": 4, "targetDepth": 8,
                        "maxItemsPerPass": 6, "maxProjectsPerPass": 5])
        XCTAssertEqual(queueRefill.policy.threshold, 4)
        XCTAssertEqual(queueRefill.policy.targetDepth, 8)
        XCTAssertEqual(queueRefill.policy.maxItemsPerPass, 6)
        XCTAssertEqual(queueRefill.policy.maxProjectsPerPass, 5)
    }

    /// How wide a pass fans out is the field this item exists for, and it has to
    /// be settable on its own: an operator whose fleet is starving is not also
    /// choosing a new threshold and target depth.
    func testTheFleetWidthIsSettableOnItsOwn() async throws {
        let (status, body) = try await harness.put("/v1/coordinator/refill",
                                                   ["maxProjectsPerPass": 9])

        XCTAssertEqual(status, 200)
        XCTAssertEqual((body["policy"] as? [String: Int])?["maxProjectsPerPass"], 9)
        XCTAssertEqual(queueRefill.policy.maxProjectsPerPass, 9)
        XCTAssertEqual(queueRefill.policy.threshold, QueueRefill.Policy.default.threshold,
                       "an omitted policy field is left alone like every other omitted field")
        XCTAssertEqual(queueRefill.policy.targetDepth, QueueRefill.Policy.default.targetDepth)
    }

    /// Both sides of the endpoint answer with the same policy, so a driver that
    /// wrote one can read it back where it expects to find it.
    func testTheReadSideReportsTheSamePolicyTheWriteSideTook() async throws {
        _ = try await harness.put("/v1/coordinator/refill",
                                  ["threshold": 3, "maxProjectsPerPass": 4])

        let (status, body) = try await harness.get("/v1/coordinator/refill")

        XCTAssertEqual(status, 200)
        XCTAssertEqual((body["policy"] as? [String: Int])?["threshold"], 3)
        XCTAssertEqual((body["policy"] as? [String: Int])?["maxProjectsPerPass"], 4)
    }

    /// What a fresh loop reports. The target and the per-pass item ceiling are
    /// the same number on purpose: a target above the ceiling is one no pass can
    /// deliver, so an emptied queue used to climb to 3 and sit there short of the
    /// depth the policy had set for itself.
    func testTheShippedPolicyCanFillAnEmptyQueueInOnePass() async throws {
        let (_, body) = try await harness.get("/v1/coordinator/refill")
        let policy = try XCTUnwrap(body["policy"] as? [String: Int])

        XCTAssertEqual(policy["targetDepth"], 3)
        XCTAssertEqual(policy["maxItemsPerPass"], 3)
        XCTAssertEqual(policy["maxProjectsPerPass"], 3)
    }

    /// Sanitized on the way out, like `GET`'s: a caller that set a target below
    /// the threshold has to read back the policy a pass will actually apply, not
    /// the one it sent.
    func testTheReplyCarriesThePolicyAPassWillApply() async throws {
        let (status, body) = try await harness.put("/v1/coordinator/refill",
                                                   ["threshold": 6, "targetDepth": 2])

        XCTAssertEqual(status, 200)
        XCTAssertEqual((body["policy"] as? [String: Int])?["targetDepth"], 6,
                       "a target below the threshold would never settle")
    }

    /// Out of range, fractional, negative and the wrong type are all the same
    /// rejection, and the message names the range that would have been taken.
    /// Zero is a rejection for three of the four: a target of nothing, a pass
    /// that files nothing and a pass that serves no project are each a way of
    /// switching the loop off without saying so.
    func testRejectsAPolicyFieldOutsideItsRange() async throws {
        let cases: [(String, [Any])] = [
            ("threshold", [-1, 51, 2.5, "2", NSNull()]),
            ("targetDepth", [0, 51, 5.5, "5", NSNull()]),
            ("maxItemsPerPass", [0, 51, 3.5, "3", NSNull()]),
            ("maxProjectsPerPass", [0, 51, 3.5, "3", NSNull()])
        ]
        let before = queueRefill.policy

        for (field, values) in cases {
            let range = field == "threshold" ? "0…50" : "1…50"
            for raw in values {
                let (status, body) = try await harness.put("/v1/coordinator/refill",
                                                           [field: raw])

                XCTAssertEqual(status, 400, "\(field)=\(raw)")
                XCTAssertEqual(body["error"] as? String,
                               "\"\(field)\" must be an integer in \(range)",
                               "\(field)=\(raw)")
                XCTAssertEqual(queueRefill.policy, before,
                               "a rejected value must not have landed: \(field)=\(raw)")
            }
        }
    }

    /// One bad field leaves the whole policy alone rather than applying the good
    /// ones beside it — a 400 that half-applied would leave the loop in a state
    /// no caller asked for and none can read off the reply.
    func testARejectedFieldLeavesTheFieldsBesideItUnchanged() async throws {
        let before = queueRefill.policy

        let (status, _) = try await harness.put("/v1/coordinator/refill",
                                                ["maxProjectsPerPass": 6, "targetDepth": 0])

        XCTAssertEqual(status, 400)
        XCTAssertEqual(queueRefill.policy, before)
    }

    /// The policy paces one session of unattended work, like the interval and the
    /// pass ceiling — it is not portfolio state, so a relaunch is back to the
    /// shipped numbers.
    func testThePolicyIsNotPersisted() async throws {
        _ = try await harness.put("/v1/coordinator/refill",
                                  ["maxProjectsPerPass": 9])

        let relaunched = CoordinatorQueueRefill(ledgerURL: tempDir.appendingPathComponent("refill.jsonl"))
        relaunched.configure(registry: registry,
                             globalConfigStore: globalConfigStore,
                             runtimeFactory: { MockAgentRuntime() })
        defer { relaunched.stop() }

        XCTAssertEqual(relaunched.policy, QueueRefill.Policy.default)
    }

    // MARK: - Rejections

    /// Zero or negative would read as "no ceiling" if it were accepted, which is
    /// the opposite of what someone typing it means.
    func testRejectsANonPositiveCeiling() async throws {
        for raw in [0, -5] {
            let (status, body) = try await harness.put("/v1/coordinator/refill",
                                                       ["dailyBudgetUSD": raw])
            XCTAssertEqual(status, 400, "dailyBudgetUSD=\(raw)")
            XCTAssertEqual(body["error"] as? String,
                           "\"dailyBudgetUSD\" must be a positive number or null")
        }
        XCTAssertNil(queueRefill.budget.capUSD)
    }

    /// Out of range, fractional and negative are all the same rejection: none of
    /// them is an integer in the range, and the message says which range. A
    /// second-long interval would spin the loop; a fraction is a caller bug
    /// worth a 400 rather than a silent truncation.
    func testRejectsAnIntervalOutsideTheRange() async throws {
        for raw: Any in [59, 86_401, 300.5, -300, 0] {
            let (status, body) = try await harness.put("/v1/coordinator/refill",
                                                       ["checkIntervalSeconds": raw])

            XCTAssertEqual(status, 400, "checkIntervalSeconds=\(raw)")
            XCTAssertEqual(body["error"] as? String,
                           "\"checkIntervalSeconds\" must be an integer in 60…86400",
                           "checkIntervalSeconds=\(raw)")
            XCTAssertEqual(queueRefill.checkInterval,
                           CoordinatorQueueRefill.Defaults.checkInterval,
                           "a rejected value must not have landed")
        }
    }

    func testRejectsANonBooleanSwitch() async throws {
        let (status, body) = try await harness.put("/v1/coordinator/refill",
                                                   ["enabled": "yes"])

        XCTAssertEqual(status, 400)
        XCTAssertEqual(body["error"] as? String, "\"enabled\" must be true or false")
        XCTAssertFalse(queueRefill.enabled)
    }

    /// A number is not a boolean, however willingly `NSNumber` bridges to one:
    /// `1` used to start the refill loop and `0` to stop it, through a check
    /// whose message says it takes only `true` or `false`.
    func testRejectsANumericSwitch() async throws {
        for raw: Any in [1, 0] {
            let (status, body) = try await harness.put("/v1/coordinator/refill",
                                                       ["enabled": raw])

            XCTAssertEqual(status, 400, "enabled=\(raw)")
            XCTAssertEqual(body["error"] as? String, "\"enabled\" must be true or false")
            XCTAssertFalse(queueRefill.enabled)
        }
    }

    /// With no loop attached there is nothing to switch on — say so, rather than
    /// reporting settings that would go nowhere.
    func testUnavailableWhenNoLoopIsAttached() async throws {
        let detached = try await startServer(queueRefill: nil)
        extraServers.append(detached)

        let (status, body) = try await detached.get("/v1/coordinator/refill")

        XCTAssertEqual(status, 503)
        XCTAssertEqual(body["error"] as? String,
                       "Queue refill is unavailable — no refill loop attached")
    }

    func testRequiresBearerToken() async throws {
        let (status, body) = try await harness.get("/v1/coordinator/refill", bearer: nil)

        XCTAssertEqual(status, 401)
        XCTAssertEqual(body["error"] as? String, "Missing or invalid bearer token")
    }

    // MARK: - Helpers

    /// The port is picked at random and probed, since NWListener reports a bind
    /// conflict asynchronously rather than throwing from start().
    private func startServer(queueRefill: CoordinatorQueueRefill?) async throws -> ControlServerHarness {
        try await ControlServerHarness.start(token: token) {
            KiteloopControlServer(registry: registry, token: $0, queueRefill: queueRefill)
        }
    }


    /// Grooming arms the same way running does: no ceiling, no switch — with
    /// the refusal naming the grooming budget, and one call able to set both.
    func testArmingGroomingWithoutABudgetIsRefusedNamingIt() async throws {
        let (status, body) = try await harness.put("/v1/coordinator/refill",
                                                   ["enabled": true])
        XCTAssertEqual(status, 422)
        XCTAssertEqual((body["error"] as? String)?.contains("daily autonomy budget"), true)
        XCTAssertFalse(queueRefill.enabled, "a refused arming must not arm")

        let (armed, _) = try await harness.put("/v1/coordinator/refill",
                                               ["enabled": true, "dailyBudgetUSD": 40])
        XCTAssertEqual(armed, 200)
        XCTAssertTrue(queueRefill.enabled)
    }
}
