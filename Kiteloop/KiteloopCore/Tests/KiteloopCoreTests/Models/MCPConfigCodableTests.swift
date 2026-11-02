import XCTest
@testable import KiteloopCore

/// Kiteloop reads an agent's `mcp.json` to change one part of it and writes the
/// rest back, so what it cannot model still has to survive the trip: a server
/// written for a transport that is not a stdio command, and any key the entry
/// struct never declares.
final class MCPConfigCodableTests: XCTestCase {

    private func tempConfigPath(_ json: String) throws -> String {
        let dir = try makeTemporaryDirectory(prefix: "mcp-config-tests")
        let url = dir.appendingPathComponent("mcp.json")
        try Data(json.utf8).write(to: url)
        return url.path
    }

    private func object(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(json, "not a JSON object", file: file, line: line)
    }

    // MARK: - Decoding

    /// The defect this file exists for: one entry with no `command` used to fail
    /// to decode, and `load(from:)` answered nil for the *whole file* — every
    /// other server in it read as absent too.
    func testEntryWithNoCommandDoesNotMakeTheFileReadAsAbsent() throws {
        let path = try tempConfigPath("""
        {
          "mcpServers": {
            "remote": { "type": "http", "url": "https://example.com/mcp" },
            "local": { "command": "npx", "args": ["-y", "server"] }
          }
        }
        """)

        let config = try XCTUnwrap(ClaudeMCPConfig.load(from: path), "the file must still load")
        XCTAssertEqual(Set(config.mcpServers.keys), ["remote", "local"])

        let remote = try XCTUnwrap(config.mcpServers["remote"])
        XCTAssertNil(remote.command)
        XCTAssertNil(remote.args)
        XCTAssertEqual(remote.extras["type"], .string("http"))
        XCTAssertEqual(remote.extras["url"], .string("https://example.com/mcp"))

        let local = try XCTUnwrap(config.mcpServers["local"])
        XCTAssertEqual(local.command, "npx")
        XCTAssertEqual(local.args, ["-y", "server"])
        XCTAssertTrue(local.extras.isEmpty, "a plain stdio entry carries nothing extra")
    }

    /// Keys the struct models are read into their own fields and are *not* also
    /// kept as extras — which would make encode write them twice.
    func testModelledKeysAreNotAlsoKeptAsExtras() throws {
        let entry = try JSONDecoder().decode(ClaudeMCPServerEntry.self, from: Data("""
        {"command": "npx", "args": ["-y"], "env": {"TOKEN": "t"}}
        """.utf8))
        XCTAssertEqual(entry.env, ["TOKEN": "t"])
        XCTAssertTrue(entry.extras.isEmpty)
    }

    /// A modelled key whose value is not the shape Kiteloop models — here an
    /// `env` with a nested object in it — is kept verbatim rather than dropped,
    /// and does not fail the entry.
    func testModelledKeyOfAnUnmodelledShapeIsKeptRatherThanDropped() throws {
        let entry = try JSONDecoder().decode(ClaudeMCPServerEntry.self, from: Data("""
        {"command": "npx", "env": {"NESTED": {"a": 1}}}
        """.utf8))
        XCTAssertNil(entry.env, "it is not a [String: String]")
        XCTAssertEqual(entry.extras["env"], .dictionary(["NESTED": .dictionary(["a": .int(1)])]))

        let reencoded = try object(try JSONEncoder().encode(entry))
        XCTAssertEqual((reencoded["env"] as? [String: Any])?.keys.first, "NESTED")
    }

    // MARK: - Round-trips

    /// An entry carrying keys Kiteloop does not model comes back out with all of
    /// them — Codable used to drop every undeclared key on the way out.
    func testRoundTripKeepsKeysKiteloopDoesNotModel() throws {
        let json = """
        {
          "mcpServers": {
            "local": {
              "args": ["-y", "server"],
              "command": "npx",
              "disabled": false,
              "env": {"TOKEN": "t"},
              "headers": {"X-Api-Key": "k"},
              "timeout": 30
            }
          }
        }
        """
        let config = try XCTUnwrap(ClaudeMCPConfig.load(from: try tempConfigPath(json)))
        let entry = try XCTUnwrap(config.mcpServers["local"])
        XCTAssertEqual(entry.extras["disabled"], .bool(false))
        XCTAssertEqual(entry.extras["timeout"], .int(30))
        XCTAssertEqual(entry.extras["headers"], .dictionary(["X-Api-Key": .string("k")]))

        let reencoded = try object(try JSONEncoder().encode(config))
        XCTAssertEqual(
            NSDictionary(dictionary: reencoded),
            NSDictionary(dictionary: try object(Data(json.utf8))),
            "a read-modify-write with no modification must give the file back unchanged"
        )
    }

    /// The same, for an entry with no command at all: saving the loaded config
    /// leaves every server and every key each server carried still present.
    func testSaveKeepsEveryServerAndEveryKeyItCarried() throws {
        let json = """
        {
          "mcpServers": {
            "local": {"args": ["-y", "server"], "command": "npx"},
            "remote": {"headers": {"Authorization": "Bearer t"}, "type": "sse", "url": "https://example.com/mcp"}
          }
        }
        """
        let path = try tempConfigPath(json)
        let config = try XCTUnwrap(ClaudeMCPConfig.load(from: path))
        try config.save(to: path)

        let saved = try object(try Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(
            NSDictionary(dictionary: saved),
            NSDictionary(dictionary: try object(Data(json.utf8)))
        )

        let reloaded = try XCTUnwrap(ClaudeMCPConfig.load(from: path), "and it still loads afterwards")
        XCTAssertEqual(Set(reloaded.mcpServers.keys), ["local", "remote"])
    }

    /// The load / `addServer` / save sequence the MCP authorization path runs:
    /// the newly approved server lands *alongside* what the file already held
    /// rather than replacing it, which is what happened while the file read as
    /// absent and the path fell back to an empty config.
    func testAuthorizingAServerAddsItAlongsideTheExistingOnes() throws {
        let path = try tempConfigPath("""
        {
          "mcpServers": {
            "remote": {"type": "http", "url": "https://example.com/mcp"},
            "existing": {"command": "npx", "args": ["-y", "existing"], "env": {"TOKEN": "old"}}
          }
        }
        """)

        var config = try XCTUnwrap(ClaudeMCPConfig.load(from: path))
        config.addServer(name: "github", entry: ClaudeMCPServerEntry(
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-github"],
            env: ["GITHUB_TOKEN": "new"]
        ))
        try config.save(to: path)

        let reloaded = try XCTUnwrap(ClaudeMCPConfig.load(from: path))
        XCTAssertEqual(Set(reloaded.mcpServers.keys), ["remote", "existing", "github"])
        XCTAssertEqual(reloaded.mcpServers["existing"]?.env, ["TOKEN": "old"])
        XCTAssertEqual(reloaded.mcpServers["remote"]?.extras["url"], .string("https://example.com/mcp"))
        XCTAssertEqual(reloaded.mcpServers["github"]?.env, ["GITHUB_TOKEN": "new"])
    }

    // MARK: - Display

    /// What the config sheet and the settings list show for an entry: its
    /// command line when it has one, and otherwise what it does carry.
    func testDisplaySummary() {
        XCTAssertEqual(
            ClaudeMCPServerEntry(command: "npx", args: ["-y", "server"]).displaySummary,
            "npx -y server"
        )
        XCTAssertEqual(ClaudeMCPServerEntry(command: "server").displaySummary, "server")
        XCTAssertEqual(
            ClaudeMCPServerEntry(extras: ["type": .string("http"), "url": .string("https://example.com/mcp")]).displaySummary,
            "http: https://example.com/mcp"
        )
        XCTAssertEqual(
            ClaudeMCPServerEntry(extras: ["url": .string("https://example.com/mcp")]).displaySummary,
            "https://example.com/mcp"
        )
        XCTAssertEqual(ClaudeMCPServerEntry(extras: ["type": .string("sse")]).displaySummary, "sse")
        XCTAssertEqual(
            ClaudeMCPServerEntry(extras: ["headers": .dictionary([:])]).displaySummary,
            "headers",
            "an entry with nothing recognisable is described by the keys it holds"
        )
        XCTAssertEqual(ClaudeMCPServerEntry().displaySummary, "")
    }

    // MARK: - Empty env vars

    /// The "Configure credentials" prompt reads every entry; one with no `env`
    /// at all is not a missing credential.
    func testHasEmptyEnvVarsIgnoresAnEntryWithNoEnv() {
        var config = ClaudeMCPConfig(mcpServers: [
            "remote": ClaudeMCPServerEntry(extras: ["url": .string("https://example.com/mcp")])
        ])
        XCTAssertFalse(config.hasEmptyEnvVars)

        config.addServer(name: "local", entry: ClaudeMCPServerEntry(command: "npx", args: [], env: ["TOKEN": ""]))
        XCTAssertTrue(config.hasEmptyEnvVars)
    }

    // MARK: - Reading, missing apart from unreadable

    /// No file at the path is not an error: the agent has no servers.
    func testLoadIfPresentAnswersNilWhenNoFileExists() throws {
        let dir = try makeTemporaryDirectory(prefix: "mcp-config-tests")
        let path = dir.appendingPathComponent("mcp.json").path
        XCTAssertNil(try ClaudeMCPConfig.loadIfPresent(from: path))
    }

    /// A file that is there but does not decode is an error to report, not an
    /// empty config — `load(from:)` answers nil for both.
    func testLoadIfPresentThrowsForMalformedJSON() throws {
        let path = try tempConfigPath("{ \"mcpServers\": ")
        XCTAssertThrowsError(try ClaudeMCPConfig.loadIfPresent(from: path)) { error in
            XCTAssertTrue(error is DecodingError, "expected a decode error, got \(error)")
        }
    }

    func testLoadIfPresentReturnsTheServersOfAValidFile() throws {
        let path = try tempConfigPath("""
        {"mcpServers": {"local": {"command": "npx", "env": {"TOKEN": "t"}}}}
        """)
        let config = try XCTUnwrap(try ClaudeMCPConfig.loadIfPresent(from: path))
        XCTAssertEqual(Set(config.mcpServers.keys), ["local"])
        XCTAssertEqual(config.mcpServers["local"]?.command, "npx")
        XCTAssertEqual(config.mcpServers["local"]?.env, ["TOKEN": "t"])
    }
}
