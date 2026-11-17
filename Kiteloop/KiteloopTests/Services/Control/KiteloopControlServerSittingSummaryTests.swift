import XCTest
import KiteloopCore
@testable import Kiteloop

/// `GET /v1/autopilot/sitting-summary` and the inbox notice behind it: a
/// sitting that ended is read back off the run records, filed once in the
/// project's inbox and served until the next — answered in process through
/// `handle(_:)`.
@MainActor
final class KiteloopControlServerSittingSummaryTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var records: RunRecordStore!
    private var harness: ControlServerHarness!
    private let began = Date().addingTimeInterval(-3_600)

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-sitting")
        let registry = ControlSessionRegistry()
        let records = RunRecordStore(url: tempDir.appending(path: "control-runs.jsonl"))
        self.registry = registry
        self.records = records
        harness = try await ControlServerHarness.start { token in
            KiteloopControlServer(registry: registry, token: token, runRecords: records)
        }
    }

    override func tearDown() async throws {
        harness?.stop()
        harness = nil
        registry = nil
        records = nil
    }

    // MARK: - The endpoint

    func testBeforeAnySittingHasEndedItIsNotFound() async throws {
        _ = try registerProject(named: "alpha")

        let response = await harness.server.handle(request(project: "alpha"))

        XCTAssertEqual(response.status, 404)
    }

    func testWithoutAProjectItIsABadRequestAndAnUnopenedOneAConflict() async {
        let missing = await harness.server.handle(request(project: nil))
        let unopened = await harness.server.handle(request(project: "nowhere"))

        XCTAssertEqual(missing.status, 400)
        XCTAssertEqual(unopened.status, 409)
    }

    func testAnEndedSittingIsServedWithWhatLandedAndWhatStalled() async throws {
        let session = try registerProject(named: "alpha")
        let project = session.project.id
        records.upsert(record("landed", .done, project: project, at: 60, cost: 1.5))
        records.upsert(record("stuck", .blocked, project: project, at: 120, reason: "verify failed\nexit 65", cost: 0.5))
        records.upsert(record("refused", .didNotRun, project: project, at: 180, reason: "size is L"))
        records.upsert(record("waiting", .awaitingApproval, project: project, at: 240))
        records.upsert(record("elsewhere", .blocked, project: "/tmp/elsewhere", at: 300))

        await registry.sittingEnded?(project, began, Date())
        let response = await harness.server.handle(request(project: "alpha"))
        let body = json(response)

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(body["project"] as? String, project)
        XCTAssertEqual(body["summary"] as? String, "1 landed, 3 stalled, $2.00 spent")
        XCTAssertEqual(body["totalSpendUSD"] as? Double, 2.0)
        XCTAssertEqual(itemIDs(body["landed"]), ["landed"])
        XCTAssertEqual(itemIDs(body["blocked"]), ["stuck"])
        XCTAssertEqual(itemIDs(body["refusedAtPickup"]), ["refused"])
        XCTAssertEqual(itemIDs(body["atGate"]), ["waiting"])
        let blocked = try XCTUnwrap((body["blocked"] as? [[String: Any]])?.first)
        XCTAssertEqual(blocked["reason"] as? String, "verify failed")
        XCTAssertEqual(blocked["action"] as? String, SittingSummary.Stall.blocked.action)
    }

    // MARK: - The notice

    func testASittingWithAStallFilesOneActionableNotice() async throws {
        let session = try registerProject(named: "alpha")
        let project = session.project.id
        records.upsert(record("landed", .done, project: project, at: 60))
        records.upsert(record("stuck", .blocked, project: project, at: 120, reason: "verify failed"))

        await registry.sittingEnded?(project, began, Date())
        let notices = try await sittingNotices(in: session)

        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices.first?.type, .error)
        XCTAssertEqual(notices.first?.projectPath, session.project.rootURL.path(percentEncoded: false))
        XCTAssertTrue(notices.first?.body.contains("stuck: Title of stuck. verify failed.") == true)
    }

    func testASittingWhereEverythingLandedFilesAReport() async throws {
        let session = try registerProject(named: "alpha")
        records.upsert(record("landed", .done, project: session.project.id, at: 60))

        await registry.sittingEnded?(session.project.id, began, Date())
        let notices = try await sittingNotices(in: session)

        XCTAssertEqual(notices.map(\.type), [.complete])
    }

    func testASittingWithNoRecordsFilesNothingAndServesNothing() async throws {
        let session = try registerProject(named: "alpha")
        records.upsert(record("earlier", .blocked, project: session.project.id, at: -600, ended: -300))

        await registry.sittingEnded?(session.project.id, began, Date())
        let notices = try await sittingNotices(in: session)
        let response = await harness.server.handle(request(project: "alpha"))

        XCTAssertEqual(notices.count, 0)
        XCTAssertEqual(response.status, 404)
    }

    // MARK: - Helpers

    /// The sitting notices in the inbox, read once a marker filed after them
    /// has landed — so "none" is an observation rather than a race won.
    private func sittingNotices(in session: ProjectSession) async throws -> [NotificationItem] {
        session.orchestrator.notify(agentID: "", type: .event, title: "Marker", body: "")
        let pending = try await eventuallyValue("the marker to be filed") { () -> [NotificationItem]? in
            let pending = await session.orchestrator.notificationStore?.pending() ?? []
            return pending.contains { $0.title == "Marker" } ? pending : nil
        }
        return pending.filter { $0.title == SittingSummary.noticeTitle }
    }

    private func record(_ item: String, _ outcome: PersistedRunRecord.Outcome, project: String,
                        at offset: TimeInterval, ended: TimeInterval? = nil,
                        reason: String? = nil, cost: Double? = nil) -> PersistedRunRecord {
        PersistedRunRecord(runId: "run-\(item)", projectID: project, itemID: item, title: "Title of \(item)",
                           startedAt: began.addingTimeInterval(offset),
                           endedAt: began.addingTimeInterval(ended ?? offset + 30),
                           outcome: outcome, reason: reason, costUSD: cost)
    }

    private func itemIDs(_ rows: Any?) -> [String] {
        (rows as? [[String: Any]] ?? []).compactMap { $0["itemId"] as? String }
    }

    private func registerProject(named name: String) throws -> ProjectSession {
        let root = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootURL = URL(fileURLWithPath: root.path(percentEncoded: false), isDirectory: false)
        let project = KiteloopProject(rootURL: rootURL)
        try project.ensureDirectoryExists()
        try "# \(name) Backlog\n\n## Now\n\n".write(to: root.appending(path: "BACKLOG.md"),
                                                     atomically: true, encoding: .utf8)

        let runtime = MockAgentRuntime()
        let eventBus = EventBus(eventsURL: project.eventsURL)
        let orchestrator = Orchestrator(runtime: runtime, eventBus: eventBus,
                                        subscriptionEngine: SubscriptionEngine(eventBus: eventBus),
                                        memoryManager: MemoryManager(project: project))
        orchestrator.configureNotifications(notificationsURL: project.notificationsURL)
        let session = ProjectSession(
            project: project, projectURL: rootURL, orchestrator: orchestrator,
            sessionStore: SessionStore(projectDir: rootURL),
            knowledgeStore: AgentKnowledgeStore(baseURL: project.knowledgeURL),
            knowledgeIndex: KnowledgeIndex(baseURL: project.knowledgeURL),
            context: ProjectSessionContext(
                runtimeFactory: { runtime },
                agentCatalogStore: AgentCatalogStore(storageURL: tempDir.appendingPathComponent("catalog.json")),
                packageResolver: nil,
                globalConfigStore: GlobalConfigStore(storageURL: tempDir.appendingPathComponent("global.json")),
                orgManifestLoader: OrgManifestLoader(),
                repoCloneService: RepoCloneService()))
        registry.register(session: session, autopilot: BacklogAutopilot())
        return session
    }

    private func request(project: String?) -> HTTPServer.Request {
        HTTPServer.Request(method: "GET", path: "/v1/autopilot/sitting-summary",
                           query: project.map { ["project": $0] } ?? [:],
                           headers: ["authorization": "Bearer \(harness.token)"], body: Data())
    }

    private func json(_ response: HTTPServer.Response) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
    }
}
