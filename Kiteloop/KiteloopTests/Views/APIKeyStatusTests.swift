import KiteloopCore
import XCTest
@testable import Kiteloop

/// The API key row's status line says whether a key is saved, and says out loud
/// when a save or a removal did not reach the tokens file.
final class APIKeyStatusTests: XCTestCase {

    func testSavedAndNotSavedStrings() {
        XCTAssertEqual(
            AppPreferencesView.apiKeyStatus(saved: true, writeFailed: false, removeFailed: false),
            "API key saved."
        )
        XCTAssertEqual(
            AppPreferencesView.apiKeyStatus(saved: false, writeFailed: false, removeFailed: false),
            "No API key saved yet."
        )
    }

    func testFailedSaveNamesTheTokensFile() {
        XCTAssertEqual(
            AppPreferencesView.apiKeyStatus(saved: false, writeFailed: true, removeFailed: false),
            "API key could not be written to ~/.kiteloop/tokens.json."
        )
    }

    /// A removal that did not reach disk leaves the key saved; the line says so
    /// rather than "API key saved."
    func testFailedRemovalNamesTheTokensFile() {
        XCTAssertEqual(
            AppPreferencesView.apiKeyStatus(saved: true, writeFailed: false, removeFailed: true),
            "API key could not be removed from ~/.kiteloop/tokens.json."
        )
    }

    /// Save then remove against a store in a temp directory, never the real file.
    func testSavedKeyIsGoneAfterRemove() throws {
        let directory = try makeTemporaryDirectory(prefix: "api-key-remove")
        let store = TokenStore(fileURL: directory.appending(path: "tokens.json"))

        XCTAssertTrue(store.set(ClaudeAuthConfig.anthropicTokenKey, value: "sk-ant-test"))
        XCTAssertEqual(store.get(ClaudeAuthConfig.anthropicTokenKey), "sk-ant-test")
        XCTAssertTrue(store.remove(ClaudeAuthConfig.anthropicTokenKey))
        XCTAssertNil(store.get(ClaudeAuthConfig.anthropicTokenKey))
    }
}
