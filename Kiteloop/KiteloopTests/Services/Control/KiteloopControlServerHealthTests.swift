import XCTest
import KiteloopCore
@testable import Kiteloop

/// `GET /health` — the unauthenticated liveness probe. Beyond "the app is up" it
/// carries what a headless driver checks before trusting its own state: the app
/// version, how long the app has been running (a restart drops every in-memory
/// run record), how many runs are in flight — and, from `HealthMonitor`, whether
/// the app is actually keeping up (`status`, main-thread latency, hitch count,
/// resident memory, subprocess count). Exercised over a real loopback socket,
/// like the other control-API tests.
@MainActor
final class KiteloopControlServerHealthTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var harness: ControlServerHarness!
    private var server: KiteloopControlServer { harness.server }

    /// The server is built with a start time an hour in the past so `uptimeSeconds`
    /// is a value the tests can assert on instead of a race against the clock.
    ///
    /// Set in `setUp`, not as a property initializer: a stored property is
    /// evaluated when XCTest constructs the test-case object, and every test
    /// that runs in between then widens the delta. As an initializer this read
    /// 3675 against a `< 3660` bound in a full-suite run while passing in
    /// isolation — the drift was other tests, not the server.
    private var launchedAt = Date()

    override func setUp() async throws {
        launchedAt = Date().addingTimeInterval(-3600)
        tempDir = try makeTemporaryDirectory(prefix: "control-health")
        registry = ControlSessionRegistry()
        harness = try await ControlServerHarness.start(token: "control-health-token-" + UUID().uuidString) {
            KiteloopControlServer(registry: registry, token: $0, startedAt: launchedAt)
        }
    }

    override func tearDown() async throws {
        harness?.stop()
        harness = nil
        registry = nil
    }

    // MARK: - Shape

    /// An idle app still answers every field, so a probe can read the payload
    /// unconditionally rather than branching on which keys are present.
    func testReportsVersionUptimeAndCountsWhenIdle() async throws {
        let (status, body) = try await harness.get("/health", bearer: nil)

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["status"] as? String, "ok")
        // Unbundled test runs have no CFBundleShortVersionString; either way the
        // field must be a non-empty string.
        XCTAssertFalse((body["version"] as? String ?? "").isEmpty)
        XCTAssertEqual(body["apiVersion"] as? Int, ControlRouter.apiVersion, "what a phone checks it can talk to this Mac by")
        XCTAssertEqual(body["projectsOpen"] as? Int, 0)
        XCTAssertEqual(body["activeRuns"] as? Int, 0)
    }

    // MARK: - Uptime

    /// Uptime counts from when the server was built — app launch in production —
    /// so a driver can tell a long-lived app from one that just restarted under it.
    func testUptimeCountsFromLaunch() async throws {
        let (_, body) = try await harness.get("/health", bearer: nil)

        let uptime = try XCTUnwrap(body["uptimeSeconds"] as? Int)
        XCTAssertGreaterThanOrEqual(uptime, 3600)
        XCTAssertLessThan(uptime, 3660, "uptime should be the launch delta, not the wall clock")
    }

    /// A freshly built server reports a small non-negative number rather than
    /// something absurd — the case a restart detector actually keys on.
    func testUptimeOfAFreshServerIsNearZero() async throws {
        let fresh = try await ControlServerHarness.start(registry: registry, token: "fresh-" + UUID().uuidString)
        defer { fresh.stop() }

        let (_, body) = try await fresh.get("/health", bearer: nil)

        let uptime = try XCTUnwrap(body["uptimeSeconds"] as? Int)
        XCTAssertGreaterThanOrEqual(uptime, 0)
        XCTAssertLessThan(uptime, 60)
    }

    // MARK: - Measured health

    /// The fields `HealthMonitor.snapshot()` carries, alongside the ones
    /// already asserted above — reported unconditionally, like the rest of the
    /// payload.
    func testReportsMeasuredHealthFields() async throws {
        let fresh = try await ControlServerHarness.start(token: "measured-" + UUID().uuidString) {
            KiteloopControlServer(registry: self.registry, token: $0, healthSnapshotProvider: {
                HealthMonitor.Snapshot(
                    processMemoryMB: 312.5,
                    activeSubprocessCount: 3,
                    mainThreadLatencyMs: 4.2,
                    hitches: [],
                    agentWorking: 0, agentIdle: 0, agentCrashed: 0)
            })
        }
        defer { fresh.stop() }

        let (_, body) = try await fresh.get("/health", bearer: nil)

        XCTAssertEqual(body["mainThreadLatencyMs"] as? Double, 4.2)
        XCTAssertEqual(body["hitchCount"] as? Int, 0)
        XCTAssertEqual(body["processMemoryMB"] as? Double, 312.5)
        XCTAssertEqual(body["activeSubprocessCount"] as? Int, 3)
    }

    /// `null`, not `0` — a reading nobody could take must not look like a
    /// process using no memory at all.
    func testProcessMemoryIsNullWhenUnreadable() async throws {
        let fresh = try await ControlServerHarness.start(token: "unreadable-" + UUID().uuidString) {
            KiteloopControlServer(registry: self.registry, token: $0, healthSnapshotProvider: {
                HealthMonitor.Snapshot(
                    processMemoryMB: nil,
                    activeSubprocessCount: 0,
                    mainThreadLatencyMs: 0,
                    hitches: [],
                    agentWorking: 0, agentIdle: 0, agentCrashed: 0)
            })
        }
        defer { fresh.stop() }

        let (_, body) = try await fresh.get("/health", bearer: nil)

        XCTAssertTrue(body["processMemoryMB"] is NSNull, "unreadable memory must be null, not absent or zero")
    }

    // MARK: - Status

    /// Below `HealthMonitor.hitchThresholdMs`, the app is keeping up.
    func testStatusIsOkBelowTheHitchThreshold() async throws {
        let fresh = try await ControlServerHarness.start(token: "ok-" + UUID().uuidString) {
            KiteloopControlServer(registry: self.registry, token: $0, healthSnapshotProvider: {
                HealthMonitor.Snapshot(
                    processMemoryMB: 200, activeSubprocessCount: 0,
                    mainThreadLatencyMs: HealthMonitor.hitchThresholdMs - 1,
                    hitches: [], agentWorking: 0, agentIdle: 0, agentCrashed: 0)
            })
        }
        defer { fresh.stop() }

        let (_, body) = try await fresh.get("/health", bearer: nil)

        XCTAssertEqual(body["status"] as? String, "ok")
    }

    /// At or above `HealthMonitor.hitchThresholdMs`, the main thread is not
    /// keeping up — a headless driver reads this instead of waiting out a long
    /// no-progress window to suspect a wedge.
    func testStatusIsDegradedAtOrAboveTheHitchThreshold() async throws {
        let fresh = try await ControlServerHarness.start(token: "degraded-" + UUID().uuidString) {
            KiteloopControlServer(registry: self.registry, token: $0, healthSnapshotProvider: {
                HealthMonitor.Snapshot(
                    processMemoryMB: 200, activeSubprocessCount: 0,
                    mainThreadLatencyMs: HealthMonitor.hitchThresholdMs,
                    hitches: [.init(id: 1, timestamp: Date(), durationMs: HealthMonitor.hitchThresholdMs)],
                    agentWorking: 0, agentIdle: 0, agentCrashed: 0)
            })
        }
        defer { fresh.stop() }

        let (_, body) = try await fresh.get("/health", bearer: nil)

        XCTAssertEqual(body["status"] as? String, "degraded")
        XCTAssertEqual(body["hitchCount"] as? Int, 1)
    }

    // MARK: - Counts

    func testProjectsOpenCountsRegisteredProjects() async throws {
        try registerProject(named: "alpha", backlog: "- [ ] item-1 | First | ready")
        try registerProject(named: "beta", backlog: "- [ ] item-2 | Second | ready")

        let (_, body) = try await harness.get("/health", bearer: nil)

        XCTAssertEqual(body["projectsOpen"] as? Int, 2)
    }

    /// Runs in flight — working or paused at the human gate — are what "active"
    /// means; both count, since either way the app is not idle.
    func testActiveRunsCountsWorkingAndGatedRuns() async throws {
        let alpha = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Working | active")
        let beta = try registerProject(named: "beta", backlog: "- [ ] item-2 | Needs sign-off | awaiting-approval")
        server.track(.init(runId: "run-1", projectID: alpha, itemId: "item-1", title: "Working", startedAt: Date()))
        server.track(.init(runId: "run-2", projectID: beta, itemId: "item-2", title: "Needs sign-off", startedAt: Date()))

        let (_, body) = try await harness.get("/health", bearer: nil)

        XCTAssertEqual(body["activeRuns"] as? Int, 2)
    }

    /// A run whose project has been closed is no longer being driven by anything,
    /// so it drops out of the count even though `GET /v1/runs` still lists it.
    func testActiveRunsExcludesRunsOfClosedProjects() async throws {
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | active")
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1", title: "Ship the thing", startedAt: Date()))
        await registry.unregister(projectID: projectID)

        let (_, body) = try await harness.get("/health", bearer: nil)

        XCTAssertEqual(body["activeRuns"] as? Int, 0)
        XCTAssertEqual(body["projectsOpen"] as? Int, 0)
    }

    // MARK: - Tools

    /// Per open project, every executable its verify commands run and where
    /// the app's search path resolved it — or null with the directories
    /// searched. A `cargo` verify was refused at grooming and a `lizard` was
    /// invisible at the merge gate on 2026-09-03, both installed; this is the
    /// call that would have said so first.
    func testToolsListEveryVerifyExecutableWithWhereItResolvedOrWhatWasSearched() async throws {
        let projectID = try registerProject(
            named: "alpha",
            backlog: "- [ ] item-1 | Build it | ready | verify: alphatool build && ls -la\n"
                + "- [ ] item-2 | Lint it | ready | verify: kiteloop-no-such-tool --check")
        let root = try XCTUnwrap(registry.entries[projectID]).session.project.rootURL
        let toolsDir = root.appending(path: "project-tools")
        try FileManager.default.createDirectory(at: toolsDir, withIntermediateDirectories: true)
        let tool = toolsDir.appending(path: "alphatool")
        try "#!/bin/sh\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path(percentEncoded: false))
        var config = ProjectConfig.default
        config.extraExecutablePaths = [toolsDir.path(percentEncoded: false)]
        try KiteloopProject(rootURL: root).saveConfig(config)

        let (_, body) = try await harness.get("/health", bearer: nil)

        let projects = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0]["project"] as? String, "alpha")
        XCTAssertEqual(projects[0]["path"] as? String, root.path(percentEncoded: false))
        let rows = try XCTUnwrap(projects[0]["tools"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["name"] as? String }, ["alphatool", "kiteloop-no-such-tool", "ls"], "sorted by name")
        XCTAssertEqual(rows[0]["path"] as? String, tool.path(percentEncoded: false),
                       "resolved only through the project's extraExecutablePaths")
        XCTAssertNil(rows[0]["searched"], "a resolved tool carries no search list")
        XCTAssertTrue(rows[1]["path"] is NSNull, "null, not absent — a client reads the key unconditionally")
        let searched = try XCTUnwrap(rows[1]["searched"] as? [String])
        XCTAssertTrue(searched.contains("/usr/bin"), searched.description)
        XCTAssertEqual(searched.last, toolsDir.path(percentEncoded: false), "the project's extras are searched last")
        XCTAssertEqual(rows[2]["path"] as? String, "/bin/ls")
    }

    /// Beside the tools, what every verify and spawn on the project's behalf
    /// runs with beyond `PATH`: the derived `CARGO_TARGET_DIR` a `Cargo.toml`
    /// earns, the project's own `buildEnvironment` entries with `$PROJECT_ROOT`
    /// expanded, and never a `PATH` from that map. A Rust project's items each
    /// paid a cold `cargo build` on 2026-09-03; this is where an operator reads
    /// that they now share one.
    func testExportsListTheSharedBuildOutputBesideTheTools() async throws {
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Build it | ready | verify: ls")
        let root = try XCTUnwrap(registry.entries[projectID]).session.project.rootURL
        try "[package]\n".write(to: root.appending(path: "Cargo.toml"), atomically: true, encoding: .utf8)
        var config = ProjectConfig.default
        config.buildEnvironment = ["SCCACHE_DIR": "$PROJECT_ROOT/.cache", "PATH": "/nope"]
        try KiteloopProject(rootURL: root).saveConfig(config)

        let (_, body) = try await harness.get("/health", bearer: nil)

        let projects = try XCTUnwrap(body["tools"] as? [[String: Any]])
        let exports = try XCTUnwrap(projects.first?["exports"] as? [[String: String]])
        XCTAssertEqual(exports, [
            ["name": "CARGO_TARGET_DIR", "value": root.appending(path: ".kiteloop/build/cargo").path(percentEncoded: false)],
            ["name": "SCCACHE_DIR", "value": root.appending(path: ".cache").path(percentEncoded: false)],
        ])
    }

    /// A project with no marker and no map still carries the key, empty.
    func testExportsIsEmptyForAProjectThatSharesNothing() async throws {
        try registerProject(named: "alpha", backlog: "- [ ] item-1 | Build it | ready | verify: ls")

        let (_, body) = try await harness.get("/health", bearer: nil)

        let projects = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual((projects.first?["exports"] as? [[String: String]])?.count, 0)
    }

    /// No projects, no rows — but the key is there, like every other field.
    func testToolsIsEmptyWhenNoProjectIsOpen() async throws {
        let (_, body) = try await harness.get("/health", bearer: nil)

        XCTAssertEqual((body["tools"] as? [[String: Any]])?.count, 0)
    }

    // MARK: - Helpers

    /// Builds a real `ProjectSession` over a throwaway directory, seeds its backlog
    /// from markdown, and registers it. Returns the canonical project id — the key
    /// `RunInfo` uses.
    @discardableResult
    private func registerProject(named name: String, backlog: String) throws -> String {
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
        session.backlogViewModel.backlogFile = BacklogParser.parse("## Epic: Work\n\n\(backlog)\n")

        registry.register(session: session, autopilot: BacklogAutopilot())
        return session.project.id
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
