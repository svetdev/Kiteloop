import XCTest
import KiteloopCore
@testable import Kiteloop

/// A scoped control token: accepted on the routes its scope includes, refused
/// with a 403 naming the scope it lacks everywhere else, never on a human
/// gate, never on `/v1/tokens` — and minted, listed and revoked there by the
/// control token alone.
@MainActor
final class KiteloopControlServerScopedTokenTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var tokens: ControlScopedTokens!
    private var devices: ControlDeviceTokens!
    private var harness: ControlServerHarness!
    private let operatorToken = "operator-scoped-test-token-" + UUID().uuidString

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-scoped-tokens")
        let registry = ControlSessionRegistry()
        let tokens = ControlScopedTokens(url: tempDir.appending(path: "control-scoped-tokens.json"))
        let devices = ControlDeviceTokens(url: tempDir.appending(path: "control-devices.json"))
        let operatorToken = operatorToken
        self.registry = registry
        self.tokens = tokens
        self.devices = devices
        harness = try await ControlServerHarness.start { token in
            KiteloopControlServer(registry: registry, token: token, operatorToken: operatorToken,
                                  deviceTokens: devices, scopedTokens: tokens)
        }
    }

    override func tearDown() async throws {
        harness?.stop()
        harness = nil
        registry = nil
    }

    // MARK: - Scope

    func testAReadTokenReadsTheBacklogAndCannotStartARun() async throws {
        try registerProject(named: "alpha")
        let read = tokens.mint(name: "dashboard", scope: .read).token

        let (listed, _) = try await harness.get("/v1/backlog?project=alpha", bearer: read)
        XCTAssertEqual(listed, 200)

        let (started, body) = try await harness.post("/v1/runs", ["project": "alpha", "item": "x"], bearer: read)
        XCTAssertEqual(started, 403)
        let error = try XCTUnwrap(body["error"] as? String)
        XCTAssertTrue(error.contains("scope is read"), error)
        XCTAssertTrue(error.contains("needs operate"), error)
    }

    func testAnOperateTokenCannotConfigure() async throws {
        let operate = tokens.mint(name: "ci", scope: .operate).token

        let (status, body) = try await harness.put("/v1/autopilot", ["project": "alpha"], bearer: operate)

        XCTAssertEqual(status, 403)
        XCTAssertTrue((body["error"] as? String ?? "").contains("needs configure"), "\(body)")
    }

    func testNoScopedTokenResolvesTheHumanGate() async throws {
        for scope in ControlScope.allCases {
            let token = tokens.mint(name: scope.rawValue, scope: scope).token

            let (status, _) = try await harness.post("/v1/backlog/approve",
                                                     ["project": "alpha", "item": "x", "approve": true], bearer: token)

            XCTAssertEqual(status, 403, "a \(scope.rawValue) token reached the gate")
        }
    }

    func testARevokedTokenIsUnauthorized() async throws {
        let (token, entry) = tokens.mint(name: "gone", scope: .configure)
        tokens.revoke(entry.id)

        let (status, _) = try await harness.get("/v1/projects", bearer: token)

        XCTAssertEqual(status, 401)
    }

    // MARK: - /v1/tokens

    func testOnlyTheControlTokenMintsATokenAndItWorks() async throws {
        let scoped = tokens.mint(name: "wide", scope: .configure).token
        let phone = devices.pair(name: "iPhone").token
        for bearer in [scoped, operatorToken, phone] {
            let (status, _) = try await harness.post("/v1/tokens", ["name": "wider", "scope": "configure"], bearer: bearer)
            XCTAssertEqual(status, 403)
        }

        let (status, body) = try await harness.post("/v1/tokens", ["name": "reader", "scope": "read"])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["scope"] as? String, "read")
        let minted = try XCTUnwrap(body["token"] as? String)
        let (reads, _) = try await harness.get("/v1/projects", bearer: minted)
        XCTAssertEqual(reads, 200)
    }

    func testAMintWithAnUnknownScopeIsRefused() async throws {
        let (status, _) = try await harness.post("/v1/tokens", ["name": "x", "scope": "admin"])
        XCTAssertEqual(status, 400)
    }

    func testTheListNamesEachTokenAndNeverItsHash() async throws {
        let (token, entry) = tokens.mint(name: "dashboard", scope: .read)

        let (status, body) = try await harness.get("/v1/tokens")

        XCTAssertEqual(status, 200)
        let listed = try XCTUnwrap((body["tokens"] as? [[String: Any]])?.first)
        XCTAssertEqual(listed["id"] as? String, entry.id.uuidString)
        XCTAssertEqual(listed["name"] as? String, "dashboard")
        XCTAssertEqual(listed["scope"] as? String, "read")
        XCTAssertNotNil(listed["createdAt"] as? String)
        XCTAssertNil(listed["tokenHash"])
        XCTAssertFalse("\(body)".contains(token))
    }

    func testRevokingOverTheAPIStopsTheToken() async throws {
        let (token, entry) = tokens.mint(name: "gone", scope: .read)

        let (revoked, _) = try await harness.send("/v1/tokens/\(entry.id.uuidString)", method: "DELETE",
                                                  body: [:], bearer: harness.token)
        XCTAssertEqual(revoked, 200)
        let (again, _) = try await harness.send("/v1/tokens/\(entry.id.uuidString)", method: "DELETE",
                                                body: [:], bearer: harness.token)
        XCTAssertEqual(again, 404)

        let (status, _) = try await harness.get("/v1/projects", bearer: token)
        XCTAssertEqual(status, 401)
    }

    // MARK: - Helpers

    private func registerProject(named name: String) throws {
        let root = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootURL = URL(fileURLWithPath: root.path(percentEncoded: false), isDirectory: false)
        let project = KiteloopProject(rootURL: rootURL)
        try project.ensureDirectoryExists()
        try "# \(name) Backlog\n\n## Now\n\n- [ ] item-1 | One item | ready\n"
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
            context: ProjectSessionContext(
                runtimeFactory: { MockAgentRuntime() },
                agentCatalogStore: AgentCatalogStore(storageURL: tempDir.appendingPathComponent("catalog.json")),
                packageResolver: nil,
                globalConfigStore: GlobalConfigStore(storageURL: tempDir.appendingPathComponent("global.json")),
                orgManifestLoader: OrgManifestLoader(),
                repoCloneService: RepoCloneService()
            )
        )
        registry.register(session: session, autopilot: BacklogAutopilot())
    }
}
