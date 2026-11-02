import XCTest
import KiteloopCore
@testable import Kiteloop

/// `GET /v1/backlog` — specifically the `issues` half of the response.
///
/// A line the parser cannot read is absent from `items` with nothing else to
/// show for it, so a headless driver used to see a shorter backlog than the file
/// holds and take the difference for work that does not exist. The panel has
/// banners for it; these tests hold the API to the same account, over a real
/// loopback socket and a real `BacklogViewModel` reading a real file.
@MainActor
final class KiteloopControlServerBacklogListTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var harness: ControlServerHarness!
    private let token = "control-backlog-list-token-" + UUID().uuidString

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-backlog-list")
        registry = ControlSessionRegistry()
        harness = try await ControlServerHarness.start(registry: registry, token: token)
    }

    override func tearDown() async throws {
        harness?.stop()
        harness = nil
        registry = nil
    }

    // MARK: - The rejected lines are reported

    /// The defect itself: a typo'd checkbox makes an item vanish from `items`,
    /// and the response has to say so rather than just being one shorter.
    func testARejectedLineIsReportedWithItsLineNumberTextAndReason() async throws {
        try registerProject(named: "alpha", items: [
            "- [ ] item-1 | A line the parser reads | ready",
            "- [~] item-2 | A line it does not | ready"
        ])

        let (status, body) = try await harness.get("/v1/backlog?project=alpha")

        XCTAssertEqual(status, 200)
        let issues = try XCTUnwrap(body["issues"] as? [[String: Any]])
        XCTAssertEqual(issues.count, 1)
        let issue = try XCTUnwrap(issues.first)
        // Line 1 is the title, 3 the heading, 5 and 6 the items — see the fixture.
        XCTAssertEqual(issue["line"] as? Int, 6)
        XCTAssertEqual(issue["text"] as? String, "- [~] item-2 | A line it does not | ready")
        XCTAssertEqual(issue["reason"] as? String, "Unrecognized checkbox `[~]` — use `[ ]` or `[x]`.")

        // And the point of reporting it: the id is nowhere in the item list, so
        // a driver counting queue depth off `items` alone would be short one.
        let ids = items(body).compactMap { $0["id"] as? String }
        XCTAssertEqual(ids, ["item-1"])
    }

    /// `issues` is present on a clean file too. An omitted field is ambiguous —
    /// it reads the same as a build too old to report any.
    func testACleanBacklogReportsAnEmptyIssuesArrayRatherThanOmittingIt() async throws {
        try registerProject(named: "alpha", items: [
            "- [ ] item-1 | Perfectly ordinary | ready"
        ])

        let (status, body) = try await harness.get("/v1/backlog?project=alpha")

        XCTAssertEqual(status, 200)
        let issues = try XCTUnwrap(body["issues"] as? [[String: Any]],
                                   "issues must be present, not omitted, on a clean file")
        XCTAssertTrue(issues.isEmpty, "\(issues)")
        XCTAssertEqual(items(body).count, 1)
    }

    /// Not every issue costs an item: a line that parsed but carried a field the
    /// parser dropped is reported *and* still appears in `items`. A driver that
    /// treated `issues` as "missing work" would otherwise double-count it.
    func testALineThatParsedDespiteAnIssueStillAppearsInItems() async throws {
        try registerProject(named: "alpha", items: [
            "- [ ] item-1 | Carries a field nothing reads | ready | wat: nonsense"
        ])

        let (_, body) = try await harness.get("/v1/backlog?project=alpha")

        let issues = try XCTUnwrap(body["issues"] as? [[String: Any]])
        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue((issues.first?["reason"] as? String ?? "").contains("Unrecognised field `wat: nonsense`"),
                      "\(issues)")
        XCTAssertEqual(items(body).compactMap { $0["id"] as? String }, ["item-1"])
    }

    /// Every rejected line is reported, not just the first — a file edited badly
    /// once is usually a file edited badly twice.
    func testEveryRejectedLineIsReportedInFileOrder() async throws {
        try registerProject(named: "alpha", items: [
            "- [~] item-1 | Bad checkbox | ready",
            "- [ ] item-2 | Fine | ready",
            "- [] item-3 | No space in the checkbox | ready"
        ])

        let (_, body) = try await harness.get("/v1/backlog?project=alpha")

        let issues = try XCTUnwrap(body["issues"] as? [[String: Any]])
        XCTAssertEqual(issues.compactMap { $0["line"] as? Int }, [5, 7])
        XCTAssertEqual(items(body).compactMap { $0["id"] as? String }, ["item-2"])
    }

    /// The wording belongs to the parser, not to the handler: a reason reworded
    /// in `BacklogParser` has to reach a driver without anyone editing the
    /// endpoint. This is the same list the panel banners.
    func testIssuesAreTheViewModelsOwnParseIssues() async throws {
        let backlog = try registerProject(named: "alpha", items: [
            "- [?] item-1 | Not readable | ready"
        ])

        let (_, body) = try await harness.get("/v1/backlog?project=alpha")

        let issues = try XCTUnwrap(body["issues"] as? [[String: Any]])
        XCTAssertEqual(issues.count, backlog.parseIssues.count)
        for (reported, known) in zip(issues, backlog.parseIssues) {
            XCTAssertEqual(reported["line"] as? Int, known.line)
            XCTAssertEqual(reported["text"] as? String, known.text)
            XCTAssertEqual(reported["reason"] as? String, known.reason)
        }
    }

    // MARK: - Errors

    func testMissingProjectIs400() async throws {
        let (status, body) = try await harness.get("/v1/backlog")

        XCTAssertEqual(status, 400)
        XCTAssertEqual(body["error"] as? String, "Missing ?project=")
    }

    func testUnknownProjectIs409() async throws {
        try registerProject(named: "alpha", items: ["- [ ] item-1 | Fine | ready"])

        let (status, body) = try await harness.get("/v1/backlog?project=beta")

        XCTAssertEqual(status, 409)
        XCTAssertEqual(body["error"] as? String, "Project not open in Kiteloop: beta")
    }

    func testRequiresBearerToken() async throws {
        try registerProject(named: "alpha", items: ["- [~] item-1 | Bad checkbox | ready"])

        let (status, body) = try await harness.get("/v1/backlog?project=alpha", bearer: nil)

        XCTAssertEqual(status, 401)
        XCTAssertEqual(body["error"] as? String, "Missing or invalid bearer token")
        XCTAssertNil(body["issues"], "an unauthenticated caller learns nothing about the file")
    }

    // MARK: - Helpers

    private func items(_ body: [String: Any]) -> [[String: Any]] {
        body["items"] as? [[String: Any]] ?? []
    }

    /// Builds a real `ProjectSession` over a throwaway directory. BACKLOG.md is
    /// written first so the session parses it on init the way the app does — the
    /// issues under test are the parser's, not a fixture's.
    ///
    /// The layout is fixed, and the tests above count on it: line 1 is the
    /// title, line 3 the `## Now` heading, and the items start at line 5.
    @discardableResult
    private func registerProject(named name: String, items: [String]) throws -> BacklogViewModel {
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
        registry.register(session: session, autopilot: BacklogAutopilot())
        return session.backlogViewModel
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
