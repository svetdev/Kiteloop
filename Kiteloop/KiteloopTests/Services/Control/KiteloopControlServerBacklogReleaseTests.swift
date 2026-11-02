import XCTest
import KiteloopCore
@testable import Kiteloop

/// `POST /v1/backlog/release` — the way out of the retry ceiling.
///
/// The ceiling stops autopilot from starting an item that has produced nothing
/// three times running, and for a while that was a one-way door: a retired item
/// cannot run, and only a run could clear the count, so the note telling a human
/// to re-groom it described something that could not happen. This endpoint is the
/// half that was missing, so what is asserted here is that it *actually releases*
/// — the ceiling's own verdict flips — and that it says so on the record.
///
/// Exercised over a real loopback socket with a real `BacklogViewModel` on disk,
/// like the other control-API tests.
@MainActor
final class KiteloopControlServerBacklogReleaseTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var ledger: GroomingLedger!
    private var metrics: TaskMetricStore!
    private var harness: ControlServerHarness!
    private var extraHarnesses: [ControlServerHarness] = []
    private let token = "control-release-token-" + UUID().uuidString

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-release")
        registry = ControlSessionRegistry()
        // Both stores live in the temp directory, so no test ever appends to the
        // developer's real ~/.kiteloop ledgers.
        ledger = GroomingLedger(url: tempDir.appendingPathComponent("grooming.jsonl"))
        metrics = TaskMetricStore(
            metricsURL: tempDir.appendingPathComponent("task-metrics.jsonl"),
            estimatesURL: tempDir.appendingPathComponent("task-estimates.jsonl"),
            approvalsURL: tempDir.appendingPathComponent("task-approvals.jsonl")
        )
        harness = try await startServer(groomingLedger: ledger, metricStore: metrics)
    }

    override func tearDown() async throws {
        harness?.stop()
        extraHarnesses.forEach { $0.stop() }
        extraHarnesses = []
        harness = nil
        registry = nil
        ledger = nil
        metrics = nil
    }

    // MARK: - Releasing

    /// The whole point: an item the ceiling refuses becomes runnable again, and
    /// the response reports both the count it cleared and the one the next pickup
    /// will read.
    func testReleasingARetiredItemMakesItRunnableAgain() async throws {
        let root = try registerProject(named: "alpha")
        retire("item-1", project: root)
        XCTAssertTrue(verdict("item-1", project: root).isRetired, "Precondition: retired")

        let (status, body) = try await harness.post("/v1/backlog/release", [
            "project": "alpha", "item": "item-1"
        ])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["item"] as? String, "item-1")
        XCTAssertEqual(body["wasRetired"] as? Bool, true)
        XCTAssertEqual(body["noWorkAttemptsBefore"] as? Int, 3)
        XCTAssertEqual(body["noWorkAttempts"] as? Int, 0)
        XCTAssertEqual(body["ceiling"] as? Int, RetryCeiling.limit)
        XCTAssertFalse(verdict("item-1", project: root).isRetired,
                       "The ceiling itself has to agree, not just the response")
    }

    /// "Why did this run again" has to have an answer months later, so the
    /// release is a record in the grooming ledger — with who released it.
    func testTheReleaseIsRecordedInTheGroomingLedger() async throws {
        let root = try registerProject(named: "alpha")
        retire("item-1", project: root)

        _ = try await harness.post("/v1/backlog/release", [
            "project": "alpha", "item": "item-1", "reason": "rewrote it by hand"
        ])

        let record = try XCTUnwrap(ledger.records.last)
        XCTAssertEqual(record.event, .released)
        XCTAssertEqual(record.itemID, "item-1")
        XCTAssertEqual(record.check, GroomingRecord.Check.retryCeiling)
        XCTAssertEqual(record.reason, "released by hand (control API): rewrote it by hand")
        XCTAssertEqual(ledger.latestRelease(itemID: "item-1", projectPath: root), record.at)
    }

    /// And in the item's own file — which is where the retirement note the human
    /// is reacting to was written, and so where they will look next.
    func testTheReleaseIsNotedOnTheItem() async throws {
        let root = try registerProject(named: "alpha")
        retire("item-1", project: root)

        _ = try await harness.post("/v1/backlog/release", ["project": "alpha", "item": "item-1"])

        let notes = try XCTUnwrap(detailNotes("item-1", in: root))
        XCTAssertTrue(notes.contains("Released for autopilot (control API)"), notes)
    }

    /// The ceiling is a ceiling, not a budget a release refills. Three more empty
    /// attempts after a release and the item is retired again.
    func testAReleasedItemIsRetiredAgainAfterThreeMoreEmptyRuns() async throws {
        let root = try registerProject(named: "alpha")
        retire("item-1", project: root)
        _ = try await harness.post("/v1/backlog/release", ["project": "alpha", "item": "item-1"])
        let releasedAt = try XCTUnwrap(ledger.latestRelease(itemID: "item-1", projectPath: root))

        for index in 0..<2 {
            metrics.append(emptyRun(item: "item-1", project: root,
                                    at: releasedAt.addingTimeInterval(Double(index + 1) * 60)))
            XCTAssertFalse(verdict("item-1", project: root).isRetired,
                           "Empty run \(index + 1) after the release is still inside the ceiling")
        }
        metrics.append(emptyRun(item: "item-1", project: root,
                                at: releasedAt.addingTimeInterval(180)))

        let after = verdict("item-1", project: root)
        XCTAssertEqual(after.noWorkAttempts, 3, "Only the attempts since the release count")
        XCTAssertTrue(after.isRetired)
    }

    /// Releasing an item nothing was refusing is allowed and is a no-op. A 409
    /// here would force a driver to reproduce the ceiling's arithmetic before it
    /// was permitted to ask.
    func testReleasingAnItemThatIsNotRetiredSaysSo() async throws {
        try registerProject(named: "alpha")

        let (status, body) = try await harness.post("/v1/backlog/release", [
            "project": "alpha", "item": "item-1"
        ])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["wasRetired"] as? Bool, false)
        XCTAssertEqual(body["noWorkAttemptsBefore"] as? Int, 0)
    }

    /// Two projects can hold an item of the same id, and the ledger is
    /// portfolio-wide — releasing one must not release the other.
    func testReleasingOneProjectsItemLeavesTheOtherRetired() async throws {
        let alpha = try registerProject(named: "alpha")
        let beta = try registerProject(named: "beta")
        retire("item-1", project: alpha)
        retire("item-1", project: beta)

        _ = try await harness.post("/v1/backlog/release", ["project": "alpha", "item": "item-1"])

        XCTAssertFalse(verdict("item-1", project: alpha).isRetired)
        XCTAssertTrue(verdict("item-1", project: beta).isRetired,
                      "beta's item-1 has its own history and its own release")
    }

    // MARK: - Errors

    func testUnknownItemIs404() async throws {
        try registerProject(named: "alpha")

        let (status, body) = try await harness.post("/v1/backlog/release", [
            "project": "alpha", "item": "ghost"
        ])

        XCTAssertEqual(status, 404)
        XCTAssertEqual(body["error"] as? String, "No backlog item 'ghost' in this project")
        XCTAssertTrue(ledger.records.isEmpty, "A 404 must not leave a release on the record")
    }

    func testMissingItemIs400() async throws {
        try registerProject(named: "alpha")

        let (status, body) = try await harness.post("/v1/backlog/release", ["project": "alpha"])

        XCTAssertEqual(status, 400)
        XCTAssertEqual(body["error"] as? String, "Body must include \"project\" and \"item\"")
    }

    func testUnknownProjectIs409() async throws {
        try registerProject(named: "alpha")

        let (status, body) = try await harness.post("/v1/backlog/release", [
            "project": "ghost", "item": "item-1"
        ])

        XCTAssertEqual(status, 409)
        XCTAssertEqual(body["error"] as? String, "Project not open in Kiteloop: ghost")
    }

    /// A release nobody can record is not a release — the next pickup would read
    /// the ledger, find nothing, and refuse the item again.
    func testReleaseWithoutALedgerIs503() async throws {
        try registerProject(named: "alpha")
        let bare = try await startServer(groomingLedger: nil, metricStore: metrics)
        extraHarnesses.append(bare)

        let (status, body) = try await bare.post("/v1/backlog/release", [
            "project": "alpha", "item": "item-1"
        ])

        XCTAssertEqual(status, 503)
        XCTAssertEqual(body["error"] as? String,
                       "Cannot release — no grooming ledger attached to record it")
    }

    /// Releasing an item is a human decision about what autopilot may spend money
    /// on, so it sits behind the token like everything else.
    func testRequiresBearerToken() async throws {
        let root = try registerProject(named: "alpha")
        retire("item-1", project: root)

        let (status, body) = try await harness.post("/v1/backlog/release",
                                            ["project": "alpha", "item": "item-1"], bearer: nil)

        XCTAssertEqual(status, 401)
        XCTAssertEqual(body["error"] as? String, "Missing or invalid bearer token")
        XCTAssertTrue(verdict("item-1", project: root).isRetired, "and the item stays retired")
    }

    // MARK: - Fixtures

    /// Puts the item over the ceiling with `limit` runs that produced nothing.
    ///
    /// Timestamped in the recent past, not at a fixed epoch: the endpoint records
    /// the release at `Date()`, and a release only discounts attempts that
    /// finished before it — a fixture dated in the future would be testing
    /// nothing.
    private func retire(_ itemID: String, project: String) {
        let base = Date().addingTimeInterval(-3600)
        for index in 0..<RetryCeiling.limit {
            metrics.append(emptyRun(item: itemID, project: project,
                                    at: base.addingTimeInterval(Double(index) * 60)))
        }
    }

    /// The ceiling's own verdict, which is what autopilot reads at pickup — the
    /// only assertion that a release actually released anything.
    private func verdict(_ itemID: String, project: String) -> RetryCeiling.Verdict {
        RetryCeiling.evaluate(itemID: itemID, projectPath: project, records: metrics.records,
                              releasedAt: ledger.latestRelease(itemID: itemID, projectPath: project))
    }

    private func emptyRun(item: String, project: String, at: Date) -> TaskMetricRecord {
        var record = TaskMetricRecord(
            projectPath: project, projectName: "alpha", itemID: item, title: "An item",
            epic: nil, declaredSize: "S", startedAt: at.addingTimeInterval(-600),
            completedAt: at, durationSeconds: 600, costUSD: 0, reviewerRetries: 0,
            outcome: "blocked:\(RunWorkEvidence.noWorkPrefix) — no commits and an unchanged worktree",
            workerAgent: "worker", reviewerAgent: "reviewer", executionID: "e-1", toolErrors: nil
        )
        record.changedFileCount = 0
        return record
    }

    private func detailNotes(_ itemID: String, in root: String) throws -> String? {
        let url = URL(fileURLWithPath: root).appending(path: "backlog/\(itemID).md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// A project with one groomed item that has a detail file to write notes into.
    @discardableResult
    private func registerProject(named name: String) throws -> String {
        let root = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appending(path: "backlog"),
                                                withIntermediateDirectories: true)
        let rootURL = URL(fileURLWithPath: root.path(percentEncoded: false), isDirectory: false)
        let project = KiteloopProject(rootURL: rootURL)
        try project.ensureDirectoryExists()

        try """
        # \(name) Backlog

        ## Now

        - [ ] item-1 | An item | ready | size: S → [detail](backlog/item-1.md)
        """.write(to: root.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)
        try """
        ---
        id: item-1
        title: An item
        size: S
        verify:
          - name: build
            cmd: "swift build"
        ---

        ## What

        The outcome this item delivers.

        ## Validation

        - [ ] It works
        """.write(to: root.appending(path: "backlog/item-1.md"), atomically: true, encoding: .utf8)

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

    private func startServer(groomingLedger: GroomingLedger?,
                             metricStore: TaskMetricStore?) async throws -> ControlServerHarness {
        try await ControlServerHarness.start(token: token) {
            KiteloopControlServer(registry: registry, token: $0,
                                  metricStore: metricStore,
                                  groomingLedger: groomingLedger)
        }
    }
}
