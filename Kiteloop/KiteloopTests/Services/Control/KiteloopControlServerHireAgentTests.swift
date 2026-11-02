import XCTest
import KiteloopCore
@testable import Kiteloop

/// `POST /v1/agents` — the endpoint a headless driver uses to put a worker or a
/// reviewer on an open project before configuring autopilot. Driven over a real
/// loopback socket so the whole path (body parsing → project lookup → the agent
/// landing on the session's orchestrator) is covered.
///
/// The behaviour worth pinning down is `select`: it defaults to **false**, so a
/// headless hire never yanks the human's selected agent out from under them
/// mid-conversation. The default is asserted against the session, not just the
/// status code — a flipped default would still return 201.
@MainActor
final class KiteloopControlServerHireAgentTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var harness: ControlServerHarness!
    private let token = "control-hire-agent-token-" + UUID().uuidString

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-hire-agent")
        registry = ControlSessionRegistry()
        harness = try await ControlServerHarness.start(registry: registry, token: token)
    }

    override func tearDown() async throws {
        harness?.stop()
        harness = nil
        registry = nil
    }

    // MARK: - Hiring

    /// The response promises an agent that exists: the id it returns has to
    /// resolve on the project's roster, so a handler that answered 201 while
    /// adding nothing fails here.
    func testHireReturns201AndAddsTheAgentToTheProject() async throws {
        let projectSession = try registerProject(named: "alpha")

        let (status, body) = try await harness.post(
            "/v1/agents",
            ["project": "alpha", "name": "Builder", "model": "sonnet"]
        )

        XCTAssertEqual(status, 201)
        XCTAssertEqual(body["name"] as? String, "Builder")
        XCTAssertEqual(body["model"] as? String, "sonnet")
        let agentID = try XCTUnwrap(body["agentId"] as? String)
        XCTAssertFalse(agentID.isEmpty)
        let agent = try XCTUnwrap(projectSession.orchestrator.agents.first { $0.id == agentID })
        XCTAssertEqual(agent.name, "Builder")
        XCTAssertEqual(agent.model, "sonnet")
    }

    /// A driver that only knows the name it wants gets the app's defaults for
    /// everything else, and the response reports the model it actually got.
    func testHireWithoutModelUsesTheDefaultModelAndPermissionMode() async throws {
        let projectSession = try registerProject(named: "alpha")

        let (status, body) = try await harness.post(
            "/v1/agents",
            ["project": "alpha", "name": "Builder"]
        )

        XCTAssertEqual(status, 201)
        XCTAssertEqual(body["model"] as? String, ModelCatalog.defaultModelID)
        let agentID = try XCTUnwrap(body["agentId"] as? String)
        let agent = try XCTUnwrap(projectSession.orchestrator.agents.first { $0.id == agentID })
        XCTAssertEqual(agent.model, ModelCatalog.defaultModelID)
        XCTAssertEqual(agent.permissionMode, "auto")
    }

    /// A hire that names no model takes the one Project Settings gives the
    /// project — here `haiku`, over an app default of `sonnet` — and the
    /// response reports it.
    func testHireWithoutModelUsesTheProjectsConfiguredModel() async throws {
        let projectSession = try registerProject(named: "alpha", appDefaultModel: "sonnet")
        var config = ProjectConfig.default
        config.model = "haiku"
        try projectSession.project.saveConfig(config)

        let (status, body) = try await harness.post(
            "/v1/agents",
            ["project": "alpha", "name": "Builder"]
        )

        XCTAssertEqual(status, 201)
        XCTAssertEqual(body["model"] as? String, "haiku")
        let agentID = try XCTUnwrap(body["agentId"] as? String)
        let agent = try XCTUnwrap(projectSession.orchestrator.agents.first { $0.id == agentID })
        XCTAssertEqual(agent.model, "haiku")
    }

    /// With no project model, a model-less hire takes Settings → Default Model.
    func testHireWithoutModelFallsBackToTheAppDefaultModel() async throws {
        try registerProject(named: "alpha", appDefaultModel: "sonnet")

        let (status, body) = try await harness.post(
            "/v1/agents",
            ["project": "alpha", "name": "Builder"]
        )

        XCTAssertEqual(status, 201)
        XCTAssertEqual(body["model"] as? String, "sonnet")
    }

    /// A model the request names wins over the project's and the app's.
    func testHireWithAnExplicitModelKeepsIt() async throws {
        let projectSession = try registerProject(named: "alpha", appDefaultModel: "sonnet")
        var config = ProjectConfig.default
        config.model = "haiku"
        try projectSession.project.saveConfig(config)

        let (status, body) = try await harness.post(
            "/v1/agents",
            ["project": "alpha", "name": "Builder", "model": "opus"]
        )

        XCTAssertEqual(status, 201)
        XCTAssertEqual(body["model"] as? String, "opus")
    }

    /// A hire that names no mode takes the one Project Settings gives new
    /// agents in that project — here `plan`, so an app default would fail it.
    func testHireWithoutModeUsesTheProjectsConfiguredMode() async throws {
        let projectSession = try registerProject(named: "alpha")
        var config = ProjectConfig.default
        config.permissionMode = "plan"
        try projectSession.project.saveConfig(config)

        let (status, body) = try await harness.post(
            "/v1/agents",
            ["project": "alpha", "name": "Builder"]
        )

        XCTAssertEqual(status, 201)
        let agentID = try XCTUnwrap(body["agentId"] as? String)
        let agent = try XCTUnwrap(projectSession.orchestrator.agents.first { $0.id == agentID })
        XCTAssertEqual(agent.permissionMode, "plan")
    }

    /// A mode the request names wins over the project's.
    func testHireWithAnExplicitModeKeepsIt() async throws {
        let projectSession = try registerProject(named: "alpha")
        var config = ProjectConfig.default
        config.permissionMode = "plan"
        try projectSession.project.saveConfig(config)

        let (status, body) = try await harness.post(
            "/v1/agents",
            ["project": "alpha", "name": "Builder", "permissionMode": "acceptEdits"]
        )

        XCTAssertEqual(status, 201)
        let agentID = try XCTUnwrap(body["agentId"] as? String)
        let agent = try XCTUnwrap(projectSession.orchestrator.agents.first { $0.id == agentID })
        XCTAssertEqual(agent.permissionMode, "acceptEdits")
    }

    /// The project can be addressed by path as well as by name — the same
    /// lookup every other route uses.
    func testHireResolvesTheProjectByPath() async throws {
        let projectSession = try registerProject(named: "alpha")
        let path = projectSession.project.rootURL.path(percentEncoded: false)

        let (status, body) = try await harness.post(
            "/v1/agents",
            ["project": path, "name": "Builder"]
        )

        XCTAssertEqual(status, 201)
        let agentID = try XCTUnwrap(body["agentId"] as? String)
        XCTAssertNotNil(projectSession.orchestrator.agents.first { $0.id == agentID })
    }

    // MARK: - Selection

    /// The point of the endpoint's `select` default: a headless hire adds the
    /// agent but leaves the human looking at whatever they were looking at.
    func testHireWithoutSelectLeavesThePriorSelectionAlone() async throws {
        let projectSession = try registerProject(named: "alpha")
        let incumbent = addAgent(named: "Incumbent", to: projectSession)
        projectSession.selectedAgentID = incumbent

        let (status, body) = try await harness.post(
            "/v1/agents",
            ["project": "alpha", "name": "Builder"]
        )

        XCTAssertEqual(status, 201)
        let agentID = try XCTUnwrap(body["agentId"] as? String)
        try await waitUntilStarted(agentID, in: projectSession)
        XCTAssertEqual(projectSession.selectedAgentID, incumbent,
                       "an API hire must not steal the user's selection")
    }

    /// `select: false` spelled out is the same as omitting it — no caller gets a
    /// different answer for being explicit.
    func testHireWithSelectFalseLeavesThePriorSelectionAlone() async throws {
        let projectSession = try registerProject(named: "alpha")
        let incumbent = addAgent(named: "Incumbent", to: projectSession)
        projectSession.selectedAgentID = incumbent

        let (status, body) = try await harness.post(
            "/v1/agents",
            ["project": "alpha", "name": "Builder", "select": false]
        )

        XCTAssertEqual(status, 201)
        let agentID = try XCTUnwrap(body["agentId"] as? String)
        try await waitUntilStarted(agentID, in: projectSession)
        XCTAssertEqual(projectSession.selectedAgentID, incumbent)
    }

    /// Opting in is what a caller does when it *wants* the view to follow — a
    /// setup wizard hiring the agent the human is about to talk to.
    func testHireWithSelectTrueSelectsTheNewAgent() async throws {
        let projectSession = try registerProject(named: "alpha")
        let incumbent = addAgent(named: "Incumbent", to: projectSession)
        projectSession.selectedAgentID = incumbent

        let (status, body) = try await harness.post(
            "/v1/agents",
            ["project": "alpha", "name": "Builder", "select": true]
        )

        XCTAssertEqual(status, 201)
        let agentID = try XCTUnwrap(body["agentId"] as? String)
        try await eventually("the new agent to be selected") { await projectSession.selectedAgentID == agentID }
        XCTAssertEqual(projectSession.selectedAgentID, agentID)
    }

    /// `select` is a boolean, and JSON hands a boolean and a number back as the
    /// same `NSNumber` — so `select: 1` used to bridge to `true` and steal the
    /// human's selection from a caller that never asked for it. Rejected rather
    /// than guessed at, and nobody is hired on the way to the 400.
    func testHireWithANumericSelectIs400() async throws {
        let projectSession = try registerProject(named: "alpha")
        let incumbent = addAgent(named: "Incumbent", to: projectSession)
        projectSession.selectedAgentID = incumbent

        let (status, body) = try await harness.post(
            "/v1/agents",
            ["project": "alpha", "name": "Builder", "select": 1]
        )

        XCTAssertEqual(status, 400)
        XCTAssertEqual(body["error"] as? String, "\"select\" must be true or false")
        XCTAssertEqual(projectSession.orchestrator.agents.map(\.name), ["Incumbent"])
        XCTAssertEqual(projectSession.selectedAgentID, incumbent)
    }

    // MARK: - Bad requests

    func testHireWithoutProjectIs400() async throws {
        let projectSession = try registerProject(named: "alpha")

        let (status, body) = try await harness.post("/v1/agents", ["name": "Builder"])

        XCTAssertEqual(status, 400)
        XCTAssertEqual(body["error"] as? String, "Body must include \"project\" and \"name\"")
        XCTAssertTrue(projectSession.orchestrator.agents.isEmpty)
    }

    func testHireWithoutNameIs400() async throws {
        let projectSession = try registerProject(named: "alpha")

        let (status, body) = try await harness.post("/v1/agents", ["project": "alpha"])

        XCTAssertEqual(status, 400)
        XCTAssertEqual(body["error"] as? String, "Body must include \"project\" and \"name\"")
        XCTAssertTrue(projectSession.orchestrator.agents.isEmpty)
    }

    /// An empty name would produce an unaddressable agent — `PUT /v1/autopilot`
    /// resolves workers by name — so it's rejected rather than hired.
    func testHireWithEmptyNameIs400() async throws {
        let projectSession = try registerProject(named: "alpha")

        let (status, body) = try await harness.post(
            "/v1/agents",
            ["project": "alpha", "name": ""]
        )

        XCTAssertEqual(status, 400)
        XCTAssertEqual(body["error"] as? String, "Body must include \"project\" and \"name\"")
        XCTAssertTrue(projectSession.orchestrator.agents.isEmpty)
    }

    /// A project Kiteloop hasn't opened is a 409, not a 400: the request is
    /// well-formed, and what the caller has to do is open the project — not fix
    /// its body.
    func testHireIntoUnopenedProjectIs409() async throws {
        let projectSession = try registerProject(named: "alpha")

        let (status, body) = try await harness.post(
            "/v1/agents",
            ["project": "beta", "name": "Builder"]
        )

        XCTAssertEqual(status, 409)
        XCTAssertEqual(body["error"] as? String, "Project not open in Kiteloop: beta")
        XCTAssertTrue(projectSession.orchestrator.agents.isEmpty)
    }

    /// Hiring starts a process, so it's a write: the token gates it and an
    /// unauthorized request must not reach the session at all.
    func testHireRequiresBearerToken() async throws {
        let projectSession = try registerProject(named: "alpha")

        let (status, body) = try await harness.post("/v1/agents", ["project": "alpha", "name": "Builder"], bearer: nil)

        XCTAssertEqual(status, 401)
        XCTAssertEqual(body["error"] as? String, "Missing or invalid bearer token")
        XCTAssertTrue(projectSession.orchestrator.agents.isEmpty)
    }

    // MARK: - Listing and chatting

    /// `GET /v1/agents` answers the roster as the sidebar shows it — the id it
    /// returns is the one the message and transcript endpoints take.
    func testListAgentsShowsAHiredAgentWithItsState() async throws {
        let projectSession = try registerProject(named: "alpha")
        let agentID = addAgent(named: "Builder", to: projectSession)

        let (status, body) = try await harness.get("/v1/agents?project=alpha")

        XCTAssertEqual(status, 200)
        let agents = try XCTUnwrap(body["agents"] as? [[String: Any]])
        let builder = try XCTUnwrap(agents.first { ($0["id"] as? String) == agentID })
        XCTAssertEqual(builder["name"] as? String, "Builder")
        XCTAssertEqual(builder["model"] as? String, "sonnet")
        XCTAssertEqual(builder["state"] as? String, "idle")
    }

    func testListAgentsWithoutProjectIs400AndUnknownProjectIs409() async throws {
        let (missing, _) = try await harness.get("/v1/agents")
        XCTAssertEqual(missing, 400)
        let (unknown, _) = try await harness.get("/v1/agents?project=nope")
        XCTAssertEqual(unknown, 409)
    }

    /// An agent that has never spoken answers an empty transcript, not an
    /// error — the phone opens the chat before the first message exists.
    func testTranscriptOfANeverChattedAgentIsEmpty() async throws {
        let projectSession = try registerProject(named: "alpha")
        let agentID = addAgent(named: "Builder", to: projectSession)

        let (status, body) = try await harness.get("/v1/agents/transcript?project=alpha&agent=\(agentID)")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["agent"] as? String, agentID)
        XCTAssertEqual((body["messages"] as? [[String: Any]])?.count, 0)
    }

    /// Both chat endpoints resolve the agent by name too, case-insensitively —
    /// a phone types "builder", not a UUID.
    func testTranscriptResolvesTheAgentByNameCaseInsensitively() async throws {
        let projectSession = try registerProject(named: "alpha")
        let agentID = addAgent(named: "Builder", to: projectSession)

        let (status, body) = try await harness.get("/v1/agents/transcript?project=alpha&agent=builder")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["agent"] as? String, agentID, "answers with the id, whatever was asked by")
    }

    func testTranscriptOfAnUnknownAgentIs404() async throws {
        try registerProject(named: "alpha")
        let (status, _) = try await harness.get("/v1/agents/transcript?project=alpha&agent=nobody")
        XCTAssertEqual(status, 404)
    }

    func testMessageWithoutAMessageIs400AndUnknownAgentIs404() async throws {
        let projectSession = try registerProject(named: "alpha")
        addAgent(named: "Builder", to: projectSession)

        let (missing, _) = try await harness.post("/v1/agents/message",
                                                  ["project": "alpha", "agent": "Builder"])
        XCTAssertEqual(missing, 400)
        let (blank, _) = try await harness.post("/v1/agents/message",
                                                ["project": "alpha", "agent": "Builder", "message": "  "])
        XCTAssertEqual(blank, 400, "an all-whitespace message would start an empty turn")
        let (unknown, _) = try await harness.post("/v1/agents/message",
                                                  ["project": "alpha", "agent": "nobody", "message": "hi"])
        XCTAssertEqual(unknown, 404)
    }

    // MARK: - Helpers

    /// Builds a real `ProjectSession` over a throwaway directory and registers it,
    /// which is all any control route needs to resolve the project.
    @discardableResult
    private func registerProject(named name: String, appDefaultModel: String? = nil) throws -> ProjectSession {
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
            context: makeContext(appDefaultModel: appDefaultModel)
        )
        registry.register(session: session, autopilot: BacklogAutopilot())
        return session
    }

    /// Puts an already-hired agent on the roster — the selection an API hire
    /// must not disturb.
    @discardableResult
    private func addAgent(named name: String, to projectSession: ProjectSession) -> String {
        let agent = Agent(
            name: name,
            model: "sonnet",
            systemPrompt: "",
            tools: [],
            denied: [],
            permissionMode: "acceptEdits"
        )
        projectSession.orchestrator.addAgent(agent)
        return agent.id
    }

    /// `addAgent` decides the selection asynchronously, right after registering
    /// the new agent's chat view model. Waiting on that view model is therefore
    /// the point where "selection was skipped" becomes an assertable fact rather
    /// than a race.
    private func waitUntilStarted(
        _ agentID: String,
        in projectSession: ProjectSession,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await eventually("a chat view model for \(agentID)", file: file, line: line) {
            await projectSession.chatViewModels[agentID] != nil
        }
    }

    /// All stores are pointed at the temp directory so the tests never read or
    /// write the developer's real global config.
    private func makeContext(appDefaultModel: String? = nil) -> ProjectSessionContext {
        let globalConfigStore = GlobalConfigStore(storageURL: tempDir.appendingPathComponent("global.json"))
        globalConfigStore.setDefaultModel(appDefaultModel)
        return ProjectSessionContext(
            runtimeFactory: { MockAgentRuntime() },
            agentCatalogStore: AgentCatalogStore(storageURL: tempDir.appendingPathComponent("catalog.json")),
            packageResolver: nil,
            globalConfigStore: globalConfigStore,
            orgManifestLoader: OrgManifestLoader(),
            repoCloneService: RepoCloneService()
        )
    }
}
