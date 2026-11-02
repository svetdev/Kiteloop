import KiteloopCore
import XCTest
@testable import Kiteloop

/// The vault row says whether a vault is set, says when its folder is gone,
/// and a cleared vault stays cleared across a relaunch.
@MainActor
final class VaultPathStatusTests: XCTestCase {

    func testNilOrEmptyPathReadsNotConfigured() {
        XCTAssertEqual(AppPreferencesView.vaultPathStatus(path: nil, folderExists: false), "Not configured")
        XCTAssertEqual(AppPreferencesView.vaultPathStatus(path: "", folderExists: false), "Not configured")
    }

    func testExistingFolderShowsItsPath() {
        XCTAssertEqual(AppPreferencesView.vaultPathStatus(path: "/tmp/vault", folderExists: true), "/tmp/vault")
    }

    func testMissingFolderIsShownAsNotFound() {
        XCTAssertEqual(
            AppPreferencesView.vaultPathStatus(path: "/tmp/gone", folderExists: false),
            "/tmp/gone (folder not found)"
        )
    }

    /// Set then clear against a store in a temp directory; a new store on the
    /// same file — the next launch — reads no vault.
    func testClearedVaultPathSurvivesReopen() throws {
        let directory = try makeTemporaryDirectory(prefix: "vault-path-clear")
        let storageURL = directory.appending(path: "global-config.json")
        let store = GlobalConfigStore(storageURL: storageURL)

        store.setVaultPath(directory.path(percentEncoded: false))
        let reopenedAfterSet = GlobalConfigStore(storageURL: storageURL).config.vaultPath
        XCTAssertNotNil(reopenedAfterSet)

        store.setVaultPath(nil)
        let reopenedAfterClear = GlobalConfigStore(storageURL: storageURL).config.vaultPath
        XCTAssertNil(reopenedAfterClear)
    }
}
