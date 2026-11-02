import XCTest
@testable import KiteloopCore

/// A token per paired phone: it authorizes until revoked, is stored hashed,
/// and revoking one leaves the others working.
final class ControlDeviceTokensTests: XCTestCase {

    private var url: URL!

    override func setUpWithError() throws {
        url = try makeTemporaryDirectory(prefix: "control-devices").appending(path: "control-devices.json")
    }

    func testAPairedPhonesTokenNamesThatPhone() {
        let store = ControlDeviceTokens(url: url)
        let (token, device) = store.pair(name: "Work iPhone")

        XCTAssertEqual(store.device(for: token)?.id, device.id)
        XCTAssertNil(store.device(for: "someone-elses-token"))
    }

    func testARevokedTokenNoLongerAuthorizesAndTheOthersStillDo() {
        let store = ControlDeviceTokens(url: url)
        let (lost, lostDevice) = store.pair(name: "Lost phone")
        let (kept, _) = store.pair(name: "Other phone")

        store.revoke(lostDevice.id)

        XCTAssertNil(store.device(for: lost))
        XCTAssertNotNil(store.device(for: kept))
    }

    func testTheTokenIsStoredOnlyAsItsHashInAPrivateFile() throws {
        let (token, _) = ControlDeviceTokens(url: url).pair(name: "iPhone")

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains(token))
        XCTAssertTrue(text.contains(ControlDeviceTokens.hash(token)))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testPairedPhonesSurviveARelaunch() {
        let (token, _) = ControlDeviceTokens(url: url).pair(name: "iPhone")

        XCTAssertEqual(ControlDeviceTokens(url: url).device(for: token)?.name, "iPhone")
    }

    func testAPhoneCanBeRenamed() {
        let store = ControlDeviceTokens(url: url)
        let (_, device) = store.pair(name: "New phone")

        store.rename(device.id, to: "My iPhone")

        XCTAssertEqual(ControlDeviceTokens(url: url).devices.first?.name, "My iPhone")
    }

    func testEachPairingMintsADifferentToken() {
        let store = ControlDeviceTokens(url: url)
        XCTAssertNotEqual(store.pair(name: "a").token, store.pair(name: "b").token)
    }

    func testAnOfferedCodePairsOnePhoneOnce() throws {
        let store = ControlDeviceTokens(url: url)
        let code = store.offer()

        let (token, device) = try XCTUnwrap(store.claim(code: code, name: "Work iPhone"))

        XCTAssertEqual(store.device(for: token)?.id, device.id)
        XCTAssertNil(store.claim(code: code, name: "Someone else"), "a code is used up by its claim")
        XCTAssertEqual(store.devices.count, 1)
    }

    func testAWithdrawnOrUnknownCodePairsNothing() {
        let store = ControlDeviceTokens(url: url)
        let code = store.offer()

        store.withdraw(code: code)

        XCTAssertNil(store.claim(code: code, name: "iPhone"))
        XCTAssertNil(store.claim(code: "not-a-code", name: "iPhone"))
        XCTAssertTrue(store.devices.isEmpty, "an offer nobody claimed leaves no paired phone behind")
    }

    func testAnOfferDoesNotOutliveARelaunch() {
        let code = ControlDeviceTokens(url: url).offer()

        XCTAssertNil(ControlDeviceTokens(url: url).claim(code: code, name: "iPhone"))
    }

    func testTheCodeIsNotTheTokenItTradesFor() throws {
        let store = ControlDeviceTokens(url: url)
        let code = store.offer()
        let (token, _) = try XCTUnwrap(store.claim(code: code, name: "iPhone"))

        XCTAssertNotEqual(code, token)
        XCTAssertNil(store.device(for: code), "a code is not a credential for the API")
    }
}
