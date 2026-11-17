import XCTest
@testable import KiteloopCore

/// A connector's settings entry keeps its env and header names; the values go
/// to the secret store and come back only when a session's config is written.
final class ConnectorSecretsTests: XCTestCase {

    private let apiKey = ConnectorSecretKey(server: "tracker", kind: .env, name: "API_KEY")
    private let auth = ConnectorSecretKey(server: "remote", kind: .header, name: "Authorization")

    private func remote(_ authorization: String) -> ClaudeMCPServerEntry {
        ClaudeMCPServerEntry(extras: [
            "type": .string("http"),
            "url": .string("https://example.com/mcp"),
            "headers": .dictionary(["Authorization": .string(authorization), "X-Retries": .int(3)]),
            "timeout": .int(30),
        ])
    }

    func testEnvValueIsTakenOutAndTheEncodedEntryKeepsOnlyTheName() throws {
        let entry = ClaudeMCPServerEntry(command: "npx", args: ["-y", "tracker"], env: ["API_KEY": "abc"])
        let store = InMemoryConnectorSecretStore()

        let stripped = ConnectorSecrets.storing(["tracker": entry], replacing: [:], in: store)

        let text = String(decoding: try JSONEncoder().encode(stripped), as: UTF8.self)
        XCTAssertTrue(text.contains("\"API_KEY\":\"\""))
        XCTAssertFalse(text.contains("abc"))
        XCTAssertEqual(stripped["tracker"]?.command, "npx")
        XCTAssertEqual(stripped["tracker"]?.args, ["-y", "tracker"])
        XCTAssertEqual(store.all, [apiKey: "abc"])
    }

    func testHeaderValueIsTakenOutAndEveryOtherExtrasKeyRoundTrips() throws {
        let original = remote("Bearer xyz")

        let separated = ConnectorSecrets.separatingSecrets(["remote": original])

        XCTAssertEqual(separated.secrets, [auth: "Bearer xyz"])
        let extras = try XCTUnwrap(separated.servers["remote"]?.extras)
        XCTAssertEqual(extras["headers"], .dictionary(["Authorization": .string(""), "X-Retries": .int(3)]))
        for key in ["type", "url", "timeout"] {
            XCTAssertEqual(extras[key], original.extras[key], key)
        }
        XCTAssertNil(separated.servers["remote"]?.command)
        XCTAssertNil(separated.servers["remote"]?.env)
    }

    func testResolvingFillsStoredValuesAndLeavesTheRestBlank() {
        let servers = ["tracker": ClaudeMCPServerEntry(command: "npx", env: ["API_KEY": "", "UNSET": ""]),
                       "remote": remote("")]
        let store = InMemoryConnectorSecretStore([apiKey: "abc", auth: "Bearer xyz"])

        let resolved = ConnectorSecrets.resolvingSecrets(servers, from: store)

        XCTAssertEqual(resolved["tracker"]?.env, ["API_KEY": "abc", "UNSET": ""])
        XCTAssertEqual(resolved["remote"]?.extras, remote("Bearer xyz").extras)
    }

    func testSeparatedThenResolvedGivesBackTheOriginal() {
        let servers = ["tracker": ClaudeMCPServerEntry(command: "npx", env: ["API_KEY": "abc"]),
                       "remote": remote("Bearer xyz")]
        let store = InMemoryConnectorSecretStore()

        let stripped = ConnectorSecrets.storing(servers, replacing: [:], in: store)
        let resolved = ConnectorSecrets.resolvingSecrets(stripped, from: store)

        XCTAssertEqual(resolved["tracker"]?.env, ["API_KEY": "abc"])
        XCTAssertEqual(resolved["remote"]?.extras, servers["remote"]?.extras)
    }

    func testBlankValueKeepsTheStoredSecret() {
        let store = InMemoryConnectorSecretStore([apiKey: "abc"])
        let saved = ["tracker": ClaudeMCPServerEntry(command: "npx", env: ["API_KEY": ""])]

        _ = ConnectorSecrets.storing(saved, replacing: saved, in: store)

        XCTAssertEqual(store.value(for: apiKey), "abc")
    }

    func testNewValueReplacesTheStoredSecret() {
        let store = InMemoryConnectorSecretStore([apiKey: "abc"])
        let saved = ["tracker": ClaudeMCPServerEntry(command: "npx", env: ["API_KEY": ""])]

        _ = ConnectorSecrets.storing(["tracker": ClaudeMCPServerEntry(command: "npx", env: ["API_KEY": "def"])],
                                     replacing: saved, in: store)

        XCTAssertEqual(store.value(for: apiKey), "def")
    }

    func testRemovedNameOrServerDeletesItsSecret() {
        let store = InMemoryConnectorSecretStore([apiKey: "abc", auth: "Bearer xyz"])
        let saved = ["tracker": ClaudeMCPServerEntry(command: "npx", env: ["API_KEY": ""]),
                     "remote": remote("")]

        _ = ConnectorSecrets.storing(["tracker": ClaudeMCPServerEntry(command: "npx", env: [:]),
                                      "remote": remote("")],
                                     replacing: saved, in: store)
        XCTAssertEqual(store.all, [auth: "Bearer xyz"])

        _ = ConnectorSecrets.storing([:], replacing: saved, in: store)
        XCTAssertEqual(store.all, [:])
    }

    func testOnlyANonEmptyValueCountsAsHeldInPlainText() {
        XCTAssertTrue(ConnectorSecrets.holdsSecrets(["tracker": ClaudeMCPServerEntry(env: ["API_KEY": "abc"])]))
        XCTAssertFalse(ConnectorSecrets.holdsSecrets(["tracker": ClaudeMCPServerEntry(env: ["API_KEY": ""])]))
        XCTAssertFalse(ConnectorSecrets.holdsSecrets(["remote": remote("")]))
    }

    func testAccountNamesTheServerKindAndName() {
        XCTAssertEqual(apiKey.account, "tracker/env/API_KEY")
        XCTAssertEqual(auth.account, "remote/header/Authorization")
    }
}
