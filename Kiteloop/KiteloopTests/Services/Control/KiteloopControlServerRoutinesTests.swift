import KiteloopCore
import XCTest
@testable import Kiteloop

/// The `/v1/routines` endpoints, in process, and the way a routine reaches the
/// agent it names: a real project, a scripted runtime.
@MainActor
final class KiteloopControlServerRoutinesTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var server: KiteloopControlServer!
    private var routines: RoutineRunner!
    private var runtime: MockAgentRuntime!
    private let token = "routines-token"

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-routines")
        registry = ControlSessionRegistry()
        runtime = MockAgentRuntime()
        server = KiteloopControlServer(registry: registry, token: token)
        routines = RoutineRunner(store: RoutineStore(directory: tempDir.appendingPathComponent("home")))
        routines.agent = { [unowned self] in self.server.routineAgent(for: $0) }
        routines.start()
        server.routines = routines
    }

    private let brief: [String: Any] = ["name": "Morning brief", "project": "vault", "agent": "Chief",
                                        "prompt": "Write the brief.", "trigger": ["at": "07:00"]]

    // MARK: - Writing and reading

    func testARoutineIsKeptOffAndListedWithWhenItNextFalls() async throws {
        let put = await send("PUT", "/v1/routines/brief", brief)
        XCTAssertEqual(put.status, 200)
        let kept = try XCTUnwrap(json(put)["routine"] as? [String: Any])
        XCTAssertEqual(kept["armed"] as? Bool, false)
        XCTAssertEqual(kept["when"] as? String, "Daily at 07:00")
        XCTAssertNotNil(kept["next"] as? String)
        XCTAssertTrue(kept["lastRun"] is NSNull)

        let listed = json(await send("GET", "/v1/routines"))["routines"] as? [[String: Any]]
        XCTAssertEqual(listed?.map { $0["id"] as? String }, ["brief"])
        let other = json(await send("GET", "/v1/routines", query: ["project": "elsewhere"]))["routines"] as? [[String: Any]]
        XCTAssertEqual(other?.count, 0)
    }

    func testABodyThatCannotBeARoutineIs400NamingEveryProblem() async {
        let response = await send("PUT", "/v1/routines/brief", ["project": "vault", "trigger": ["at": "7"]])

        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(json(response)["error"] as? String,
                       "\"agent\" is required; \"prompt\" is required; \"at\" is a time of day as HH:mm")
    }

    func testReplacingARoutineKeepsItArmed() async throws {
        var armed = brief
        armed["armed"] = true
        _ = await send("PUT", "/v1/routines/brief", armed)

        var reworded = brief
        reworded["prompt"] = "Shorter."
        let response = await send("PUT", "/v1/routines/brief", reworded)

        let kept = try XCTUnwrap(json(response)["routine"] as? [String: Any])
        XCTAssertEqual(kept["armed"] as? Bool, true)
        XCTAssertEqual(kept["prompt"] as? String, "Shorter.")
    }

    func testDeletingRemovesItAndASecondDeleteIs404() async {
        _ = await send("PUT", "/v1/routines/brief", brief)

        let removed = await send("DELETE", "/v1/routines/brief")
        let again = await send("DELETE", "/v1/routines/brief")

        XCTAssertEqual(removed.status, 200)
        XCTAssertEqual(json(removed)["removed"] as? String, "brief")
        XCTAssertEqual(again.status, 404)
        XCTAssertEqual(routines.routines, [])
    }

    func testARoutinesFileThatCannotBeWrittenIs500() async throws {
        let blocked = tempDir.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let stuck = RoutineRunner(store: RoutineStore(directory: blocked))
        server.routines = stuck

        let response = await send("PUT", "/v1/routines/brief", brief)

        XCTAssertEqual(response.status, 500)
        XCTAssertTrue((json(response)["error"] as? String ?? "").hasPrefix("The routines file could not be written"))
    }

    func testAServerWithNoRoutinesAnswers503() async {
        server.routines = nil

        let response = await send("GET", "/v1/routines")

        XCTAssertEqual(response.status, 503)
    }

    // MARK: - Running

    func testRunNowSendsThePromptToTheAgentAndTheLedgerSaysHowItWent() async throws {
        let session = try registerProject(named: "vault")
        let agentID = addAgent(named: "Chief", to: session)
        runtime.events = [.assistantText("Three things today."), .result(Self.done("Three things today."))]
        _ = await send("PUT", "/v1/routines/brief", brief)

        let started = await send("POST", "/v1/routines/brief/run")
        XCTAssertEqual(started.status, 202)
        try await eventually("the turn ended") { self.routines.lastRun(of: "brief")?.finishedAt != nil }

        let chat = try XCTUnwrap(session.chatViewModels[agentID])
        XCTAssertTrue(chat.messages.contains { message in
            if case .text(let text) = message.content { return text == "Write the brief." }
            return false
        }, "the prompt went into the agent's chat")
        let ledger = await send("GET", "/v1/routines/runs", query: ["routine": "brief"])
        let runs = try XCTUnwrap(json(ledger)["runs"] as? [[String: Any]])
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?["outcome"] as? String, "started")
        XCTAssertEqual(runs.first?["reply"] as? String, "Three things today.")
        XCTAssertEqual(runs.first?["costUSD"] as? Double, 0.01)
        let none = json(await send("GET", "/v1/routines/runs", query: ["routine": "other"]))["runs"] as? [[String: Any]]
        XCTAssertEqual(none?.count, 0)
    }

    func testRunNowForAnIdNobodyHasIs404() async {
        let response = await send("POST", "/v1/routines/nobody/run")

        XCTAssertEqual(response.status, 404)
    }

    // MARK: - Reaching the agent

    func testWhatStandsBetweenARoutineAndItsAgentIsNamed() async throws {
        let routine = Routine(id: "brief", name: "Brief", project: "vault", agent: "Chief", prompt: "x",
                              trigger: .init(at: "07:00"))
        XCTAssertEqual(refusal(routine), "project not open in Kiteloop: vault")

        let session = try registerProject(named: "vault")
        XCTAssertEqual(refusal(routine), "no agent 'Chief' in vault")

        addAgent(named: "Chief", to: session)
        XCTAssertNil(refusal(routine))

        _ = await server.fleet.quiesce()
        XCTAssertEqual(refusal(routine), "the fleet is being held for a restart")
    }

    func testTheDaysBudgetRefusesARoutineOnceItIsSpent() throws {
        let folder = try registerProject(named: "vault").project.rootURL
        let ledger = DailySpendLedger(storageURL: tempDir.appendingPathComponent("spend.json"))

        XCTAssertNil(server.routineBudgetRefusal(folder: folder, ledger: ledger, portfolioBudgetUSD: 5))
        ledger.charge(costUSD: 6, project: folder.path(percentEncoded: false))

        XCTAssertEqual(server.routineBudgetRefusal(folder: folder, ledger: ledger, portfolioBudgetUSD: 5),
                       "daily budget $5.00 exhausted ($6.00 spent today)")
        XCTAssertNil(server.routineBudgetRefusal(folder: folder, ledger: ledger, portfolioBudgetUSD: nil))
    }

    // MARK: - Helpers

    private func refusal(_ routine: Routine) -> String? {
        guard case .failure(let refusal) = server.routineAgent(for: routine) else { return nil }
        return refusal.reason
    }

    private func send(_ method: String, _ path: String, _ body: [String: Any] = [:],
                      query: [String: String] = [:]) async -> HTTPServer.Response {
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        return await server.handle(HTTPServer.Request(method: method, path: path, query: query,
                                                      headers: ["authorization": "Bearer \(token)"], body: data))
    }

    private func json(_ response: HTTPServer.Response) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
    }

    private static func done(_ text: String) -> StreamEvent.ResultPayload {
        .init(text: text, costUSD: 0.01, durationMs: 500, inputTokens: 100, outputTokens: 50,
              cacheCreationInputTokens: 0, cacheReadInputTokens: 0, sessionID: "s1", permissionDenials: [])
    }

    @discardableResult
    private func registerProject(named name: String) throws -> ProjectSession {
        let root = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootURL = URL(fileURLWithPath: root.path(percentEncoded: false), isDirectory: false)
        let project = KiteloopProject(rootURL: rootURL)
        try project.ensureDirectoryExists()
        let eventBus = EventBus(eventsURL: project.eventsURL)
        let orchestrator = Orchestrator(
            runtime: runtime, eventBus: eventBus,
            subscriptionEngine: SubscriptionEngine(eventBus: eventBus),
            memoryManager: MemoryManager(project: project))
        let session = ProjectSession(
            project: project, projectURL: rootURL, orchestrator: orchestrator,
            sessionStore: SessionStore(projectDir: rootURL),
            knowledgeStore: AgentKnowledgeStore(baseURL: project.knowledgeURL),
            knowledgeIndex: KnowledgeIndex(baseURL: project.knowledgeURL),
            context: ProjectSessionContext(
                runtimeFactory: { [runtime] in runtime! },
                agentCatalogStore: AgentCatalogStore(storageURL: tempDir.appendingPathComponent("catalog.json")),
                packageResolver: nil,
                globalConfigStore: GlobalConfigStore(storageURL: tempDir.appendingPathComponent("global.json")),
                orgManifestLoader: OrgManifestLoader(),
                repoCloneService: RepoCloneService()))
        registry.register(session: session, autopilot: BacklogAutopilot())
        return session
    }

    @discardableResult
    private func addAgent(named name: String, to projectSession: ProjectSession) -> String {
        let agent = Agent(name: name, model: "sonnet", systemPrompt: "", tools: [], denied: [],
                          permissionMode: "acceptEdits")
        projectSession.orchestrator.addAgent(agent)
        return agent.id
    }
}
