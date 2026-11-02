import XCTest
import KiteloopCore
@testable import Kiteloop

/// `GET`/`POST /v1/fleet/quiesce` and `POST /v1/fleet/resume` over a real loopback
/// socket — the fleet-level verb an operator uses before restarting the app.
/// `FleetQuiesceTests` covers the decisions; this covers the wire: the shape of
/// the reading, the validation, and the gate that makes a quiesced fleet actually
/// refuse a run.
@MainActor
final class KiteloopControlServerFleetQuiesceTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var harness: ControlServerHarness!
    private var server: KiteloopControlServer { harness.server }
    private let token = "control-fleet-token-" + UUID().uuidString

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-fleet")
        registry = ControlSessionRegistry()
        harness = try await ControlServerHarness.start(registry: registry, token: token)
    }

    override func tearDown() async throws {
        harness?.stop()
        harness = nil
        registry = nil
    }

    // MARK: - The reading

    /// A fleet nobody has held says so, rather than reporting a hold that isn't
    /// there. Read-only: it must not close the gate as a side effect.
    func testStatusOnAFleetNobodyHasHeld() async throws {
        try registerProject(named: "alpha", items: ["- [ ] a1 | Ready to go | ready"])

        let (status, body) = try await harness.get("/v1/fleet/quiesce")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["quiesced"] as? Bool, false)
        XCTAssertEqual(body["drained"] as? Bool, true)
        XCTAssertEqual(body["running"] as? Int, 0)
        XCTAssertEqual(body["summary"] as? String, "not quiesced, drained")
        XCTAssertFalse(server.fleet.isQuiesced, "a read must not hold the fleet")
    }

    /// One call, every project, and the per-project lines say what happened to
    /// each — held, already held, or nothing to hold.
    func testQuiesceHoldsTheFleetAndReportsEachProject() async throws {
        let alpha = try registerProject(named: "alpha", items: ["- [ ] a1 | Ready to go | ready"])
        alpha.stageRunForTesting(status: .running(itemIndex: 0, total: 2), queue: [item("a1"), item("a2")])
        alpha.stageExecutingRunForTesting(true)
        try registerProject(named: "beta", items: ["- [ ] b1 | Ready to go | ready"])

        let (status, body) = try await post("/v1/fleet/quiesce", [:], bearer: token)

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["quiesced"] as? Bool, true)
        // The pause lands at the next item boundary, so alpha's run is still
        // finishing — which is exactly what `drained` is for.
        XCTAssertEqual(body["drained"] as? Bool, false)
        XCTAssertEqual(body["summary"] as? String, "quiesced, 1 run(s) still finishing")
        XCTAssertEqual(alpha.status, .paused)

        let projects = try XCTUnwrap(body["projects"] as? [[String: Any]])
        XCTAssertEqual(projects.count, 2)
        let held = try XCTUnwrap(projects.first { $0["name"] as? String == "alpha" })
        XCTAssertEqual(held["action"] as? String, "held")
        XCTAssertEqual(held["heldByQuiesce"] as? Bool, true)
        XCTAssertEqual(held["heldItems"] as? Int, 2)
        let idle = try XCTUnwrap(projects.first { $0["name"] as? String == "beta" })
        XCTAssertEqual(idle["action"] as? String, "idle")
        XCTAssertEqual(idle["heldByQuiesce"] as? Bool, false)
    }

    /// The drained signal: a run still in flight is counted and named, so the
    /// operator knows a restart would strand it.
    func testQuiesceReportsRunsStillFinishing() async throws {
        let alpha = try registerProject(named: "alpha", items: ["- [ ] a1 | Ready to go | ready"])
        alpha.stageRunForTesting(status: .running(itemIndex: 0, total: 1), queue: [item("a1")])
        alpha.stageExecutingRunForTesting(true)

        let (status, body) = try await post("/v1/fleet/quiesce", [:], bearer: token)

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["quiesced"] as? Bool, true)
        XCTAssertEqual(body["drained"] as? Bool, false)
        XCTAssertEqual(body["running"] as? Int, 1)
        XCTAssertEqual(body["summary"] as? String, "quiesced, 1 run(s) still finishing")
        let projects = try XCTUnwrap(body["projects"] as? [[String: Any]])
        XCTAssertEqual(projects.first?["item"] as? String, "a1")
        XCTAssertEqual(projects.first?["running"] as? Bool, true)
    }

    /// A wait that runs out is a 200 carrying a truthful reading, not an error —
    /// and above all not a `drained: true` the caller would restart on.
    func testQuiesceWithAWaitThatTimesOutStillAnswersTruthfully() async throws {
        let alpha = try registerProject(named: "alpha", items: ["- [ ] a1 | Ready to go | ready"])
        alpha.stageRunForTesting(status: .running(itemIndex: 0, total: 1), queue: [item("a1")])
        alpha.stageExecutingRunForTesting(true)

        let (status, body) = try await post("/v1/fleet/quiesce", ["waitSeconds": 1], bearer: token)

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["drained"] as? Bool, false)
        XCTAssertEqual(body["running"] as? Int, 1)
    }

    /// The wait returns as soon as the last run ends, which is the point of the
    /// endpoint: the operator neither polls nor misses the window.
    func testQuiesceWaitReturnsOnceTheLastRunEnds() async throws {
        let alpha = try registerProject(named: "alpha", items: ["- [ ] a1 | Ready to go | ready"])
        alpha.stageRunForTesting(status: .running(itemIndex: 0, total: 1), queue: [item("a1")])
        alpha.stageExecutingRunForTesting(true)

        // The run ends a moment after the wait begins.
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            alpha.stageExecutingRunForTesting(false)
        }

        let (status, body) = try await post("/v1/fleet/quiesce", ["waitSeconds": 20], bearer: token)

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["drained"] as? Bool, true)
        XCTAssertEqual(body["running"] as? Int, 0)
    }

    func testQuiesceRejectsAnOutOfRangeWait() async throws {
        let (status, body) = try await post("/v1/fleet/quiesce", ["waitSeconds": 5_000], bearer: token)

        XCTAssertEqual(status, 400)
        XCTAssertEqual(body["error"] as? String, "\"waitSeconds\" must be a number in 0…600")
        XCTAssertFalse(server.fleet.isQuiesced, "a refused call must not hold the fleet")
    }

    // MARK: - The gate

    /// The load-bearing half. Pausing alone does not stop a driver — `POST
    /// /v1/runs` never reads `status`, and `start()` discards a paused queue and
    /// runs anyway — so without this the drivers would refill the fleet while it
    /// was being drained, which is exactly how the hand-run window kept closing.
    func testAQuiescedFleetRefusesANewRun() async throws {
        try registerProject(named: "alpha", items: ["- [ ] a1 | Ready to go | ready"])

        let (quiesced, _) = try await post("/v1/fleet/quiesce", [:], bearer: token)
        XCTAssertEqual(quiesced, 200)

        let (status, body) = try await post("/v1/runs", ["project": "alpha", "item": "a1"], bearer: token)

        XCTAssertEqual(status, 409, "a quiesced fleet must refuse, and 409 says retry later")
        XCTAssertEqual(
            body["error"] as? String,
            "The fleet is quiesced for a restart — no new runs are being accepted. "
            + "POST /v1/fleet/resume to lift the hold, or GET /v1/fleet/quiesce to see it."
        )
    }

    /// The gate lifts with the hold: after resuming, runs are accepted again.
    /// Checked by the refusal being gone rather than by a run starting — starting
    /// one needs a worker and reviewer, and that refusal is a different endpoint's.
    func testResumeReopensTheGate() async throws {
        try registerProject(named: "alpha", items: ["- [ ] a1 | Ready to go | ready"])
        _ = try await post("/v1/fleet/quiesce", [:], bearer: token)

        let (resumed, _) = try await post("/v1/fleet/resume", [:], bearer: token)
        XCTAssertEqual(resumed, 200)

        let (status, body) = try await post("/v1/runs", ["project": "alpha", "item": "a1"], bearer: token)

        XCTAssertEqual(status, 409)
        XCTAssertEqual(body["error"] as? String,
                       "Configure worker and reviewer agents in the Autopilot screen first",
                       "the fleet gate must be gone — this is the next guard, not the quiesce")
    }

    // MARK: - Resume

    /// Resume reports what it picked up and lifts the hold, and the reading it
    /// returns is the same shape the other two endpoints answer with.
    func testResumeReportsWhatItPickedUp() async throws {
        let alpha = try registerProject(named: "alpha", items: ["- [ ] a1 | Ready to go | ready"])
        alpha.stageRunForTesting(status: .running(itemIndex: 0, total: 2), queue: [item("a1"), item("a2")])
        alpha.stageExecutingRunForTesting(true)
        _ = try await post("/v1/fleet/quiesce", [:], bearer: token)
        // The held queue drains to nothing, so the resume has no items to execute —
        // this test is about what the reply says it picked up.
        alpha.stageExecutingRunForTesting(false)
        alpha.stageRunForTesting(status: .paused, queue: [])

        let (status, body) = try await post("/v1/fleet/resume", [:], bearer: token)

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["quiesced"] as? Bool, false)
        XCTAssertEqual(body["resumed"] as? [String], ["alpha"])
        XCTAssertEqual((body["skipped"] as? [[String: Any]])?.isEmpty, true)
        XCTAssertNotNil(body["projects"])
    }

    /// The post-restart call. Nothing is held, so nothing is resumed — and that is
    /// a 200 saying so, not an error a runbook would have to special-case.
    func testResumeWithNothingHeldIsAnEmptySuccess() async throws {
        try registerProject(named: "alpha", items: ["- [ ] a1 | Ready to go | ready"])

        let (status, body) = try await post("/v1/fleet/resume", [:], bearer: token)

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["resumed"] as? [String], [])
        XCTAssertEqual(body["quiesced"] as? Bool, false)
    }

    // MARK: - Auth

    /// All three change or reveal what the fleet is doing, so all three sit behind
    /// the token — and an unauthenticated call changes nothing.
    func testFleetEndpointsRequireTheBearerToken() async throws {
        try registerProject(named: "alpha", items: ["- [ ] a1 | Ready to go | ready"])

        let (readStatus, _) = try await harness.get("/v1/fleet/quiesce", bearer: nil)
        let (holdStatus, body) = try await post("/v1/fleet/quiesce", [:])
        let (resumeStatus, _) = try await post("/v1/fleet/resume", [:])

        XCTAssertEqual(readStatus, 401)
        XCTAssertEqual(holdStatus, 401)
        XCTAssertEqual(resumeStatus, 401)
        XCTAssertEqual(body["error"] as? String, "Missing or invalid bearer token")
        XCTAssertFalse(server.fleet.isQuiesced)
    }

    // MARK: - Helpers

    private func item(_ id: String) -> BacklogItem {
        BacklogItem(id: id, title: id.uppercased(), verify: "true", status: .ready, type: .local, size: .s)
    }

    /// Builds a real `ProjectSession` over a throwaway directory with a BACKLOG.md
    /// the run request can resolve its item against.
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

    /// Kept local for its timeout: a quiesce can wait up to `waitSeconds` before
    /// answering, and the harness's 10 s would cut a 20 s wait short.
    private func post(
        _ path: String,
        _ body: [String: Any],
        bearer: String? = nil
    ) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: harness.url(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        return try await harness.send(request)
    }
}
