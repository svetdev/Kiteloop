import XCTest
import KiteloopCore
@testable import Kiteloop

/// Reading a project's working tree from the phone: the agent's uncommitted
/// changes, a file it names, and the web preview — and the refusals that keep
/// ignored files and anything outside the project on the Mac.
@MainActor
final class KiteloopControlServerWorkspaceTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var harness: ControlServerHarness!
    private var runtime: MockAgentRuntime!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-workspace")
        registry = ControlSessionRegistry()
        runtime = MockAgentRuntime()
        harness = try await ControlServerHarness.start(registry: registry)
    }

    override func tearDown() async throws {
        harness?.stop()
        harness = nil
        registry = nil
        runtime = nil
    }

    func testChangesListAChangedAndAnUntrackedFileWithThePatch() async throws {
        let root = try repository(named: "alpha")
        try "b\n".write(to: root.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: root.appending(path: "new.txt"), atomically: true, encoding: .utf8)

        let (status, body) = try await harness.get("/v1/workspace/changes?project=alpha")

        XCTAssertEqual(status, 200)
        let files = try XCTUnwrap(body["files"] as? [[String: Any]])
        XCTAssertEqual(files.compactMap { $0["path"] as? String }, ["a.txt", "new.txt"])
        XCTAssertTrue((body["patch"] as? String)?.contains("+b") == true)
    }

    func testChangesOfAProjectThatIsNotARepositoryIs409() async throws {
        try registerProject(named: "alpha")

        let (status, _) = try await harness.get("/v1/workspace/changes?project=alpha")

        XCTAssertEqual(status, 409)
    }

    func testAFileIsReadAndAnIgnoredOneIsRefused() async throws {
        let root = try repository(named: "alpha")
        try "SECRET=1\n".write(to: root.appending(path: ".env"), atomically: true, encoding: .utf8)

        let (status, body) = try await harness.get("/v1/workspace/file?project=alpha&path=a.txt")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["text"] as? String, "a\n")

        let (ignored, _) = try await harness.get("/v1/workspace/file?project=alpha&path=.env")
        XCTAssertEqual(ignored, 403, "a git-ignored file stays on the Mac")
        let (outside, _) = try await harness.get("/v1/workspace/file?project=alpha&path=../../etc/hosts")
        XCTAssertEqual(outside, 403)
    }

    func testThePreviewWithNoPreviewOpenIs409() async throws {
        try registerProject(named: "alpha")

        let (status, body) = try await harness.get("/v1/preview/screenshot?project=alpha")

        XCTAssertEqual(status, 409)
        XCTAssertTrue((body["error"] as? String)?.contains("No web preview") == true)
    }

    // MARK: - Helpers

    /// A registered project whose root is a git repository holding one commit
    /// of `a.txt` and a `.gitignore` naming `.env`.
    private func repository(named name: String) throws -> URL {
        let root = try registerProject(named: name).project.rootURL
        try "a\n".write(to: root.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try ".env\n.kiteloop/\n".write(to: root.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        for args in [["init", "-q"], ["config", "user.email", "t@t"], ["config", "user.name", "t"],
                     ["add", "a.txt", ".gitignore"], ["commit", "-q", "-m", "one"]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = root
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
        }
        return root
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
            runtime: runtime,
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

    private func makeContext() -> ProjectSessionContext {
        ProjectSessionContext(
            runtimeFactory: { [runtime] in runtime! },
            agentCatalogStore: AgentCatalogStore(storageURL: tempDir.appendingPathComponent("catalog.json")),
            packageResolver: nil,
            globalConfigStore: GlobalConfigStore(storageURL: tempDir.appendingPathComponent("global.json")),
            orgManifestLoader: OrgManifestLoader(),
            repoCloneService: RepoCloneService()
        )
    }
}
