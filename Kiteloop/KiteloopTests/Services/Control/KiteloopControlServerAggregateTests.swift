import XCTest
import KiteloopCore
@testable import Kiteloop

/// `GET /v1/metrics?aggregate=` — the reason the index exists. Listing is capped
/// at 200 records so a poller can't drag a growing log through the socket every
/// tick; an aggregate returns a handful of groups however many runs went into
/// them, so it isn't capped at all, and answering "what did last night cost per
/// merged item" stops meaning "pull the records out and add them up in a script".
///
/// The sibling `KiteloopControlServerMetricsTests` covers listing with no index
/// attached — the in-memory fallback. This file attaches one, so it also pins the
/// contract that both paths answer the same thing.
@MainActor
final class KiteloopControlServerAggregateTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var metricStore: TaskMetricStore!
    private var metricIndex: MetricIndex!
    private var harness: ControlServerHarness!
    private var extraHarnesses: [ControlServerHarness] = []
    private let token = "control-aggregate-token-" + UUID().uuidString

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-aggregate")
        registry = ControlSessionRegistry()
        // Store and index are pointed at the same throwaway logs, which is the
        // production arrangement: the index projects what the store appends.
        metricStore = TaskMetricStore(
            metricsURL: tempDir.appendingPathComponent("task-metrics.jsonl"),
            estimatesURL: tempDir.appendingPathComponent("task-estimates.jsonl"),
            approvalsURL: tempDir.appendingPathComponent("task-approvals.jsonl")
        )
        metricIndex = MetricIndex(sources: .standard(in: tempDir))
        harness = try await startServer(metricStore: metricStore, metricIndex: metricIndex)
    }

    override func tearDown() async throws {
        harness?.stop()
        extraHarnesses.forEach { $0.stop() }
        extraHarnesses = []
        harness = nil
        registry = nil
        metricStore = nil
        metricIndex = nil
    }

    // MARK: - Aggregating

    /// Throughput and spend per size, from one call.
    func testAggregatesRunsBySize() async throws {
        metricStore.append(makeRecord(itemID: "a", size: "S", durationSeconds: 100, costUSD: 1.0))
        metricStore.append(makeRecord(itemID: "b", size: "S", durationSeconds: 300, costUSD: 3.0))
        metricStore.append(makeRecord(itemID: "c", size: "M", durationSeconds: 900, costUSD: 8.0))

        let (status, body) = try await harness.get("/v1/metrics?aggregate=size")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["aggregate"] as? String, "size")
        XCTAssertEqual(body["unit"] as? String, "runs")
        let groups = try XCTUnwrap(body["groups"] as? [[String: Any]])
        XCTAssertEqual(groups.map { $0["key"] as? String }, ["S", "M"])
        XCTAssertEqual(groups[0]["runs"] as? Int, 2)
        XCTAssertEqual(try XCTUnwrap(groups[0]["costUSD"] as? Double), 4.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(groups[0]["avgCostUSD"] as? Double), 2.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(groups[0]["avgDurationSec"] as? Double), 200, accuracy: 0.0001)
        XCTAssertEqual(groups[1]["runs"] as? Int, 1)
    }

    /// `aggregate=total` is the whole selection as one group — the shape a
    /// scorecard reads.
    func testAggregatesEverythingAsOneGroup() async throws {
        metricStore.append(makeRecord(itemID: "a", costUSD: 4.0, changedFileCount: 3, merged: true))
        metricStore.append(makeRecord(itemID: "b", costUSD: 2.0, changedFileCount: 0))

        let (status, body) = try await harness.get("/v1/metrics?aggregate=total")

        XCTAssertEqual(status, 200)
        let groups = try XCTUnwrap(body["groups"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0]["key"] as? String, "total")
        XCTAssertEqual(groups[0]["runs"] as? Int, 2)
        XCTAssertEqual(groups[0]["merged"] as? Int, 1)
        XCTAssertEqual(groups[0]["producedWork"] as? Int, 1)
        // Spend over the runs that left work behind — what "cost per item" means.
        XCTAssertEqual(try XCTUnwrap(groups[0]["costPerProducedRunUSD"] as? Double), 6.0, accuracy: 0.0001)
    }

    /// The cap is on listing, not on aggregating: 250 runs is past the 200-record
    /// ceiling and every one of them still counts toward the group.
    func testAggregateIsNotCappedAtTheRecordLimit() async throws {
        let base = Date(timeIntervalSince1970: 1_770_000_000)
        for i in 0..<250 {
            metricStore.append(makeRecord(itemID: "item-\(i)", startedAt: base.addingTimeInterval(Double(i) * 60),
                                          costUSD: 1.0))
        }

        let (status, body) = try await harness.get("/v1/metrics?aggregate=total")

        XCTAssertEqual(status, 200)
        let groups = try XCTUnwrap(body["groups"] as? [[String: Any]])
        XCTAssertEqual(groups[0]["runs"] as? Int, 250)
        XCTAssertEqual(try XCTUnwrap(groups[0]["costUSD"] as? Double), 250.0, accuracy: 0.0001)
    }

    /// Tokens are `null` rather than four zeros when nothing in the group
    /// recorded any — a group that was never measured must not read as one that
    /// consumed nothing.
    func testTokensAreNullWhenNothingRecordedThem() async throws {
        metricStore.append(makeRecord(itemID: "a"))

        let (_, body) = try await harness.get("/v1/metrics?aggregate=total")

        let groups = try XCTUnwrap(body["groups"] as? [[String: Any]])
        XCTAssertTrue(groups[0]["tokens"] is NSNull)
        XCTAssertEqual(groups[0]["runsWithUsage"] as? Int, 0)
    }

    /// And when some of the history was measured, the counters come back with the
    /// honest denominator beside them.
    func testTokensReportTheirOwnDenominator() async throws {
        var measured = makeRecord(itemID: "a")
        measured.inputTokens = 100
        measured.outputTokens = 20
        measured.cacheCreationTokens = 5
        measured.cacheReadTokens = 900
        metricStore.append(measured)
        metricStore.append(makeRecord(itemID: "b"))

        let (_, body) = try await harness.get("/v1/metrics?aggregate=total")

        let groups = try XCTUnwrap(body["groups"] as? [[String: Any]])
        let tokens = try XCTUnwrap(groups[0]["tokens"] as? [String: Any])
        XCTAssertEqual(tokens["input"] as? Int, 100)
        XCTAssertEqual(tokens["cacheRead"] as? Int, 900)
        XCTAssertEqual(groups[0]["runs"] as? Int, 2)
        XCTAssertEqual(groups[0]["runsWithUsage"] as? Int, 1)
    }

    /// The defect rate rides along with an aggregate exactly as it does with a
    /// listing — it's whole-history either way.
    func testAggregateCarriesTheEscapedDefectRate() async throws {
        let approvedAt = Date(timeIntervalSince1970: 1_770_000_000)
        approve("item-1", at: approvedAt)
        reopen("item-1", approvedAt: approvedAt, at: approvedAt.addingTimeInterval(2 * 86_400))
        approve("item-2", at: approvedAt)

        let (_, body) = try await harness.get("/v1/metrics?aggregate=total")

        let escaped = try XCTUnwrap(body["escapedDefects"] as? [String: Any])
        XCTAssertEqual(escaped["approvals"] as? Int, 2)
        XCTAssertEqual(escaped["reopened"] as? Int, 1)
        XCTAssertEqual(escaped["rate"] as? Double, 0.5)
    }

    /// So does the first-pass rate — the other half of metric #3, and
    /// whole-history for the same reason.
    func testAggregateCarriesTheFirstPassRate() async throws {
        metricStore.append(makeRecord(itemID: "a", reviewerRetries: 0, outcome: "done"))
        metricStore.append(makeRecord(itemID: "b", reviewerRetries: 1, outcome: "done"))
        metricStore.append(makeRecord(itemID: "c", reviewerRetries: 0, outcome: "cancelled"))

        let (_, body) = try await harness.get("/v1/metrics?aggregate=total")

        let firstPass = try XCTUnwrap(body["firstPassRate"] as? [String: Any])
        XCTAssertEqual(firstPass["judged"] as? Int, 2)
        XCTAssertEqual(firstPass["firstPass"] as? Int, 1)
        XCTAssertEqual(firstPass["rate"] as? Double, 0.5)
    }

    /// The listing is served from the index here and from the log in the sibling
    /// file, so the two have to agree on the same records — otherwise the number
    /// the SLO is read from depends on whether a database happened to be open.
    func testTheIndexAndTheLogAgreeOnTheFirstPassRate() async throws {
        let outcomes = ["done", "awaiting-approval", "blocked:review did not pass",
                        "blocked:stalled: no progress for 20 min on worker", "cancelled"]
        for (offset, outcome) in outcomes.enumerated() {
            metricStore.append(makeRecord(itemID: "item-\(offset)",
                                          reviewerRetries: offset % 2, outcome: outcome))
        }

        let (_, body) = try await harness.get("/v1/metrics")
        let served = try XCTUnwrap(body["firstPassRate"] as? [String: Any])
        let inMemory = metricStore.firstPassRate(projectPath: nil)

        XCTAssertEqual(served["judged"] as? Int, inMemory.judged)
        XCTAssertEqual(served["firstPass"] as? Int, inMemory.firstPass)
        XCTAssertEqual(served["rate"] as? Double, inMemory.rate)
        XCTAssertEqual(inMemory.judged, 4)
        XCTAssertEqual(inMemory.firstPass, 1)
    }

    /// `?project=` narrows an aggregate the same way it narrows a listing, and
    /// answers with the project's name so a caller can tell what it scoped to.
    func testProjectFilterNarrowsTheAggregate() async throws {
        let alpha = try registerProject(named: "alpha")
        try registerProject(named: "beta")
        metricStore.append(makeRecord(projectPath: alpha, projectName: "alpha", itemID: "a", costUSD: 1.0))
        metricStore.append(makeRecord(projectPath: "/elsewhere/beta", projectName: "beta",
                                      itemID: "b", costUSD: 9.0))

        let (status, body) = try await harness.get("/v1/metrics?project=alpha&aggregate=total")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["project"] as? String, "alpha")
        let groups = try XCTUnwrap(body["groups"] as? [[String: Any]])
        XCTAssertEqual(groups[0]["runs"] as? Int, 1)
        XCTAssertEqual(try XCTUnwrap(groups[0]["costUSD"] as? Double), 1.0, accuracy: 0.0001)
    }

    /// Same contract as every other project-scoped read: a project that isn't
    /// open is a 409, checked before the aggregate is attempted.
    func testAggregateRequiresAnOpenProject() async throws {
        let (status, body) = try await harness.get("/v1/metrics?project=ghost&aggregate=total")

        XCTAssertEqual(status, 409)
        XCTAssertEqual(body["error"] as? String, "Project not open in Kiteloop: ghost")
    }

    // MARK: - Turns

    /// `aggregate=role` groups turns rather than runs: the split between worker
    /// and reviewer spend only exists at the level the spend was incurred.
    func testAggregatesTurnsByRole() async throws {
        let alpha = try registerProject(named: "alpha")
        metricStore.append(makeRecord(projectPath: alpha, projectName: "alpha", itemID: "a"))
        try appendTurns(projectPath: alpha, [
            turn(role: "worker", costUSD: 3.0, inputTokens: 10),
            turn(role: "worker", costUSD: 1.0, inputTokens: 20),
            turn(role: "reviewer", costUSD: 2.0, inputTokens: 30)
        ])

        let (status, body) = try await harness.get("/v1/metrics?project=alpha&aggregate=role")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["unit"] as? String, "turns")
        let groups = try XCTUnwrap(body["groups"] as? [[String: Any]])
        XCTAssertEqual(groups.map { $0["key"] as? String }, ["worker", "reviewer"])
        XCTAssertEqual(groups[0]["turns"] as? Int, 2)
        XCTAssertEqual(try XCTUnwrap(groups[0]["costUSD"] as? Double), 4.0, accuracy: 0.0001)
        XCTAssertEqual(groups[1]["turns"] as? Int, 1)
        XCTAssertEqual(try XCTUnwrap(groups[1]["costUSD"] as? Double), 2.0, accuracy: 0.0001)
    }

    // MARK: - Listing from the index

    /// The listing path is served from the index when one is attached, and has to
    /// answer exactly what the in-memory path answers — the endpoint's existing
    /// contract, unchanged by where the records now come from.
    func testListingIsUnchangedWhenServedFromTheIndex() async throws {
        let started = Date(timeIntervalSince1970: 1_770_000_000)
        var record = makeRecord(itemID: "item-1", title: "Ship the thing",
                                startedAt: started, durationSeconds: 942, costUSD: 1.25)
        record.qualityScore = 0.87
        record.judgeDimensions = ["verify_passed": 1.0, "scope_respected": 0.75]
        metricStore.append(record)
        metricStore.append(makeRecord(itemID: "older", startedAt: started.addingTimeInterval(-3_600)))

        let (status, body) = try await harness.get("/v1/metrics")

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["count"] as? Int, 2)
        let metrics = try XCTUnwrap(body["metrics"] as? [[String: Any]])
        // Newest first, as the endpoint has always ordered.
        XCTAssertEqual(metrics.map { $0["item"] as? String }, ["item-1", "older"])
        XCTAssertEqual(metrics[0]["title"] as? String, "Ship the thing")
        XCTAssertEqual(metrics[0]["project"] as? String, "alpha")
        XCTAssertEqual(metrics[0]["epic"] as? String, "Work")
        XCTAssertEqual(metrics[0]["size"] as? String, "M")
        XCTAssertEqual(metrics[0]["runId"] as? String, "exec-item-1")
        XCTAssertEqual(metrics[0]["startedAt"] as? String, ISO8601DateFormatter().string(from: started))
        XCTAssertEqual(metrics[0]["durationSec"] as? Int, 942)
        XCTAssertEqual(metrics[0]["costUSD"] as? Double, 1.25)
        XCTAssertEqual(metrics[0]["outcome"] as? String, "done")
        XCTAssertEqual(metrics[0]["worker"] as? String, "Builder")
        XCTAssertEqual(metrics[0]["qualityScore"] as? Double, 0.87)
        XCTAssertEqual((metrics[0]["judgeDimensions"] as? [String: Double])?["verify_passed"], 1.0)
        XCTAssertTrue(metrics[1]["qualityScore"] is NSNull)
    }

    /// `limit` still caps the listing when it comes from the index — the cap is
    /// relaxed for aggregates only.
    func testLimitStillCapsTheListing() async throws {
        let base = Date(timeIntervalSince1970: 1_770_000_000)
        for i in 0..<5 {
            metricStore.append(makeRecord(itemID: "item-\(i)", startedAt: base.addingTimeInterval(Double(i) * 60)))
        }

        let (_, body) = try await harness.get("/v1/metrics?limit=2")

        XCTAssertEqual(body["count"] as? Int, 2)
        let metrics = try XCTUnwrap(body["metrics"] as? [[String: Any]])
        XCTAssertEqual(metrics.map { $0["item"] as? String }, ["item-4", "item-3"])
    }

    /// Deleting the database mid-flight loses no answer: it holds nothing the log
    /// doesn't, so the next call rebuilds it and reports the same runs.
    func testDeletingTheIndexLosesNoRecords() async throws {
        metricStore.append(makeRecord(itemID: "a"))
        metricStore.append(makeRecord(itemID: "b"))
        let (_, before) = try await harness.get("/v1/metrics?aggregate=total")
        XCTAssertEqual((before["groups"] as? [[String: Any]])?.first?["runs"] as? Int, 2)

        try FileManager.default.removeItem(at: tempDir.appendingPathComponent("metrics.sqlite3"))

        // A fresh index over the same logs — what the app does after the file is
        // deleted or the schema moves on.
        let rebuilt = MetricIndex(sources: .standard(in: tempDir))
        let restarted = try await startServer(metricStore: metricStore, metricIndex: rebuilt)
        extraHarnesses.append(restarted)

        let (status, after) = try await restarted.get("/v1/metrics?aggregate=total")
        XCTAssertEqual(status, 200)
        XCTAssertEqual((after["groups"] as? [[String: Any]])?.first?["runs"] as? Int, 2)
    }

    // MARK: - Errors

    /// An aggregate is the one thing the JSONL log can't do without loading
    /// itself, so with no index attached it says so rather than falling back.
    func testAggregateIsUnavailableWithNoIndexAttached() async throws {
        let detached = try await startServer(metricStore: metricStore, metricIndex: nil)
        extraHarnesses.append(detached)

        let (status, body) = try await detached.get("/v1/metrics?aggregate=size")

        XCTAssertEqual(status, 503)
        XCTAssertEqual(body["error"] as? String, "Aggregates are unavailable — no metric index attached")
    }

    /// A dimension that doesn't exist is a caller bug, and the error names the
    /// ones that do rather than leaving them to be guessed.
    func testRejectsAnUnknownAggregateDimension() async throws {
        let (status, body) = try await harness.get("/v1/metrics?aggregate=colour")

        XCTAssertEqual(status, 400)
        let message = try XCTUnwrap(body["error"] as? String)
        XCTAssertTrue(message.hasPrefix("\"aggregate\" must be one of "), message)
        for dimension in MetricGrouping.allCases {
            XCTAssertTrue(message.contains(dimension.rawValue), "missing \(dimension.rawValue): \(message)")
        }
    }

    /// The store is still what "metrics are unavailable" is about — an index
    /// without one has no logs to project.
    func testUnavailableWhenNoStoreIsAttached() async throws {
        let detached = try await startServer(metricStore: nil, metricIndex: metricIndex)
        extraHarnesses.append(detached)

        let (status, body) = try await detached.get("/v1/metrics?aggregate=total")

        XCTAssertEqual(status, 503)
        XCTAssertEqual(body["error"] as? String, "Metrics are unavailable — no metric store attached")
    }

    func testRequiresBearerToken() async throws {
        let (status, body) = try await harness.get("/v1/metrics?aggregate=size", bearer: nil)

        XCTAssertEqual(status, 401)
        XCTAssertEqual(body["error"] as? String, "Missing or invalid bearer token")
    }

    // MARK: - Helpers

    private func makeRecord(
        projectPath: String = "/tmp/alpha",
        projectName: String = "alpha",
        itemID: String = "item-1",
        title: String = "Ship the thing",
        size: String? = "M",
        startedAt: Date = Date(timeIntervalSince1970: 1_770_000_000),
        durationSeconds: Double = 60,
        costUSD: Double = 0.5,
        reviewerRetries: Int = 0,
        outcome: String = "done",
        changedFileCount: Int? = nil,
        merged: Bool? = nil
    ) -> TaskMetricRecord {
        var record = TaskMetricRecord(
            projectPath: projectPath,
            projectName: projectName,
            itemID: itemID,
            title: title,
            epic: "Work",
            declaredSize: size,
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(durationSeconds),
            durationSeconds: durationSeconds,
            costUSD: costUSD,
            reviewerRetries: reviewerRetries,
            outcome: outcome,
            workerAgent: "Builder",
            reviewerAgent: "Reviewer",
            executionID: "exec-\(itemID)",
            toolErrors: nil
        )
        record.changedFileCount = changedFileCount
        record.merged = merged
        return record
    }

    private func approve(_ itemID: String, projectPath: String = "/tmp/alpha", at: Date) {
        metricStore.appendApprovalEvent(ItemApprovalEvent(
            projectPath: projectPath, projectName: "alpha", itemID: itemID, kind: .approved, at: at
        ))
    }

    private func reopen(_ itemID: String, projectPath: String = "/tmp/alpha",
                        approvedAt: Date, at: Date) {
        metricStore.appendApprovalEvent(ItemApprovalEvent(
            projectPath: projectPath, projectName: "alpha", itemID: itemID, kind: .reopened,
            at: at, approvedAt: approvedAt, toStatus: "ready"
        ))
    }

    private func turn(role: String, costUSD: Double, inputTokens: Int) -> TraceSpan {
        let start = Date(timeIntervalSince1970: 1_770_000_000)
        return TraceSpan(
            id: UUID().uuidString, agentID: "Builder", sessionID: "s-1",
            startTime: start, endTime: start.addingTimeInterval(30), type: .turn,
            metadata: [
                TraceSpan.MetadataKey.role: role,
                TraceSpan.MetadataKey.executionID: "exec-a",
                TraceSpan.MetadataKey.costUSD: String(costUSD),
                TraceSpan.MetadataKey.inputTokens: String(inputTokens),
                TraceSpan.MetadataKey.model: "claude-opus-5"
            ]
        )
    }

    /// Writes turn spans where the project actually keeps them, which is where
    /// the index looks for them — discovered from the runs, not registered.
    private func appendTurns(projectPath: String, _ spans: [TraceSpan]) throws {
        let traces = KiteloopProject(rootURL: URL(fileURLWithPath: projectPath)).tracesURL
        try FileManager.default.createDirectory(at: traces, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let text = spans.compactMap { span -> String? in
            guard let data = try? encoder.encode(span) else { return nil }
            return String(data: data, encoding: .utf8).map { $0 + "\n" }
        }.joined()
        try Data(text.utf8).write(to: traces.appending(path: "2026-02-01.jsonl"))
    }

    /// Builds a real `ProjectSession` over a throwaway directory and registers it.
    /// Returns the project's root path — what a metric record stores.
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
                             metricIndex: MetricIndex?) async throws -> ControlServerHarness {
        try await ControlServerHarness.start(token: token) {
            KiteloopControlServer(registry: registry, token: $0,
                                  metricStore: metricStore, metricIndex: metricIndex)
        }
    }
}
