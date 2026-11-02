import XCTest
import KiteloopCore
@testable import Kiteloop

/// `GET`, `PUT` and `POST /v1/autopilot/reset` — reading the autopilot
/// configuration, assigning the worker/reviewer/coordinator by **agent id or
/// name**, and the way back to defaults. Exercised over a real loopback socket
/// so the whole path (query/body parsing → project lookup → agent resolution →
/// payload) is covered. All three share a response shape, so a caller can read
/// back exactly what it wrote.
@MainActor
final class KiteloopControlServerAutopilotTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var harness: ControlServerHarness!
    private let token = "control-autopilot-token-" + UUID().uuidString

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-autopilot")
        registry = ControlSessionRegistry()
        harness = try await ControlServerHarness.start(registry: registry, token: token)
    }

    override func tearDown() async throws {
        harness?.stop()
        harness = nil
        registry = nil
    }

    // MARK: - Defaults

    /// A freshly opened project has no worker or reviewer yet: those read back as
    /// JSON null rather than being omitted, so a driver can tell "unset" from
    /// "unknown field".
    func testReturnsDefaultConfigForFreshProject() async throws {
        try registerProject(named: "alpha", configure: { _ in })

        let (status, body) = try await harness.get("/v1/autopilot?project=alpha")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["project"] as? String, "alpha")
        XCTAssertTrue(body["worker"] is NSNull)
        XCTAssertTrue(body["reviewer"] is NSNull)
        XCTAssertEqual(body["autonomy"] as? String, "off", "no switch is on, so the dial reads off")
        XCTAssertNil(body["useWorktree"], "worktree isolation is not a setting")
        XCTAssertEqual(body["maxRetries"] as? Int, 3)
        XCTAssertEqual(body["stallTimeoutMinutes"] as? Int, 20)
        XCTAssertNil(body["qualityJudgeEnabled"])
        XCTAssertNil(body["refuteRoundEnabled"], "the refute round is retired, not a setting")
        XCTAssertNil(body["protectedPaths"], "protected paths are retired, not a setting")
        XCTAssertTrue(body["budgetUSD"] is NSNull,
                      "no ceiling of its own — the portfolio's governs it alone")
        XCTAssertEqual(body["autoMergeOnApproval"] as? Bool, false)
        XCTAssertNil(body["autoMergeVerifyCommand"], "the merge-verify is the verify map's, not a setting")
        XCTAssertEqual(body["autoMergeVerifyTimeoutMinutes"] as? Int, 30)
        XCTAssertTrue(body["worktreeSetupCommand"] is NSNull, "unset means nothing runs beyond today's behaviour")
        XCTAssertTrue(body["baseBranch"] is NSNull, "unset means the checkout's own HEAD")
        XCTAssertEqual(body["openPullRequest"] as? Bool, false,
                       "publishing a branch to GitHub is opt-in")
        XCTAssertEqual(body["approveReviewPassedRuns"] as? Bool, false,
                       "the human gate is the default — a project only stops asking on purpose")
    }

    // MARK: - Configured values

    // MARK: - Derived from the ledger

    /// A project with nothing landed reports the two clocks it will actually
    /// run under, and says they are not measured — the number alone cannot
    /// distinguish a measured 20 from an unmeasured one.
    func testAProjectWithoutEnoughHistoryReportsTheDefaultClocksAndSaysSo() async throws {
        try registerProject(named: "alpha", landedRuns: (count: 4, workerSeconds: 1_800, gateSeconds: 1_200),
                            configure: { _ in })

        let (_, body) = try await harness.get("/v1/autopilot?project=alpha")

        XCTAssertEqual(body["stallTimeoutMinutes"] as? Int, 20)
        XCTAssertEqual(body["autoMergeVerifyTimeoutMinutes"] as? Int, 30)
        XCTAssertEqual(runTimeoutSource(body), ["worker": "default", "gate": "default"])
        XCTAssertEqual(body["workerMaxTurns"] as? Int, 50)
        XCTAssertEqual(body["workerMaxTurnsSource"] as? String, "default")
        XCTAssertTrue(body["itemCostCapUSD"] is NSNull, "four runs measure no cost cap")
        XCTAssertEqual(body["itemCostCapSource"] as? String, "default")
    }

    /// Ten landed runs, and both clocks are this project's own p95 phase plus
    /// half again — the worker's off the worker phase (1800s → 45 min), the
    /// gate's off the gate phase (1200s → 30 min), neither off the whole run,
    /// which here is 9000 seconds.
    func testTenLandedRunsAreReportedAsDerivedClocks() async throws {
        try registerProject(named: "alpha", landedRuns: (count: 10, workerSeconds: 1_800, gateSeconds: 1_200),
                            configure: { _ in })

        let (_, body) = try await harness.get("/v1/autopilot?project=alpha")

        XCTAssertEqual(body["stallTimeoutMinutes"] as? Int, 45)
        XCTAssertEqual(body["autoMergeVerifyTimeoutMinutes"] as? Int, 30)
        XCTAssertEqual(runTimeoutSource(body), ["worker": "derived", "gate": "derived"])
        // Every landed run cost $1.00: the cap is that plus half again.
        XCTAssertEqual(body["itemCostCapUSD"] as? Double, 1.5)
        XCTAssertEqual(body["itemCostCapSource"] as? String, "derived")
    }

    /// Ten runs whose workers each took 60 turns, and the reply reports the
    /// worker's turn budget as 60 plus half again, measured.
    func testLandedRunsWithTurnCountsReportADerivedTurnBudget() async throws {
        try registerProject(named: "alpha", landedRuns: (count: 10, workerSeconds: 1_800, gateSeconds: nil),
                            workerTurns: 60, configure: { _ in })

        let (_, body) = try await harness.get("/v1/autopilot?project=alpha")

        XCTAssertEqual(body["workerMaxTurns"] as? Int, 90)
        XCTAssertEqual(body["workerMaxTurnsSource"] as? String, "derived")
    }

    /// A project whose runs stop at the approval gate measures no gate phase,
    /// and is still measured on the phase it does run: the worker clock is its
    /// own p95 worker phase plus half again, the gate clock the default — and
    /// the reply says which of the two is which, one answer per clock.
    func testRunsThatNeverReachTheGateStillDeriveTheWorkerClock() async throws {
        try registerProject(named: "alpha", landedRuns: (count: 10, workerSeconds: 1_800, gateSeconds: nil),
                            configure: { _ in })

        let (_, body) = try await harness.get("/v1/autopilot?project=alpha")

        XCTAssertEqual(body["stallTimeoutMinutes"] as? Int, 45)
        XCTAssertEqual(body["autoMergeVerifyTimeoutMinutes"] as? Int, 30)
        XCTAssertEqual(runTimeoutSource(body), ["worker": "derived", "gate": "default"])
    }

    /// A caller that still sends the two numbers is not handed a 400 — it is
    /// answered with what the project will really run under, so an old driver
    /// keeps working and learns the truth in the same reply.
    func testAPutCarryingEitherTimeoutIsAnsweredWithTheDerivedValue() async throws {
        let autopilot = try registerProject(
            named: "alpha", landedRuns: (count: 10, workerSeconds: 1_800, gateSeconds: 1_200),
            configure: { _ in })

        let (status, body) = try await harness.put(
            "/v1/autopilot",
            ["project": "alpha", "stallTimeoutMinutes": 99, "autoMergeVerifyTimeoutMinutes": 99,
             "maxRetries": 5])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["stallTimeoutMinutes"] as? Int, 45)
        XCTAssertEqual(body["autoMergeVerifyTimeoutMinutes"] as? Int, 30)
        XCTAssertEqual(runTimeoutSource(body), ["worker": "derived", "gate": "derived"])
        XCTAssertEqual(body["maxRetries"] as? Int, 5, "the settings beside them still apply")
        XCTAssertEqual(autopilot.stallTimeoutMinutes, 45,
                       "and the autopilot that runs the next item is unmoved")
    }

    // MARK: - Derived from the repository

    /// A fresh project with nothing configured and nothing in its tree says
    /// so: both effective commands are null, and each source says why.
    func testAFreshProjectDerivesNoCommandsAndSaysWhy() async throws {
        try registerProject(named: "alpha", configure: { _ in })

        let (_, body) = try await harness.get("/v1/autopilot?project=alpha")

        XCTAssertTrue(body["effectiveAutoMergeVerifyCommand"] is NSNull)
        XCTAssertEqual(body["autoMergeVerifyCommandSource"] as? String, "no verify map")
        XCTAssertTrue(body["effectiveWorktreeSetupCommand"] is NSNull)
        XCTAssertTrue((body["worktreeSetupCommandSource"] as? String ?? "").contains("nothing to set up"))
    }

    /// A lockfile under a directory and a verify map with a widest rule are
    /// read as the setup and the merge-verify, and GET names where each came
    /// from — while the settings themselves stay null, as written.
    func testCommandsAreDerivedFromTheTreeWhenNothingIsConfigured() async throws {
        let autopilot = try registerProject(named: "alpha", configure: { _ in })
        let root = try XCTUnwrap(autopilot.projectRoot)
        let web = root.appending(path: "apps/web")
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try "{}".write(to: web.appending(path: "package-lock.json"), atomically: true, encoding: .utf8)
        try "export {}".write(to: web.appending(path: "index.ts"), atomically: true, encoding: .utf8)
        let map = #"{"rules":[{"glob":"apps/web/**","command":"npm test"},{"glob":"apps/api/**","command":"cargo test"}]}"#
        try map.write(to: KiteloopProject(rootURL: root).verifyMapURL, atomically: true, encoding: .utf8)

        let (_, body) = try await harness.get("/v1/autopilot?project=alpha")

        XCTAssertNil(body["autoMergeVerifyCommand"], "not a setting, so not reported")
        XCTAssertEqual(body["effectiveAutoMergeVerifyCommand"] as? String, "npm test")
        XCTAssertEqual(body["autoMergeVerifyCommandSource"] as? String, "from verify-map rule `apps/web/**`")
        XCTAssertTrue(body["worktreeSetupCommand"] is NSNull)
        XCTAssertEqual(body["effectiveWorktreeSetupCommand"] as? String, "(cd apps/web && npm ci)")
        XCTAssertEqual(body["worktreeSetupCommandSource"] as? String, "from a package-lock under apps/web")
    }

    /// A configured command wins over whatever the tree implies.
    func testAConfiguredCommandWinsOverTheDerivedOne() async throws {
        let autopilot = try registerProject(named: "alpha") { $0.worktreeSetupCommand = "make deps" }
        let root = try XCTUnwrap(autopilot.projectRoot)
        try "{}".write(to: root.appending(path: "package-lock.json"), atomically: true, encoding: .utf8)

        let (_, body) = try await harness.get("/v1/autopilot?project=alpha")

        XCTAssertEqual(body["effectiveWorktreeSetupCommand"] as? String, "make deps")
        XCTAssertEqual(body["worktreeSetupCommandSource"] as? String, "configured")
    }

    func testReturnsConfiguredWorkerReviewerCapsAndFlags() async throws {
        try registerProject(named: "alpha") { autopilot in
            autopilot.workerAgentID = "worker-1"
            autopilot.reviewerAgentID = "reviewer-1"
            autopilot.maxRetries = 6
            autopilot.budgetUSD = 25
            autopilot.autoMergeVerifyCommand = "swift test"
            autopilot.worktreeSetupCommand = "npm ci"
            autopilot.baseBranch = "quality/rebased"
            autopilot.openPullRequest = true
            autopilot.approvalGate = .land
            autopilot.autonomousWorkEnabled = true
        }

        let (status, body) = try await harness.get("/v1/autopilot?project=alpha")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["baseBranch"] as? String, "quality/rebased")
        XCTAssertEqual(body["budgetUSD"] as? Double, 25)
        XCTAssertEqual(body["worker"] as? String, "worker-1")
        XCTAssertEqual(body["reviewer"] as? String, "reviewer-1")
        XCTAssertEqual(body["maxRetries"] as? Int, 6)
        XCTAssertEqual(body["stallTimeoutMinutes"] as? Int, 20,
                       "not a setting: nothing configured can move a derived clock")
        XCTAssertEqual(body["autoMergeOnApproval"] as? Bool, true)
        XCTAssertNil(body["autoMergeVerifyCommand"], "a stored command is not a setting GET reports")
        XCTAssertEqual(body["autoMergeVerifyTimeoutMinutes"] as? Int, 30, "not a setting: nothing configured can move a derived clock")
        XCTAssertEqual(body["openPullRequest"] as? Bool, true)
        XCTAssertEqual(body["approveReviewPassedRuns"] as? Bool, true)
        XCTAssertEqual(body["approvalGate"] as? String, "land")
        XCTAssertEqual(body["autonomy"] as? String, "land",
                       "work enabled with the gate at land reads as land")
    }

    /// The lookup is the shared registry one, so a full path addresses the same
    /// project as its folder name.
    func testResolvesProjectByPath() async throws {
        let autopilot = try registerProject(named: "alpha") { $0.maxRetries = 7 }
        XCTAssertEqual(autopilot.maxRetries, 7)
        let path = try XCTUnwrap(registry.entry(forProject: "alpha")).session.project.id

        let (status, body) = try await harness.get("/v1/autopilot?project=\(encoded(path))")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["project"] as? String, "alpha")
        XCTAssertEqual(body["maxRetries"] as? Int, 7)
    }

    /// Two open projects must not bleed into each other's configuration.
    func testReturnsConfigForTheRequestedProjectOnly() async throws {
        try registerProject(named: "alpha") { $0.workerAgentID = "alpha-worker" }
        try registerProject(named: "beta") { $0.workerAgentID = "beta-worker" }

        let (_, alpha) = try await harness.get("/v1/autopilot?project=alpha")
        let (_, beta) = try await harness.get("/v1/autopilot?project=beta")

        XCTAssertEqual(alpha["worker"] as? String, "alpha-worker")
        XCTAssertEqual(beta["worker"] as? String, "beta-worker")
    }

    // MARK: - The autonomy dial

    /// `off` iff `autonomousWorkEnabled` is false, whatever the gate reads —
    /// the mapping `BacklogAutopilot.autonomy`'s getter uses, exercised end to
    /// end through the config file and the GET response.
    func testDialReadsOffWhenWorkIsNotEnabled() async throws {
        try registerProject(named: "alpha") { autopilot in
            autopilot.autonomousWorkEnabled = false
            autopilot.approvalGate = .land
        }
        let (_, body) = try await harness.get("/v1/autopilot?project=alpha")
        XCTAssertEqual(body["autonomy"] as? String, "off")
        XCTAssertEqual(body["approvalGate"] as? String, "land")
    }

    func testDialReadsProposeWhenWorkIsEnabledAndTheGateProposes() async throws {
        try registerProject(named: "alpha") { autopilot in
            autopilot.autonomousWorkEnabled = true
            autopilot.approvalGate = .propose
        }
        let (_, body) = try await harness.get("/v1/autopilot?project=alpha")
        XCTAssertEqual(body["autonomy"] as? String, "propose")
    }

    func testDialReadsLandWhenWorkIsEnabledAndTheGateLands() async throws {
        try registerProject(named: "alpha") { autopilot in
            autopilot.autonomousWorkEnabled = true
            autopilot.approvalGate = .land
        }
        let (_, body) = try await harness.get("/v1/autopilot?project=alpha")
        XCTAssertEqual(body["autonomy"] as? String, "land")
    }

    /// The two deprecated switches map onto the gate the way an old config
    /// file does: `land` only when both end up on, a switch the body leaves
    /// out keeping the value the gate gives it now.
    func testPutWithTheOldSwitchesMapsThemOntoTheGate() async throws {
        typealias Gate = BacklogAutopilot.ApprovalGate
        let cases: [(start: Gate, body: [String: Bool], expected: Gate)] = [
            (.propose, ["approveReviewPassedRuns": true, "autoMergeOnApproval": true], .land),
            (.propose, ["approveReviewPassedRuns": true, "autoMergeOnApproval": false], .propose),
            (.propose, ["approveReviewPassedRuns": false, "autoMergeOnApproval": true], .propose),
            (.land, ["approveReviewPassedRuns": false, "autoMergeOnApproval": false], .propose),
            (.propose, ["approveReviewPassedRuns": true], .propose),
            (.land, ["autoMergeOnApproval": true], .land),
            (.land, ["approveReviewPassedRuns": false], .propose)
        ]
        for (index, row) in cases.enumerated() {
            let name = "legacy-\(index)"
            let autopilot = try registerProject(named: name) { $0.approvalGate = row.start }
            var body: [String: Any] = ["project": name]
            body.merge(row.body) { _, new in new }

            let (status, reply) = try await harness.put("/v1/autopilot", body)

            XCTAssertEqual(status, 200)
            XCTAssertEqual(autopilot.approvalGate, row.expected, "\(row)")
            XCTAssertEqual(reply["approvalGate"] as? String, row.expected.rawValue)
        }
    }

    func testPutRejectsAnUnknownReviewGateValue() async throws {
        let autopilot = try registerProject(named: "alpha", configure: { _ in })

        let (status, _) = try await harness.put("/v1/autopilot", ["project": "alpha", "approvalGate": "merge"])

        XCTAssertEqual(status, 400)
        XCTAssertEqual(autopilot.approvalGate, .propose)
    }

    /// `PUT` with `autonomy` sets the three switches together — the dial's own
    /// semantics, checked against what a run actually does: `land` merges,
    /// `propose` parks at the gate, `off` is never picked up unattended.
    func testPutAutonomySetsAllThreeSwitchesToLand() async throws {
        let autopilot = try registerProject(named: "alpha", configure: { _ in })

        let (status, body) = try await harness.put("/v1/autopilot", ["project": "alpha", "autonomy": "land"])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["autonomy"] as? String, "land")
        XCTAssertTrue(autopilot.autonomousWorkEnabled)
        XCTAssertTrue(autopilot.approveReviewPassedRuns)
        XCTAssertTrue(autopilot.autoMergeOnApproval)
    }

    func testPutAutonomyProposeEnablesWorkWithoutTheOtherTwo() async throws {
        let autopilot = try registerProject(named: "alpha", configure: { _ in })

        let (status, body) = try await harness.put("/v1/autopilot", ["project": "alpha", "autonomy": "propose"])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["autonomy"] as? String, "propose")
        XCTAssertTrue(autopilot.autonomousWorkEnabled)
        XCTAssertFalse(autopilot.approveReviewPassedRuns)
        XCTAssertFalse(autopilot.autoMergeOnApproval)
    }

    func testPutAutonomyOffDisarmsAllThreeSwitches() async throws {
        let autopilot = try registerProject(named: "alpha") { autopilot in
            autopilot.autonomousWorkEnabled = true
            autopilot.approvalGate = .land
        }

        let (status, body) = try await harness.put("/v1/autopilot", ["project": "alpha", "autonomy": "off"])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["autonomy"] as? String, "off")
        XCTAssertFalse(autopilot.autonomousWorkEnabled)
        XCTAssertFalse(autopilot.approveReviewPassedRuns)
        XCTAssertFalse(autopilot.autoMergeOnApproval)
    }

    /// A value the dial doesn't recognise is a 400, not a silent no-op.
    func testPutRejectsAnUnknownAutonomyValue() async throws {
        let autopilot = try registerProject(named: "alpha", configure: { _ in })

        let (status, body) = try await harness.put("/v1/autopilot", ["project": "alpha", "autonomy": "sideways"])

        XCTAssertEqual(status, 400)
        XCTAssertEqual(body["error"] as? String, "\"autonomy\" must be \"off\", \"propose\" or \"land\"")
        XCTAssertFalse(autopilot.autonomousWorkEnabled)
    }

    /// The old switches are deprecated, not removed: a `PUT` naming only them —
    /// no `autonomy` field at all — still works, and produces the same dial a
    /// `PUT` of `autonomy` would.
    func testPutWithOnlyTheOldSwitchesProducesTheSameDial() async throws {
        let autopilot = try registerProject(named: "alpha", configure: { _ in })

        let (status, body) = try await harness.put("/v1/autopilot", [
            "project": "alpha", "autonomousWorkEnabled": true,
            "approveReviewPassedRuns": true, "autoMergeOnApproval": true
        ])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["autonomy"] as? String, "land")
        XCTAssertTrue(autopilot.autonomousWorkEnabled)
        XCTAssertTrue(autopilot.approveReviewPassedRuns)
        XCTAssertTrue(autopilot.autoMergeOnApproval)
    }

    // MARK: - Run state

    /// The question nothing could answer before: is this project running
    /// something? A fresh project is running nothing, and says so.
    func testReportsAnIdleProjectAsIdle() async throws {
        try registerProject(named: "alpha", configure: { _ in })

        let (status, body) = try await harness.get("/v1/autopilot?project=alpha")
        let run = try XCTUnwrap(body["run"] as? [String: Any])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(run["state"] as? String, "idle")
        XCTAssertEqual(run["running"] as? Bool, false)
        XCTAssertTrue(run["item"] is NSNull)
        XCTAssertTrue(run["startedAt"] is NSNull)
        XCTAssertTrue(run["detail"] is NSNull)
    }

    /// And when it is running, it names the item and when it started — the two
    /// facts the 2026-08-09 investigation had to reconstruct from four sources.
    func testNamesTheItemInFlightAndWhenItStarted() async throws {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let autopilot = try registerProject(named: "alpha", configure: { _ in })
        autopilot.stageRunForTesting(status: .running(itemIndex: 0, total: 1), queue: [stagedItem("item-1")])
        autopilot.stageExecutingRunForTesting(true)
        autopilot.stageItemStartedAtForTesting(started)

        let (status, body) = try await harness.get("/v1/autopilot?project=alpha")
        let run = try XCTUnwrap(body["run"] as? [String: Any])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(run["state"] as? String, "running")
        XCTAssertEqual(run["running"] as? Bool, true)
        XCTAssertEqual(run["item"] as? String, "item-1")
        XCTAssertEqual(run["itemTitle"] as? String, "ITEM-1")
        XCTAssertEqual(run["startedAt"] as? String, "2023-11-14T22:13:20Z")
    }

    /// A project claiming busy with no run behind it reads as `inconsistent`,
    /// not as `idle` and not as `running`. Rounding it to either is what made
    /// "kiteloop refuses everything" take an hour and three wrong diagnoses.
    func testShowsABusyClaimWithNoRunBehindItAsInconsistent() async throws {
        let autopilot = try registerProject(named: "alpha", configure: { _ in })
        autopilot.stageRunForTesting(status: .running(itemIndex: 0, total: 1), queue: [stagedItem("item-1")])

        let (status, body) = try await harness.get("/v1/autopilot?project=alpha")
        let run = try XCTUnwrap(body["run"] as? [String: Any])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(run["state"] as? String, "inconsistent")
        XCTAssertEqual(run["running"] as? Bool, false)
        XCTAssertEqual(run["status"] as? String, "running", "the stale claim is shown, not hidden")
        XCTAssertNotNil(run["detail"] as? String, "an inconsistent state has to say what is wrong")
    }

    /// The read that reports the stale claim clears it: a project driven
    /// unattended posts no run by hand and reopens nothing, and one sat
    /// `inconsistent` for a day with every read saying so.
    func testTheReadThatReportsAnInconsistentClaimClearsItForTheNext() async throws {
        let autopilot = try registerProject(named: "alpha", configure: { _ in })
        autopilot.stageRunForTesting(status: .running(itemIndex: 0, total: 1), queue: [stagedItem("item-1")])

        let (_, first) = try await harness.get("/v1/autopilot?project=alpha")
        XCTAssertEqual((first["run"] as? [String: Any])?["state"] as? String, "inconsistent",
                       "the read says what it found")

        let (_, second) = try await harness.get("/v1/autopilot?project=alpha")
        XCTAssertEqual((second["run"] as? [String: Any])?["state"] as? String, "idle")
        XCTAssertEqual(autopilot.status, .idle)
    }

    /// `GET /v1/projects` clears it the same way — it is the read the fleet
    /// and a driver's dashboard take.
    func testAProjectsListingClearsAnInconsistentClaimToo() async throws {
        let autopilot = try registerProject(named: "alpha", configure: { _ in })
        autopilot.stageRunForTesting(status: .running(itemIndex: 0, total: 1), queue: [stagedItem("item-1")])

        let (_, listing) = try await harness.get("/v1/projects")
        let project = try XCTUnwrap((listing["projects"] as? [[String: Any]])?.first { $0["name"] as? String == "alpha" })
        XCTAssertEqual((project["run"] as? [String: Any])?["state"] as? String, "inconsistent")
        XCTAssertEqual(autopilot.status, .idle, "cleared once reported")
    }

    /// A paused queue with work left is a hold, not a fault — an operator must be
    /// able to tell "resume this" from "this is stuck".
    func testShowsAPausedQueueWithItemsLeftAsHeld() async throws {
        let autopilot = try registerProject(named: "alpha", configure: { _ in })
        autopilot.stageRunForTesting(status: .paused,
                                     queue: [stagedItem("item-1"), stagedItem("item-2")])
        autopilot.stageQueueIndexForTesting(1)

        let (_, body) = try await harness.get("/v1/autopilot?project=alpha")
        let run = try XCTUnwrap(body["run"] as? [String: Any])

        XCTAssertEqual(run["state"] as? String, "held")
        XCTAssertEqual(run["heldItems"] as? Int, 1)
        XCTAssertEqual(run["status"] as? String, "paused")
    }

    /// Run state and live spend belong to the read. `PUT` answers with what it
    /// wrote, and either of those there would be a value the write never set.
    func testWriteResponsesCarryNoRunState() async throws {
        try registerProject(named: "alpha", configure: { _ in })

        let (_, put) = try await harness.put("/v1/autopilot", ["project": "alpha", "maxRetries": 5])
        let (_, reset) = try await harness.post("/v1/autopilot/reset", ["project": "alpha"])

        XCTAssertNil(put["run"])
        XCTAssertNil(reset["run"])
        XCTAssertNil(put["sessionSpendUSD"])
        XCTAssertNil(reset["sessionSpendUSD"])
    }

    // MARK: - What the session has spent

    /// The figure the project's budget is measured against. A session outlives
    /// a run — every driver starts one item per run — so a driver deciding
    /// whether tonight's queue is still affordable cannot derive it from any
    /// one run's cost, and the endpoint that reports the budget has to report
    /// the spend.
    func testReportsWhatTheSessionHasSpentAcrossItsRuns() async throws {
        let autopilot = try registerProject(named: "alpha", configure: { _ in })
        autopilot.stageSpentSessionForTesting(capUSD: 30, spentUSD: 6)    // runs already finished
        autopilot.stageInFlightCostForTesting(spentUSD: 1.5, capUSD: 4)   // the item running now

        let (status, body) = try await harness.get("/v1/autopilot?project=alpha")

        XCTAssertEqual(status, 200)
        let spend = try XCTUnwrap(body["sessionSpendUSD"] as? Double)
        XCTAssertEqual(spend, 7.5, accuracy: 0.0001, "the finished runs plus the item in flight")
    }

    /// Reported at zero rather than omitted: a session that has spent nothing is
    /// a fact about the project, and a missing field reads as "this build cannot
    /// tell me" — which is the answer a driver would have to treat as unknown.
    func testReportsZeroSessionSpendBeforeAnythingHasRun() async throws {
        try registerProject(named: "alpha", configure: { _ in })

        let (_, body) = try await harness.get("/v1/autopilot?project=alpha")

        XCTAssertEqual(body["sessionSpendUSD"] as? Double, 0)
    }

    /// One call answers "what is every project doing?" — and each project
    /// answers for itself rather than inheriting its neighbour's state.
    func testProjectsListReportsRunStatePerProject() async throws {
        let alpha = try registerProject(named: "alpha", configure: { _ in })
        alpha.stageRunForTesting(status: .running(itemIndex: 0, total: 1), queue: [stagedItem("item-1")])
        alpha.stageExecutingRunForTesting(true)
        try registerProject(named: "beta", configure: { _ in })

        let (status, body) = try await harness.get("/v1/projects")
        let projects = try XCTUnwrap(body["projects"] as? [[String: Any]])
        let byName = Dictionary(uniqueKeysWithValues: projects.map { ($0["name"] as? String ?? "", $0) })

        XCTAssertEqual(status, 200)
        let alphaRun = try XCTUnwrap(byName["alpha"]?["run"] as? [String: Any])
        let betaRun = try XCTUnwrap(byName["beta"]?["run"] as? [String: Any])
        XCTAssertEqual(alphaRun["state"] as? String, "running")
        XCTAssertEqual(alphaRun["item"] as? String, "item-1")
        XCTAssertEqual(betaRun["state"] as? String, "idle")
    }

    /// The guarantee the whole thing rests on: `GET /v1/projects` and
    /// `GET /v1/autopilot` are the same derivation, so a driver polling either
    /// gets the same answer.
    func testProjectsListAndAutopilotAgreeOnRunState() async throws {
        let autopilot = try registerProject(named: "alpha", configure: { _ in })
        autopilot.stageRunForTesting(status: .paused, queue: [stagedItem("item-1")])
        autopilot.stageQueueIndexForTesting(1)

        let (_, listBody) = try await harness.get("/v1/projects")
        // The read that reported the stale claim cleared it; stage the same
        // claim again so the second endpoint derives from the same state.
        autopilot.stageRunForTesting(status: .paused, queue: [stagedItem("item-1")])
        autopilot.stageQueueIndexForTesting(1)
        let (_, autopilotBody) = try await harness.get("/v1/autopilot?project=alpha")

        let listed = try XCTUnwrap((listBody["projects"] as? [[String: Any]])?.first?["run"] as? [String: Any])
        let read = try XCTUnwrap(autopilotBody["run"] as? [String: Any])
        XCTAssertEqual(listed["state"] as? String, read["state"] as? String)
        XCTAssertEqual(listed["state"] as? String, "inconsistent")
        XCTAssertEqual(listed["detail"] as? String, read["detail"] as? String)
    }

    /// `GET /v1/projects` reports the branch a run would actually use: the
    /// configured base as set, the checkout's own branch when nothing is set,
    /// and null for a root that is not a git repository — so "run on
    /// `quality/rebased`" can be checked against the one project it names.
    func testProjectsListReportsTheEffectiveBaseBranch() async throws {
        try registerProject(named: "alpha") { $0.baseBranch = "quality/rebased" }
        try registerProject(named: "beta", configure: { _ in })
        try registerProject(named: "gamma", configure: { _ in })
        let gammaRoot = try XCTUnwrap(registry.entry(forProject: "gamma")).session.project.rootURL
        git(["init"], in: gammaRoot)
        git(["config", "user.email", "test@test.com"], in: gammaRoot)
        git(["config", "user.name", "Test"], in: gammaRoot)
        git(["commit", "--allow-empty", "-m", "init"], in: gammaRoot)
        let gammaBranch = git(["rev-parse", "--abbrev-ref", "HEAD"], in: gammaRoot)
        XCTAssertFalse(gammaBranch.isEmpty)

        let (status, body) = try await harness.get("/v1/projects")
        let projects = try XCTUnwrap(body["projects"] as? [[String: Any]])
        let byName = Dictionary(uniqueKeysWithValues: projects.map { ($0["name"] as? String ?? "", $0) })

        XCTAssertEqual(status, 200)
        XCTAssertEqual(byName["alpha"]?["baseBranch"] as? String, "quality/rebased")
        XCTAssertEqual(byName["alpha"]?["unattendedPermissions"] as? String, "auto",
                       "how an unattended run is permitted is stated per project, not left as a default")
        XCTAssertTrue(byName["beta"]?["baseBranch"] is NSNull, "not a repository — nothing to resolve to")
        XCTAssertEqual(byName["gamma"]?["baseBranch"] as? String, gammaBranch,
                       "unset resolves to the branch the checkout is on")
    }

    /// The queue entry a staged run sits on; its title is what the run state
    /// reports back.
    private func stagedItem(_ id: String) -> BacklogItem {
        BacklogItem(id: id, title: id.uppercased(), verify: "true", status: .ready, type: .local, size: .s)
    }

    // MARK: - PUT: worker/reviewer by id or name

    /// The headline of the endpoint: a driver that just hired "Builder" and
    /// "Reviewer" can assign them by the names it used, without first looking up
    /// their UUIDs. The response always reports ids, so a read-back is stable.
    func testPutAssignsWorkerAndReviewerByName() async throws {
        let autopilot = try registerProject(named: "alpha", configure: { _ in })
        let worker = try hire("Builder", inProject: "alpha")
        let reviewer = try hire("Reviewer", inProject: "alpha")

        let (status, body) = try await harness.put("/v1/autopilot", [
            "project": "alpha", "worker": "Builder", "reviewer": "Reviewer"
        ])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["worker"] as? String, worker)
        XCTAssertEqual(body["reviewer"] as? String, reviewer)
        XCTAssertEqual(autopilot.workerAgentID, worker)
        XCTAssertEqual(autopilot.reviewerAgentID, reviewer)
    }

    /// Ids keep working — names are an addition, not a replacement.
    func testPutAssignsWorkerAndReviewerByID() async throws {
        let autopilot = try registerProject(named: "alpha", configure: { _ in })
        let worker = try hire("Builder", inProject: "alpha")
        let reviewer = try hire("Reviewer", inProject: "alpha")

        let (status, body) = try await harness.put("/v1/autopilot", [
            "project": "alpha", "worker": worker, "reviewer": reviewer
        ])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["worker"] as? String, worker)
        XCTAssertEqual(autopilot.reviewerAgentID, reviewer)
    }

    /// The coordinator resolves by name too, and null puts it back on the
    /// The per-project coordinator persona retired (the-run-supervisor-retires):
    /// the field is tolerated so old callers keep working, ignored so it does
    /// nothing, and absent from the payload so new callers never learn it.
    func testPutToleratesTheRetiredCoordinatorField() async throws {
        let autopilot = try registerProject(named: "alpha", configure: { _ in })
        _ = try hire("Coordinator", inProject: "alpha")

        let (status, body) = try await harness.put(
            "/v1/autopilot", ["project": "alpha", "coordinator": "Coordinator"]
        )
        XCTAssertEqual(status, 200, "a deprecated field is ignored, not refused")
        XCTAssertNil(body["coordinator"], "the payload no longer carries the retired field")
        XCTAssertNotNil(autopilot)
    }

    /// A name nobody answers to is a 400, not a silent no-op that leaves the
    /// driver believing the pair is configured.
    func testPutRejectsUnknownAgentName() async throws {
        let autopilot = try registerProject(named: "alpha", configure: { _ in })
        try hire("Builder", inProject: "alpha")

        let (status, body) = try await harness.put("/v1/autopilot", [
            "project": "alpha", "worker": "Nobody"
        ])

        XCTAssertEqual(status, 400)
        XCTAssertEqual(body["error"] as? String, "No agent matching \"worker\" in this project")
        XCTAssertNil(autopilot.workerAgentID)
    }

    /// A rejected body must not land half of itself: the known worker stays
    /// unassigned when the reviewer in the same PUT can't be resolved.
    func testPutWithOneUnknownNameAssignsNeither() async throws {
        let autopilot = try registerProject(named: "alpha", configure: { _ in })
        try hire("Builder", inProject: "alpha")

        let (status, body) = try await harness.put("/v1/autopilot", [
            "project": "alpha", "worker": "Builder", "reviewer": "Nobody"
        ])

        XCTAssertEqual(status, 400)
        XCTAssertEqual(body["error"] as? String, "No agent matching \"reviewer\" in this project")
        XCTAssertNil(autopilot.workerAgentID)
        XCTAssertNil(autopilot.reviewerAgentID)
    }

    /// Omitted fields are left alone, so a PUT that only tunes a knob can't
    /// disband an already-configured pair.
    func testPutLeavesOmittedFieldsUnchanged() async throws {
        let autopilot = try registerProject(named: "alpha", configure: { _ in })
        let worker = try hire("Builder", inProject: "alpha")
        let reviewer = try hire("Reviewer", inProject: "alpha")
        _ = try await harness.put("/v1/autopilot", [
            "project": "alpha", "worker": "Builder", "reviewer": "Reviewer"
        ])

        let (status, body) = try await harness.put(
            "/v1/autopilot", ["project": "alpha", "maxRetries": 5]
        )

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["maxRetries"] as? Int, 5)
        XCTAssertEqual(autopilot.workerAgentID, worker)
        XCTAssertEqual(autopilot.reviewerAgentID, reviewer)
    }

    /// "No separate reviewer" is a setting, so the API can say it and set it:
    /// `GET` reports a null reviewer, and `PUT` with null clears an assigned one
    /// while leaving the worker alone.
    func testPutWithANullReviewerClearsItAndGetReportsNull() async throws {
        let autopilot = try registerProject(named: "alpha", configure: { _ in })
        let worker = try hire("Builder", inProject: "alpha")
        try hire("Reviewer", inProject: "alpha")
        _ = try await harness.put("/v1/autopilot", [
            "project": "alpha", "worker": "Builder", "reviewer": "Reviewer"
        ])

        let (status, put) = try await harness.put(
            "/v1/autopilot", ["project": "alpha", "reviewer": NSNull()]
        )
        let (_, body) = try await harness.get("/v1/autopilot?project=alpha")

        XCTAssertEqual(status, 200)
        XCTAssertTrue(put["reviewer"] is NSNull, "the reply reports the cleared reviewer as null")
        XCTAssertTrue(body["reviewer"] is NSNull, "GET reports no separate reviewer as null")
        XCTAssertNil(autopilot.reviewerAgentID)
        XCTAssertEqual(autopilot.workerAgentID, worker)
    }

    /// The worker has no "none" meaning, so clearing it stays a 400.
    func testPutWithANullWorkerIsStillRefused() async throws {
        try registerProject(named: "alpha", configure: { _ in })

        let (status, body) = try await harness.put(
            "/v1/autopilot", ["project": "alpha", "worker": NSNull()]
        )

        XCTAssertEqual(status, 400)
        XCTAssertEqual(body["error"] as? String, "No agent matching \"worker\" in this project")
    }

    /// Names are scoped to the project being configured — an agent hired in one
    /// project can't be assigned in another.
    func testPutResolvesNamesWithinTheRequestedProjectOnly() async throws {
        try registerProject(named: "alpha", configure: { _ in })
        let beta = try registerProject(named: "beta", configure: { _ in })
        try hire("Builder", inProject: "alpha")

        let (status, _) = try await harness.put("/v1/autopilot", [
            "project": "beta", "worker": "Builder"
        ])

        XCTAssertEqual(status, 400)
        XCTAssertNil(beta.workerAgentID)
    }

    func testPutRequiresBearerToken() async throws {
        let autopilot = try registerProject(named: "alpha", configure: { _ in })
        try hire("Builder", inProject: "alpha")

        let (status, body) = try await harness.put(
            "/v1/autopilot", ["project": "alpha", "worker": "Builder"], bearer: nil
        )

        XCTAssertEqual(status, 401)
        XCTAssertEqual(body["error"] as? String, "Missing or invalid bearer token")
        XCTAssertNil(autopilot.workerAgentID)
    }

    // MARK: - PUT: opening a pull request

    /// The headless half of ADR-0001's PR step: a driver can turn branch
    /// publishing on, read it back, and — because it is a project setting — find
    /// it still on after a relaunch.
    func testPutSetsAndPersistsOpenPullRequest() async throws {
        let configURL = tempDir.appendingPathComponent("autopilot-alpha.json")
        let autopilot = try registerProject(named: "alpha", configURL: configURL, configure: { _ in })
        XCTAssertFalse(autopilot.openPullRequest, "off until asked for")

        let (status, body) = try await harness.put(
            "/v1/autopilot", ["project": "alpha", "openPullRequest": true]
        )

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["openPullRequest"] as? Bool, true)
        XCTAssertTrue(autopilot.openPullRequest)

        let (_, read) = try await harness.get("/v1/autopilot?project=alpha")
        XCTAssertEqual(read["openPullRequest"] as? Bool, true, "a read matches the last write")

        let saved = try JSONSerialization.jsonObject(
            with: Data(contentsOf: configURL)
        ) as? [String: Any] ?? [:]
        XCTAssertEqual(saved["openPullRequest"] as? Bool, true)
    }

    /// It goes back off again, and a body that doesn't mention it leaves it
    /// alone — the same contract every other knob on this endpoint has.
    func testOpenPullRequestTurnsBackOffAndSurvivesAnUnrelatedWrite() async throws {
        let autopilot = try registerProject(named: "alpha", configure: { _ in })
        _ = try await harness.put("/v1/autopilot", ["project": "alpha", "openPullRequest": true])

        let (_, untouched) = try await harness.put(
            "/v1/autopilot", ["project": "alpha", "maxRetries": 5]
        )
        XCTAssertEqual(untouched["openPullRequest"] as? Bool, true)

        let (status, body) = try await harness.put(
            "/v1/autopilot", ["project": "alpha", "openPullRequest": false]
        )
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["openPullRequest"] as? Bool, false)
        XCTAssertFalse(autopilot.openPullRequest)
    }

    // MARK: - PUT: the base branch

    /// A name sets the branch runs fork from and land on; `""` and `null` both
    /// clear it, back to the checkout's own `HEAD`; a body that doesn't mention
    /// it leaves it alone. Persisted, since a base that reverted on relaunch
    /// would put the next night's merges on the wrong branch.
    func testPutSetsAndClearsTheBaseBranch() async throws {
        let configURL = tempDir.appendingPathComponent("autopilot-alpha.json")
        let autopilot = try registerProject(named: "alpha", configURL: configURL, configure: { _ in })

        let (status, body) = try await harness.put("/v1/autopilot", ["project": "alpha", "baseBranch": " release "])
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["baseBranch"] as? String, "release", "trimmed on the way in")
        XCTAssertEqual(autopilot.baseBranch, "release")
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any] ?? [:]
        XCTAssertEqual(saved["baseBranch"] as? String, "release")

        let (_, untouched) = try await harness.put("/v1/autopilot", ["project": "alpha", "maxRetries": 5])
        XCTAssertEqual(untouched["baseBranch"] as? String, "release")

        let (_, blank) = try await harness.put("/v1/autopilot", ["project": "alpha", "baseBranch": ""])
        XCTAssertTrue(blank["baseBranch"] is NSNull, "an empty name is not a branch called nothing")
        XCTAssertNil(autopilot.baseBranch)

        _ = try await harness.put("/v1/autopilot", ["project": "alpha", "baseBranch": "release"])
        let (_, nulled) = try await harness.put("/v1/autopilot", ["project": "alpha", "baseBranch": NSNull()])
        XCTAssertTrue(nulled["baseBranch"] is NSNull)
        XCTAssertNil(autopilot.baseBranch)
    }

    // MARK: - PUT: the worktree setup command

    /// A command runs in a fresh worktree before anything else touches it;
    /// `null` clears it, back to today's behaviour of running nothing; a body
    /// that doesn't mention it leaves it alone. Persisted. Unlike `baseBranch` this field has no
    /// trim-to-nil setter, so `""` is stored as itself — a blank string,
    /// which `runSetupCommand` already treats as nothing to run.
    func testPutSetsAndClearsTheWorktreeSetupCommand() async throws {
        let configURL = tempDir.appendingPathComponent("autopilot-alpha.json")
        let autopilot = try registerProject(named: "alpha", configURL: configURL, configure: { _ in })

        let (status, body) = try await harness.put(
            "/v1/autopilot", ["project": "alpha", "worktreeSetupCommand": "npm ci"])
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["worktreeSetupCommand"] as? String, "npm ci")
        XCTAssertEqual(autopilot.worktreeSetupCommand, "npm ci")
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any] ?? [:]
        XCTAssertEqual(saved["worktreeSetupCommand"] as? String, "npm ci")

        let (_, untouched) = try await harness.put("/v1/autopilot", ["project": "alpha", "maxRetries": 5])
        XCTAssertEqual(untouched["worktreeSetupCommand"] as? String, "npm ci")

        let (_, blank) = try await harness.put("/v1/autopilot", ["project": "alpha", "worktreeSetupCommand": ""])
        XCTAssertEqual(blank["worktreeSetupCommand"] as? String, "")
        XCTAssertEqual(autopilot.worktreeSetupCommand, "")

        _ = try await harness.put("/v1/autopilot", ["project": "alpha", "worktreeSetupCommand": "npm ci"])
        let (_, nulled) = try await harness.put(
            "/v1/autopilot", ["project": "alpha", "worktreeSetupCommand": NSNull()])
        XCTAssertTrue(nulled["worktreeSetupCommand"] is NSNull)
        XCTAssertNil(autopilot.worktreeSetupCommand)
    }

    /// `autoMergeVerifyCommand` is no longer a setting: a `PUT` naming it is
    /// tolerated, stores nothing, and the reply does not carry it.
    func testPutIgnoresTheRetiredMergeVerifyCommand() async throws {
        let configURL = tempDir.appendingPathComponent("autopilot-alpha.json")
        let autopilot = try registerProject(named: "alpha", configURL: configURL, configure: { _ in })

        let (status, body) = try await harness.put(
            "/v1/autopilot", ["project": "alpha", "autoMergeVerifyCommand": "swift test"])

        XCTAssertEqual(status, 200)
        XCTAssertNil(body["autoMergeVerifyCommand"])
        XCTAssertNil(autopilot.autoMergeVerifyCommand)
        let saved = (try? Data(contentsOf: configURL)) ?? Data()
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("autoMergeVerifyCommand"))
    }

    // MARK: - PUT: approving review-passed runs without asking

    /// The in-app half of what `kiteloop-verify.py --marathon --auto-approve`
    /// does from outside: a driver can turn the human gate off for one project,
    /// read it back, and — because it is a project setting — find it still off
    /// after a relaunch.
    func testPutSetsAndPersistsTheReviewGate() async throws {
        let configURL = tempDir.appendingPathComponent("autopilot-alpha.json")
        let autopilot = try registerProject(named: "alpha", configURL: configURL, configure: { _ in })
        XCTAssertFalse(autopilot.approveReviewPassedRuns, "the gate stands until asked otherwise")

        let (status, body) = try await harness.put(
            "/v1/autopilot", ["project": "alpha", "approvalGate": "land"]
        )

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["approvalGate"] as? String, "land")
        XCTAssertTrue(autopilot.approveReviewPassedRuns)

        let (_, read) = try await harness.get("/v1/autopilot?project=alpha")
        XCTAssertEqual(read["approvalGate"] as? String, "land", "a read matches the last write")

        let saved = try JSONSerialization.jsonObject(
            with: Data(contentsOf: configURL)
        ) as? [String: Any] ?? [:]
        XCTAssertEqual(saved["approvalGate"] as? String, "land")
        XCTAssertNil(saved["approveReviewPassedRuns"], "the replaced switches are never written")
        XCTAssertNil(saved["autoMergeOnApproval"])
    }

    /// It goes back on again, and a body that doesn't mention it leaves it
    /// alone — the same contract every other knob on this endpoint has. Putting
    /// the gate back is the more important direction of the two.
    func testTheReviewGateGoesBackToProposeAndSurvivesAnUnrelatedWrite() async throws {
        let autopilot = try registerProject(named: "alpha", configure: { _ in })
        _ = try await harness.put("/v1/autopilot", ["project": "alpha", "approvalGate": "land"])

        let (_, untouched) = try await harness.put(
            "/v1/autopilot", ["project": "alpha", "maxRetries": 5]
        )
        XCTAssertEqual(untouched["approvalGate"] as? String, "land")

        let (status, body) = try await harness.put(
            "/v1/autopilot", ["project": "alpha", "approvalGate": "propose"]
        )
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["approvalGate"] as? String, "propose")
        XCTAssertFalse(autopilot.approveReviewPassedRuns)
    }

    /// One project's widening is one project's. There is no fleet-wide variant,
    /// so a project that never asked for it must still ask its owner.
    func testTheReviewGateIsScopedToItsOwnProject() async throws {
        try registerProject(named: "alpha", configure: { _ in })
        let beta = try registerProject(named: "beta", configure: { _ in })

        _ = try await harness.put("/v1/autopilot", ["project": "alpha", "approvalGate": "land"])

        let (_, betaBody) = try await harness.get("/v1/autopilot?project=beta")
        XCTAssertEqual(betaBody["approvalGate"] as? String, "propose")
        XCTAssertFalse(beta.approveReviewPassedRuns)
    }

    // MARK: - PUT: the behaviour flags are booleans, not numbers

    /// The flags are validated, not coerced. `NSNumber as? Bool` succeeds for a
    /// JSON *number* — `1` bridges to `true` — so `{"useWorktree": 1}` used to
    /// switch worktree isolation on for every run this project makes, with a 200
    /// from a check that reads as if it had rejected it.
    func testPutRejectsANumberForABooleanFlag() async throws {
        for flag in ["autoMergeOnApproval", "openPullRequest", "approveReviewPassedRuns"] {
            let project = "flag-\(flag)"
            try registerProject(named: project, configure: { _ in })
            let (_, before) = try await harness.get("/v1/autopilot?project=\(project)")

            for raw: Any in [1, 0, "true"] {
                let (status, body) = try await harness.put(
                    "/v1/autopilot", ["project": project, flag: raw]
                )
                XCTAssertEqual(status, 400, "\(flag)=\(raw)")
                XCTAssertEqual(body["error"] as? String, "\"\(flag)\" must be true or false")
            }

            let (_, after) = try await harness.get("/v1/autopilot?project=\(project)")
            XCTAssertEqual(after[flag] as? Bool, before[flag] as? Bool,
                           "a rejected body leaves \(flag) exactly as it was")
        }
    }

    /// The rejection is of numbers, not of the flags: every one of them still
    /// takes a real boolean and reads back as one.
    func testPutStillSetsEveryBooleanFlagFromARealBoolean() async throws {
        let autopilot = try registerProject(named: "alpha", configure: { _ in })

        let (status, body) = try await harness.put("/v1/autopilot", [
            "project": "alpha",
            "autoMergeOnApproval": true, "openPullRequest": true,
            "approveReviewPassedRuns": true
        ])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["autoMergeOnApproval"] as? Bool, true)
        XCTAssertEqual(body["openPullRequest"] as? Bool, true)
        XCTAssertEqual(body["approveReviewPassedRuns"] as? Bool, true)
        XCTAssertTrue(autopilot.autoMergeOnApproval)
        XCTAssertTrue(autopilot.openPullRequest)
        XCTAssertTrue(autopilot.approveReviewPassedRuns)
    }

    /// The refute round is retired. A caller written against it still sends
    /// the key: the write is accepted, the key is ignored whatever it holds,
    /// and the rest of the body still applies.
    func testPutIgnoresTheRetiredRefuteSetting() async throws {
        let autopilot = try registerProject(named: "alpha", configure: { _ in })

        for raw: Any in [true, 1] {
            let (status, body) = try await harness.put("/v1/autopilot", [
                "project": "alpha", "refuteRoundEnabled": raw, "openPullRequest": true
            ])

            XCTAssertEqual(status, 200, "refuteRoundEnabled=\(raw) was refused")
            XCTAssertNil(body["refuteRoundEnabled"])
            XCTAssertEqual(body["openPullRequest"] as? Bool, true)
        }
        XCTAssertTrue(autopilot.openPullRequest)
    }

    /// Worktree isolation is not a setting. A caller written against the old
    /// toggle still sends the key: the write is accepted, the key is ignored,
    /// and the rest of the body still applies.
    func testPutIgnoresTheRetiredWorktreeToggle() async throws {
        let autopilot = try registerProject(named: "alpha", configure: { _ in })

        let (status, body) = try await harness.put("/v1/autopilot", [
            "project": "alpha", "useWorktree": false, "openPullRequest": true
        ])

        XCTAssertEqual(status, 200)
        XCTAssertNil(body["useWorktree"])
        XCTAssertEqual(body["openPullRequest"] as? Bool, true)
        XCTAssertTrue(autopilot.openPullRequest)
    }

    /// Protected paths are not a setting. A caller written against it still
    /// sends the key: the write is accepted, the key is ignored, and the rest
    /// of the body still applies.
    func testPutIgnoresTheRetiredProtectedPaths() async throws {
        let autopilot = try registerProject(named: "alpha", configure: { _ in })

        let (status, body) = try await harness.put("/v1/autopilot", [
            "project": "alpha", "protectedPaths": ["docs/suite-status.md"], "openPullRequest": true
        ])

        XCTAssertEqual(status, 200)
        XCTAssertNil(body["protectedPaths"])
        XCTAssertEqual(body["openPullRequest"] as? Bool, true)
        XCTAssertTrue(autopilot.openPullRequest)
    }

    /// The quality judge's switch is gone: the judge scores every run and
    /// never blocks one. A caller written against it still sends the key: the
    /// write is accepted, the key is ignored, and the rest of the body applies.
    func testPutIgnoresTheRetiredQualityJudgeSwitch() async throws {
        let autopilot = try registerProject(named: "alpha", configure: { _ in })

        let (status, body) = try await harness.put("/v1/autopilot", [
            "project": "alpha", "qualityJudgeEnabled": false, "openPullRequest": true
        ])

        XCTAssertEqual(status, 200)
        XCTAssertNil(body["qualityJudgeEnabled"])
        XCTAssertTrue(autopilot.openPullRequest)
    }

    /// The flags are read before anything is written, so a body carrying one bad
    /// flag leaves the whole config alone rather than half-applying it — the same
    /// contract the agent slots already had.
    func testARejectedFlagLeavesTheRestOfTheBodyUnapplied() async throws {
        let autopilot = try registerProject(named: "alpha", configure: { _ in })
        try hire("Builder", inProject: "alpha")

        let (status, _) = try await harness.put("/v1/autopilot", [
            "project": "alpha", "worker": "Builder", "maxRetries": 6,
            "openPullRequest": 1
        ])

        XCTAssertEqual(status, 400)
        XCTAssertNil(autopilot.workerAgentID, "nobody was assigned on the way to the 400")
        XCTAssertEqual(autopilot.maxRetries, 3)
        XCTAssertFalse(autopilot.openPullRequest)
    }

    // MARK: - PUT: how many worker/reviewer rounds an item gets

    /// The headless half of the setting: a driver can widen the round limit,
    /// read the same number back, and — because it is a project setting — find it
    /// still set after a relaunch. Until it became one it was a literal 3 that no
    /// surface could reach.
    func testPutSetsAndPersistsMaxRetries() async throws {
        let configURL = tempDir.appendingPathComponent("autopilot-alpha.json")
        let autopilot = try registerProject(named: "alpha", configURL: configURL, configure: { _ in })
        XCTAssertEqual(autopilot.maxRetries, 3, "the built-in until somebody says otherwise")

        let (status, body) = try await harness.put(
            "/v1/autopilot", ["project": "alpha", "maxRetries": 6]
        )

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["maxRetries"] as? Int, 6)
        XCTAssertEqual(autopilot.maxRetries, 6)

        let (_, read) = try await harness.get("/v1/autopilot?project=alpha")
        XCTAssertEqual(read["maxRetries"] as? Int, 6, "a read matches the last write")

        let saved = try JSONSerialization.jsonObject(
            with: Data(contentsOf: configURL)
        ) as? [String: Any] ?? [:]
        XCTAssertEqual(saved["maxRetries"] as? Int, 6)
    }

    /// Out-of-range values are clamped by the property — so the number the
    /// reply reports is the number the run loop will use, never the one the
    /// body asked for. Zero rounds is the case that matters: it is a run that
    /// cannot reach its own reviewer.
    func testPutClampsMaxRetriesToTheAcceptedRange() async throws {
        let autopilot = try registerProject(named: "alpha", configure: { _ in })

        for (asked, expected) in [(0, 1), (-4, 1), (99, 10)] {
            let (status, body) = try await harness.put(
                "/v1/autopilot", ["project": "alpha", "maxRetries": asked]
            )
            XCTAssertEqual(status, 200, "maxRetries=\(asked)")
            XCTAssertEqual(body["maxRetries"] as? Int, expected, "maxRetries=\(asked)")
            XCTAssertEqual(autopilot.maxRetries, expected, "maxRetries=\(asked)")

            let (_, read) = try await harness.get("/v1/autopilot?project=alpha")
            XCTAssertEqual(read["maxRetries"] as? Int, expected,
                           "a read reports the clamped value, not the one asked for")
        }
    }

    /// A body that doesn't mention it leaves it alone — the same contract every
    /// other knob on this endpoint has.
    func testMaxRetriesSurvivesAnUnrelatedWrite() async throws {
        let autopilot = try registerProject(named: "alpha", configure: { _ in })
        _ = try await harness.put("/v1/autopilot", ["project": "alpha", "maxRetries": 5])

        let (_, untouched) = try await harness.put(
            "/v1/autopilot", ["project": "alpha", "openPullRequest": true]
        )

        XCTAssertEqual(untouched["maxRetries"] as? Int, 5)
        XCTAssertEqual(autopilot.maxRetries, 5)
    }

    // MARK: - PUT: the project's one budget

    /// The headless half of the item: a project's own daily ceiling, set and
    /// read back over the API under its new name — replacing
    /// `perItemCostCapUSD`, `sessionCostCapUSD`, `costCapMargin` and
    /// `dailyBudgetUSD`.
    func testPutSetsAndClearsTheProjectsBudget() async throws {
        let autopilot = try registerProject(named: "alpha", configure: { _ in })

        let (set, setBody) = try await harness.put(
            "/v1/autopilot", ["project": "alpha", "budgetUSD": 25.5]
        )
        XCTAssertEqual(set, 200)
        XCTAssertEqual(setBody["budgetUSD"] as? Double, 25.5)
        XCTAssertEqual(autopilot.budgetUSD, 25.5)

        let (cleared, clearedBody) = try await harness.put(
            "/v1/autopilot", ["project": "alpha", "budgetUSD": NSNull()]
        )
        XCTAssertEqual(cleared, 200)
        XCTAssertTrue(clearedBody["budgetUSD"] is NSNull)
        XCTAssertNil(autopilot.budgetUSD, "null is how a driver removes the ceiling")
    }

    /// Validated rather than coerced. A budget that reads a typo as "no ceiling"
    /// is the exact failure the ceiling exists to prevent, so junk is a 400 and
    /// the previous ceiling stands.
    func testPutRejectsANonPositiveOrNonNumericBudget() async throws {
        let autopilot = try registerProject(named: "alpha") { $0.budgetUSD = 40 }

        for raw: Any in ["20", 0, -5, true, [String: Any]()] {
            let (status, body) = try await harness.put(
                "/v1/autopilot", ["project": "alpha", "budgetUSD": raw]
            )
            XCTAssertEqual(status, 400, "budgetUSD=\(raw)")
            XCTAssertEqual(body["error"] as? String,
                           "\"budgetUSD\" must be a positive number or null")
            XCTAssertEqual(autopilot.budgetUSD, 40, "a rejected body changes nothing")
        }
    }

    /// A $1 ceiling is a real ceiling, and `true` is not one. JSON hands both
    /// back as the same NSNumber type, so the obvious way to reject the boolean
    /// also rejects the number.
    func testAOneDollarProjectBudgetIsAcceptedEvenThoughBooleansAreNot() async throws {
        let autopilot = try registerProject(named: "alpha", configure: { _ in })

        let (accepted, body) = try await harness.put(
            "/v1/autopilot", ["project": "alpha", "budgetUSD": 1]
        )
        XCTAssertEqual(accepted, 200)
        XCTAssertEqual(body["budgetUSD"] as? Double, 1)
        XCTAssertEqual(autopilot.budgetUSD, 1)

        let (rejected, _) = try await harness.put(
            "/v1/autopilot", ["project": "alpha", "budgetUSD": true]
        )
        XCTAssertEqual(rejected, 400)
        XCTAssertEqual(autopilot.budgetUSD, 1,
                       "`true` must not be read as the $1 ceiling it bridges to")
    }

    /// One project's ceiling is one project's — the whole point of splitting the
    /// number was that projects stop spending each other's allowance.
    func testTheProjectBudgetIsScopedToItsOwnProject() async throws {
        try registerProject(named: "alpha", configure: { _ in })
        let beta = try registerProject(named: "beta", configure: { _ in })

        _ = try await harness.put("/v1/autopilot", ["project": "alpha", "budgetUSD": 12])

        let (_, betaBody) = try await harness.get("/v1/autopilot?project=beta")
        XCTAssertTrue(betaBody["budgetUSD"] is NSNull)
        XCTAssertNil(beta.budgetUSD)
    }

    /// It is a project setting, so it lives in the project's own config file and
    /// survives a relaunch.
    func testTheProjectBudgetPersistsToTheProjectConfigFile() async throws {
        let configURL = tempDir.appendingPathComponent("autopilot-alpha.json")
        try registerProject(named: "alpha", configURL: configURL, configure: { _ in })

        _ = try await harness.put("/v1/autopilot", ["project": "alpha", "budgetUSD": 18])

        let saved = try JSONSerialization.jsonObject(
            with: Data(contentsOf: configURL)
        ) as? [String: Any] ?? [:]
        XCTAssertEqual(saved["dailyBudgetUSD"] as? Double, 18,
                       "budgetUSD is the API's name for the same stored field")
    }

    // MARK: - Reset

    /// Every tuned knob goes back to its built-in default, while the worker and
    /// reviewer stay assigned — a reset clears the settings, it doesn't disband
    /// the pair, so autopilot is still runnable afterwards.
    func testResetRestoresDefaultsAndKeepsWorkerReviewer() async throws {
        let autopilot = try registerProject(named: "alpha") { autopilot in
            autopilot.workerAgentID = "worker-1"
            autopilot.reviewerAgentID = "reviewer-1"
            autopilot.maxRetries = 6
            autopilot.budgetUSD = 25
            autopilot.baseBranch = "release"
            autopilot.openPullRequest = true
            autopilot.approvalGate = .land
        }

        let (status, body) = try await harness.post("/v1/autopilot/reset", ["project": "alpha"])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["project"] as? String, "alpha")
        XCTAssertEqual(body["worker"] as? String, "worker-1")
        XCTAssertEqual(body["reviewer"] as? String, "reviewer-1")
        XCTAssertNil(body["useWorktree"])
        XCTAssertEqual(body["maxRetries"] as? Int, 3)
        XCTAssertEqual(body["stallTimeoutMinutes"] as? Int, 20)
        XCTAssertNil(body["qualityJudgeEnabled"])
        XCTAssertNil(body["refuteRoundEnabled"])
        XCTAssertTrue(body["budgetUSD"] is NSNull)
        XCTAssertEqual(body["autoMergeOnApproval"] as? Bool, false)
        XCTAssertNil(body["autoMergeVerifyCommand"])
        XCTAssertEqual(body["autoMergeVerifyTimeoutMinutes"] as? Int, 30)
        XCTAssertTrue(body["baseBranch"] is NSNull, "a reset puts the runs back on the checkout's own HEAD")
        XCTAssertNil(autopilot.baseBranch)
        XCTAssertEqual(body["openPullRequest"] as? Bool, false)
        XCTAssertEqual(body["approveReviewPassedRuns"] as? Bool, false,
                       "a reset puts the human gate back — it is the one knob it must not leave widened")
        XCTAssertFalse(autopilot.approveReviewPassedRuns)
        XCTAssertEqual(body["autonomy"] as? String, "off")

        // The response isn't just a rendering of the defaults — the autopilot
        // that will run the next item holds them too.
        XCTAssertEqual(autopilot.maxRetries, 3)
        XCTAssertEqual(autopilot.stallTimeoutMinutes, 20)
        XCTAssertNil(autopilot.budgetUSD)
        XCTAssertEqual(autopilot.autoMergeVerifyTimeoutMinutes, 30)
        XCTAssertEqual(autopilot.workerAgentID, "worker-1")
    }

    /// A reset survives a relaunch: it rewrites the project's persisted config
    /// rather than only clearing the live object.
    func testResetPersistsDefaultsToConfigFile() async throws {
        let configURL = tempDir.appendingPathComponent("autopilot-alpha.json")
        try registerProject(named: "alpha", configURL: configURL) { autopilot in
            autopilot.workerAgentID = "worker-1"
            autopilot.budgetUSD = 2.5
        }

        let (status, _) = try await harness.post("/v1/autopilot/reset", ["project": "alpha"])

        XCTAssertEqual(status, 200)
        let saved = try JSONSerialization.jsonObject(
            with: Data(contentsOf: configURL)
        ) as? [String: Any] ?? [:]
        XCTAssertEqual(saved["workerAgentID"] as? String, "worker-1")
        XCTAssertNil(saved["stallTimeoutMinutes"],
                     "a derived clock is not persisted — there is no setting to write")
        XCTAssertNil(saved["autoMergeVerifyTimeoutMinutes"])
        // Cleared caps are encoded as absent, which decodes back to nil.
        XCTAssertNil(saved["dailyBudgetUSD"])
    }

    /// Resetting one project must not touch another open project's settings.
    func testResetLeavesOtherProjectsUntouched() async throws {
        try registerProject(named: "alpha") { $0.maxRetries = 6 }
        let beta = try registerProject(named: "beta") { $0.maxRetries = 8 }

        let (status, _) = try await harness.post("/v1/autopilot/reset", ["project": "alpha"])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(beta.maxRetries, 8)
    }

    func testResetWithoutProjectIs400() async throws {
        let (status, body) = try await harness.post("/v1/autopilot/reset", [:])
        XCTAssertEqual(status, 400)
        XCTAssertEqual(body["error"] as? String, "Body must include \"project\"")
    }

    func testResetUnknownProjectIs409() async throws {
        try registerProject(named: "alpha", configure: { _ in })

        let (status, body) = try await harness.post("/v1/autopilot/reset", ["project": "beta"])

        XCTAssertEqual(status, 409)
        XCTAssertEqual(body["error"] as? String, "Project not open in Kiteloop: beta")
    }

    /// A reset mutates state, so it must be behind the token like every other write.
    func testResetRequiresBearerToken() async throws {
        let autopilot = try registerProject(named: "alpha") { $0.maxRetries = 6 }

        let (status, body) = try await harness.post("/v1/autopilot/reset", ["project": "alpha"], bearer: nil)

        XCTAssertEqual(status, 401)
        XCTAssertEqual(body["error"] as? String, "Missing or invalid bearer token")
        XCTAssertEqual(autopilot.maxRetries, 6)
    }

    // MARK: - Errors

    func testMissingProjectQueryIs400() async throws {
        let (status, body) = try await harness.get("/v1/autopilot")
        XCTAssertEqual(status, 400)
        XCTAssertEqual(body["error"] as? String, "Missing ?project=")
    }

    func testUnknownProjectIs409() async throws {
        try registerProject(named: "alpha", configure: { _ in })

        let (status, body) = try await harness.get("/v1/autopilot?project=beta")

        XCTAssertEqual(status, 409)
        XCTAssertEqual(body["error"] as? String, "Project not open in Kiteloop: beta")
    }

    func testRequiresBearerToken() async throws {
        try registerProject(named: "alpha", configure: { _ in })

        let (status, body) = try await harness.get("/v1/autopilot?project=alpha", bearer: nil)

        XCTAssertEqual(status, 401)
        XCTAssertEqual(body["error"] as? String, "Missing or invalid bearer token")
    }

    // MARK: - Helpers

    /// Builds a real `ProjectSession` over a throwaway directory and registers it
    /// with a fresh autopilot. Without a `configURL` the autopilot has nowhere to
    /// persist, so the mutations stay in memory; pass one to assert on what a
    /// relaunch would read back.
    @discardableResult
    private func registerProject(
        named name: String,
        configURL: URL? = nil,
        landedRuns: (count: Int, workerSeconds: Double, gateSeconds: Double?)? = nil,
        workerTurns: Int? = nil,
        configure: (BacklogAutopilot) -> Void
    ) throws -> BacklogAutopilot {
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

        let autopilot = BacklogAutopilot()
        autopilot.configure(
            orchestrator: orchestrator,
            backlogViewModel: session.backlogViewModel,
            configURL: configURL,
            metricStore: landedRuns.map { makeMetricStore($0, workerTurns: workerTurns,
                                                          projectPath: rootURL.path(percentEncoded: false)) },
            projectPath: rootURL.path(percentEncoded: false),
            projectName: name
        )
        configure(autopilot)
        registry.register(session: session, autopilot: autopilot)
        return autopilot
    }

    /// Where each of the two clocks came from, as the reply states it — one
    /// answer per clock, since each is counted from its own phase's runs.
    private func runTimeoutSource(_ body: [String: Any]) -> [String: String]? {
        body["runTimeoutSource"] as? [String: String]
    }

    /// A ledger holding `runs.count` of this project's runs, each having spent
    /// the given seconds in the worker phase and the gate phase. A nil
    /// `gateSeconds` is a run that stopped before the merge gate: still a
    /// worker sample, and no gate sample at all.
    private func makeMetricStore(_ runs: (count: Int, workerSeconds: Double, gateSeconds: Double?),
                                 workerTurns: Int? = nil,
                                 projectPath: String) -> TaskMetricStore {
        let store = TaskMetricStore(
            metricsURL: tempDir.appendingPathComponent("task-metrics.jsonl"),
            estimatesURL: tempDir.appendingPathComponent("task-estimates.jsonl"),
            approvalsURL: tempDir.appendingPathComponent("task-approvals.jsonl"),
            mergesURL: tempDir.appendingPathComponent("task-merges.jsonl"))
        for index in 0..<runs.count {
            var record = TaskMetricRecord(
                projectPath: projectPath, projectName: "demo", itemID: "item-\(index)",
                title: "An item", epic: nil, declaredSize: nil, startedAt: Date(),
                completedAt: Date(), durationSeconds: 9_000, costUSD: 1, reviewerRetries: 0,
                outcome: "done", workerAgent: nil, reviewerAgent: nil, executionID: nil,
                toolErrors: nil)
            record.workerPhaseSeconds = runs.workerSeconds
            record.gatePhaseSeconds = runs.gateSeconds
            record.workerTurns = workerTurns
            store.append(record)
        }
        return store
    }

    /// Puts a named agent on a registered project's orchestrator — the roster
    /// `PUT /v1/autopilot` resolves names against — and returns its id.
    @discardableResult
    private func hire(_ name: String, inProject project: String) throws -> String {
        let entry = try XCTUnwrap(registry.entry(forProject: project))
        let agent = Agent(
            name: name,
            model: "sonnet",
            systemPrompt: "",
            tools: [],
            denied: [],
            permissionMode: "acceptEdits"
        )
        entry.session.orchestrator.addAgent(agent)
        return agent.id
    }

    /// All stores are pointed at the temp directory so the tests never read or
    /// write the developer's real global config.
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

    private func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    /// Runs git in `url` and returns what it printed, trimmed — for the one
    /// test that needs a project root to be a repository.
    @discardableResult
    private func git(_ args: [String], in url: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = url
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
