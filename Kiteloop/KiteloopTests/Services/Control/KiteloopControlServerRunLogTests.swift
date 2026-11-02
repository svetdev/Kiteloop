import XCTest
import KiteloopCore
@testable import Kiteloop

/// `GET /v1/runs/{runId}/log` — the Autopilot tab's log list for a caller that has
/// no tab, exercised over a real loopback socket. The autopilot's log is one
/// rolling buffer per project, so most of what is under test here is the slicing
/// that turns it back into a single run's narration.
@MainActor
final class KiteloopControlServerRunLogTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var harness: ControlServerHarness!
    private var server: KiteloopControlServer { harness.server }
    private let token = "control-run-log-token-" + UUID().uuidString

    /// A fixed clock so log lines can be placed either side of a run's window
    /// without sleeping. In the past on purpose: a fixture clock set in the
    /// future passes or fails depending on the day it runs, and one of these
    /// tests used to be waiting on 2027 to go green by itself.
    private let epoch = Date(timeIntervalSince1970: 1_600_000_000)   // 2020-09-13

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-run-log")
        registry = ControlSessionRegistry()
        harness = try await ControlServerHarness.start(registry: registry, token: token)
    }

    override func tearDown() async throws {
        harness?.stop()
        harness = nil
        registry = nil
    }

    // MARK: - Slicing the project log into one run

    /// The run's own lines and nothing else: what the autopilot logged before this
    /// run started belongs to the previous one, and reporting it would pin another
    /// run's failure on this one.
    func testLogReturnsOnlyTheRunsLines() async throws {
        let autopilot = try registerProject(named: "alpha") { $0.pause() }
        autopilot.stageLogEntryForTesting("Run complete: 1 items processed", at: epoch - 60)
        autopilot.stageLogEntryForTesting("Executing: Item one", at: epoch + 1)
        autopilot.stageLogEntryForTesting("→ Reviewer (attempt 1)", at: epoch + 2)
        trackRun(id: "exec-alpha", project: "alpha", item: "item-1", startedAt: epoch)

        let (status, body) = try await harness.get("/v1/runs/exec-alpha/log")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["runId"] as? String, "exec-alpha")
        XCTAssertEqual(body["item"] as? String, "item-1")
        XCTAssertEqual(body["project"] as? String, "alpha")
        XCTAssertEqual(body["count"] as? Int, 2)
        XCTAssertEqual(body["truncated"] as? Bool, false)
        XCTAssertEqual(messages(body), ["Executing: Item one", "→ Reviewer (attempt 1)"])
    }

    /// Lines are chronological and carry their timestamp — a log read top-down,
    /// the same order the tab shows.
    func testLogLinesAreChronologicalWithTimestamps() async throws {
        let autopilot = try registerProject(named: "alpha") { $0.pause() }
        autopilot.stageLogEntryForTesting("first", at: epoch + 1)
        autopilot.stageLogEntryForTesting("second", at: epoch + 2)
        trackRun(id: "exec-alpha", project: "alpha", item: "item-1", startedAt: epoch)

        let (status, body) = try await harness.get("/v1/runs/exec-alpha/log")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(messages(body), ["first", "second"])
        let stamps = (body["lines"] as? [[String: Any]] ?? []).compactMap { $0["ts"] as? String }
        XCTAssertEqual(stamps.count, 2)
        XCTAssertTrue(stamps[0] < stamps[1], "expected ascending timestamps, got \(stamps)")
    }

    /// A later run in the same project closes this one's window: once the next item
    /// is executing, its lines are its own.
    func testLogStopsAtTheNextRunInTheSameProject() async throws {
        let autopilot = try registerProject(named: "alpha") { $0.pause() }
        autopilot.stageLogEntryForTesting("Executing: Item one", at: epoch + 1)
        autopilot.stageLogEntryForTesting("Executing: Item two", at: epoch + 11)
        trackRun(id: "exec-first", project: "alpha", item: "item-1", startedAt: epoch)
        trackRun(id: "exec-second", project: "alpha", item: "item-2", startedAt: epoch + 10)

        let (_, first) = try await harness.get("/v1/runs/exec-first/log")
        let (_, second) = try await harness.get("/v1/runs/exec-second/log")

        XCTAssertEqual(messages(first), ["Executing: Item one"])
        // The newest run's window stays open, so its lines keep arriving.
        XCTAssertEqual(messages(second), ["Executing: Item two"])
    }

    /// Another project's autopilot has its own buffer; a run must never report it.
    func testLogIsScopedToTheRunsProject() async throws {
        let alpha = try registerProject(named: "alpha") { $0.pause() }
        let beta = try registerProject(named: "beta") { $0.pause() }
        alpha.stageLogEntryForTesting("alpha line", at: epoch + 1)
        beta.stageLogEntryForTesting("beta line", at: epoch + 1)
        trackRun(id: "exec-alpha", project: "alpha", item: "item-1", startedAt: epoch)

        let (status, body) = try await harness.get("/v1/runs/exec-alpha/log")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(messages(body), ["alpha line"])
    }

    /// A run that has not logged anything yet is an empty log, not a 404 — the run
    /// exists, it just started a moment ago.
    func testLogOfARunWithNoLinesIsEmpty() async throws {
        try registerProject(named: "alpha") { $0.pause() }
        trackRun(id: "exec-alpha", project: "alpha", item: "item-1", startedAt: epoch)

        let (status, body) = try await harness.get("/v1/runs/exec-alpha/log")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["count"] as? Int, 0)
        XCTAssertEqual(body["truncated"] as? Bool, false)
        XCTAssertEqual(messages(body), [])
    }

    // MARK: - Truncation

    /// `limit` keeps the newest lines — the end of a run says how it went — and the
    /// caller is told the slice was cut.
    func testLimitKeepsTheNewestLinesAndFlagsTruncation() async throws {
        let autopilot = try registerProject(named: "alpha") { $0.pause() }
        for i in 1...5 {
            autopilot.stageLogEntryForTesting("line \(i)", at: epoch + Double(i))
        }
        trackRun(id: "exec-alpha", project: "alpha", item: "item-1", startedAt: epoch)

        let (status, body) = try await harness.get("/v1/runs/exec-alpha/log?limit=2")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["count"] as? Int, 2)
        XCTAssertEqual(body["truncated"] as? Bool, true)
        XCTAssertEqual(messages(body), ["line 4", "line 5"])
    }

    /// A long run overruns the rolling buffer, and the lines it dropped are gone.
    /// Saying so is the point: a caller diagnosing a failure must not read the
    /// surviving tail as the whole story.
    func testFullBufferPastTheRunStartReportsTruncated() async throws {
        let autopilot = try registerProject(named: "alpha") { $0.pause() }
        // Every surviving line postdates the run's start, so the evicted ones were
        // this run's — exactly the state a run longer than the buffer leaves behind.
        for i in 0..<BacklogAutopilot.logCapacity {
            autopilot.stageLogEntryForTesting("line \(i)", at: epoch + Double(i + 1))
        }
        trackRun(id: "exec-alpha", project: "alpha", item: "item-1", startedAt: epoch)

        let (status, body) = try await harness.get("/v1/runs/exec-alpha/log")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["count"] as? Int, BacklogAutopilot.logCapacity)
        XCTAssertEqual(body["truncated"] as? Bool, true)
    }

    // MARK: - Errors

    /// A limit outside the buffer's size can't be honoured, so it's rejected rather
    /// than quietly clamped — a caller asking for 500 lines should learn that 50 is
    /// all there ever is.
    func testOutOfRangeLimitIs400() async throws {
        try registerProject(named: "alpha") { $0.pause() }
        trackRun(id: "exec-alpha", project: "alpha", item: "item-1", startedAt: epoch)

        let (status, body) = try await harness.get("/v1/runs/exec-alpha/log?limit=500")

        XCTAssertEqual(status, 400)
        XCTAssertEqual(body["error"] as? String, "\"limit\" must be an integer in 1...50")
    }

    func testNonNumericLimitIs400() async throws {
        try registerProject(named: "alpha") { $0.pause() }
        trackRun(id: "exec-alpha", project: "alpha", item: "item-1", startedAt: epoch)

        let (status, _) = try await harness.get("/v1/runs/exec-alpha/log?limit=all")

        XCTAssertEqual(status, 400)
    }

    /// Run bookkeeping is in memory, so an id from before a restart — or a typo —
    /// is unknown rather than an empty log, which would read as "nothing happened".
    func testLogOfUnknownRunIs404() async throws {
        try registerProject(named: "alpha") { $0.pause() }

        let (status, body) = try await harness.get("/v1/runs/nope/log")

        XCTAssertEqual(status, 404)
        XCTAssertEqual(body["error"] as? String, "Unknown run: nope")
    }

    /// The log can name branches, files and blocking reasons, so it sits behind the
    /// token like every other route.
    func testLogRequiresBearerToken() async throws {
        let autopilot = try registerProject(named: "alpha") { $0.pause() }
        autopilot.stageLogEntryForTesting("Executing: Item one", at: epoch + 1)
        trackRun(id: "exec-alpha", project: "alpha", item: "item-1", startedAt: epoch)

        let (status, body) = try await harness.get("/v1/runs/exec-alpha/log", bearer: nil)

        XCTAssertEqual(status, 401)
        XCTAssertEqual(body["error"] as? String, "Missing or invalid bearer token")
    }

    // MARK: - Helpers

    private func messages(_ body: [String: Any]) -> [String] {
        (body["lines"] as? [[String: Any]] ?? []).compactMap { $0["message"] as? String }
    }

    /// Records a run with the server the way `POST /v1/runs` would, so the per-run
    /// endpoints can find it without starting real agents.
    private func trackRun(id: String, project: String, item: String, startedAt: Date) {
        let projectID = registry.entry(forProject: project)!.session.project.id
        server.track(KiteloopControlServer.RunInfo(
            runId: id,
            projectID: projectID,
            itemId: item,
            title: "Item one",
            startedAt: startedAt
        ))
    }

    /// Builds a real `ProjectSession` over a throwaway directory and registers it
    /// with a fresh autopilot, which `configure` can drive into the state under
    /// test (`pause()` gives a queue that is not idle).
    ///
    /// The log is emptied afterwards, so `epoch` is the only clock the buffer
    /// sees: driving the autopilot into position narrates ("Paused by user"),
    /// and those lines carry a real timestamp that lands in the middle of every
    /// window these tests slice.
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
        autopilot.clearLogForTesting()
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
