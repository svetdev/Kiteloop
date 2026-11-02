import XCTest
import KiteloopCore
@testable import Kiteloop

/// `POST /v1/backlog/refresh` — rebasing a stale item at the gate by hand, the
/// same round autopilot runs on its own once the project goes idle
/// (`GateRefreshTests` covers that round itself, with a scripted worker that
/// performs the merge). What is asserted here is the HTTP surface: the
/// project has to be a real repository since staleness is a `merge-base`
/// question, so these run over a real loopback socket with a real git-backed
/// project, like the other control-API backlog tests.
@MainActor
final class KiteloopControlServerBacklogRefreshTests: XCTestCase {

    private var tempDir: URL!
    private var retainedChatVMs: [ChatViewModel] = []
    private var registry: ControlSessionRegistry!
    private var harness: ControlServerHarness!
    private let token = "control-refresh-token-" + UUID().uuidString

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-refresh")
        registry = ControlSessionRegistry()
        harness = try await ControlServerHarness.start(registry: registry, token: token)
    }

    override func tearDown() async throws {
        harness?.stop()
        harness = nil
        registry = nil
    }

    // MARK: - The happy path

    /// A stale item is rebased and reads clean afterwards, still sitting at
    /// the gate.
    func testRefreshesAStaleItemAndAnswersRefreshed() async throws {
        let root = projectRoot("alpha")
        try registerGitProject(
            named: "alpha", itemID: "item-1",
            verify: "test -f feature.txt && test -f advanced.txt",
            runtime: MergingAgentRuntimeBox())

        // The round below really runs — a worker graph plus the item's verify —
        // so give the request the round's clock, not the default one.
        let (status, body) = try await harness.post("/v1/backlog/refresh", [
            "project": "alpha", "item": "item-1",
        ], timeout: 90)

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["item"] as? String, "item-1")
        XCTAssertEqual(body["result"] as? String, "refreshed")
        let manager = WorktreeManager(projectRoot: root)
        let stillStale = await manager.isStale(for: "item-1")
        XCTAssertFalse(stillStale, "the branch must read clean after the round")
        XCTAssertEqual(registry.entry(forProject: "alpha")?.session.backlogViewModel
            .item(withID: "item-1")?.status, .awaitingApproval,
            "a refresh never leaves the gate")
    }

    // MARK: - Preconditions that answer 409 without running a round

    func testItemNotAtTheGateAnswers409() async throws {
        _ = try registerProject(named: "beta", items: ["- [ ] item-1 | Ready item | ready"])

        let (status, body) = try await harness.post("/v1/backlog/refresh", [
            "project": "beta", "item": "item-1",
        ])

        XCTAssertEqual(status, 409)
        XCTAssertTrue((body["error"] as? String ?? "").contains("not awaiting approval"),
                      body["error"] as? String ?? "")
    }

    func testAnAlreadyFreshItemAnswers409() async throws {
        try registerGitProject(named: "gamma", itemID: "item-1", verify: nil,
                               runtime: NoOpAgentRuntimeBox(), stale: false)

        let (status, body) = try await harness.post("/v1/backlog/refresh", [
            "project": "gamma", "item": "item-1",
        ])

        XCTAssertEqual(status, 409)
        XCTAssertTrue((body["error"] as? String ?? "").contains("fresh"), body["error"] as? String ?? "")
    }

    // MARK: - Errors that don't depend on the gate at all

    func testMissingItemIs400() async throws {
        try registerProject(named: "delta", items: ["- [ ] item-1 | An item | ready"])

        let (status, body) = try await harness.post("/v1/backlog/refresh", ["project": "delta"])

        XCTAssertEqual(status, 400)
        XCTAssertEqual(body["error"] as? String, "Body must include \"project\" and \"item\"")
    }

    func testUnknownProjectIs409() async throws {
        let (status, body) = try await harness.post("/v1/backlog/refresh", [
            "project": "ghost", "item": "item-1",
        ])

        XCTAssertEqual(status, 409)
        XCTAssertEqual(body["error"] as? String, "Project not open in Kiteloop: ghost")
    }

    func testUnknownItemIs404() async throws {
        _ = try registerProject(named: "epsilon", items: ["- [ ] item-1 | An item | ready"])

        let (status, body) = try await harness.post("/v1/backlog/refresh", [
            "project": "epsilon", "item": "ghost",
        ])

        XCTAssertEqual(status, 404)
        XCTAssertEqual(body["error"] as? String, "No backlog item 'ghost' in this project")
    }

    func testRequiresBearerToken() async throws {
        _ = try registerProject(named: "zeta", items: ["- [ ] item-1 | An item | ready"])

        let (status, body) = try await harness.post(
            "/v1/backlog/refresh", ["project": "zeta", "item": "item-1"], bearer: nil)

        XCTAssertEqual(status, 401)
        XCTAssertEqual(body["error"] as? String, "Missing or invalid bearer token")
    }

    // MARK: - Scripted runtimes
    //
    // Boxed rather than passed directly: `AgentRuntime` is `Sendable` and these
    // classes hold mutable state (`lastCwd`) a `@unchecked Sendable` box is the
    // established way to carry across the actor hop `Orchestrator` makes.

    /// A worker whose turn merges the project's base branch into whatever its
    /// worktree has checked out — the scripted stand-in for a real worker's
    /// Bash tool carrying out the merge instruction.
    private final class MergingAgentRuntimeBox: AgentRuntime, @unchecked Sendable {
        var base = "main"
        private(set) var lastCwd: URL?

        func startSession(agent: Agent, cwd: URL, strategy: ResumeStrategy) async throws -> AgentSession {
            try await startSession(agent: agent, cwd: cwd, strategy: strategy, options: SessionOptions())
        }
        func startSession(agent: Agent, cwd: URL, strategy: ResumeStrategy, options: SessionOptions) async throws -> AgentSession {
            lastCwd = cwd
            return AgentSession(id: "mock-session", agentID: agent.id, startedAt: .now)
        }
        func send(_ message: String, attachments: [ChatAttachment], to session: AgentSession) -> AsyncStream<StreamEvent> {
            let cwd = lastCwd
            let base = self.base
            return AsyncStream { continuation in
                Task {
                    if let cwd {
                        let merge = Process()
                        merge.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                        merge.arguments = ["merge", "--no-ff", "-m", "merge \(base)", base]
                        merge.currentDirectoryURL = cwd
                        merge.standardOutput = Pipe()
                        merge.standardError = Pipe()
                        try? merge.run()
                        merge.waitUntilExit()
                    }
                    continuation.yield(.result(StreamEvent.ResultPayload(
                        text: "merged", costUSD: 0, durationMs: 0,
                        inputTokens: 0, outputTokens: 0,
                        cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                        sessionID: "mock-session", permissionDenials: [])))
                    continuation.finish()
                }
            }
        }
        func sendToolResult(toolCallID: String, content: String, to session: AgentSession) -> AsyncStream<StreamEvent> {
            AsyncStream { $0.finish() }
        }
        func sendMCPToolResult(requestID: String, result: String, to session: AgentSession) {}
        func interrupt(session: AgentSession) {}
        func stop(session: AgentSession) {}
    }

    /// A worker that answers but never touches the tree.
    private final class NoOpAgentRuntimeBox: AgentRuntime, @unchecked Sendable {
        func startSession(agent: Agent, cwd: URL, strategy: ResumeStrategy) async throws -> AgentSession {
            AgentSession(id: "mock-session", agentID: agent.id, startedAt: .now)
        }
        func startSession(agent: Agent, cwd: URL, strategy: ResumeStrategy, options: SessionOptions) async throws -> AgentSession {
            AgentSession(id: "mock-session", agentID: agent.id, startedAt: .now)
        }
        func send(_ message: String, attachments: [ChatAttachment], to session: AgentSession) -> AsyncStream<StreamEvent> {
            AsyncStream { continuation in
                continuation.yield(.result(StreamEvent.ResultPayload(
                    text: "nothing to do", costUSD: 0, durationMs: 0,
                    inputTokens: 0, outputTokens: 0,
                    cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                    sessionID: "mock-session", permissionDenials: [])))
                continuation.finish()
            }
        }
        func sendToolResult(toolCallID: String, content: String, to session: AgentSession) -> AsyncStream<StreamEvent> {
            AsyncStream { $0.finish() }
        }
        func sendMCPToolResult(requestID: String, result: String, to session: AgentSession) {}
        func interrupt(session: AgentSession) {}
        func stop(session: AgentSession) {}
    }

    // MARK: - Fixtures

    private func projectRoot(_ name: String) -> URL {
        tempDir.appendingPathComponent(name, isDirectory: true)
    }

    /// A project whose root is a real git repository, with `item-1`'s branch
    /// either stale (default — `main` has moved past it) or fresh (forked at
    /// the tip), and its autopilot fully wired to `runtime` — the same
    /// `orchestrator`, `backlogViewModel` and root the control server reads.
    @discardableResult
    private func registerGitProject(
        named name: String, itemID: String, verify: String?,
        runtime: AgentRuntime, stale: Bool = true
    ) throws -> String {
        let line = verify.map { "- [ ] \(itemID) | Needs sign-off | verify: \($0) | awaiting-approval" }
            ?? "- [ ] \(itemID) | Needs sign-off | awaiting-approval"
        _ = try registerProject(named: name, items: [line], runtime: runtime)

        let root = projectRoot(name)
        git(["init", "-b", "main"], in: root)
        git(["config", "user.email", "test@test.com"], in: root)
        git(["config", "user.name", "Test"], in: root)
        git(["add", "."], in: root)
        git(["commit", "-m", "init"], in: root)
        git(["checkout", "-b", WorktreeSession.branchName(for: itemID)], in: root)
        try "feature".write(to: root.appending(path: "feature.txt"), atomically: true, encoding: .utf8)
        git(["add", "."], in: root)
        git(["commit", "-m", "the item's own work"], in: root)
        git(["checkout", "main"], in: root)
        if stale {
            try "advanced".write(to: root.appending(path: "advanced.txt"), atomically: true, encoding: .utf8)
            git(["add", "."], in: root)
            git(["commit", "-m", "the base moved on"], in: root)
        }
        return "main"
    }

    /// Every registered project's autopilot is fully wired — the same
    /// `orchestrator`, `backlogViewModel` and root the control server reads —
    /// because `refreshGateItem` runs through the autopilot's own state the
    /// way starting a run does, unlike the pure backlog-file mutations
    /// (`approve`, `groom`, `move`) whose tests leave it unconfigured.
    @discardableResult
    private func registerProject(
        named name: String, items: [String], runtime: AgentRuntime = MockAgentRuntime()
    ) throws -> ControlSessionRegistry.Entry {
        let root = projectRoot(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootURL = URL(fileURLWithPath: root.path(percentEncoded: false), isDirectory: false)
        let project = KiteloopProject(rootURL: rootURL)
        try project.ensureDirectoryExists()

        try "# \(name) Backlog\n\n## Now\n\n\(items.joined(separator: "\n"))\n"
            .write(to: root.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)

        let eventBus = EventBus(eventsURL: project.eventsURL)
        let orchestrator = Orchestrator(
            runtime: runtime,
            eventBus: eventBus,
            subscriptionEngine: SubscriptionEngine(eventBus: eventBus),
            memoryManager: MemoryManager(project: project)
        )
        orchestrator.addAgent(Agent(
            id: "worker", name: "Worker", model: "sonnet", systemPrompt: "",
            tools: [], denied: [], permissionMode: "default", state: .idle))
        // The delivery half of a workflow round — the same wiring
        // `ProjectSession` gives every agent; without it the refresh round's
        // worker node never runs and the request dies of the stall clock.
        retainedChatVMs.append(ChatViewModel(
            agentID: "worker", projectURL: rootURL, orchestrator: orchestrator))
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
        registry.register(session: session, autopilot: autopilot)
        autopilot.configure(
            orchestrator: orchestrator,
            backlogViewModel: session.backlogViewModel,
            projectPath: rootURL.path(percentEncoded: false),
            projectName: name)
        autopilot.workerAgentID = "worker"
        return try XCTUnwrap(registry.entry(forProject: name))
    }

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
}
