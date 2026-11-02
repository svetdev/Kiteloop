import XCTest
import KiteloopCore
@testable import Kiteloop

/// `GET /v1/grooming` — the pre-run half of a night — and `GET /v1/report`, which
/// aggregates that half with the run half into what the period produced.
/// `GET /v1/metrics` only has a record for an item that *ran*, so a queue that
/// drained because four items were refused for a missing `verify:` looks the same
/// there as a queue that drained because the work is done. These records are what
/// tells them apart. Exercised over a real loopback socket, like the other
/// control-API tests.
@MainActor
final class KiteloopControlServerGroomingTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var ledger: GroomingLedger!
    /// The run half of the report. Attached to the same server: `/v1/grooming`
    /// never reads it, and `/v1/report` needs both ledgers to answer at all.
    private var metrics: TaskMetricStore!
    private var harness: ControlServerHarness!
    /// Extra servers a test started (e.g. one with no ledger attached), stopped in teardown.
    private var extraServers: [ControlServerHarness] = []
    private let token = "control-grooming-token-" + UUID().uuidString

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-grooming")
        registry = ControlSessionRegistry()
        // Pointed at the temp directory so the tests never read or append to the
        // developer's real ~/.kiteloop/grooming.jsonl.
        ledger = GroomingLedger(url: tempDir.appendingPathComponent("grooming.jsonl"))
        metrics = TaskMetricStore(
            metricsURL: tempDir.appendingPathComponent("task-metrics.jsonl"),
            estimatesURL: tempDir.appendingPathComponent("task-estimates.jsonl"),
            approvalsURL: tempDir.appendingPathComponent("task-approvals.jsonl")
        )
        harness = try await startServer(metricStore: metrics, groomingLedger: ledger)
    }

    override func tearDown() async throws {
        harness?.stop()
        extraServers.forEach { $0.stop() }
        extraServers = []
        harness = nil
        registry = nil
        ledger = nil
        metrics = nil
    }

    // MARK: - Listing

    /// Nothing groomed yet is a normal state, not a 404 — a driver can read before
    /// the first item is ever filed.
    func testEmptyListWhenNothingHasBeenGroomed() async throws {
        let (status, body) = try await harness.get("/v1/grooming")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["count"] as? Int, 0)
        XCTAssertEqual((body["grooming"] as? [[String: Any]])?.count, 0)
    }

    /// A refusal is the reason the endpoint exists: it has to name the check that
    /// refused and the clause that failed, or the operator learns only that
    /// *something* went wrong.
    func testRefusalCarriesItsCheckAndReason() async throws {
        let at = Date(timeIntervalSince1970: 1_770_000_000)
        ledger.recordCheckFailure(
            itemID: "item-1", projectPath: "/tmp/alpha", projectName: "alpha",
            check: GroomingRecord.Check.definitionOfReady,
            reason: "No verify: command", at: at
        )

        let (status, body) = try await harness.get("/v1/grooming")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["count"] as? Int, 1)
        let records = try XCTUnwrap(body["grooming"] as? [[String: Any]])
        XCTAssertEqual(records[0]["at"] as? String, ISO8601DateFormatter().string(from: at))
        XCTAssertEqual(records[0]["item"] as? String, "item-1")
        XCTAssertEqual(records[0]["project"] as? String, "alpha")
        XCTAssertEqual(records[0]["event"] as? String, "check-failed")
        XCTAssertEqual(records[0]["check"] as? String, "definition-of-ready")
        XCTAssertEqual(records[0]["reason"] as? String, "No verify: command")
    }

    /// A filing reports the stage it landed at — "filed 6 items" says nothing until
    /// you know how many of them were runnable — and names no check.
    func testFilingCarriesItsEventAndNoCheck() async throws {
        ledger.recordFiled(itemID: "ready-1", projectPath: "/tmp/alpha", projectName: "alpha", ready: true)
        ledger.recordFiled(itemID: "draft-1", projectPath: "/tmp/alpha", projectName: "alpha", ready: false)

        let (_, body) = try await harness.get("/v1/grooming")

        let records = try XCTUnwrap(body["grooming"] as? [[String: Any]])
        XCTAssertEqual(records.map { $0["event"] as? String }, ["filed-draft", "filed-ready"])
        for record in records {
            XCTAssertTrue(record["check"] is NSNull, "a filing names no check")
            XCTAssertTrue(record["reason"] is NSNull, "a filing has no failing clause")
        }
    }

    /// Newest first, matching every other listing — the refusal that just happened
    /// is at index 0, where a driver watching a night looks.
    func testOrdersNewestFirst() async throws {
        let base = Date(timeIntervalSince1970: 1_770_000_000)
        ledger.recordFiled(itemID: "older", projectPath: "/tmp/alpha", projectName: "alpha",
                           ready: true, at: base)
        ledger.recordFiled(itemID: "newer", projectPath: "/tmp/alpha", projectName: "alpha",
                           ready: true, at: base.addingTimeInterval(3_600))

        let (_, body) = try await harness.get("/v1/grooming")

        let records = try XCTUnwrap(body["grooming"] as? [[String: Any]])
        XCTAssertEqual(records.map { $0["item"] as? String }, ["newer", "older"])
    }

    /// Each check writes its own name, so a reader can tell "ungroomed" from
    /// "groomed and going nowhere".
    func testReportsEachCheckThatRefusedAnItem() async throws {
        let base = Date(timeIntervalSince1970: 1_770_000_000)
        let checks = [GroomingRecord.Check.definitionOfReady,
                      GroomingRecord.Check.grounding,
                      GroomingRecord.Check.retryCeiling]
        for (i, check) in checks.enumerated() {
            ledger.recordCheckFailure(itemID: "item-\(i)", projectPath: "/tmp/alpha",
                                      projectName: "alpha", check: check, reason: "because",
                                      at: base.addingTimeInterval(Double(i) * 60))
        }

        let (_, body) = try await harness.get("/v1/grooming")

        let records = try XCTUnwrap(body["grooming"] as? [[String: Any]])
        XCTAssertEqual(records.map { $0["check"] as? String },
                       ["retry-ceiling", "grounding-check", "definition-of-ready"])
    }

    // MARK: - Filtering

    func testProjectFilterNarrowsToThatProjectsRecords() async throws {
        let alpha = try registerProject(named: "alpha")
        try registerProject(named: "beta")
        ledger.recordFiled(itemID: "item-1", projectPath: alpha, projectName: "alpha", ready: true)
        ledger.recordFiled(itemID: "item-2", projectPath: "/elsewhere/beta", projectName: "beta", ready: true)

        let (status, body) = try await harness.get("/v1/grooming?project=alpha")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["project"] as? String, "alpha")
        let records = try XCTUnwrap(body["grooming"] as? [[String: Any]])
        XCTAssertEqual(records.map { $0["item"] as? String }, ["item-1"])
    }

    /// Records keep the raw root path while the registry keys on the canonical one,
    /// so a trailing slash must not hide a project's own records.
    func testProjectFilterMatchesDespiteATrailingSlash() async throws {
        let alpha = try registerProject(named: "alpha")
        ledger.recordCheckFailure(itemID: "item-1", projectPath: alpha + "/", projectName: "alpha",
                                  check: GroomingRecord.Check.grounding, reason: "No such file")

        let (_, body) = try await harness.get("/v1/grooming?project=alpha")

        let records = try XCTUnwrap(body["grooming"] as? [[String: Any]])
        XCTAssertEqual(records.map { $0["item"] as? String }, ["item-1"])
    }

    /// Same contract as the other project-scoped reads: a project that isn't open
    /// is a 409, not an empty list a caller could mistake for "nothing was refused".
    func testProjectFilterRequiresAnOpenProject() async throws {
        let (status, body) = try await harness.get("/v1/grooming?project=ghost")

        XCTAssertEqual(status, 409)
        XCTAssertEqual(body["error"] as? String, "Project not open in Kiteloop: ghost")
    }

    // MARK: - Limit

    func testLimitCapsHowManyRecordsComeBack() async throws {
        let base = Date(timeIntervalSince1970: 1_770_000_000)
        for i in 0..<5 {
            ledger.recordFiled(itemID: "item-\(i)", projectPath: "/tmp/alpha", projectName: "alpha",
                               ready: true, at: base.addingTimeInterval(Double(i) * 60))
        }

        let (status, body) = try await harness.get("/v1/grooming?limit=2")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["count"] as? Int, 2)
        let records = try XCTUnwrap(body["grooming"] as? [[String: Any]])
        XCTAssertEqual(records.map { $0["item"] as? String }, ["item-4", "item-3"])
    }

    /// Without a limit the default keeps a long ledger from arriving all at once.
    func testDefaultLimitIsTwenty() async throws {
        for i in 0..<25 {
            ledger.recordFiled(itemID: "item-\(i)", projectPath: "/tmp/alpha",
                               projectName: "alpha", ready: true)
        }

        let (_, body) = try await harness.get("/v1/grooming")

        XCTAssertEqual(body["count"] as? Int, 20)
    }

    /// A limit that isn't a number in range is a caller bug, so it's rejected
    /// rather than silently rounded into the default.
    func testRejectsAnUnusableLimit() async throws {
        for raw in ["0", "999", "abc", "-3"] {
            let (status, body) = try await harness.get("/v1/grooming?limit=\(raw)")
            XCTAssertEqual(status, 400, "limit=\(raw)")
            XCTAssertEqual(body["error"] as? String, "\"limit\" must be an integer in 1...200", "limit=\(raw)")
        }
    }

    // MARK: - Errors

    /// With no ledger attached there is nothing to report — say so instead of
    /// answering an empty list that reads as "nothing was ever refused".
    func testUnavailableWhenNoLedgerIsAttached() async throws {
        let detached = try await startServer(metricStore: metrics, groomingLedger: nil)
        extraServers.append(detached)

        let (status, body) = try await detached.get("/v1/grooming")

        XCTAssertEqual(status, 503)
        XCTAssertEqual(body["error"] as? String,
                       "Grooming records are unavailable — no grooming ledger attached")
    }

    func testRequiresBearerToken() async throws {
        let (status, body) = try await harness.get("/v1/grooming", bearer: nil)

        XCTAssertEqual(status, 401)
        XCTAssertEqual(body["error"] as? String, "Missing or invalid bearer token")
    }

    // MARK: - GET /v1/report

    /// The headline the whole report exists for: what was filed, what ran, what
    /// merged, per project and for the portfolio — from the two ledgers the raw
    /// listings serve separately.
    func testReportCountsThePeriodPerProjectAndInTotal() async throws {
        let hourAgo = Date().addingTimeInterval(-3_600)
        ledger.recordFiled(itemID: "item-1", projectPath: "/tmp/alpha", projectName: "alpha",
                           ready: true, at: hourAgo)
        ledger.recordFiled(itemID: "item-2", projectPath: "/tmp/alpha", projectName: "alpha",
                           ready: true, at: hourAgo)
        ledger.recordFiled(itemID: "item-3", projectPath: "/tmp/alpha", projectName: "alpha",
                           ready: false, at: hourAgo)
        appendRun(item: "item-1", outcome: "done", merged: true, costUSD: 1.50, completedAt: hourAgo)
        appendRun(item: "item-2", outcome: "done", merged: true, costUSD: 2.00, completedAt: hourAgo)
        appendRun(item: "item-3", outcome: "blocked:review did not pass", merged: false,
                  costUSD: 0.40, completedAt: hourAgo)

        let (status, body) = try await harness.get("/v1/report")

        XCTAssertEqual(status, 200)
        let period = try XCTUnwrap(body["period"] as? [String: Any])
        XCTAssertEqual(period["hours"] as? Int, 24)
        XCTAssertEqual(period["label"] as? String, "last 24h")
        XCTAssertNotNil(period["start"] as? String)
        XCTAssertNotNil(period["end"] as? String)
        XCTAssertEqual(body["empty"] as? Bool, false)
        XCTAssertEqual(body["omittedProjects"] as? Int, 0)

        let rows = try XCTUnwrap(body["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["project"] as? String, "alpha")
        XCTAssertEqual(rows[0]["filed"] as? Int, 3)
        XCTAssertEqual(rows[0]["ready"] as? Int, 2)
        XCTAssertEqual(rows[0]["draft"] as? Int, 1)
        XCTAssertEqual(rows[0]["run"] as? Int, 3)
        XCTAssertEqual(rows[0]["merged"] as? Int, 2)
        XCTAssertEqual(rows[0]["rejected"] as? Int, 1)

        // The total is every project in the period, in the same shape as a row.
        let total = try XCTUnwrap(body["total"] as? [String: Any])
        XCTAssertEqual(total["project"] as? String, "All projects")
        XCTAssertEqual(total["run"] as? Int, 3)
        XCTAssertEqual(total["merged"] as? Int, 2)
        XCTAssertEqual(try XCTUnwrap(total["spendUSD"] as? Double), 3.90, accuracy: 0.001)
    }

    /// merged ÷ **filed** is the rate that judges the grooming, and it says so —
    /// a driver must never have to guess which of the two questions it is reading.
    func testMergeRateOverFilingsNamesFiledAsItsBasis() async throws {
        let hourAgo = Date().addingTimeInterval(-3_600)
        for id in ["item-1", "item-2", "item-3", "item-4"] {
            ledger.recordFiled(itemID: id, projectPath: "/tmp/alpha", projectName: "alpha",
                               ready: true, at: hourAgo)
        }
        appendRun(item: "item-1", outcome: "done", merged: true, completedAt: hourAgo)

        let (_, body) = try await harness.get("/v1/report")

        let rate = try XCTUnwrap((body["total"] as? [String: Any])?["mergeRate"] as? [String: Any])
        XCTAssertEqual(rate["basis"] as? String, "filed")
        XCTAssertEqual(rate["merged"] as? Int, 1)
        XCTAssertEqual(rate["of"] as? Int, 4)
        XCTAssertEqual(try XCTUnwrap(rate["fraction"] as? Double), 0.25, accuracy: 0.001)
    }

    /// Nothing files items in a period where the coordinator did no grooming, so
    /// the rate falls back to merged ÷ **run** — visibly, or a good night reading
    /// 1/1 would be mistaken for a perfect filing rate.
    func testMergeRateFallsBackToRunsAndSaysSo() async throws {
        let hourAgo = Date().addingTimeInterval(-3_600)
        appendRun(item: "item-1", outcome: "done", merged: true, completedAt: hourAgo)
        appendRun(item: "item-2", outcome: "blocked:review did not pass", merged: false,
                  completedAt: hourAgo)

        let (_, body) = try await harness.get("/v1/report")

        let rate = try XCTUnwrap((body["total"] as? [String: Any])?["mergeRate"] as? [String: Any])
        XCTAssertEqual(rate["basis"] as? String, "run", "no filings — the denominator is runs")
        XCTAssertEqual(rate["of"] as? Int, 2)
        XCTAssertEqual(try XCTUnwrap(rate["fraction"] as? Double), 0.5, accuracy: 0.001)
    }

    /// A rejection is only actionable with the verdict behind it, so the causes
    /// carry the check that refused the item and one reason verbatim.
    func testRejectionsAreGroupedByTheCheckThatRefusedThem() async throws {
        let hourAgo = Date().addingTimeInterval(-3_600)
        ledger.recordCheckFailure(itemID: "item-1", projectPath: "/tmp/alpha", projectName: "alpha",
                                  check: GroomingRecord.Check.grounding,
                                  reason: "No such file: Services/Ghost.swift", at: hourAgo)
        appendRun(item: "item-1", outcome: "blocked:review did not pass", merged: false,
                  completedAt: hourAgo)

        let (_, body) = try await harness.get("/v1/report")

        let total = try XCTUnwrap(body["total"] as? [String: Any])
        XCTAssertEqual(total["skippedByCheck"] as? Int, 1)
        let causes = try XCTUnwrap(total["causes"] as? [[String: Any]])
        XCTAssertEqual(causes.count, 1)
        XCTAssertEqual(causes[0]["label"] as? String, "grounding-check")
        XCTAssertEqual(causes[0]["count"] as? Int, 1)
        XCTAssertEqual(causes[0]["example"] as? String, "No such file: Services/Ghost.swift")
    }

    /// The row list is bounded, and what it left out is counted rather than
    /// dropped — a truncated report that looks complete is worse than none.
    func testProjectsBeyondTheRowLimitAreCountedInTheTotal() async throws {
        let hourAgo = Date().addingTimeInterval(-3_600)
        for i in 0..<7 {
            ledger.recordFiled(itemID: "item-\(i)", projectPath: "/tmp/p\(i)", projectName: "p\(i)",
                               ready: true, at: hourAgo)
        }

        let (_, body) = try await harness.get("/v1/report")

        XCTAssertEqual((body["rows"] as? [[String: Any]])?.count, 6)
        XCTAssertEqual(body["omittedProjects"] as? Int, 1)
        XCTAssertEqual((body["total"] as? [String: Any])?["filed"] as? Int, 7,
                       "the arithmetic covers every project, only the list is bounded")
    }

    /// `?hours=` is the window, and the default is the night a driver asks about.
    func testHoursSelectsTheWindow() async throws {
        let twoDaysAgo = Date().addingTimeInterval(-48 * 3_600)
        appendRun(item: "item-1", outcome: "done", merged: true, completedAt: twoDaysAgo)

        let (_, day) = try await harness.get("/v1/report")
        XCTAssertEqual((day["total"] as? [String: Any])?["run"] as? Int, 0)
        XCTAssertEqual(day["empty"] as? Bool, true, "nothing finished in the last 24h")

        let (status, week) = try await harness.get("/v1/report?hours=72")
        XCTAssertEqual(status, 200)
        XCTAssertEqual((week["period"] as? [String: Any])?["hours"] as? Int, 72)
        XCTAssertEqual((week["total"] as? [String: Any])?["run"] as? Int, 1)
    }

    /// An hours value that isn't a number in range is a caller bug, so it's
    /// rejected — with the range named, rather than rounded into the default.
    func testRejectsAnUnusableHours() async throws {
        for raw in ["0", "721", "abc", "-3"] {
            let (status, body) = try await harness.get("/v1/report?hours=\(raw)")
            XCTAssertEqual(status, 400, "hours=\(raw)")
            XCTAssertEqual(body["error"] as? String, "\"hours\" must be an integer in 1...720", "hours=\(raw)")
        }
    }

    /// Half the report is the run ledger, so without it there is no rate to
    /// report — say which half is missing rather than answering a report whose
    /// numerator came from nowhere.
    func testReportUnavailableWhenNoMetricStoreIsAttached() async throws {
        let detached = try await startServer(metricStore: nil, groomingLedger: ledger)
        extraServers.append(detached)

        let (status, body) = try await detached.get("/v1/report")

        XCTAssertEqual(status, 503)
        XCTAssertEqual(body["error"] as? String, "Metrics are unavailable — no metric store attached")
    }

    /// And the other half: without the grooming ledger nothing knows what was
    /// filed, which is the report's denominator.
    func testReportUnavailableWhenNoLedgerIsAttached() async throws {
        let detached = try await startServer(metricStore: metrics, groomingLedger: nil)
        extraServers.append(detached)

        let (status, body) = try await detached.get("/v1/report")

        XCTAssertEqual(status, 503)
        XCTAssertEqual(body["error"] as? String,
                       "Grooming records are unavailable — no grooming ledger attached")
    }

    func testReportRequiresBearerToken() async throws {
        let (status, body) = try await harness.get("/v1/report", bearer: nil)

        XCTAssertEqual(status, 401)
        XCTAssertEqual(body["error"] as? String, "Missing or invalid bearer token")
    }

    // MARK: - Helpers

    /// One finished run on the metric ledger — the half of the report the
    /// grooming ledger can't see.
    private func appendRun(item: String, project: String = "alpha", path: String = "/tmp/alpha",
                           outcome: String, merged: Bool, costUSD: Double = 1.0,
                           completedAt: Date) {
        var record = TaskMetricRecord(
            projectPath: path, projectName: project, itemID: item, title: "An item",
            epic: nil, declaredSize: "S", startedAt: completedAt.addingTimeInterval(-600),
            completedAt: completedAt, durationSeconds: 600, costUSD: costUSD,
            reviewerRetries: 0, outcome: outcome, workerAgent: "worker",
            reviewerAgent: "reviewer", executionID: "exec-\(item)"
        )
        record.merged = merged
        metrics.append(record)
    }

    /// Builds a real `ProjectSession` over a throwaway directory and registers it.
    /// Returns the project's root path — what a record stores.
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
    private func startServer(metricStore: TaskMetricStore?,
                             groomingLedger: GroomingLedger?) async throws -> ControlServerHarness {
        try await ControlServerHarness.start(token: token) {
            KiteloopControlServer(registry: registry, token: $0,
                                  metricStore: metricStore,
                                  groomingLedger: groomingLedger)
        }
    }
}
