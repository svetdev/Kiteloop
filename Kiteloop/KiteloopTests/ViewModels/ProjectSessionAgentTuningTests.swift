// Kiteloop/KiteloopTests/ViewModels/ProjectSessionAgentTuningTests.swift
import XCTest
import KiteloopCore
@testable import Kiteloop

/// The app's Default Reasoning Effort used to reach no agent, and an agent
/// hired while the project was open started with neither the project's effort
/// nor its per-turn budget. These pin the effort every new agent starts with —
/// project, else app, else none — and that a hired agent carries both.
final class ProjectSessionAgentTuningTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "project-session-agent-tuning-test")
    }

    func testAppEffortAppliesWhenTheProjectLeavesItAtDefault() {
        let tuning = ProjectSession.startingTuning(config: .default, appDefaultEffort: "high")
        XCTAssertEqual(tuning.effort, "high")
    }

    func testProjectEffortWinsOverTheApps() {
        var config = ProjectConfig.default
        config.effort = "low"
        let tuning = ProjectSession.startingTuning(config: config, appDefaultEffort: "high")
        XCTAssertEqual(tuning.effort, "low")
    }

    func testEmptyStringAtEitherScopeIsUnset() {
        var config = ProjectConfig.default
        config.effort = ""
        XCTAssertEqual(ProjectSession.startingTuning(config: config, appDefaultEffort: "max").effort, "max")
        XCTAssertNil(ProjectSession.startingTuning(config: config, appDefaultEffort: "").effort)
    }

    func testNeitherScopeSetLeavesNoEffort() {
        XCTAssertNil(ProjectSession.startingTuning(config: .default, appDefaultEffort: nil).effort)
    }

    func testBudgetIsCarriedFromTheProject() {
        var config = ProjectConfig.default
        config.maxBudgetUSD = 2.5
        XCTAssertEqual(ProjectSession.startingTuning(config: config, appDefaultEffort: nil).maxBudgetUSD, 2.5)
        XCTAssertNil(ProjectSession.startingTuning(config: .default, appDefaultEffort: nil).maxBudgetUSD)
    }

    @MainActor
    func testHiredAgentCarriesTheProjectBudgetAndResolvedEffort() throws {
        let globalConfigStore = GlobalConfigStore(storageURL: tempDir.appending(path: "global.json"))
        globalConfigStore.setDefaultEffort("high")
        let session = try makeSession(globalConfigStore: globalConfigStore)
        var config = session.project.loadConfig()
        config.maxBudgetUSD = 1.75
        try session.project.saveConfig(config)

        let id = session.addAgent(name: "Hired", model: "sonnet", permissionMode: "default", select: false)

        let agent = try XCTUnwrap(session.orchestrator.agents.first { $0.id == id })
        XCTAssertEqual(agent.effort, "high")
        XCTAssertEqual(agent.maxBudgetUSD, 1.75)
    }

    // MARK: - Helpers

    @MainActor
    private func makeSession(globalConfigStore: GlobalConfigStore) throws -> ProjectSession {
        let rootURL = tempDir.appending(path: "repo")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let project = KiteloopProject(rootURL: rootURL)
        try project.ensureDirectoryExists()
        let eventBus = EventBus(eventsURL: project.eventsURL)
        let orchestrator = Orchestrator(
            runtime: MockAgentRuntime(),
            eventBus: eventBus,
            subscriptionEngine: SubscriptionEngine(eventBus: eventBus) { _, _ in },
            memoryManager: MemoryManager(project: project)
        )
        return ProjectSession(
            project: project,
            projectURL: rootURL,
            orchestrator: orchestrator,
            sessionStore: SessionStore(projectDir: rootURL),
            knowledgeStore: AgentKnowledgeStore(baseURL: project.knowledgeURL),
            knowledgeIndex: KnowledgeIndex(baseURL: project.knowledgeURL),
            context: ProjectSessionContext(
                runtimeFactory: { MockAgentRuntime() },
                agentCatalogStore: AgentCatalogStore(storageURL: tempDir.appending(path: "catalog.json")),
                packageResolver: nil,
                globalConfigStore: globalConfigStore,
                orgManifestLoader: OrgManifestLoader(),
                repoCloneService: RepoCloneService()
            )
        )
    }
}
