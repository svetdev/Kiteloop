import XCTest
import KiteloopCore
@testable import Kiteloop

/// `POST /v1/runs/{runId}/cancel` — the way out of a run gone wrong for a headless
/// driver, exercised over a real loopback socket. Before it, the only stop button
/// was the one in the Autopilot tab, which a script can't reach.
@MainActor
final class KiteloopControlServerCancelRunTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var harness: ControlServerHarness!
    private var server: KiteloopControlServer { harness.server }
    private let token = "control-cancel-token-" + UUID().uuidString

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-cancel")
        registry = ControlSessionRegistry()
        harness = try await ControlServerHarness.start(registry: registry, token: token)
    }

    override func tearDown() async throws {
        harness?.stop()
        harness = nil
        registry = nil
    }

    // MARK: - Cancelling the run in flight

    /// The happy path: the run being cancelled is the one autopilot is executing,
    /// so its queue is stopped as well — otherwise autopilot would march straight
    /// on to the next item, which is not what "cancel" means to a caller.
    func testCancelStopsTheQueueForTheRunInFlight() async throws {
        let autopilot = try registerProject(named: "alpha") { $0.pause() }
        autopilot.stageExecutionIDForTesting("exec-alpha")
        trackRun(id: "exec-alpha", project: "alpha", item: "item-1")

        let (status, body) = try await harness.post("/v1/runs/exec-alpha/cancel")

        XCTAssertEqual(status, 202)
        XCTAssertEqual(body["runId"] as? String, "exec-alpha")
        XCTAssertEqual(body["item"] as? String, "item-1")
        XCTAssertEqual(body["state"] as? String, "cancelling")
        // The queue is stopped, not held: a stopped autopilot has to read `idle` or
        // the next `POST /v1/runs` waits out a 30s tail and then 409s.
        XCTAssertEqual(body["autopilot"] as? String, "idle")
        XCTAssertEqual(autopilot.status, .idle)
        XCTAssertTrue(autopilot.log.contains { $0.message == "Stopped by user" })
    }

    /// A run id that is no longer the one in flight must not stop the item that has
    /// since taken its place — cancelling a run that already moved on is a stale
    /// caller, not a licence to kill the current work.
    func testCancelOfAStaleRunLeavesTheQueueRunning() async throws {
        let autopilot = try registerProject(named: "alpha") { $0.pause() }
        autopilot.stageExecutionIDForTesting("exec-current")
        trackRun(id: "exec-stale", project: "alpha", item: "item-1")

        let (status, body) = try await harness.post("/v1/runs/exec-stale/cancel")

        XCTAssertEqual(status, 202)
        XCTAssertEqual(body["autopilot"] as? String, "paused")
        XCTAssertEqual(autopilot.status, .paused)
        XCTAssertFalse(autopilot.log.contains { $0.message == "Stopped by user" })
    }

    /// A finished run has nothing left to cancel — its item has already landed, and
    /// a 202 here would tell the caller work was called off that in fact shipped.
    func testCancelOfAFinishedRunIs409() async throws {
        let autopilot = try registerProject(named: "alpha") { $0.pause() }
        autopilot.stageExecutionIDForTesting("exec-alpha")
        autopilot.stageResultForTesting(
            BacklogAutopilot.ItemResult(id: "item-1", title: "Item one", outcome: .done, duration: 12)
        )
        trackRun(id: "exec-alpha", project: "alpha", item: "item-1")

        let (status, body) = try await harness.post("/v1/runs/exec-alpha/cancel")

        XCTAssertEqual(status, 409)
        XCTAssertEqual(body["error"] as? String, "Run exec-alpha has already finished")
        XCTAssertEqual(autopilot.status, .paused)
        XCTAssertFalse(autopilot.log.contains { $0.message == "Stopped by user" })
    }

    /// Cancelling one project's run must not stop another project's queue.
    func testCancelLeavesOtherProjectsRunning() async throws {
        let alpha = try registerProject(named: "alpha") { $0.pause() }
        let beta = try registerProject(named: "beta") { $0.pause() }
        alpha.stageExecutionIDForTesting("exec-alpha")
        beta.stageExecutionIDForTesting("exec-beta")
        trackRun(id: "exec-alpha", project: "alpha", item: "item-1")

        let (status, _) = try await harness.post("/v1/runs/exec-alpha/cancel")

        XCTAssertEqual(status, 202)
        XCTAssertEqual(alpha.status, .idle)
        XCTAssertEqual(beta.status, .paused)
        XCTAssertFalse(beta.log.contains { $0.message == "Stopped by user" })
    }

    // MARK: - Errors

    /// Run bookkeeping is in memory, so an id from before a restart — or a typo —
    /// is unknown rather than silently accepted.
    func testCancelUnknownRunIs404() async throws {
        try registerProject(named: "alpha") { $0.pause() }

        let (status, body) = try await harness.post("/v1/runs/nope/cancel")

        XCTAssertEqual(status, 404)
        XCTAssertEqual(body["error"] as? String, "Unknown run: nope")
    }

    /// Cancelling ends work in progress, so it sits behind the token like every
    /// other write — and an unauthenticated call changes nothing.
    func testCancelRequiresBearerToken() async throws {
        let autopilot = try registerProject(named: "alpha") { $0.pause() }
        autopilot.stageExecutionIDForTesting("exec-alpha")
        trackRun(id: "exec-alpha", project: "alpha", item: "item-1")

        let (status, body) = try await harness.post("/v1/runs/exec-alpha/cancel", bearer: nil)

        XCTAssertEqual(status, 401)
        XCTAssertEqual(body["error"] as? String, "Missing or invalid bearer token")
        XCTAssertEqual(autopilot.status, .paused)
        XCTAssertFalse(autopilot.log.contains { $0.message == "Stopped by user" })
    }

    // MARK: - Helpers

    /// Records a run with the server the way `POST /v1/runs` would, so the per-run
    /// endpoints can find it without starting real agents.
    private func trackRun(id: String, project: String, item: String) {
        let projectID = registry.entry(forProject: project)!.session.project.id
        server.track(KiteloopControlServer.RunInfo(
            runId: id,
            projectID: projectID,
            itemId: item,
            title: "Item one",
            startedAt: Date()
        ))
    }

    /// Builds a real `ProjectSession` over a throwaway directory and registers it
    /// with a fresh autopilot, which `configure` can drive into the state under
    /// test (`pause()` gives a queue that is not idle).
    @discardableResult
    private func registerProject(
        named name: String,
        configure: (BacklogAutopilot) -> Void
    ) throws -> BacklogAutopilot {
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
            context: makeContext()
        )

        let autopilot = BacklogAutopilot()
        configure(autopilot)
        registry.register(session: session, autopilot: autopilot)
        return autopilot
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
