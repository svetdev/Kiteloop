import XCTest
@testable import KiteloopCore

/// A routine's webhook: its secret finds it and nothing else does, it is
/// stored only as its hash, it survives a relaunch, and a revoke ends it.
final class RoutineHooksTests: XCTestCase {

    private var url: URL!

    override func setUpWithError() throws {
        url = try makeTemporaryDirectory(prefix: "routine-hooks").appending(path: "routine-hooks.json")
    }

    private func mint(_ store: RoutineHooks, _ name: String, routine: String = "brief") throws -> String {
        try store.mint(name: name, routine: routine).get().secret
    }

    func testAMintedSecretFindsItsHook() throws {
        let store = RoutineHooks(url: url)
        let secret = try mint(store, "deploys")

        let hook = store.hook(named: "deploys", secret: secret)

        XCTAssertEqual(hook?.name, "deploys")
        XCTAssertEqual(hook?.routine, "brief")
    }

    func testAWrongSecretOrAnUnknownNameFindsNothing() throws {
        let store = RoutineHooks(url: url)
        let secret = try mint(store, "deploys")
        let other = try mint(store, "alerts", routine: "triage")

        XCTAssertNil(store.hook(named: "deploys", secret: "not-the-secret"))
        XCTAssertNil(store.hook(named: "deploys", secret: other), "one hook's secret does not open another")
        XCTAssertNil(store.hook(named: "nobody", secret: secret))
        XCTAssertNil(store.hook(named: "deploys", secret: ""))
    }

    func testRevokeRemovesTheHook() throws {
        let store = RoutineHooks(url: url)
        let secret = try mint(store, "deploys")

        XCTAssertTrue(store.revoke(name: "deploys"))

        XCTAssertNil(store.hook(named: "deploys", secret: secret))
        XCTAssertNil(RoutineHooks(url: url).hook(named: "deploys", secret: secret), "the revoke is saved")
        XCTAssertFalse(store.revoke(name: "deploys"), "nothing left to revoke")
    }

    func testTheFileHoldsTheHashAndNeverTheSecret() throws {
        let secret = try mint(RoutineHooks(url: url), "deploys")

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains(secret))
        XCTAssertTrue(text.contains(ControlDeviceTokens.hash(secret)))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testTheHooksReloadFromDisk() throws {
        let secret = try mint(RoutineHooks(url: url), "deploys")

        let reloaded = RoutineHooks(url: url)

        XCTAssertEqual(reloaded.hooks.map(\.name), ["deploys"])
        XCTAssertEqual(reloaded.hook(named: "deploys", secret: secret)?.routine, "brief")
    }

    func testANameMustBeAValidIdAndUnused() throws {
        let store = RoutineHooks(url: url)
        _ = try mint(store, "deploys")

        XCTAssertThrowsError(try store.mint(name: "Not Valid", routine: "brief").get()) {
            XCTAssertEqual($0 as? RoutineHooks.MintRefusal, .invalidName)
        }
        XCTAssertThrowsError(try store.mint(name: "deploys", routine: "other").get()) {
            XCTAssertEqual($0 as? RoutineHooks.MintRefusal, .nameTaken)
        }
        XCTAssertEqual(store.hooks.count, 1)
    }
}
