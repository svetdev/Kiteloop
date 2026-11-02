import XCTest
import KiteloopCore
@testable import Kiteloop

/// `POST /v1/projects/ask` — the one endpoint that reads a project's **source**.
///
/// Every other read on this API answers from what the app already holds and
/// costs nothing; this one spends a model call with tools, which is why it is
/// asked for by name. What is asserted here is the endpoint's half of that
/// bargain: the shape of an answer, that a capped one says so in the body a
/// caller prints, and that each refusal reaches the caller as its own status
/// rather than as a 200 carrying an apology.
///
/// Exercised over a real loopback socket, like the other control-API tests.
@MainActor
final class KiteloopControlServerAskProjectTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var globalConfigStore: GlobalConfigStore!
    private var refill: CoordinatorQueueRefill!
    private var runtime: StubHeadlessRuntime!
    private var harness: ControlServerHarness!
    private var extraHarnesses: [ControlServerHarness] = []
    private let token = "control-ask-token-" + UUID().uuidString

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-ask")
        registry = ControlSessionRegistry()
        globalConfigStore = GlobalConfigStore(storageURL: tempDir.appending(path: "global.json"))
        refill = CoordinatorQueueRefill(ledgerURL: tempDir.appending(path: "refill.jsonl"))
        configure(reply: "Services/Foo.swift:12 still declares `Foo`.")
        harness = try await startServer(queueRefill: refill)
    }

    override func tearDown() async throws {
        harness?.stop()
        extraHarnesses.forEach { $0.stop() }
        extraHarnesses = []
        harness = nil
        refill?.stop()
        refill = nil
        registry = nil
        globalConfigStore = nil
        runtime = nil
    }

    // MARK: - Answering

    func testAnswersAQuestionAboutANamedProjectsSource() async throws {
        try registerProject(named: "alpha")

        let (status, body) = try await harness.post("/v1/projects/ask",
                                            ["project": "alpha", "question": "does Foo still exist?"])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["project"] as? String, "alpha")
        XCTAssertEqual(body["answer"] as? String, "Services/Foo.swift:12 still declares `Foo`.")
        XCTAssertEqual(body["capped"] as? Bool, false)
        XCTAssertNotNil(body["costUSD"] as? Double, "a read's price is part of its answer")
    }

    /// `q` is taken as an alias, the way `itemId` is elsewhere on this API.
    func testTakesQAsAnAliasForQuestion() async throws {
        try registerProject(named: "alpha")

        let (status, _) = try await harness.post("/v1/projects/ask",
                                         ["project": "alpha", "q": "does Foo still exist?"])

        XCTAssertEqual(status, 200)
    }

    /// The acceptance criterion, at the surface a driver actually reads: `capped`
    /// says so, and so does the answer's own text — a caller that prints only
    /// `answer` still learns it was cut.
    func testACappedAnswerSaysSoInBothPlaces() async throws {
        try registerProject(named: "alpha")
        configure(reply: String(repeating: "match at Services/Foo.swift ", count: 500))

        let (status, body) = try await harness.post("/v1/projects/ask",
                                            ["project": "alpha", "question": "every match?"])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["capped"] as? Bool, true)
        XCTAssertEqual((body["answer"] as? String)?.contains(RepoRead.capNotice), true)
    }

    // MARK: - Refusals

    /// A name that matched nothing is a 404 that lists the open projects, not a
    /// read of whichever project was nearest.
    func testAnUnknownProjectIs404AndNamesTheOpenOnes() async throws {
        try registerProject(named: "alpha")

        let (status, body) = try await harness.post("/v1/projects/ask",
                                            ["project": "alfa", "question": "q"])

        XCTAssertEqual(status, 404)
        XCTAssertEqual((body["error"] as? String)?.contains("alpha"), true)
    }

    func testAnExhaustedDailyCeilingIs429() async throws {
        try registerProject(named: "alpha")
        globalConfigStore.setDailyBudgetUSD(2)
        refill.recordSpend(2)

        let (status, body) = try await harness.post("/v1/projects/ask",
                                            ["project": "alpha", "question": "q"])

        XCTAssertEqual(status, 429)
        XCTAssertNotNil(body["error"] as? String)
    }

    func testAMissingOrEmptyQuestionIs400() async throws {
        try registerProject(named: "alpha")

        for body in [["project": "alpha"], ["project": "alpha", "question": "   "]] {
            let (status, reply) = try await harness.post("/v1/projects/ask", body)
            XCTAssertEqual(status, 400, "\(body)")
            XCTAssertEqual(reply["error"] as? String,
                           "Body must include \"project\" and a non-empty \"question\"")
        }
    }

    func testAMissingProjectIs400() async throws {
        let (status, _) = try await harness.post("/v1/projects/ask", ["question": "q"])

        XCTAssertEqual(status, 400)
    }

    /// With no Planner attached there is nothing to do the reading — say so,
    /// rather than answering from nothing.
    func testUnavailableWhenNoPlannerIsAttached() async throws {
        let detached = try await startServer(queueRefill: nil)
        extraHarnesses.append(detached)

        let (status, body) = try await detached.post("/v1/projects/ask",
                                            ["project": "alpha", "question": "q"])

        XCTAssertEqual(status, 503)
        XCTAssertEqual(body["error"] as? String,
                       "Cannot read a project's source — no Planner is attached to do the reading")
    }

    func testRequiresBearerToken() async throws {
        let (status, body) = try await harness.post("/v1/projects/ask",
                                            ["project": "alpha", "question": "q"], bearer: nil)

        XCTAssertEqual(status, 401)
        XCTAssertEqual(body["error"] as? String, "Missing or invalid bearer token")
    }

    // MARK: - Helpers

    private func configure(reply: String, costUSD: Double = 0.4) {
        runtime = StubHeadlessRuntime(behavior: .events([
            .result(.init(text: reply, costUSD: costUSD, durationMs: 0,
                          inputTokens: 0, outputTokens: 0,
                          cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                          sessionID: "stub-session", permissionDenials: []))
        ]))
        let runtime = runtime!
        refill.configure(registry: registry,
                         globalConfigStore: globalConfigStore,
                         runtimeFactory: { runtime })
    }

    private func registerProject(named name: String) throws {
        let root = tempDir.appending(path: name, directoryHint: .isDirectory)
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
            context: ProjectSessionContext(
                runtimeFactory: { MockAgentRuntime() },
                agentCatalogStore: AgentCatalogStore(
                    storageURL: tempDir.appending(path: "catalog-\(name).json")),
                packageResolver: nil,
                globalConfigStore: globalConfigStore,
                orgManifestLoader: OrgManifestLoader(),
                repoCloneService: RepoCloneService()
            )
        )
        registry.register(session: session, autopilot: BacklogAutopilot())
    }

    /// The port is picked at random and probed, since NWListener reports a bind
    /// conflict asynchronously rather than throwing from start().
    private func startServer(queueRefill: CoordinatorQueueRefill?)
    async throws -> ControlServerHarness {
        try await ControlServerHarness.start(token: token) {
            KiteloopControlServer(registry: registry, token: $0, queueRefill: queueRefill)
        }
    }
}
