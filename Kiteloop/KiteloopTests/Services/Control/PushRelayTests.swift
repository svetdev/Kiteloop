import CryptoKit
import XCTest
import KiteloopCore
@testable import Kiteloop

/// The Mac telling the phone: which notices become pushes, that each one goes
/// to every registered phone signed with the key from Settings, that a token
/// Apple calls dead is forgotten, and that with no key nothing is sent. The
/// transport is scripted — no request leaves the machine.
@MainActor
final class PushRelayTests: XCTestCase {

    private var tempDir: URL!
    private var relay: PushRelay!
    private var devices: PushDeviceStore!
    private var key: PushKeyConfig?
    private let sent = SentRequests()

    final class SentRequests: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        var status = 200
        var body = Data()
        func record(_ request: URLRequest) { lock.withLock { requests.append(request) } }
        var all: [URLRequest] { lock.withLock { requests } }
    }

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "push-relay")
        let keyURL = tempDir.appending(path: "AuthKey_TEST.p8")
        try P256.Signing.PrivateKey().pemRepresentation.write(to: keyURL, atomically: true, encoding: .utf8)
        key = PushKeyConfig(keyPath: keyURL.path(percentEncoded: false), keyID: "KEY1234567", teamID: "TEAM123456")
        devices = PushDeviceStore(url: tempDir.appending(path: "push-devices.json"))
        relay = PushRelay()
        relay.configure(devices: devices, key: { [unowned self] in key })
        let sent = sent
        relay.transport = { request in
            sent.record(request)
            return (sent.status, sent.body)
        }
    }

    private func register(_ token: String) async {
        await devices.register(PushDevice(token: token, environment: .sandbox, name: "iPhone", registeredAt: .now))
    }

    func testAPushGoesToEveryRegisteredPhoneSignedForThePhoneApp() async {
        await register("aa11")
        await register("bb22")

        let delivered = await relay.send(title: "Builder finished", body: "All tests pass", info: ["kind": "finished"])

        XCTAssertEqual(delivered, 2)
        XCTAssertEqual(sent.all.compactMap { $0.url?.lastPathComponent }, ["aa11", "bb22"])
        XCTAssertTrue(sent.all.allSatisfy { $0.value(forHTTPHeaderField: "authorization")?.hasPrefix("bearer ") == true })
        XCTAssertNil(relay.problem)
    }

    func testATokenApplesCallsDeadIsForgotten() async {
        await register("aa11")
        sent.status = 410

        _ = await relay.send(title: "t", body: "b", info: [:])

        let remaining = await devices.all()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testWithNoKeyNothingIsSentAndSettingsIsToldWhy() async {
        await register("aa11")
        key = nil
        relay.keyChanged()

        let delivered = await relay.send(title: "t", body: "b", info: [:])

        XCTAssertEqual(delivered, 0)
        XCTAssertTrue(sent.all.isEmpty)
        XCTAssertEqual(relay.problem, "No push key is set, so phones get no notifications.")
    }

    func testAnUnreadableKeyFileIsNamed() {
        key = PushKeyConfig(keyPath: "/nowhere/AuthKey.p8", keyID: "k", teamID: "t")
        relay.keyChanged()

        XCTAssertTrue(relay.problem?.contains("no readable key file") == true, relay.problem ?? "")
    }

    func testALiveActivityIsMovedOnWithALiveActivityPushAndForgottenWhenItEnds() async throws {
        relay.registerActivity(token: "cafe", environment: .production, project: "alpha", agent: "b1")

        relay.updateActivity(project: "alpha", agent: "b1", working: false, status: "Waiting for your answer",
                             line: "Keep it?", ends: false)
        try await eventually("the update went out") { self.sent.all.count == 1 }
        let update = try XCTUnwrap(sent.all.first)
        XCTAssertEqual(update.value(forHTTPHeaderField: "apns-push-type"), "liveactivity")
        XCTAssertEqual(update.url?.lastPathComponent, "cafe")
        XCTAssertEqual(relay.activityCount, 1, "waiting keeps the activity")

        relay.updateActivity(project: "alpha", agent: "b1", working: false, status: "Done", line: "", ends: true)
        try await eventually("the end went out") { self.sent.all.count == 2 }
        XCTAssertEqual(relay.activityCount, 0)
    }

    func testAnAgentWithNoActivitySendsNothing() {
        relay.updateActivity(project: "alpha", agent: "nobody", working: false, status: "Done", line: "", ends: true)
        XCTAssertTrue(sent.all.isEmpty)
    }

    func testAGateAQuestionAndAFinishBecomePushesAndAnErrorDoesNot() throws {
        let gate = NotificationItem(agentID: "w1", type: .approval, title: "Approval needed", body: "item-7",
                                    itemID: "item-7", projectPath: "/Users/me/alpha")
        let push = try XCTUnwrap(PushRelay.push(for: gate))
        XCTAssertEqual(push.info, ["kind": "approval", "project": "alpha", "agent": "w1", "item": "item-7"])

        let question = NotificationItem(agentID: "b1", type: .question, title: "Builder needs input", body: "Keep it?")
        XCTAssertEqual(PushRelay.push(for: question)?.info["kind"], "question")
        let done = NotificationItem(agentID: "", type: .complete, title: "Agents finished", body: "…")
        XCTAssertEqual(PushRelay.push(for: done)?.info["kind"], "finished")
        XCTAssertNil(PushRelay.push(for: NotificationItem(agentID: "", type: .error, title: "x", body: "y")))
    }
}

/// `POST /v1/devices/push` refusing what is not a push token. The shared relay
/// is never configured under tests (the app's bootstrap is skipped), so a
/// registration is refused rather than written into the developer's own file.
@MainActor
final class KiteloopControlServerPushDeviceTests: XCTestCase {
    private var harness: ControlServerHarness!

    override func setUp() async throws {
        harness = try await ControlServerHarness.start()
    }

    override func tearDown() async throws {
        harness?.stop()
        harness = nil
    }

    func testATokenThatIsNotHexIs400() async throws {
        let (status, _) = try await harness.post("/v1/devices/push", ["token": "not-hex!", "environment": "sandbox"])
        XCTAssertEqual(status, 400)
    }

    func testAnUnknownEnvironmentIs400() async throws {
        let (status, _) = try await harness.post("/v1/devices/push", ["token": "aa11", "environment": "staging"])
        XCTAssertEqual(status, 400)
    }

    func testALiveActivityWithoutItsAgentIs400() async throws {
        let (status, _) = try await harness.post("/v1/devices/activity",
                                                 ["token": "aa11", "environment": "sandbox", "project": "alpha"])
        XCTAssertEqual(status, 400)
    }

    func testWithPushesNotSetUpARegistrationIsRefused() async throws {
        let (status, _) = try await harness.post("/v1/devices/push", ["token": "aa11", "environment": "sandbox"])
        XCTAssertEqual(status, 503)
    }
}
