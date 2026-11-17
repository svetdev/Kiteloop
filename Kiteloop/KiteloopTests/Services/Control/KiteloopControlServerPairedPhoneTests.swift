import XCTest
import KiteloopCore
@testable import Kiteloop

/// A token per paired phone: it opens every endpoint the control token does,
/// a revoked one is refused, and revoking one phone leaves the others and the
/// control token working.
@MainActor
final class KiteloopControlServerPairedPhoneTests: XCTestCase {
    private var harness: ControlServerHarness!
    private var devices: ControlDeviceTokens!

    override func setUp() async throws {
        let dir = try makeTemporaryDirectory(prefix: "control-paired-phones")
        let devices = ControlDeviceTokens(url: dir.appending(path: "control-devices.json"))
        self.devices = devices
        harness = try await ControlServerHarness.start { token in
            KiteloopControlServer(registry: ControlSessionRegistry(), token: token, deviceTokens: devices)
        }
    }

    override func tearDown() async throws {
        harness?.stop()
        harness = nil
    }

    func testAPairedPhonesTokenAuthorizesRequests() async throws {
        let token = devices.pair(name: "Work iPhone").token

        let (status, _) = try await harness.get("/v1/projects", bearer: token)

        XCTAssertEqual(status, 200)
    }

    func testARevokedPhoneIsRefusedAndTheOthersAreNot() async throws {
        let lost = devices.pair(name: "Lost").token
        let kept = devices.pair(name: "Kept").token
        let lostID = try XCTUnwrap(harness.server.pairedPhones.first { $0.name == "Lost" }?.id)

        harness.server.revokePhone(lostID)

        let (refused, _) = try await harness.get("/v1/projects", bearer: lost)
        XCTAssertEqual(refused, 401)
        let (allowed, _) = try await harness.get("/v1/projects", bearer: kept)
        XCTAssertEqual(allowed, 200)
        let (control, _) = try await harness.get("/v1/projects")
        XCTAssertEqual(control, 200, "the control token is untouched by a revoke")
    }

    func testATokenNoPhoneHoldsIsRefused() async throws {
        let (status, _) = try await harness.get("/v1/projects", bearer: "0123456789abcdef")
        XCTAssertEqual(status, 401)
    }

    func testAPhonesTokenReachesTheHumanGateTheOperatorTokenCannot() async throws {
        let token = devices.pair(name: "iPhone").token

        // No such item, so the gate answers 4xx from the handler — not the
        // 403 the operator token gets before any handler runs.
        let (status, body) = try await harness.post("/v1/backlog/approve",
                                                    ["project": "nope", "item": "x", "approve": true], bearer: token)

        XCTAssertNotEqual(status, 403, body["error"] as? String ?? "")
        XCTAssertNotEqual(status, 401)
    }
}

/// The pairing QR's one-time code: traded without a bearer token for a
/// phone's own token, once, only while the sheet showing it is open, and
/// only after the person allows the device on that sheet.
@MainActor
final class KiteloopControlServerPairingCodeTests: XCTestCase {
    private var harness: ControlServerHarness!
    private var devices: ControlDeviceTokens!

    override func setUp() async throws {
        let dir = try makeTemporaryDirectory(prefix: "control-pairing-codes")
        let devices = ControlDeviceTokens(url: dir.appending(path: "control-devices.json"))
        self.devices = devices
        harness = try await ControlServerHarness.start { token in
            KiteloopControlServer(registry: ControlSessionRegistry(), token: token, deviceTokens: devices)
        }
    }

    override func tearDown() async throws {
        harness?.stop()
        harness = nil
    }

    /// Sends `code` as a phone would and waits until the sheet has its request.
    /// The task answers with the status and the token, if one was issued.
    private func send(_ code: String, name: String = "Work iPhone") async throws -> Task<(Int, String?), Error> {
        let harness = harness!
        let claim = Task { () -> (Int, String?) in
            let (status, body) = try await harness.post("/v1/pair", ["code": code, "name": name], bearer: nil)
            return (status, body["token"] as? String)
        }
        try await eventually("the device to be waiting on the sheet") {
            harness.server.pairingRequests.waiting[code]?.name == name
        }
        return claim
    }

    func testACodeOnOfferTradesForATokenOnceThePersonAllowsIt() async throws {
        let code = try XCTUnwrap(harness.server.offerPairingCode())
        let claim = try await send(code)
        XCTAssertTrue(harness.server.pairedPhones.isEmpty, "the code alone pairs nothing")

        harness.server.answerPairingRequest(code: code, allow: true)

        let (status, issued) = try await claim.value
        XCTAssertEqual(status, 200)
        let token = try XCTUnwrap(issued)
        let (projects, _) = try await harness.get("/v1/projects", bearer: token)
        XCTAssertEqual(projects, 200)
        XCTAssertEqual(harness.server.pairedPhones.map(\.name), ["Work iPhone"])
        XCTAssertEqual(harness.server.pairingClaims[code], "Work iPhone", "the sheet can say the code was used")
    }

    func testADeclinedDeviceGetsNoTokenAndLeavesNoPhoneBehind() async throws {
        let code = try XCTUnwrap(harness.server.offerPairingCode())
        let claim = try await send(code)

        harness.server.answerPairingRequest(code: code, allow: false)

        let (status, issued) = try await claim.value
        XCTAssertEqual(status, 403)
        XCTAssertNil(issued)
        XCTAssertTrue(harness.server.pairedPhones.isEmpty)
    }

    func testTwoDevicesSendingOneCodePairNeitherAndSpendTheCode() async throws {
        let code = try XCTUnwrap(harness.server.offerPairingCode())
        let first = try await send(code, name: "Someone quicker")

        let (second, _) = try await harness.post("/v1/pair", ["code": code, "name": "Work iPhone"], bearer: nil)

        let (firstStatus, _) = try await first.value
        XCTAssertEqual(firstStatus, 409)
        XCTAssertEqual(second, 409)
        XCTAssertTrue(harness.server.pairedPhones.isEmpty)
        XCTAssertTrue(harness.server.pairingRequests.contested.contains(code), "the sheet can say so")
        let (third, _) = try await harness.post("/v1/pair", ["code": code], bearer: nil)
        XCTAssertEqual(third, 403, "the code is withdrawn")
    }

    func testClosingTheSheetEndsAWaitingRequestWithoutPairing() async throws {
        let code = try XCTUnwrap(harness.server.offerPairingCode())
        let claim = try await send(code)

        harness.server.withdrawPairingCode(code)

        let (status, _) = try await claim.value
        XCTAssertEqual(status, 403)
        XCTAssertTrue(harness.server.pairedPhones.isEmpty)
    }

    func testAUsedCodeIsRefused() async throws {
        let code = try XCTUnwrap(harness.server.offerPairingCode())
        let claim = try await send(code)
        harness.server.answerPairingRequest(code: code, allow: true)
        _ = try await claim.value

        let (status, _) = try await harness.post("/v1/pair", ["code": code], bearer: nil)

        XCTAssertEqual(status, 403)
        XCTAssertEqual(harness.server.pairedPhones.count, 1)
        XCTAssertTrue(harness.server.pairingRequests.waiting.isEmpty, "a spent code asks the person nothing")
    }

    func testClosingTheSheetWithdrawsItsCodeAndLeavesNoPhoneBehind() async throws {
        let code = try XCTUnwrap(harness.server.offerPairingCode())

        harness.server.withdrawPairingCode(code)

        let (status, _) = try await harness.post("/v1/pair", ["code": code], bearer: nil)
        XCTAssertEqual(status, 403)
        XCTAssertTrue(harness.server.pairedPhones.isEmpty)
    }

    func testAnUnknownCodeIsRefusedAndNoCodeIsABadRequest() async throws {
        let (unknown, _) = try await harness.post("/v1/pair", ["code": "0123"], bearer: nil)
        XCTAssertEqual(unknown, 403)
        let (missing, _) = try await harness.post("/v1/pair", [:], bearer: nil)
        XCTAssertEqual(missing, 400)
    }
}

/// Every request leaves a line in the access log naming its credential — a
/// paired phone by name — and never the token or the query string.
@MainActor
final class KiteloopControlServerAccessLogTests: XCTestCase {
    private var harness: ControlServerHarness!
    private var logURL: URL!
    private var devices: ControlDeviceTokens!

    override func setUp() async throws {
        let dir = try makeTemporaryDirectory(prefix: "control-access-log")
        logURL = dir.appending(path: "control-access.log")
        let devices = ControlDeviceTokens(url: dir.appending(path: "control-devices.json"))
        self.devices = devices
        let log = ControlAccessLog(url: logURL)
        harness = try await ControlServerHarness.start { token in
            KiteloopControlServer(registry: ControlSessionRegistry(), token: token, deviceTokens: devices, accessLog: log)
        }
    }

    override func tearDown() async throws {
        harness?.stop()
        harness = nil
    }

    private var lines: [String] {
        ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func testARequestFromAPairedPhoneIsLoggedUnderItsName() async throws {
        let token = devices.pair(name: "Work iPhone").token

        _ = try await harness.get("/v1/backlog?project=alpha", bearer: token)

        try await eventually("the request was logged") {
            self.lines.contains { $0.contains("\tGET\t/v1/backlog\tWork iPhone\t409\t") }
        }
        XCTAssertFalse(lines.joined().contains(token), "the token never reaches the log")
        XCTAssertFalse(lines.joined().contains("project=alpha"), "nor the query string")
    }

    func testARefusedRequestIsLoggedAsComingWithNoCredential() async throws {
        _ = try await harness.get("/v1/projects", bearer: nil)

        try await eventually("the refusal was logged") {
            self.lines.contains { $0.contains("\tGET\t/v1/projects\tnone\t401\t") }
        }
    }
}
