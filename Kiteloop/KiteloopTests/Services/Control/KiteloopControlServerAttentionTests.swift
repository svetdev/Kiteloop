import XCTest
import KiteloopCore
@testable import Kiteloop

/// `GET /v1/attention`: the waiting drawer's list over the control API — an
/// item at the approval gate and an agent holding an `ask_human`, each naming
/// the call that answers it — answered in process through `handle(_:)`.
@MainActor
final class KiteloopControlServerAttentionTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var tokens: ControlScopedTokens!
    private var harness: ControlServerHarness!
    private var runtime: MockAgentRuntime!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-attention")
        let registry = ControlSessionRegistry()
        let tokens = ControlScopedTokens(url: tempDir.appending(path: "control-scoped-tokens.json"))
        self.registry = registry
        self.tokens = tokens
        runtime = MockAgentRuntime()
        harness = try await ControlServerHarness.start { token in
            KiteloopControlServer(registry: registry, token: token, scopedTokens: tokens)
        }
    }

    override func tearDown() async throws {
        harness?.stop()
        harness = nil
        registry = nil
        runtime = nil
    }

    // MARK: - The list

    func testAnApprovalAndAQuestionAreServedWithTheirAnswers() async throws {
        let session = try registerProject(named: "alpha", items: [
            "- [ ] item-1 | Needs sign-off | awaiting-approval"
        ])
        let agentID = try await askedTurn(in: session)

        let body = try await eventuallyValue("both rows to be listed") { () -> [String: Any]? in
            let response = await self.harness.server.handle(self.request(bearer: self.harness.token))
            let body = self.json(response)
            return (body["count"] as? Int) == 2 ? body : nil
        }
        let rows = try XCTUnwrap(body["rows"] as? [[String: Any]])
        let approval = try XCTUnwrap(rows.first { $0["kind"] as? String == "approval" })
        XCTAssertEqual(approval["itemId"] as? String, "item-1")
        XCTAssertEqual(approval["title"] as? String, "Needs sign-off")
        XCTAssertEqual(approval["answer"] as? [String: String],
                       ["method": "POST", "path": "/v1/backlog/approve"])
        let question = try XCTUnwrap(rows.first { $0["kind"] as? String == "question" })
        XCTAssertEqual(question["agentId"] as? String, agentID)
        XCTAssertEqual(question["answer"] as? [String: String],
                       ["method": "POST", "path": "/v1/agents/answer"])
        XCTAssertEqual((question["project"] as? [String: Any])?["name"] as? String, "alpha")
        XCTAssertEqual(body["summary"] as? String, "1 approval · 1 question")
    }

    // MARK: - Auth

    func testWithoutATokenItIsUnauthorized() async {
        let response = await harness.server.handle(request(bearer: nil))
        XCTAssertEqual(response.status, 401)
    }

    func testAReadScopedTokenReadsIt() async {
        let read = tokens.mint(name: "dashboard", scope: .read).token
        let response = await harness.server.handle(request(bearer: read))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(json(response)["count"] as? Int, 0)
        XCTAssertEqual(json(response)["summary"] as? String, "nothing is waiting on you")
    }

    // MARK: - Helpers

    private static func done(_ text: String) -> StreamEvent.ResultPayload {
        .init(text: text, costUSD: 0.01, durationMs: 500, inputTokens: 100, outputTokens: 50,
              cacheCreationInputTokens: 0, cacheReadInputTokens: 0, sessionID: "s1", permissionDenials: [])
    }

    /// An agent whose turn ended on an unanswered `ask_human`.
    private func askedTurn(in session: ProjectSession) async throws -> String {
        let agent = Agent(name: "Builder", model: "sonnet", systemPrompt: "", tools: [], denied: [],
                          permissionMode: "acceptEdits")
        session.orchestrator.addAgent(agent)
        runtime.events = [
            .toolUse(id: "ask-1", name: "ask_human", input: "{\"question\": \"Keep the old rounding?\"}"),
            .result(Self.done("waiting"))
        ]
        _ = try await harness.post("/v1/agents/message",
                                   ["project": "alpha", "agent": "Builder", "message": "fix it", "wait": true],
                                   timeout: 30)
        XCTAssertEqual(session.chatViewModels[agent.id]?.pendingHumanToolCallID, "ask-1")
        return agent.id
    }

    private func registerProject(named name: String, items: [String]) throws -> ProjectSession {
        let root = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootURL = URL(fileURLWithPath: root.path(percentEncoded: false), isDirectory: false)
        let project = KiteloopProject(rootURL: rootURL)
        try project.ensureDirectoryExists()
        try "# \(name) Backlog\n\n## Now\n\n\(items.joined(separator: "\n"))\n"
            .write(to: root.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)

        let eventBus = EventBus(eventsURL: project.eventsURL)
        let orchestrator = Orchestrator(runtime: runtime, eventBus: eventBus,
                                        subscriptionEngine: SubscriptionEngine(eventBus: eventBus),
                                        memoryManager: MemoryManager(project: project))
        orchestrator.configureNotifications(notificationsURL: project.notificationsURL)
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

    private func request(bearer: String?) -> HTTPServer.Request {
        var headers: [String: String] = [:]
        if let bearer { headers["authorization"] = "Bearer \(bearer)" }
        return HTTPServer.Request(method: "GET", path: "/v1/attention", query: [:], headers: headers, body: Data())
    }

    private func json(_ response: HTTPServer.Response) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
    }
}
