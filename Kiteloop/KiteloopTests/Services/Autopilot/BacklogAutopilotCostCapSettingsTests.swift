import XCTest
import KiteloopCore
@testable import Kiteloop

/// Covers what the Autopilot tab's **cost cap** fields read and write: how the
/// text fields parse to a cap (blank/junk/non-positive = no cap), how the margin
/// stepper's value is normalized, and that all three survive a reopen of the
/// project — a cap that silently reverted on relaunch would let an unattended
/// queue spend past the ceiling its owner set.
@MainActor
final class BacklogAutopilotCostCapSettingsTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try makeTemporaryDirectory(prefix: "autopilot-cost-caps")
    }

    /// An autopilot wired to `configURL`, the way `MainWindow` wires a project's
    /// `autopilot-config.json`.
    private func makeAutopilot(configURL: URL, reporter: StoreProblemReporter = .shared) -> BacklogAutopilot {
        let autopilot = BacklogAutopilot()
        autopilot.configure(
            orchestrator: Orchestrator(runtime: MockAgentRuntime()),
            backlogViewModel: BacklogViewModel(
                globalConfigStore: GlobalConfigStore(
                    storageURL: tempDir.appendingPathComponent("global-config.json")
                )
            ),
            configURL: configURL,
            reporter: reporter
        )
        return autopilot
    }

    // MARK: - Field parsing

    /// Everything that isn't a positive amount means "no cap". A $0 or negative
    /// ceiling would end every item before it spent anything.
    func testBlankAndJunkAndNonPositiveTextMeanNoCap() {
        for text in ["", "   ", "$", "abc", "0", "0.00", "-3", "$-3"] {
            XCTAssertNil(BacklogAutopilot.parseCostCapUSD(text), "expected no cap for \(text.debugDescription)")
        }
    }

    func testParsesAmountsWithOptionalDollarSignAndPadding() {
        XCTAssertEqual(BacklogAutopilot.parseCostCapUSD("5"), 5)
        XCTAssertEqual(BacklogAutopilot.parseCostCapUSD("12.50"), 12.50)
        XCTAssertEqual(BacklogAutopilot.parseCostCapUSD("$12.50"), 12.50)
        XCTAssertEqual(BacklogAutopilot.parseCostCapUSD("  $ 7.25  "), 7.25)
    }

    func testFormatsCapsAsDollarsAndCentsAndUncappedAsEmpty() {
        XCTAssertEqual(BacklogAutopilot.formatCostCapUSD(nil), "")
        XCTAssertEqual(BacklogAutopilot.formatCostCapUSD(5), "5.00")
        XCTAssertEqual(BacklogAutopilot.formatCostCapUSD(12.5), "12.50")
    }

    /// The field re-renders from the committed value, so format→parse has to be
    /// a fixed point or the displayed cap would drift from the enforced one.
    func testFormatThenParseRoundTrips() {
        for value in [0.25, 2, 12.5, 100] as [Double] {
            XCTAssertEqual(
                BacklogAutopilot.parseCostCapUSD(BacklogAutopilot.formatCostCapUSD(value)),
                value
            )
        }
    }

    // MARK: - Defaults and persistence

    /// The budget starts unset — autopilot only enforces one once asked to.
    func testTheBudgetIsUnsetByDefault() {
        let autopilot = makeAutopilot(configURL: tempDir.appendingPathComponent("autopilot-config.json"))
        XCTAssertNil(autopilot.budgetUSD)
    }

    /// The per-item cap and its margin are no longer settings, and the session
    /// cap's old name was folded into the budget long ago: a file written
    /// before still loads, every other setting in it intact, and the three
    /// keys are ignored rather than read or refused.
    func testRetiredCostCapKeysLoadAndAreIgnored() throws {
        let configURL = tempDir.appendingPathComponent("autopilot-config.json")
        let json = #"{"maxRetries": 4, "perItemCostCapUSD": 3, "costCapMargin": 2, "sessionCostCapUSD": 30}"#
        try Data(json.utf8).write(to: configURL)

        let autopilot = makeAutopilot(configURL: configURL)
        XCTAssertNil(autopilot.configLoadFailure)
        XCTAssertEqual(autopilot.maxRetries, 4)
        XCTAssertNil(autopilot.budgetUSD, "the old session cap is not read as the budget")
        let item = BacklogItem(id: "cap-item", title: "Capped item", verify: nil, status: .ready, type: .local, size: .m)
        XCTAssertNil(autopilot.effectiveCostCap(for: item), "the old flat cap is not read as the item's cap")
        XCTAssertFalse(autopilot.isConfigAtDefaults, "maxRetries was tuned")

        autopilot.maxRetries = BacklogAutopilot.Defaults.maxRetries
        let saved = try XCTUnwrap(FileManager.default.contents(atPath: configURL.path(percentEncoded: false)))
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any]).keys
        for retired in ["perItemCostCapUSD", "costCapMargin", "sessionCostCapUSD"] {
            XCTAssertFalse(keys.contains(retired), "\(retired) is not written back")
        }
    }

    func testTheBudgetPersistsAcrossReload() {
        let configURL = tempDir.appendingPathComponent("autopilot-config.json")

        let first = makeAutopilot(configURL: configURL)
        first.budgetUSD = 30

        XCTAssertEqual(makeAutopilot(configURL: configURL).budgetUSD, 30)
    }

    /// Clearing the field has to persist too: a stale budget left in the config
    /// would keep pausing runs after its owner removed it.
    func testClearingTheBudgetPersistsAcrossReload() {
        let configURL = tempDir.appendingPathComponent("autopilot-config.json")

        let first = makeAutopilot(configURL: configURL)
        first.budgetUSD = 30
        first.budgetUSD = nil

        XCTAssertNil(makeAutopilot(configURL: configURL).budgetUSD)
    }

    /// The quality judge's switch is gone: a config file written while it
    /// existed still loads, the stored key is ignored rather than an error,
    /// and the next save no longer writes it.
    func testAConfigStillNamingTheRetiredQualityJudgeSwitchLoadsAndDropsIt() throws {
        let configURL = tempDir.appendingPathComponent("autopilot-config.json")
        try Data(#"{"maxRetries": 5, "qualityJudgeEnabled": false}"#.utf8).write(to: configURL)

        let autopilot = makeAutopilot(configURL: configURL)
        XCTAssertEqual(autopilot.maxRetries, 5, "the file around the retired key was not loaded")
        autopilot.maxRetries = 4

        let saved = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertFalse(saved.contains("qualityJudgeEnabled"), saved)
    }

    // MARK: - Reset to defaults (the Autopilot tab's Reset control)

    /// A freshly configured project has nothing to reset, so the control is off.
    func testResetIsUnavailableWhenEverythingIsAlreadyDefault() {
        let autopilot = makeAutopilot(configURL: tempDir.appendingPathComponent("autopilot-config.json"))
        XCTAssertTrue(autopilot.isConfigAtDefaults)
        XCTAssertFalse(autopilot.canResetConfigToDefaults)
    }

    /// Every knob the control resets has to be one that switches it on, or a
    /// setting could be tuned with no visible way back.
    func testEachTunedSettingMakesResetAvailable() {
        let mutations: [(String, (BacklogAutopilot) -> Void)] = [
            ("maxRetries", { $0.maxRetries = BacklogAutopilot.Defaults.maxRetries + 1 }),
            ("budgetUSD", { $0.budgetUSD = 30 }),
            ("baseBranch", { $0.baseBranch = "release" }),
            ("openPullRequest", { $0.openPullRequest = !BacklogAutopilot.Defaults.openPullRequest }),
            ("approvalGate", { $0.approvalGate = .land }),
        ]

        for (name, mutate) in mutations {
            let autopilot = makeAutopilot(
                configURL: tempDir.appendingPathComponent("autopilot-\(name).json")
            )
            mutate(autopilot)
            XCTAssertFalse(autopilot.isConfigAtDefaults, "\(name) tuned should not read as default")
            XCTAssertTrue(autopilot.canResetConfigToDefaults, "\(name) tuned should offer a reset")

            autopilot.resetConfigToDefaults()
            XCTAssertTrue(autopilot.isConfigAtDefaults, "reset should clear \(name)")
            XCTAssertFalse(autopilot.canResetConfigToDefaults, "nothing left to reset after \(name)")
        }
    }

    /// A config file written while the refute round was still a setting holds
    /// its key. The key is ignored, not an error: the rest of the file still
    /// loads, and the item runs the ordinary worker/reviewer graph.
    func testAConfigStillNamingTheRetiredRefuteSettingLoadsAndRunsTheOrdinaryGraph() throws {
        let configURL = tempDir.appendingPathComponent("autopilot-config.json")
        try Data(#"{"maxRetries": 5, "refuteRoundEnabled": true}"#.utf8)
            .write(to: configURL)

        let autopilot = makeAutopilot(configURL: configURL)
        XCTAssertEqual(autopilot.maxRetries, 5, "the file around the retired key was not loaded")
        let graph = BacklogAutopilot.buildWorkflowGraph(
            workerAgentID: "engineer", reviewerAgentID: "reviewer", maxIterations: autopilot.maxRetries)
        XCTAssertEqual(Set(graph.nodes.keys),
                       ["worker", "reviewer", "reviewer-clarify", "done", "blocked"])
    }

    /// The base branch survives a relaunch — a base that reverted would put the
    /// next night's merges on the wrong branch — and is stored normalized:
    /// trimmed, with a blank read as unset, so the text field, the config file
    /// and the control API cannot disagree about what "unset" looks like.
    func testTheBaseBranchPersistsNormalizedAndBlankMeansUnset() {
        let configURL = tempDir.appendingPathComponent("autopilot-config.json")

        let autopilot = makeAutopilot(configURL: configURL)
        XCTAssertNil(autopilot.baseBranch, "the checkout's own HEAD until someone names a branch")
        autopilot.baseBranch = "  quality/rebased\n"
        XCTAssertEqual(autopilot.baseBranch, "quality/rebased")
        XCTAssertEqual(makeAutopilot(configURL: configURL).baseBranch, "quality/rebased")

        autopilot.baseBranch = "   "
        XCTAssertNil(autopilot.baseBranch)
        XCTAssertTrue(autopilot.isConfigAtDefaults, "a blank name is not a tuned setting")
        XCTAssertNil(makeAutopilot(configURL: configURL).baseBranch)
    }

    /// The agent assignment isn't a knob: resetting the settings must not disband
    /// the pair, or a reset would leave autopilot unrunnable.
    func testResetKeepsTheAgentAssignmentAndPersists() {
        let configURL = tempDir.appendingPathComponent("autopilot-config.json")

        let autopilot = makeAutopilot(configURL: configURL)
        autopilot.workerAgentID = "worker-1"
        autopilot.reviewerAgentID = "reviewer-1"
        autopilot.budgetUSD = 30

        autopilot.resetConfigToDefaults()

        XCTAssertEqual(autopilot.workerAgentID, "worker-1")
        XCTAssertEqual(autopilot.reviewerAgentID, "reviewer-1")

        // The reset is written through, not just held in memory.
        let reloaded = makeAutopilot(configURL: configURL)
        XCTAssertTrue(reloaded.isConfigAtDefaults)
        XCTAssertEqual(reloaded.workerAgentID, "worker-1")
        XCTAssertEqual(reloaded.reviewerAgentID, "reviewer-1")
    }

    // MARK: - Durable writes and failure reporting

    /// Records what reached the inbox without keeping a file around: these tests
    /// care about which rows were filed, not how they are persisted.
    private actor StubNotificationStore: NotificationStoring {
        private var items: [NotificationItem] = []
        private var resolvedItems: [NotificationItem] = []

        func add(_ item: NotificationItem) async { items.append(item) }

        func markResolved(id: String) async {
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            resolvedItems.append(items.remove(at: index))
        }

        func resolveApprovals(itemID: String, closure: GateClosure) async -> Int { 0 }

        func resolveQuestions(agentID: String, closure: GateClosure) async -> Int { 0 }

        func backfillPassedNotices(itemsAtGate: Set<String>) async -> Int { 0 }

        func dismiss(id: String) async { items.removeAll { $0.id == id } }

        func dismissAllPending(actionable: Bool) async { items.removeAll() }

        func pending() async -> [NotificationItem] { items }

        func resolved() async -> [NotificationItem] { resolvedItems }

        func pendingCount() async -> Int { items.count }

        func actionablePendingCount() async -> Int { items.count }
    }

    /// A save that cannot land — `configURL` sits one component below a regular
    /// file, so the directory `AtomicFileWriter` needs cannot be created — files
    /// exactly one row naming the store and the path, and leaves the in-memory
    /// setting exactly as the caller set it: reporting the failure is all this
    /// does, there is no rollback.
    func testASaveThatCannotLandIsReportedAndTheSettingIsUnchangedInMemory() async throws {
        let blocker = tempDir.appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: blocker)
        let configURL = blocker.appendingPathComponent("autopilot-config.json")

        let inbox = StubNotificationStore()
        let reporter = StoreProblemReporter(notifications: inbox)
        let autopilot = makeAutopilot(configURL: configURL, reporter: reporter)

        autopilot.budgetUSD = 5
        await reporter.drain()

        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.type, .error)
        XCTAssertEqual(pending.first?.title, "Could not write \(BacklogAutopilot.storeName)")
        XCTAssertEqual(pending.first?.body.contains(configURL.path(percentEncoded: false)), true)

        // Reporting is all this does — the setting the caller made is not undone.
        XCTAssertEqual(autopilot.budgetUSD, 5)
    }

    /// Constructing without an injected reporter must not stop the file from
    /// being written — `.shared` is the default, so every existing caller that
    /// never passed one keeps saving exactly as before.
    func testNoInjectedReporterStillWritesTheFile() {
        let configURL = tempDir.appendingPathComponent("autopilot-config.json")
        let autopilot = BacklogAutopilot()
        autopilot.configure(
            orchestrator: Orchestrator(runtime: MockAgentRuntime()),
            backlogViewModel: BacklogViewModel(
                globalConfigStore: GlobalConfigStore(
                    storageURL: tempDir.appendingPathComponent("global-config.json")
                )
            ),
            configURL: configURL
        )

        autopilot.budgetUSD = 5
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path(percentEncoded: false)))
    }

    /// A successful save goes through `AtomicFileWriter.write`, and `loadConfig()`
    /// reads the same values back — a cap and a flag together.
    func testASuccessfulSaveRoundTripsThroughAtomicFileWriter() throws {
        let configURL = tempDir.appendingPathComponent("autopilot-config.json")

        let first = makeAutopilot(configURL: configURL)
        first.budgetUSD = 4.5
        first.autonomousWorkEnabled = !BacklogAutopilot.Defaults.autonomousWorkEnabled

        // The file the durable writer left behind is complete JSON, not a
        // truncated write — `AtomicFileWriter` only ever leaves the old file or
        // the whole new one in place.
        let data = try XCTUnwrap(FileManager.default.contents(atPath: configURL.path(percentEncoded: false)))
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(decoded?["dailyBudgetUSD"] as? Double, 4.5)

        let reloaded = makeAutopilot(configURL: configURL)
        XCTAssertEqual(reloaded.budgetUSD, 4.5)
        XCTAssertEqual(reloaded.autonomousWorkEnabled, !BacklogAutopilot.Defaults.autonomousWorkEnabled)
    }
}
