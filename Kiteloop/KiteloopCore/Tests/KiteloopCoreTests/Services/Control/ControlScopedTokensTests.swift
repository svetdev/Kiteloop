import XCTest
@testable import KiteloopCore

/// A scoped control token: it resolves to its scope until revoked, is stored
/// only as its hash, and survives a relaunch.
final class ControlScopedTokensTests: XCTestCase {

    private var url: URL!

    override func setUpWithError() throws {
        url = try makeTemporaryDirectory(prefix: "control-scoped-tokens").appending(path: "control-scoped-tokens.json")
    }

    func testAMintedTokenResolvesToItsScope() {
        let store = ControlScopedTokens(url: url)
        let (token, entry) = store.mint(name: "dashboard", scope: .read)

        XCTAssertEqual(store.token(for: token)?.id, entry.id)
        XCTAssertEqual(store.token(for: token)?.scope, .read)
        XCTAssertNil(store.token(for: "someone-elses-token"))
    }

    func testTheFileHoldsOnlyTheHashInAPrivateFile() throws {
        let (token, _) = ControlScopedTokens(url: url).mint(name: "ci", scope: .operate)

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains(token))
        XCTAssertTrue(text.contains(ControlDeviceTokens.hash(token)))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testARevokedTokenResolvesToNilAndTheOthersStillDo() {
        let store = ControlScopedTokens(url: url)
        let (lost, lostEntry) = store.mint(name: "lost", scope: .configure)
        let (kept, _) = store.mint(name: "kept", scope: .read)

        XCTAssertTrue(store.revoke(lostEntry.id))

        XCTAssertNil(store.token(for: lost))
        XCTAssertNil(ControlScopedTokens(url: url).token(for: lost), "the revoke is saved")
        XCTAssertNotNil(store.token(for: kept))
        XCTAssertFalse(store.revoke(lostEntry.id), "nothing left to revoke")
    }

    func testTheStoreReloadsFromDisk() {
        let (token, entry) = ControlScopedTokens(url: url).mint(name: "dashboard", scope: .operate)

        let reloaded = ControlScopedTokens(url: url).token(for: token)

        XCTAssertEqual(reloaded?.id, entry.id)
        XCTAssertEqual(reloaded?.name, "dashboard")
        XCTAssertEqual(reloaded?.scope, .operate)
    }

    func testEachMintIsADifferentToken() {
        let store = ControlScopedTokens(url: url)
        XCTAssertNotEqual(store.mint(name: "a", scope: .read).token, store.mint(name: "b", scope: .read).token)
    }
}
