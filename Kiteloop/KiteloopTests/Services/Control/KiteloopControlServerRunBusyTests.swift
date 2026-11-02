import XCTest
import KiteloopCore
@testable import Kiteloop

/// `POST /v1/runs` and what may refuse it.
///
/// A project could be refused forever: the guard read the autopilot's `status`,
/// which a run that never began (the session cost cap fires before the first
/// item) leaves non-idle, and a driver reads 409 as "wait for the run in flight"
/// and waits for one that does not exist. The guard now asks whether a run
/// actually exists — and, when one does, the refusal names it.
@MainActor
final class KiteloopControlServerRunBusyTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var harness: ControlServerHarness!
    private var server: KiteloopControlServer { harness.server }
    private let token = "control-runbusy-token-" + UUID().uuidString

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-runbusy")
        registry = ControlSessionRegistry()
        // The refusal is the point of these tests, so don't spend the production
        // tail wait on reaching it.
        KiteloopControlServer.busyWaitMilliseconds = 1_000
        harness = try await ControlServerHarness.start(registry: registry, token: token)
    }

    override func tearDown() async throws {
        KiteloopControlServer.busyWaitMilliseconds = 30_000
        harness?.stop()
        harness = nil
        registry = nil
    }

    // MARK: - A claim with nothing behind it

    /// Since `pausing-a-project-holds-only-its-queue`, a `paused` status is a
    /// real hold rather than a stale claim: the request is refused as a pause,
    /// with the remedy named — not cleared, and not mistaken for a busy run.
    func testAPausedStatusRefusesTheRunAsAPause() async throws {
        let autopilot = try registerProject(named: "alpha", items: [
            "- [ ] item-1 | Ready to go | ready"
        ])
        autopilot.stageRunForTesting(status: .paused, queue: [stagedItem("item-1")])
        autopilot.stageQueueIndexForTesting(1)   // the queue ran out under the hold

        let (status, body) = try await harness.post("/v1/runs", ["project": "alpha", "item": "item-1"])

        XCTAssertEqual(status, 409)
        XCTAssertEqual(body["error"] as? String,
                       "This project is paused — no new runs are being accepted. "
                       + "POST /v1/autopilot/resume to lift the hold, or GET /v1/projects to see it.")
    }

    /// And the claim is put right rather than left to refuse the Autopilot tab's
    /// Start button, which is only enabled while the autopilot reads idle.
    func testAStaleBusyClaimIsReconciledByARunRequest() async throws {
        let autopilot = try registerProject(named: "alpha", items: [
            "- [ ] item-1 | Ready to go | ready"
        ])
        autopilot.stageRunForTesting(status: .running(itemIndex: 0, total: 1),
                                     queue: [stagedItem("item-1")])

        _ = try await harness.post("/v1/runs", ["project": "alpha", "item": "item-1"])

        XCTAssertEqual(autopilot.status, .idle)
        XCTAssertTrue(autopilot.log.contains { $0.message.contains("Cleared a stale busy state (run requested)") })
    }

    /// The claim that outlived its run, and the one nothing could shift: the
    /// execution the last item ran under is still live, and *it* — not the
    /// status, which reads a perfectly ordinary `idle` — is what holds the
    /// project's one run slot. On 2026-08-11 this request answered 409 against
    /// it and the driver went away to wait for a run that had already finished;
    /// only restarting the app cleared it. The request clears it instead, and is
    /// refused for the next reason, about this request.
    func testAStrandedExecutionDoesNotRefuseARun() async throws {
        let (autopilot, stranded) = try await registerProjectHoldingAStrandedRun(named: "alpha")

        let (status, body) = try await harness.post("/v1/runs", ["project": "alpha", "item": "item-1"])

        XCTAssertEqual(status, 409)
        XCTAssertEqual(body["error"] as? String,
                       "Configure worker and reviewer agents in the Autopilot screen first",
                       "the run slot must not be what refuses this")
        XCTAssertNil(autopilot.currentExecutionID, "the claim is cleared, not merely stepped around")
        XCTAssertTrue(autopilot.log.contains {
            $0.message.contains("Cleared a stale busy state (run requested): run \(stranded)")
        }, "clearing it has to be visible in the run log: \(autopilot.log.map(\.message))")
    }

    // MARK: - A run that really is in flight

    /// The guard is not weakened: a project executing a run still refuses another,
    /// and says what it thinks it is running so a caller can check the claim.
    func testARunInFlightStillRefusesAnotherAndNamesIt() async throws {
        let autopilot = try registerProject(named: "alpha", items: [
            "- [ ] item-1 | Ready to go | ready"
        ])
        autopilot.stageRunForTesting(status: .running(itemIndex: 0, total: 1),
                                     queue: [stagedItem("item-1")])
        autopilot.stageExecutingRunForTesting(true)

        let (status, body) = try await harness.post("/v1/runs", ["project": "alpha", "item": "item-1"])

        XCTAssertEqual(status, 409)
        XCTAssertEqual(body["error"] as? String,
                       "Autopilot is still busy for this project — running item-1 (ITEM-1)")
        XCTAssertEqual(autopilot.status, .running(itemIndex: 0, total: 1),
                       "a live run must not be reconciled out from under itself")
    }

    // MARK: - After a cancel

    /// Cancelling stops the project's queue, and a stopped queue is not a busy
    /// one: the next item can be started without waiting anything out.
    func testACancelledRunLeavesTheProjectAbleToStartAnother() async throws {
        let autopilot = try registerProject(named: "alpha", items: [
            "- [ ] item-1 | Ready to go | ready"
        ])
        autopilot.stageRunForTesting(status: .running(itemIndex: 0, total: 1),
                                     queue: [stagedItem("item-1")])
        autopilot.stageExecutionIDForTesting("exec-alpha")
        server.track(KiteloopControlServer.RunInfo(
            runId: "exec-alpha",
            projectID: registry.entry(forProject: "alpha")!.session.project.id,
            itemId: "item-1",
            title: "Ready to go",
            startedAt: Date()
        ))

        let (cancelled, _) = try await harness.post("/v1/runs/exec-alpha/cancel", [:])
        let (status, body) = try await harness.post("/v1/runs", ["project": "alpha", "item": "item-1"])

        XCTAssertEqual(cancelled, 202)
        XCTAssertEqual(status, 409)
        XCTAssertEqual(body["error"] as? String,
                       "Configure worker and reviewer agents in the Autopilot screen first")
    }

    // MARK: - Helpers

    /// The queue entry a staged run is sitting on. Its title is what the refusal
    /// quotes back.
    private func stagedItem(_ id: String) -> BacklogItem {
        BacklogItem(id: id, title: id.uppercased(), verify: "true", status: .ready, type: .local, size: .s)
    }

    /// Builds a real `ProjectSession` over a throwaway directory with a BACKLOG.md
    /// the run request can resolve its item against, and returns the autopilot the
    /// test drives into the state under test.
    @discardableResult
    private func registerProject(named name: String, items: [String]) throws -> BacklogAutopilot {
        let root = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootURL = URL(fileURLWithPath: root.path(percentEncoded: false), isDirectory: false)
        let project = KiteloopProject(rootURL: rootURL)
        try project.ensureDirectoryExists()

        try "# \(name) Backlog\n\n## Now\n\n\(items.joined(separator: "\n"))\n"
            .write(to: root.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)

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
        registry.register(session: session, autopilot: autopilot)
        return autopilot
    }

    /// A project whose autopilot still names the execution its last run was
    /// using, with that execution live in the orchestrator's engine and holding
    /// its agents — what a run that ended by timing out on the reservation queue
    /// leaves behind. The session keeps the orchestrator alive; the autopilot
    /// only holds it weakly.
    private func registerProjectHoldingAStrandedRun(
        named name: String
    ) async throws -> (BacklogAutopilot, String) {
        let autopilot = try registerProject(named: name, items: [
            "- [ ] item-1 | Ready to go | ready"
        ])
        let entry = try XCTUnwrap(registry.entry(forProject: name))
        let orchestrator = entry.session.orchestrator

        var nodes: [String: WorkflowNode] = [:]
        for (index, agentID) in ["worker", "reviewer"].enumerated() {
            nodes["node-\(index)"] = WorkflowNode(id: "node-\(index)", agentID: agentID, prompt: "Do work")
        }
        await orchestrator.workflowEngine.register(graph: WorkflowGraph(
            id: "g", name: "g", version: 1,
            nodes: nodes,
            edges: [WorkflowEdge(from: "node-0", to: "node-1", condition: .always)],
            entryNode: "node-0",
            terminalNodes: ["node-1"],
            metadata: .empty
        ))
        let stranded = try await orchestrator.workflowEngine.start(graphID: "g", initialState: [:])

        autopilot.configure(orchestrator: orchestrator,
                            backlogViewModel: entry.session.backlogViewModel,
                            configURL: nil)
        autopilot.stageExecutionIDForTesting(stranded)
        return (autopilot, stranded)
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
