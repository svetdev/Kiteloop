import XCTest
import KiteloopCore
@testable import Kiteloop

/// A configuration change made with the operator token or a scoped token is
/// held on a card until a person answers it, logged before it applies, and
/// answerable only with a person's credential. Driven in process, so a held
/// request is a task the test answers rather than a socket left open.
@MainActor
final class KiteloopControlServerConfigChangeGateTests: XCTestCase {

    private let token = "control-token-" + UUID().uuidString
    private let operatorToken = "operator-token-" + UUID().uuidString
    private var tempDir: URL!
    private var settings: GlobalConfigStore!
    private var scoped: ControlScopedTokens!
    private var devices: ControlDeviceTokens!
    private var defaults: UserDefaults!
    private var defaultsName: String!
    private var server: KiteloopControlServer!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-config-gate")
        settings = GlobalConfigStore(storageURL: tempDir.appending(path: "global.json"),
                                     secretStore: InMemoryConnectorSecretStore())
        scoped = ControlScopedTokens(url: tempDir.appending(path: "scoped.json"))
        devices = ControlDeviceTokens(url: tempDir.appending(path: "devices.json"))
        defaultsName = "control-config-gate-" + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        server = KiteloopControlServer(registry: ControlSessionRegistry(), token: token, operatorToken: operatorToken,
                                       deviceTokens: devices, scopedTokens: scoped)
        server.settings = settings
        server.defaults = defaults
        server.configChangeLogDirectory = tempDir
    }

    override func tearDown() async throws {
        server = nil
        defaults?.removePersistentDomain(forName: defaultsName)
    }

    // MARK: - Approve, decline

    func testAnOperatorsChangeAppliesOnlyOnceAPersonApprovesIt() async throws {
        let held = send("PUT", "/v1/settings", ["defaultModel": "opus"], bearer: operatorToken)
        let change = try await waitingChange()

        XCTAssertNil(settings.config.defaultModel, "nothing applies while the card waits")
        XCTAssertEqual(change.caller, "operator")
        XCTAssertEqual(change.route, "PUT /v1/settings")
        XCTAssertTrue(log().isEmpty)

        let answered = await answer(change.id, approve: true, bearer: token)
        let response = await held.value

        XCTAssertEqual(answered.status, 200)
        XCTAssertEqual(json(answered)["decision"] as? String, "approved")
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(json(response)["defaultModel"] as? String, "opus", "answered as the route answers today")
        XCTAssertEqual(settings.config.defaultModel, "opus")
        XCTAssertTrue(server.configChanges.waiting.isEmpty)
        XCTAssertEqual(log().map(\.decision), [.approved])
        XCTAssertEqual(log().first?.requestedBy, "operator")
        XCTAssertEqual(log().first?.tool, "PUT /v1/settings")
    }

    func testADeclinedChangeAnswers403AndChangesNothing() async throws {
        let held = send("PUT", "/v1/settings", ["defaultModel": "opus"], bearer: operatorToken)
        let change = try await waitingChange()

        let answered = await answer(change.id, approve: false, bearer: token)
        let response = await held.value

        XCTAssertEqual(json(answered)["decision"] as? String, "denied")
        XCTAssertEqual(response.status, 403)
        XCTAssertEqual(json(response)["error"] as? String, "declined by the person")
        XCTAssertNil(settings.config.defaultModel)
        XCTAssertEqual(log().map(\.decision), [.denied])
    }

    func testAScopedConfigureTokenIsHeldUnderItsOwnName() async throws {
        let ci = scoped.mint(name: "ci", scope: .configure).token
        let held = send("PUT", "/v1/settings", ["defaultModel": "opus"], bearer: ci)
        let change = try await waitingChange()

        XCTAssertEqual(change.caller, "ci (configure)")
        _ = await answer(change.id, approve: false, bearer: token)
        let response = await held.value
        XCTAssertEqual(response.status, 403)
    }

    /// A paired phone answers as the person does.
    func testAPairedPhoneAnswersTheCard() async throws {
        let phone = devices.pair(name: "iPhone").token
        let held = send("PUT", "/v1/settings", ["defaultModel": "opus"], bearer: operatorToken)
        let change = try await waitingChange()

        let answered = await answer(change.id, approve: true, bearer: phone)
        let response = await held.value

        XCTAssertEqual(answered.status, 200)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(settings.config.defaultModel, "opus")
    }

    // MARK: - Only a person answers

    func testNeitherTheOperatorNorAScopedTokenAnswersACard() async throws {
        let ci = scoped.mint(name: "ci", scope: .configure).token
        let held = send("PUT", "/v1/settings", ["defaultModel": "opus"], bearer: operatorToken)
        let change = try await waitingChange()

        for bearer in [operatorToken, ci] {
            let refused = await answer(change.id, approve: true, bearer: bearer)
            XCTAssertEqual(refused.status, 403)
        }
        XCTAssertEqual(server.configChanges.waiting.map(\.id), [change.id], "the card is still waiting")
        XCTAssertNil(settings.config.defaultModel)
        XCTAssertTrue(log().isEmpty)

        _ = await answer(change.id, approve: false, bearer: token)
        _ = await held.value
    }

    func testAnswersThatNameNoChangeOrNoDecisionAreRefused() async throws {
        let unknown = await answer("no-such-change", approve: true, bearer: token)
        XCTAssertEqual(unknown.status, 404)

        let held = send("PUT", "/v1/settings", ["defaultModel": "opus"], bearer: operatorToken)
        let change = try await waitingChange()
        let undecided = await server.handle(request("POST", "/v1/config-changes/\(change.id)/answer", [:], bearer: token))
        XCTAssertEqual(undecided.status, 400)
        XCTAssertEqual(server.configChanges.waiting.count, 1)

        _ = await answer(change.id, approve: false, bearer: token)
        _ = await held.value
    }

    // MARK: - The person is never held

    func testThePersonsOwnTokenAndAPairedPhoneApplyAtOnce() async throws {
        let phone = devices.pair(name: "iPhone").token

        let own = await server.handle(request("PUT", "/v1/settings", ["defaultModel": "opus"], bearer: token))
        let paired = await server.handle(request("PUT", "/v1/settings", ["defaultEffort": "high"], bearer: phone))

        XCTAssertEqual(own.status, 200)
        XCTAssertEqual(paired.status, 200)
        XCTAssertEqual(settings.config.defaultModel, "opus")
        XCTAssertEqual(settings.config.defaultEffort, "high")
        XCTAssertTrue(server.configChanges.waiting.isEmpty)
        XCTAssertTrue(log().isEmpty, "a person's own change is not a held one")
    }

    func testAnOperatorsReadIsNotHeld() async throws {
        let response = await server.handle(request("GET", "/v1/settings", [:], bearer: operatorToken))

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(json(response)["agentAPIChangesNeedApproval"] as? Bool, true, "on unless switched off")
        XCTAssertTrue(server.configChanges.waiting.isEmpty)
    }

    // MARK: - The switch

    func testWithTheGateOffAnOperatorsChangeAppliesAtOnce() async throws {
        settings.setAgentAPIChangesNeedApproval(false)

        let response = await server.handle(request("PUT", "/v1/settings", ["defaultModel": "opus"], bearer: operatorToken))

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(json(response)["agentAPIChangesNeedApproval"] as? Bool, false)
        XCTAssertEqual(settings.config.defaultModel, "opus")
        XCTAssertTrue(server.configChanges.waiting.isEmpty)
    }

    /// The token the gate holds cannot switch the gate off: that call is a
    /// configuration change like any other, and waits on the same card.
    func testAnOperatorCannotSwitchTheGateOffWithoutTheCard() async throws {
        let held = send("PUT", "/v1/settings", ["agentAPIChangesNeedApproval": false], bearer: operatorToken)
        let change = try await waitingChange()

        XCTAssertTrue(ConfigChangeEndpoints(server: server).holdsAgentChanges)
        _ = await answer(change.id, approve: false, bearer: token)
        let response = await held.value

        XCTAssertEqual(response.status, 403)
        XCTAssertTrue(ConfigChangeEndpoints(server: server).holdsAgentChanges)
        XCTAssertNil(settings.config.agentAPIChangesNeedApproval)
    }

    func testThePersonSwitchesTheGateOffAndOnOverTheAPI() async throws {
        let off = await server.handle(request("PUT", "/v1/settings", ["agentAPIChangesNeedApproval": false], bearer: token))
        XCTAssertEqual(json(off)["agentAPIChangesNeedApproval"] as? Bool, false)
        XCTAssertFalse(ConfigChangeEndpoints(server: server).holdsAgentChanges)

        let on = await server.handle(request("PUT", "/v1/settings", ["agentAPIChangesNeedApproval": true], bearer: token))
        XCTAssertEqual(json(on)["agentAPIChangesNeedApproval"] as? Bool, true)
        XCTAssertTrue(ConfigChangeEndpoints(server: server).holdsAgentChanges)

        let mistyped = await server.handle(request("PUT", "/v1/settings", ["agentAPIChangesNeedApproval": "no"], bearer: token))
        XCTAssertEqual(mistyped.status, 400)
    }

    // MARK: - Secrets

    func testSecretsAreOnNeitherTheCardNorTheAttentionListNorTheLog() async throws {
        let held = send("PUT", "/v1/mcp-servers/tracker",
                        ["command": "npx", "env": ["TRACKER_TOKEN": "s3cret-value"]], bearer: operatorToken)
        let change = try await waitingChange()

        XCTAssertFalse(change.summary.contains("s3cret-value"))
        XCTAssertTrue(change.summary.contains("TRACKER_TOKEN"), "the name stays, so the card says what is set")
        let attention = await server.handle(request("GET", "/v1/attention", [:], bearer: token))
        let listed = String(decoding: attention.body, as: UTF8.self)
        XCTAssertFalse(listed.contains("s3cret-value"))
        let row = try XCTUnwrap((json(attention)["rows"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["kind"] as? String, "configChange")
        XCTAssertEqual(row["caller"] as? String, "operator")
        XCTAssertEqual((row["answer"] as? [String: String])?["path"], "/v1/config-changes/\(change.id)/answer")

        _ = await answer(change.id, approve: true, bearer: token)
        let response = await held.value

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(settings.config.mcpServers?["tracker"]?.env?["TRACKER_TOKEN"], "s3cret-value",
                       "the change itself is applied whole")
        let logged = try String(contentsOf: ConfigChangeLog.url(appDirectory: tempDir), encoding: .utf8)
        XCTAssertFalse(logged.contains("s3cret-value"))
        XCTAssertTrue(logged.contains("TRACKER_TOKEN"))
    }

    // MARK: - Unrecorded, abandoned

    /// An approval whose log line cannot be written is refused to both sides,
    /// and the change is not applied.
    func testAnApprovalThatCannotBeLoggedIsRefusedAndNothingApplies() async throws {
        let blocker = tempDir.appending(path: "not-a-directory")
        try Data("x".utf8).write(to: blocker)
        server.configChangeLogDirectory = blocker
        let held = send("PUT", "/v1/settings", ["defaultModel": "opus"], bearer: operatorToken)
        let change = try await waitingChange()

        let answered = await answer(change.id, approve: true, bearer: token)
        let response = await held.value

        XCTAssertEqual(answered.status, 500)
        XCTAssertEqual(response.status, 500)
        XCTAssertTrue((json(response)["error"] as? String ?? "").contains("could not be written to the change log"))
        XCTAssertNil(settings.config.defaultModel)
        XCTAssertTrue(server.configChanges.waiting.isEmpty)
    }

    /// A caller that hangs up leaves its card; answering it applies nothing
    /// and is logged as abandoned.
    func testACardWhoseCallerHungUpAppliesNothing() async throws {
        let hangUp = HangUp()
        var asked = request("PUT", "/v1/settings", ["defaultModel": "opus"], bearer: operatorToken)
        asked.whenClientGone = { hangUp.register($0) }
        let server = server!
        let held = Task { await server.handle(asked) }
        let change = try await waitingChange()

        hangUp.fire()
        _ = await held.value

        XCTAssertEqual(server.configChanges.waiting.map(\.id), [change.id], "the card stays")
        XCTAssertEqual(server.configChanges.waiting.first?.callerGone, true)

        let answered = await answer(change.id, approve: true, bearer: token)

        XCTAssertEqual(json(answered)["decision"] as? String, "abandoned")
        XCTAssertNil(settings.config.defaultModel)
        XCTAssertEqual(log().map(\.decision), [.abandoned])
        XCTAssertTrue(server.configChanges.waiting.isEmpty)
    }

    // MARK: - Helpers

    private func request(_ method: String, _ path: String, _ body: [String: Any],
                         bearer: String) -> HTTPServer.Request {
        let data = body.isEmpty ? Data() : (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        return HTTPServer.Request(method: method, path: path, query: [:],
                                  headers: ["authorization": "Bearer \(bearer)"], body: data)
    }

    /// Sends a request that is expected to be held, as a task to await later.
    private func send(_ method: String, _ path: String, _ body: [String: Any],
                      bearer: String) -> Task<HTTPServer.Response, Never> {
        let server = server!
        let asked = request(method, path, body, bearer: bearer)
        return Task { await server.handle(asked) }
    }

    private func waitingChange() async throws -> HeldConfigChange {
        let server = server!
        try await eventually("the change to be waiting on a card") { !server.configChanges.waiting.isEmpty }
        return try XCTUnwrap(server.configChanges.waiting.first)
    }

    private func answer(_ id: String, approve: Bool, bearer: String) async -> HTTPServer.Response {
        await server.handle(request("POST", "/v1/config-changes/\(id)/answer", ["approve": approve], bearer: bearer))
    }

    private func log() -> [ConfigChangeLog.Record] {
        ConfigChangeLog.read(from: ConfigChangeLog.url(appDirectory: tempDir))
    }

    private func json(_ response: HTTPServer.Response) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
    }
}

/// Stands in for the socket's "client has gone" signal.
private final class HangUp: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [@Sendable () -> Void] = []

    func register(_ handler: @escaping @Sendable () -> Void) {
        lock.lock(); defer { lock.unlock() }
        handlers.append(handler)
    }

    func fire() {
        lock.lock()
        let registered = handlers
        handlers = []
        lock.unlock()
        for handler in registered { handler() }
    }
}
