import XCTest
import KiteloopCore
@testable import Kiteloop

/// `GET /v1/estimates` — the forecast side of `GET /v1/metrics`. Scoping an item
/// appends a new estimate rather than replacing the old one, so a driver reading
/// what a run was planned against needs the *latest* one per item, not the whole
/// append log. Exercised over a real loopback socket, like the other control-API
/// tests.
@MainActor
final class KiteloopControlServerEstimatesTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var metricStore: TaskMetricStore!
    private var harness: ControlServerHarness!
    /// Extra servers a test started (e.g. one with no store attached), stopped in teardown.
    private var extraServers: [ControlServerHarness] = []
    private let token = "control-estimates-token-" + UUID().uuidString

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-estimates")
        registry = ControlSessionRegistry()
        // Pointed at the temp directory so the tests never read or append to the
        // developer's real ~/.kiteloop/task-estimates.jsonl.
        metricStore = TaskMetricStore(
            metricsURL: tempDir.appendingPathComponent("task-metrics.jsonl"),
            estimatesURL: tempDir.appendingPathComponent("task-estimates.jsonl")
        )
        harness = try await startServer(metricStore: metricStore)
    }

    override func tearDown() async throws {
        harness?.stop()
        extraServers.forEach { $0.stop() }
        extraServers = []
        harness = nil
        registry = nil
        metricStore = nil
    }

    // MARK: - Listing

    /// Nothing has been scoped yet is a normal state, not a 404 — a driver can
    /// read before the first item is ever estimated.
    func testEmptyListWhenNothingHasBeenScoped() async throws {
        let (status, body) = try await harness.get("/v1/estimates")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["count"] as? Int, 0)
        XCTAssertEqual((body["estimates"] as? [[String: Any]])?.count, 0)
    }

    /// The whole estimate, because each field is one a caller scores an actual
    /// against: size, duration, cost, rework — plus the confidence that says how
    /// much the number should be trusted.
    func testReportsTheFullEstimate() async throws {
        let created = Date(timeIntervalSince1970: 1_770_000_000)
        metricStore.appendEstimate(makeEstimate(
            projectPath: "/tmp/alpha", itemID: "item-1", createdAt: created,
            size: "S", durationSeconds: 900, costUSD: 0.75, retries: 1,
            confidence: 0.62, rationale: "One endpoint plus a test."
        ))

        let (status, body) = try await harness.get("/v1/estimates")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["count"] as? Int, 1)
        let estimates = try XCTUnwrap(body["estimates"] as? [[String: Any]])
        XCTAssertEqual(estimates[0]["item"] as? String, "item-1")
        XCTAssertEqual(estimates[0]["project"] as? String, "alpha")
        XCTAssertEqual(estimates[0]["createdAt"] as? String, ISO8601DateFormatter().string(from: created))
        XCTAssertEqual(estimates[0]["size"] as? String, "S")
        XCTAssertEqual(estimates[0]["predictedDurationSec"] as? Int, 900)
        XCTAssertEqual(estimates[0]["predictedCostUSD"] as? Double, 0.75)
        XCTAssertEqual(estimates[0]["predictedRetries"] as? Int, 1)
        XCTAssertEqual(estimates[0]["confidence"] as? Double, 0.62)
        XCTAssertEqual(estimates[0]["source"] as? String, "hybrid")
        XCTAssertEqual(estimates[0]["rationale"] as? String, "One endpoint plus a test.")
    }

    /// The point of the endpoint: re-scoping an item appends, and only the newest
    /// estimate describes what the next run is planned against.
    func testReportsOnlyTheLatestEstimatePerItem() async throws {
        let base = Date(timeIntervalSince1970: 1_770_000_000)
        metricStore.appendEstimate(makeEstimate(itemID: "item-1", createdAt: base, size: "S", durationSeconds: 600))
        metricStore.appendEstimate(makeEstimate(
            itemID: "item-1", createdAt: base.addingTimeInterval(3_600), size: "M", durationSeconds: 1_800
        ))

        let (_, body) = try await harness.get("/v1/estimates")

        XCTAssertEqual(body["count"] as? Int, 1)
        let estimates = try XCTUnwrap(body["estimates"] as? [[String: Any]])
        XCTAssertEqual(estimates[0]["size"] as? String, "M")
        XCTAssertEqual(estimates[0]["predictedDurationSec"] as? Int, 1_800)
    }

    /// Item ids are only unique within a project, so two projects that both have
    /// an `item-1` must each keep their own estimate.
    func testItemsAreKeyedPerProject() async throws {
        let base = Date(timeIntervalSince1970: 1_770_000_000)
        metricStore.appendEstimate(makeEstimate(projectPath: "/tmp/alpha", itemID: "item-1", createdAt: base))
        metricStore.appendEstimate(makeEstimate(
            projectPath: "/tmp/beta", itemID: "item-1", createdAt: base.addingTimeInterval(60)
        ))

        let (_, body) = try await harness.get("/v1/estimates")

        XCTAssertEqual(body["count"] as? Int, 2)
        let estimates = try XCTUnwrap(body["estimates"] as? [[String: Any]])
        XCTAssertEqual(estimates.map { $0["project"] as? String }, ["beta", "alpha"])
    }

    /// Newest first, so the item most recently scoped — the one a driver is about
    /// to run — is at index 0, matching how `/v1/metrics` orders.
    func testOrdersNewestFirst() async throws {
        let base = Date(timeIntervalSince1970: 1_770_000_000)
        metricStore.appendEstimate(makeEstimate(itemID: "older", createdAt: base))
        metricStore.appendEstimate(makeEstimate(itemID: "newer", createdAt: base.addingTimeInterval(3_600)))

        let (_, body) = try await harness.get("/v1/estimates")

        let estimates = try XCTUnwrap(body["estimates"] as? [[String: Any]])
        XCTAssertEqual(estimates.map { $0["item"] as? String }, ["newer", "older"])
    }

    /// An estimate the engine couldn't ground in history reports `null` rather
    /// than a zero that would read as a free run.
    func testUngroundedEstimateReportsNullCostAndRetries() async throws {
        metricStore.appendEstimate(makeEstimate(itemID: "item-1", costUSD: nil, retries: nil))

        let (_, body) = try await harness.get("/v1/estimates")

        let estimates = try XCTUnwrap(body["estimates"] as? [[String: Any]])
        XCTAssertTrue(estimates[0]["predictedCostUSD"] is NSNull)
        XCTAssertTrue(estimates[0]["predictedRetries"] is NSNull)
    }

    // MARK: - Filtering

    func testProjectFilterNarrowsToThatProjectsEstimates() async throws {
        let alpha = try registerProject(named: "alpha")
        try registerProject(named: "beta")
        metricStore.appendEstimate(makeEstimate(projectPath: alpha, itemID: "item-1"))
        metricStore.appendEstimate(makeEstimate(projectPath: "/elsewhere/beta", itemID: "item-2"))

        let (status, body) = try await harness.get("/v1/estimates?project=alpha")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["project"] as? String, "alpha")
        let estimates = try XCTUnwrap(body["estimates"] as? [[String: Any]])
        XCTAssertEqual(estimates.map { $0["item"] as? String }, ["item-1"])
    }

    /// Estimates keep the raw root path while the registry keys on the canonical
    /// one, so a trailing slash must not hide a project's own estimates.
    func testProjectFilterMatchesDespiteATrailingSlash() async throws {
        let alpha = try registerProject(named: "alpha")
        metricStore.appendEstimate(makeEstimate(projectPath: alpha + "/", itemID: "item-1"))

        let (_, body) = try await harness.get("/v1/estimates?project=alpha")

        let estimates = try XCTUnwrap(body["estimates"] as? [[String: Any]])
        XCTAssertEqual(estimates.map { $0["item"] as? String }, ["item-1"])
        XCTAssertEqual(estimates[0]["project"] as? String, "alpha")
    }

    /// Same contract as the other project-scoped reads: a project that isn't open
    /// is a 409, not an empty list a caller could mistake for "nothing scoped yet".
    func testProjectFilterRequiresAnOpenProject() async throws {
        let (status, body) = try await harness.get("/v1/estimates?project=ghost")

        XCTAssertEqual(status, 409)
        XCTAssertEqual(body["error"] as? String, "Project not open in Kiteloop: ghost")
    }

    // MARK: - Limit

    func testLimitCapsHowManyEstimatesComeBack() async throws {
        let base = Date(timeIntervalSince1970: 1_770_000_000)
        for i in 0..<5 {
            metricStore.appendEstimate(makeEstimate(itemID: "item-\(i)", createdAt: base.addingTimeInterval(Double(i) * 60)))
        }

        let (status, body) = try await harness.get("/v1/estimates?limit=2")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["count"] as? Int, 2)
        let estimates = try XCTUnwrap(body["estimates"] as? [[String: Any]])
        XCTAssertEqual(estimates.map { $0["item"] as? String }, ["item-4", "item-3"])
    }

    /// Without a limit the default keeps a long history from arriving all at once.
    func testDefaultLimitIsTwenty() async throws {
        let base = Date(timeIntervalSince1970: 1_770_000_000)
        for i in 0..<25 {
            metricStore.appendEstimate(makeEstimate(itemID: "item-\(i)", createdAt: base.addingTimeInterval(Double(i) * 60)))
        }

        let (_, body) = try await harness.get("/v1/estimates")

        XCTAssertEqual(body["count"] as? Int, 20)
    }

    /// A limit that isn't a number in range is a caller bug, so it's rejected
    /// rather than silently rounded into the default.
    func testRejectsAnUnusableLimit() async throws {
        for raw in ["0", "999", "abc", "-3"] {
            let (status, body) = try await harness.get("/v1/estimates?limit=\(raw)")
            XCTAssertEqual(status, 400, "limit=\(raw)")
            XCTAssertEqual(body["error"] as? String, "\"limit\" must be an integer in 1...200", "limit=\(raw)")
        }
    }

    // MARK: - Errors

    /// With no store attached there is nothing to report — say so instead of
    /// answering an empty list that reads as "nothing has ever been scoped".
    func testUnavailableWhenNoStoreIsAttached() async throws {
        let detached = try await startServer(metricStore: nil)
        extraServers.append(detached)

        let (status, body) = try await detached.get("/v1/estimates")

        XCTAssertEqual(status, 503)
        XCTAssertEqual(body["error"] as? String, "Estimates are unavailable — no metric store attached")
    }

    func testRequiresBearerToken() async throws {
        let (status, body) = try await harness.get("/v1/estimates", bearer: nil)

        XCTAssertEqual(status, 401)
        XCTAssertEqual(body["error"] as? String, "Missing or invalid bearer token")
    }

    // MARK: - Helpers

    private func makeEstimate(
        projectPath: String = "/tmp/alpha",
        itemID: String = "item-1",
        createdAt: Date = Date(timeIntervalSince1970: 1_770_000_000),
        size: String = "M",
        durationSeconds: Double = 900,
        costUSD: Double? = 0.5,
        retries: Int? = 0,
        confidence: Double = 0.5,
        rationale: String = "Because."
    ) -> TaskEstimate {
        TaskEstimate(
            itemID: itemID,
            projectPath: projectPath,
            createdAt: createdAt,
            estimatedSize: size,
            predictedDurationSeconds: durationSeconds,
            predictedCostUSD: costUSD,
            predictedRetries: retries,
            confidence: confidence,
            source: "hybrid",
            rationale: rationale
        )
    }

    /// Builds a real `ProjectSession` over a throwaway directory and registers it.
    /// Returns the project's root path — what an estimate stores.
    @discardableResult
    private func registerProject(named name: String) throws -> String {
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
        registry.register(session: session, autopilot: BacklogAutopilot())
        return rootURL.path(percentEncoded: false)
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

    /// The port is picked at random and probed, since NWListener reports a bind
    /// conflict asynchronously rather than throwing from start().
    private func startServer(metricStore: TaskMetricStore?) async throws -> ControlServerHarness {
        try await ControlServerHarness.start(token: token) {
            KiteloopControlServer(registry: registry, token: $0, metricStore: metricStore)
        }
    }
}
