// Kiteloop/KiteloopTests/ViewModels/ProjectSessionPackInstallTests.swift
import XCTest
import KiteloopCore
@testable import Kiteloop

/// Installing a pack is the one place someone else's setup is written into a
/// project and into the app's settings. These drive the install a person
/// confirms, end to end, and read back what it left on disk, in the routines,
/// in the settings and on the team — and that an install which fails part-way
/// leaves nothing of itself behind.
final class ProjectSessionPackInstallTests: XCTestCase {
    private static let secret = "sk-live-do-not-repeat-4f9a"
    private static let headerSecret = "Bearer do-not-repeat-77c1"
    private static let fullLists = """
        "agents": ["agents/scout"], "routines": ["routines/brief.json"],
        "connectors": ["connectors/tracker.json"], "templates": ["templates/standup.md"]
        """

    private var tempDir: URL!
    private var pack: URL { tempDir.appending(path: "pack") }
    private var routinesHome: URL { tempDir.appending(path: "home") }

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "project-session-pack-install-test")
    }

    // MARK: - A whole pack

    @MainActor
    func testAFullPackInstallsItsAgentRoutineConnectorsAndTemplate() throws {
        try writePack()
        let secrets = InMemoryConnectorSecretStore()
        let globalConfig = try makeGlobalConfig(secrets: secrets)
        globalConfig.setDefaultEffort("high")
        globalConfig.setMCPServers(["notes": ClaudeMCPServerEntry(command: "notes-mcp")])
        let session = try makeSession(globalConfigStore: globalConfig)
        let runner = RoutineRunner(store: RoutineStore(directory: routinesHome))
        let plan = try session.packInstallPlan(folder: pack, routines: runner, globalConfig: globalConfig)
        XCTAssertTrue(plan.canInstall, "\(plan.refusals)")

        try session.installPack(plan, routines: runner, globalConfig: globalConfig)

        // The agent package and the template are copied into the project.
        let copiedAgent = session.project.localAgentsURL.appending(path: "scout")
        XCTAssertEqual(try text(copiedAgent.appending(path: "agent.json")),
                       try text(pack.appending(path: "agents/scout/agent.json")))
        XCTAssertEqual(try text(copiedAgent.appending(path: "knowledge/profile.md")), "# Scout\n")
        XCTAssertEqual(try text(session.project.rootURL.appending(path: "templates/standup.md")),
                       "# Standup notes\n")

        // The routine is in the runner and on file: disarmed, in this project.
        XCTAssertEqual(runner.routines.map(\.id), ["morning-brief"])
        let routine = try XCTUnwrap(runner.routines.first)
        XCTAssertFalse(routine.armed, "the pack marks it armed; an install never arms")
        XCTAssertNil(routine.armedAt)
        XCTAssertEqual(routine.project, "repo")
        XCTAssertEqual(RoutineStore(directory: routinesHome).routines(), runner.routines)

        // The connectors join the app's servers with names kept and no value.
        let servers = try XCTUnwrap(globalConfig.config.mcpServers)
        XCTAssertEqual(servers.keys.sorted(), ["notes", "search", "tracker"])
        XCTAssertEqual(servers["notes"]?.command, "notes-mcp", "a server the app already had is left as it was")
        XCTAssertEqual(servers["tracker"]?.command, "npx")
        XCTAssertEqual(servers["tracker"]?.env, ["TRACKER_TOKEN": ""])
        XCTAssertEqual(servers["search"]?.extras["headers"], .dictionary(["Authorization": .string("")]))
        XCTAssertTrue(secrets.all.isEmpty, "no value from the pack reaches the secret store")
        let settingsOnFile = try text(tempDir.appending(path: "app/global.json"))
        XCTAssertTrue(settingsOnFile.contains("TRACKER_TOKEN"))
        XCTAssertFalse(settingsOnFile.contains(Self.secret))
        XCTAssertFalse(settingsOnFile.contains(Self.headerSecret))

        // The agent is on the team, stopped, as the package and the plan say.
        let scouts = session.orchestrator.agents.filter { $0.name == "Scout" }
        XCTAssertEqual(scouts.count, 1)
        let scout = try XCTUnwrap(scouts.first)
        XCTAssertEqual(scout.systemPrompt, "Look around.")
        XCTAssertEqual(scout.permissionMode, "plan")
        XCTAssertEqual(scout.effort, "high", "a new agent starts on the app's default effort")
        XCTAssertNil(session.orchestrator.sessions[scout.id], "nothing is started")
        let team = try JSONDecoder().decode([AgentTemplate].self,
                                            from: Data(contentsOf: session.project.teamConfigURL))
        XCTAssertEqual(team.filter { $0.name == "Scout" }.map(\.permissionMode), ["plan"])

        // One line in the app's change log names the pack and what it added.
        let records = ConfigChangeLog.read(from: globalConfig.configChangeLogURL)
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.requestedBy, "person")
        XCTAssertEqual(record.kind, "pack")
        XCTAssertEqual(record.tool, "Install Pack")
        XCTAssertEqual(record.decision, .approved)
        XCTAssertEqual(record.after, "Morning desk 1.2.0 from \(pack.path): agents Scout; "
                       + "routines morning-brief; connectors search, tracker; templates standup.md")
        XCTAssertEqual(record.project, session.project.rootURL.path(percentEncoded: false))
    }

    @MainActor
    func testAPackWithNoRoutinesOrConnectorsInstallsWithoutARoutineRunner() throws {
        try writePack(lists: #""agents": ["agents/scout"], "templates": ["templates/standup.md"]"#)
        let globalConfig = try makeGlobalConfig()
        let session = try makeSession(globalConfigStore: globalConfig)
        let plan = try session.packInstallPlan(folder: pack, routines: nil, globalConfig: globalConfig)

        try session.installPack(plan, routines: nil, globalConfig: globalConfig)

        XCTAssertTrue(exists(session.project.localAgentsURL.appending(path: "scout/agent.json")))
        XCTAssertTrue(exists(session.project.rootURL.appending(path: "templates/standup.md")))
        XCTAssertEqual(session.orchestrator.agents.filter { $0.name == "Scout" }.count, 1)
        XCTAssertNil(globalConfig.config.mcpServers, "a pack with no connector leaves the app's servers untouched")
        XCTAssertFalse(exists(routinesHome), "a pack with no routine writes no routines file")
        XCTAssertEqual(ConfigChangeLog.read(from: globalConfig.configChangeLogURL).map(\.after),
                       ["Morning desk 1.2.0 from \(pack.path): agents Scout; templates standup.md"])
    }

    @MainActor
    func testAnInstallStandsWhenTheChangeLogCannotBeWritten() throws {
        try writePack()
        let globalConfig = try makeGlobalConfig()
        // A folder where the log file goes: the append has nothing to open.
        try FileManager.default.createDirectory(at: globalConfig.configChangeLogURL,
                                                withIntermediateDirectories: true)
        let session = try makeSession(globalConfigStore: globalConfig)
        let runner = RoutineRunner(store: RoutineStore(directory: routinesHome))
        let plan = try session.packInstallPlan(folder: pack, routines: runner, globalConfig: globalConfig)

        try session.installPack(plan, routines: runner, globalConfig: globalConfig)

        XCTAssertEqual(session.orchestrator.agents.filter { $0.name == "Scout" }.count, 1)
        XCTAssertEqual(runner.routines.map(\.id), ["morning-brief"])
        XCTAssertEqual(globalConfig.config.mcpServers?.keys.sorted(), ["search", "tracker"])
        XCTAssertTrue(exists(session.project.rootURL.appending(path: "templates/standup.md")))
        XCTAssertEqual(ConfigChangeLog.read(from: globalConfig.configChangeLogURL), [])
    }

    // MARK: - Refused before anything is written

    @MainActor
    func testAPlanThatChangedSinceItWasShownIsRefusedAndWritesNothing() throws {
        try writePack()
        let globalConfig = try makeGlobalConfig()
        let session = try makeSession(globalConfigStore: globalConfig)
        let runner = RoutineRunner(store: RoutineStore(directory: routinesHome))
        let shown = try session.packInstallPlan(folder: pack, routines: runner, globalConfig: globalConfig)
        XCTAssertTrue(shown.canInstall, "\(shown.refusals)")
        // After the person read the plan, the id its routine wants is taken.
        let taken = try existingRoutine()
        try runner.put(taken)

        XCTAssertThrowsError(try session.installPack(shown, routines: runner, globalConfig: globalConfig)) {
            XCTAssertEqual($0 as? PackInstallError, .changedSinceRead)
        }

        XCTAssertEqual(runner.routines, [taken], "the routine that was there is not replaced")
        assertNothingInstalled(session, globalConfig)
    }

    @MainActor
    func testAPlanWithARefusedEntryInstallsNothing() throws {
        try writePack()
        let globalConfig = try makeGlobalConfig()
        let session = try makeSession(globalConfigStore: globalConfig)
        let runner = RoutineRunner(store: RoutineStore(directory: routinesHome))
        let taken = try existingRoutine()
        try runner.put(taken)
        let plan = try session.packInstallPlan(folder: pack, routines: runner, globalConfig: globalConfig)
        XCTAssertEqual(plan.refusals, ["A routine with the id morning-brief already exists."])

        XCTAssertThrowsError(try session.installPack(plan, routines: runner, globalConfig: globalConfig)) {
            XCTAssertEqual($0 as? PackInstallError, .refused(plan.refusals))
        }

        XCTAssertEqual(runner.routines, [taken])
        assertNothingInstalled(session, globalConfig)
    }

    @MainActor
    func testAPackThatIsGoneWhenTheInstallIsConfirmedInstallsNothing() throws {
        try writePack()
        let globalConfig = try makeGlobalConfig()
        let session = try makeSession(globalConfigStore: globalConfig)
        let runner = RoutineRunner(store: RoutineStore(directory: routinesHome))
        let shown = try session.packInstallPlan(folder: pack, routines: runner, globalConfig: globalConfig)
        try FileManager.default.removeItem(at: pack.appending(path: "pack.json"))

        XCTAssertThrowsError(try session.installPack(shown, routines: runner, globalConfig: globalConfig))

        XCTAssertEqual(runner.routines, [])
        assertNothingInstalled(session, globalConfig)
    }

    // MARK: - Routines that cannot be added

    @MainActor
    func testAPackWithARoutineIsRefusedWithoutARoutineRunnerAndItsFilesAreTakenBack() throws {
        try writePack()
        let globalConfig = try makeGlobalConfig()
        let session = try makeSession(globalConfigStore: globalConfig)
        let plan = try session.packInstallPlan(folder: pack, routines: nil, globalConfig: globalConfig)
        XCTAssertTrue(plan.canInstall, "\(plan.refusals)")

        XCTAssertThrowsError(try session.installPack(plan, routines: nil, globalConfig: globalConfig)) {
            XCTAssertEqual($0 as? Routine.Refusal,
                           Routine.Refusal(problems: ["Routines are unavailable, so the pack's cannot be added"]))
        }

        assertNothingInstalled(session, globalConfig)
    }

    @MainActor
    func testARoutineThatCannotBeSavedFailsTheInstallAndItsFilesAreTakenBack() throws {
        try writePack()
        let globalConfig = try makeGlobalConfig()
        let session = try makeSession(globalConfigStore: globalConfig)
        // A file where the routines directory goes: every save is refused.
        let blocked = tempDir.appending(path: "blocked")
        try Data().write(to: blocked)
        let stuck = RoutineRunner(store: RoutineStore(directory: blocked))
        let plan = try session.packInstallPlan(folder: pack, routines: stuck, globalConfig: globalConfig)
        XCTAssertTrue(plan.canInstall, "\(plan.refusals)")

        XCTAssertThrowsError(try session.installPack(plan, routines: stuck, globalConfig: globalConfig))

        XCTAssertEqual(stuck.routines, [])
        assertNothingInstalled(session, globalConfig)
    }

    // MARK: - Reading back

    /// Nothing of the pack is in the project, the settings, the team or the log.
    @MainActor
    private func assertNothingInstalled(_ session: ProjectSession, _ globalConfig: GlobalConfigStore,
                                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(exists(session.project.localAgentsURL.appending(path: "scout")),
                       "the agent package is not in the project", file: file, line: line)
        XCTAssertFalse(exists(session.project.rootURL.appending(path: "templates/standup.md")),
                       "the template is not in the project", file: file, line: line)
        XCTAssertNil(globalConfig.config.mcpServers, "no connector was added", file: file, line: line)
        XCTAssertEqual(session.orchestrator.agents.filter { $0.name == "Scout" }.map(\.name), [],
                       "no agent joined the team", file: file, line: line)
        let team = (try? text(session.project.teamConfigURL)) ?? ""
        XCTAssertFalse(team.contains("Scout"), "the team file does not name the agent", file: file, line: line)
        XCTAssertFalse(exists(globalConfig.configChangeLogURL), "nothing was logged", file: file, line: line)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    private func text(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Fixture

    private func write(_ text: String, to path: String) throws {
        let url = pack.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// A pack with one agent asking for `plan` mode, one routine the pack
    /// marks armed in someone else's project, two connectors carrying a
    /// secret each and one template; `lists` is what its manifest names.
    private func writePack(lists: String = ProjectSessionPackInstallTests.fullLists) throws {
        try write(#"{"name": "Morning desk", "version": "1.2.0", \#(lists)}"#, to: "pack.json")
        try write("""
            {"handle": "@scout", "version": "1.0.0",
             "template": {"name": "Scout", "model": "sonnet", "systemPrompt": "Look around.",
                          "permissionMode": "plan"},
             "knowledge": {"critical": [], "files": [], "imports": []}}
            """, to: "agents/scout/agent.json")
        try write("# Scout\n", to: "agents/scout/knowledge/profile.md")
        try write("""
            {"id": "morning-brief", "name": "Morning brief", "project": "someone-elses", "agent": "Scout",
             "prompt": "Summarise what changed overnight.", "trigger": {"at": "08:30"},
             "armed": true, "armedAt": "2026-01-01T00:00:00Z"}
            """, to: "routines/brief.json")
        try write("""
            {"tracker": {"command": "npx", "args": ["-y", "tracker-mcp"],
                         "env": {"TRACKER_TOKEN": "\(Self.secret)"}},
             "search": {"type": "http", "url": "https://search.example/mcp",
                        "headers": {"Authorization": "\(Self.headerSecret)"}}}
            """, to: "connectors/tracker.json")
        try write("# Standup notes\n", to: "templates/standup.md")
    }

    /// A routine already kept under the id the pack's routine asks for.
    private func existingRoutine() throws -> Routine {
        try Routine.parse(["name": "Already here", "project": "repo", "agent": "Coder",
                           "prompt": "Check the queue.", "trigger": ["at": "09:00"]],
                          id: "morning-brief", existing: nil).get()
    }

    /// The app's settings on a file of their own folder, so the change log
    /// beside them is this test's alone.
    @MainActor
    private func makeGlobalConfig(
        secrets: ConnectorSecretStore = InMemoryConnectorSecretStore()
    ) throws -> GlobalConfigStore {
        let appDirectory = tempDir.appending(path: "app")
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        return GlobalConfigStore(storageURL: appDirectory.appending(path: "global.json"), secretStore: secrets)
    }

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
