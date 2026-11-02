import XCTest
import KiteloopCore
@testable import Kiteloop

/// What the human says matters: whether a project is parked and what it is for,
/// plus one portfolio-level statement.
///
/// The load-bearing case is `paused`. It is a hard stop, not a strong hint —
/// enforced by `PortfolioSnapshot.selectableProjects` before any persona is
/// given a choice — so the tests here check the filter, not the wording of a
/// prompt. The other half is the defaults: a project that has said nothing must
/// behave exactly like a running one and never fall out of selection.
@MainActor
final class PortfolioPrioritiesTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "portfolio-priorities")
    }

    // MARK: - Persistence

    /// The statement has to survive a restart, otherwise it isn't a statement —
    /// re-reading through a fresh `KiteloopProject` is what a relaunch does.
    func testThePausedSwitchAndGoalSurviveARestart() throws {
        let root = try makeProjectDir("alpha")

        try KiteloopProject(rootURL: root).setPaused(true, goal: "Parked until Q3")

        let reopened = KiteloopProject(rootURL: root)
        XCTAssertTrue(reopened.isPaused)
        XCTAssertEqual(reopened.goal, "Parked until Q3")
    }

    /// It lives in the project's own config, so it travels with the repo rather
    /// than sitting in a machine-local list of projects — and it is written
    /// under `paused`, not under the ranking key it replaced.
    func testThePausedSwitchAndGoalAreStoredInTheProjectsOwnConfig() throws {
        let root = try makeProjectDir("alpha")
        let project = KiteloopProject(rootURL: root)

        try project.setPaused(true, goal: "Parked until Q3")

        let data = try Data(contentsOf: project.configURL)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["paused"] as? Bool, true)
        XCTAssertNil(json["priority"], "the saved config speaks the new key alone")
        XCTAssertEqual(json["goal"] as? String, "Parked until Q3")
    }

    /// A config written before the dial became a switch keeps the one thing the
    /// dial said that anything still reads — nothing parked today unparks on
    /// upgrade — and the two ranking values map to nothing at all.
    func testALegacyPriorityMapsOnlyItsPausedValueForward() throws {
        let parked = KiteloopProject(rootURL: try makeProjectDir("parked"))
        try legacyConfig(priority: "paused").write(to: parked.configURL)
        XCTAssertTrue(parked.isPaused)

        for ranking in ["high", "normal"] {
            let running = KiteloopProject(rootURL: try makeProjectDir("ranked-\(ranking)"))
            try legacyConfig(priority: ranking).write(to: running.configURL)
            XCTAssertFalse(running.isPaused, ranking)
        }
    }

    /// Parking a project must not be a way to lose the rest of its settings —
    /// everything else in `config.json` is preserved.
    func testPausingAProjectKeepsTheRestOfTheConfig() throws {
        let root = try makeProjectDir("alpha")
        let project = KiteloopProject(rootURL: root)
        var config = ProjectConfig.default
        config.model = "opus"
        config.maxBudgetUSD = 12.5
        try project.saveConfig(config)

        try project.setPaused(true, goal: "Ship it")

        let reloaded = KiteloopProject(rootURL: root).loadConfig()
        XCTAssertEqual(reloaded.model, "opus")
        XCTAssertEqual(reloaded.maxBudgetUSD, 12.5)
        XCTAssertEqual(reloaded.paused, true)
    }

    /// A project nobody has touched is running, not stopped — the default has
    /// to be the safe direction.
    func testAProjectThatHasStatedNothingIsRunningWithNoGoal() throws {
        let project = KiteloopProject(rootURL: try makeProjectDir("alpha"))

        XCTAssertFalse(project.isPaused, "silence must never read as paused")
        XCTAssertNil(project.goal)
    }

    /// An empty goal is a legitimate state — nothing stated — so it is stored as
    /// absent rather than as an empty string that later reads as a statement.
    func testAnEmptyGoalIsNothingStatedRatherThanAnError() throws {
        let root = try makeProjectDir("alpha")
        let project = KiteloopProject(rootURL: root)
        try project.setPaused(false, goal: "Something")

        try project.setPaused(false, goal: "   \n  ")

        XCTAssertNil(KiteloopProject(rootURL: root).goal)
        XCTAssertNil(project.loadConfig().goal)
    }

    /// `ProjectDirectionView`'s Goal field saves by carrying the project's
    /// paused switch forward unchanged — the same pairing the Portfolio card
    /// makes — so setting a goal from Project Settings can never park or
    /// unpark the project.
    func testSavingAGoalFromTheDirectionTabLeavesThePausedSwitchUnchanged() throws {
        let root = try makeProjectDir("alpha")
        let project = KiteloopProject(rootURL: root)
        try project.setPaused(true, goal: nil)

        try project.setPaused(project.isPaused, goal: "Ship the autonomy loop")

        let reopened = KiteloopProject(rootURL: root)
        XCTAssertTrue(reopened.isPaused)
        XCTAssertEqual(reopened.goal, "Ship the autonomy loop")
    }

    /// A paused switch that cannot be written has parked nothing — the loops
    /// read the file — so the save says so and files one report under the
    /// store name the app already uses for this file.
    func testAPausedSwitchThatCannotBeSavedReturnsFalseAndReportsTheWrite() async throws {
        let root = tempDir.appendingPathComponent("unwritable", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // A plain file where `.kiteloop` belongs: the directory cannot be made.
        try Data().write(to: root.appending(path: ".kiteloop"))
        let inbox = NotificationStore(notificationsURL: tempDir.appending(path: "inbox.log"))
        let reporter = StoreProblemReporter(notifications: inbox)

        let saved = await PortfolioSummaryLoader.save(paused: true, goal: "Parked",
                                                      projectPath: root.path(percentEncoded: false),
                                                      reporter: reporter)
        await reporter.drain()

        XCTAssertFalse(saved)
        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.type, .error)
        XCTAssertEqual(pending.first?.title, "Could not write \(KiteloopProject.configStoreName)")
    }

    func testAPausedSwitchThatSavesReturnsTrueAndReportsNothing() async throws {
        let root = try makeProjectDir("alpha")
        let inbox = NotificationStore(notificationsURL: tempDir.appending(path: "inbox.log"))
        let reporter = StoreProblemReporter(notifications: inbox)

        let saved = await PortfolioSummaryLoader.save(paused: true, goal: "Parked",
                                                      projectPath: root.path(percentEncoded: false),
                                                      reporter: reporter)
        await reporter.drain()

        XCTAssertTrue(saved)
        let pending = await inbox.pending()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(KiteloopProject(rootURL: root).isPaused)
    }

    /// The portfolio-level statement lives in the global config and comes back
    /// after a restart the same way.
    func testPortfolioGoalPersistsInTheGlobalConfig() {
        let url = tempDir.appendingPathComponent("global-config.json")
        let store = GlobalConfigStore(storageURL: url)

        store.setPortfolioGoal("Get the autonomy loop unattended this month")

        XCTAssertEqual(GlobalConfigStore(storageURL: url).portfolioGoal,
                       "Get the autonomy loop unattended this month")
    }

    func testAnEmptyPortfolioGoalIsStoredAsNothingStated() {
        let url = tempDir.appendingPathComponent("global-config.json")
        let store = GlobalConfigStore(storageURL: url)
        store.setPortfolioGoal("Something")

        store.setPortfolioGoal("  ")

        XCTAssertNil(store.portfolioGoal)
        XCTAssertNil(GlobalConfigStore(storageURL: url).portfolioGoal)
    }

    // MARK: - `paused` is a hard stop

    /// The central promise: a paused project is not offered to the coordinator
    /// at all. It is filtered in code, so no reasoning can put work on it.
    func testAPausedProjectIsExcludedFromCoordinatorSelection() {
        let snapshot = PortfolioSnapshot(projects: [
            project(named: "alpha"),
            project(named: "beta", paused: true),
            project(named: "gamma")
        ])

        XCTAssertEqual(snapshot.selectableProjects.map(\.name), ["alpha", "gamma"])
        XCTAssertFalse(snapshot.isSelectable(projectNamed: "beta"))
        XCTAssertTrue(snapshot.isSelectable(projectNamed: "alpha"))
    }

    /// A paused project stays visible — the coordinator should be able to see
    /// why nothing is moving there — it just isn't selectable.
    func testAPausedProjectIsStillVisibleInThePortfolio() {
        let snapshot = PortfolioSnapshot(projects: [project(named: "beta", paused: true)])

        XCTAssertEqual(snapshot.projects.map(\.name), ["beta"])
        XCTAssertTrue(snapshot.project(named: "beta")?.isPaused == true)
        XCTAssertTrue(snapshot.selectableProjects.isEmpty)
        XCTAssertTrue(snapshot.promptSection.contains("paused (hard stop"),
                      snapshot.promptSection)
    }

    /// The other direction of the same rule: an unstated project must not be
    /// quietly skipped, which would make silence as costly as pausing.
    func testAProjectThatSaidNothingIsSelectable() {
        let snapshot = PortfolioSnapshot(projects: [
            PortfolioSnapshot.project(name: "alpha", path: "/tmp/alpha", autopilotReady: true,
                                      backlog: nil, status: .idle, runQueue: [], results: [])
        ])

        let alpha = snapshot.project(named: "alpha")
        XCTAssertEqual(alpha?.paused, false)
        XCTAssertFalse(alpha?.isPaused == true)
        XCTAssertEqual(snapshot.selectableProjects.map(\.name), ["alpha"])
    }

    /// The other cause of the same hard stop: an unparked project whose own
    /// autopilot is holding its queue (`BacklogAutopilot.pause()`, `POST
    /// /v1/autopilot/pause`). Pausing is one act now — a held queue is exactly
    /// as off limits to a fresh pickup as the fleet board's switch, so it must
    /// fall out of selection the same way.
    func testAProjectWithAHeldAutopilotQueueIsExcludedFromSelectionToo() {
        let held = PortfolioSnapshot.project(name: "alpha", path: "/tmp/alpha", autopilotReady: true,
                                             backlog: nil, status: .paused,
                                             runQueue: [BacklogItem(id: "a1", title: "A1", verify: "true",
                                                                    status: .ready, type: .local, size: .s)],
                                             results: [])
        let snapshot = PortfolioSnapshot(projects: [held, project(named: "beta")])

        XCTAssertFalse(held.paused, "the fleet board's switch itself was never touched")
        XCTAssertTrue(held.isPaused)
        XCTAssertFalse(snapshot.isSelectable(projectNamed: "alpha"))
        XCTAssertEqual(snapshot.selectableProjects.map(\.name), ["beta"])
    }

    /// A name the portfolio doesn't know is not a project the coordinator has
    /// been given, so it is not selectable either.
    func testAnUnknownProjectIsNotSelectable() {
        let snapshot = PortfolioSnapshot(projects: [project(named: "alpha")])

        XCTAssertFalse(snapshot.isSelectable(projectNamed: "nope"))
    }

    // MARK: - What the coordinator reads

    /// Capture reads each project's paused switch and goal from its own config,
    /// so an edit in the Portfolio lands on the next consult.
    func testCaptureReadsThePausedSwitchAndGoalFromEachProject() throws {
        let registry = ControlSessionRegistry()
        let alpha = try makeProjectDir("alpha")
        try KiteloopProject(rootURL: alpha).setPaused(true, goal: "Parked")
        try register(alpha, in: registry)
        let beta = try makeProjectDir("beta")
        try register(beta, in: registry)

        let snapshot = PortfolioSnapshot.capture(registry: registry,
                                                 portfolioGoal: "Unattended runs this month")

        XCTAssertEqual(snapshot.project(named: "alpha")?.paused, true)
        XCTAssertEqual(snapshot.project(named: "alpha")?.goal, "Parked")
        XCTAssertEqual(snapshot.project(named: "beta")?.paused, false, "unstated is running")
        XCTAssertNil(snapshot.project(named: "beta")?.goal)
        XCTAssertEqual(snapshot.portfolioGoal, "Unattended runs this month")
        XCTAssertEqual(snapshot.selectableProjects.map(\.name), ["beta"])
    }

    /// The portfolio statement reads alongside the per-project ones rather than
    /// replacing them — a tie-breaker needs both halves present.
    func testPromptSectionCarriesThePortfolioGoalAndEachProjectsOwn() {
        let snapshot = PortfolioSnapshot(
            projects: [
                project(named: "alpha", goal: "Ship the autonomy loop"),
                project(named: "beta", paused: true, goal: "Parked until Q3")
            ],
            portfolioGoal: "Get one repo running unattended"
        )

        let section = snapshot.promptSection

        XCTAssertTrue(section.contains("Portfolio goal: Get one repo running unattended"), section)
        XCTAssertTrue(section.contains("| goal: Ship the autonomy loop"), section)
        XCTAssertFalse(section.contains("priority"), "the rank word is gone from the prompt: \(section)")
        XCTAssertTrue(section.contains("| paused (hard stop — never select this project for work) "
                                       + "| goal: Parked until Q3"), section)
    }

    /// Nothing stated adds nothing to the prompt — no empty heading, no "none".
    func testPromptSectionOmitsAnUnstatedGoal() {
        let snapshot = PortfolioSnapshot(projects: [project(named: "alpha")])

        let section = snapshot.promptSection

        XCTAssertFalse(section.contains("Portfolio goal:"), section)
        XCTAssertFalse(section.contains("goal:"), section)
        XCTAssertFalse(section.contains("paused"), "a running project says nothing about pausing: \(section)")
    }

    /// A goal is free text a human typed, so it is flattened and capped before it
    /// reaches the prompt — one project stays one line.
    func testAMultiLineGoalStaysOnOneLineAndIsCapped() {
        XCTAssertEqual(PortfolioSnapshot.statementLine("ship\nthe   loop"), "ship the loop")

        let long = String(repeating: "a", count: PortfolioSnapshot.statementLimit + 50)
        let rendered = PortfolioSnapshot.statementLine(long)
        XCTAssertEqual(rendered.count, PortfolioSnapshot.statementLimit + 1, "capped plus the ellipsis")
        XCTAssertTrue(rendered.hasSuffix("…"))

        let snapshot = PortfolioSnapshot(projects: [project(named: "alpha",
                                                            goal: "ship\nthe loop")])
        XCTAssertEqual(snapshot.promptSection.split(separator: "\n").count, 2,
                       "one header line, one project line")
    }

    /// The snapshot is the Coordinator's way in, so the statement has to reach
    /// it through a registry capture and not only through hand-built values.
    func testCapturedSnapshotCarriesThePausedSwitchAndThePortfolioGoal() throws {
        let registry = ControlSessionRegistry()
        let alpha = try makeProjectDir("alpha")
        try KiteloopProject(rootURL: alpha).setPaused(true, goal: "Parked")
        try register(alpha, in: registry)
        let store = GlobalConfigStore(storageURL: tempDir.appendingPathComponent("global-config.json"))
        store.setPortfolioGoal("Unattended runs this month")

        let snapshot = PortfolioSnapshot.capture(registry: registry,
                                                 portfolioGoal: store.portfolioGoal)
        XCTAssertEqual(snapshot.portfolioGoal, "Unattended runs this month")
        XCTAssertEqual(snapshot.project(named: "alpha")?.paused, true)
        XCTAssertTrue(snapshot.selectableProjects.isEmpty)
    }

    // MARK: - The Portfolio landing

    /// What the cards show is read from the same place the coordinator reads, so
    /// the two can't disagree about what the human said.
    func testPortfolioSummaryLoaderReadsThePausedSwitchAndGoal() async throws {
        let root = try makeProjectDir("alpha")
        try KiteloopProject(rootURL: root).setPaused(true, goal: "Ship the autonomy loop")
        let path = root.path(percentEncoded: false)
        let recent = RecentProject(id: path, name: "alpha", path: path, lastOpened: Date())

        let summaries = await PortfolioSummaryLoader.load([recent], vaultURL: nil)

        XCTAssertEqual(summaries.first?.paused, true)
        XCTAssertEqual(summaries.first?.goal, "Ship the autonomy loop")
    }

    /// Editing a card writes through to the project config the coordinator reads.
    func testPortfolioSummaryLoaderSaveWritesWhatTheCoordinatorReads() async throws {
        let root = try makeProjectDir("alpha")

        await PortfolioSummaryLoader.save(paused: true, goal: "Parked",
                                          projectPath: root.path(percentEncoded: false))

        XCTAssertTrue(KiteloopProject(rootURL: root).isPaused)
        XCTAssertEqual(KiteloopProject(rootURL: root).goal, "Parked")
    }

    /// A project whose `.kiteloop/` doesn't exist yet must still be settable —
    /// the human shouldn't have to open a project before parking it.
    func testAProjectWithoutAKiteloopDirectoryCanStillBePaused() throws {
        let root = tempDir.appendingPathComponent("fresh", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try KiteloopProject(rootURL: root).setPaused(true, goal: nil)

        XCTAssertTrue(KiteloopProject(rootURL: root).isPaused)
    }

    // MARK: - Helpers

    private func makeProjectDir(_ name: String) throws -> URL {
        let root = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appending(path: ".kiteloop"), withIntermediateDirectories: true)
        return root
    }

    private func project(named name: String, paused: Bool = false,
                         goal: String? = nil) -> PortfolioSnapshot.Project {
        PortfolioSnapshot.project(name: name, path: "/tmp/\(name)", autopilotReady: true,
                                  backlog: nil, status: .idle, runQueue: [], results: [],
                                  paused: paused, goal: goal)
    }

    /// A `config.json` as it was written before the dial became a switch: the
    /// legacy `priority` string beside the fields that have not moved.
    private func legacyConfig(priority: String) -> Data {
        Data("""
        {"priority": "\(priority)", "permissionMode": "acceptEdits",
         "autoApprovedTools": ["Read"], "deniedTools": []}
        """.utf8)
    }

    /// Registers a project the way `MainWindow` does, so `capture` reads it off
    /// the same registry the control API does. No agents are started.
    private func register(_ root: URL, in registry: ControlSessionRegistry) throws {
        let project = KiteloopProject(rootURL: root)
        let eventBus = EventBus(eventsURL: project.eventsURL)
        let orchestrator = Orchestrator(
            runtime: MockAgentRuntime(),
            eventBus: eventBus,
            subscriptionEngine: SubscriptionEngine(eventBus: eventBus),
            memoryManager: MemoryManager(project: project)
        )
        let session = ProjectSession(
            project: project,
            projectURL: root,
            orchestrator: orchestrator,
            sessionStore: SessionStore(projectDir: root),
            knowledgeStore: AgentKnowledgeStore(baseURL: project.knowledgeURL),
            knowledgeIndex: KnowledgeIndex(baseURL: project.knowledgeURL),
            context: ProjectSessionContext(
                runtimeFactory: { MockAgentRuntime() },
                agentCatalogStore: AgentCatalogStore(
                    storageURL: tempDir.appendingPathComponent("catalog.json")),
                packageResolver: nil,
                globalConfigStore: GlobalConfigStore(
                    storageURL: tempDir.appendingPathComponent("global.json")),
                orgManifestLoader: OrgManifestLoader(),
                repoCloneService: RepoCloneService()
            )
        )
        registry.register(session: session, autopilot: BacklogAutopilot())
    }
}
