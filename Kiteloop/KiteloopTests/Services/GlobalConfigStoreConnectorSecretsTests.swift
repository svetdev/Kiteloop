import XCTest
import KiteloopCore
@testable import Kiteloop

/// A connector's env and header values live in the secret store, never in
/// `global-config.json`: saved that way, and moved there from a file an older
/// build wrote in plain text.
@MainActor
final class GlobalConfigStoreConnectorSecretsTests: XCTestCase {

    private var tempDir: URL!
    private var storageURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try makeTemporaryDirectory(prefix: "global-config-secrets")
        storageURL = tempDir.appendingPathComponent("global-config.json")
    }

    override func tearDownWithError() throws {
        storageURL = nil
        tempDir = nil
        try super.tearDownWithError()
    }

    private func fileText() throws -> String {
        try String(contentsOf: storageURL, encoding: .utf8)
    }

    func testSavedEnvValueGoesToTheStoreAndTheFileKeepsTheName() throws {
        let secrets = InMemoryConnectorSecretStore()
        let store = GlobalConfigStore(storageURL: storageURL, secretStore: secrets)

        store.setMCPServers(["tracker": ClaudeMCPServerEntry(command: "npx", env: ["API_KEY": "abc"])])

        XCTAssertEqual(store.config.mcpServers?["tracker"]?.env, ["API_KEY": ""])
        let text = try fileText()
        XCTAssertTrue(text.contains("\"API_KEY\" : \"\""))
        XCTAssertFalse(text.contains("abc"))
        XCTAssertEqual(secrets.value(for: ConnectorSecretKey(server: "tracker", kind: .env, name: "API_KEY")), "abc")
    }

    func testPlainTextValuesOnDiskMoveToTheStoreOnFirstLoad() throws {
        try Data("""
        {"mcpServers": {"tracker": {"command": "npx", "env": {"API_KEY": "abc"}}}}
        """.utf8).write(to: storageURL)
        let secrets = InMemoryConnectorSecretStore()

        let store = GlobalConfigStore(storageURL: storageURL, secretStore: secrets)

        XCTAssertEqual(store.config.mcpServers?["tracker"]?.env, ["API_KEY": ""])
        XCTAssertFalse(try fileText().contains("abc"))
        XCTAssertEqual(secrets.value(for: ConnectorSecretKey(server: "tracker", kind: .env, name: "API_KEY")), "abc")
    }

    func testBlankValueKeepsTheSecretAndRemovalDeletesIt() {
        let key = ConnectorSecretKey(server: "tracker", kind: .env, name: "API_KEY")
        let secrets = InMemoryConnectorSecretStore()
        let store = GlobalConfigStore(storageURL: storageURL, secretStore: secrets)
        store.setMCPServers(["tracker": ClaudeMCPServerEntry(command: "npx", env: ["API_KEY": "abc"])])

        store.setMCPServers(["tracker": ClaudeMCPServerEntry(command: "node", env: ["API_KEY": ""])])
        XCTAssertEqual(secrets.value(for: key), "abc")

        store.setMCPServers(nil)
        XCTAssertNil(secrets.value(for: key))
    }
}
