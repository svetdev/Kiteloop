import XCTest
@testable import Kiteloop

/// What the MCP panel's Save does with a list it cannot write.
///
/// A row with no name or no command used to be skipped by the loop that built
/// `mcpServers`, and the second of two rows sharing one name overwrote the
/// first — the write succeeded either way, so `saveError` stayed nil and the
/// row was simply gone at the next load. A refusal carries no dictionary, so
/// `saveServers()` returns before it touches `.claude/settings.json` and shows
/// the message in the panel's error label instead.
@MainActor
final class MCPServerSaveRefusalTests: XCTestCase {

    private func row(_ name: String, _ command: String, args: String = "", env: String = "") -> MCPServerRow {
        MCPServerRow(name: name, command: command, args: args, env: env)
    }

    private func refusal(_ rows: [MCPServerRow]) -> String? {
        if case .refused(let message) = MCPServerConfigView.serversToWrite(from: rows) { return message }
        return nil
    }

    private func servers(_ rows: [MCPServerRow]) -> [String: Any]? {
        if case .servers(let entries) = MCPServerConfigView.serversToWrite(from: rows) { return entries }
        return nil
    }

    /// A half-filled row is the person's work in progress, not a row to drop.
    func testEmptyNameIsRefusedByItsPosition() {
        let message = refusal([row("github", "npx"), row("", "npx")])
        XCTAssertEqual(message, "Row 2 has no server name. Name it or remove it before saving.")
        XCTAssertNil(servers([row("github", "npx"), row("", "npx")]))
    }

    /// A named row with no command names both, so the person can find it.
    func testEmptyCommandIsRefusedNamingTheRow() {
        let message = refusal([row("github", "")])
        XCTAssertEqual(message, "Row 1 (\"github\") has no command. Give it one or remove the row before saving.")
    }

    /// Two rows with one name collapsed into one entry; now neither is written.
    func testDuplicateNameIsRefusedNamingTheName() {
        let rows = [row("github", "npx"), row("local", "node"), row("github", "python")]
        XCTAssertEqual(refusal(rows), "Two rows are named \"github\". Rename one before saving.")
        XCTAssertNil(servers(rows))
    }

    /// A list with nothing wrong with it writes exactly what it wrote before:
    /// the command as typed, the arguments tokenized, the environment parsed.
    func testCleanListProducesTheSameDictionary() throws {
        let rows = [row("github", "npx", args: "-y @example/server --root \"/My Project\"", env: "TOKEN=abc")]
        let entries = try XCTUnwrap(servers(rows))
        let entry = try XCTUnwrap(entries["github"] as? [String: Any])
        XCTAssertEqual(entry["command"] as? String, "npx")
        XCTAssertEqual(entry["args"] as? [String], ["-y", "@example/server", "--root", "/My Project"])
        XCTAssertEqual(entry["env"] as? [String: String], ["TOKEN": "abc"])
    }

    /// A server with no environment lines carries no `env` key, as before.
    func testRowWithoutEnvironmentCarriesNoEnvKey() throws {
        let entries = try XCTUnwrap(servers([row("local", "node", args: "server.js")]))
        let entry = try XCTUnwrap(entries["local"] as? [String: Any])
        XCTAssertNil(entry["env"])
    }

    /// Deleting the last row is a real edit: an empty list writes an empty
    /// `mcpServers`, it is not a refusal.
    func testEmptyListIsWritable() {
        XCTAssertEqual(servers([])?.isEmpty, true)
    }

    /// A remote entry reads into a row and writes back with its type, url and
    /// headers, and gains no command or args.
    func testRemoteEntryRoundTripsWithoutCommandOrArgs() throws {
        let remote: [String: Any] = ["type": "http", "url": "https://x/mcp", "headers": ["A": "b"]]
        let rows = MCPServerConfigView.rows(from: ["remote": remote])
        let entry = MCPServerConfigView.entry(for: try XCTUnwrap(rows.first))
        XCTAssertEqual(entry["type"] as? String, "http")
        XCTAssertEqual(entry["url"] as? String, "https://x/mcp")
        XCTAssertEqual(entry["headers"] as? [String: String], ["A": "b"])
        XCTAssertNil(entry["command"])
        XCTAssertNil(entry["args"])
    }

    /// A remote row with no command no longer refuses the whole list.
    func testRemoteRowBesideStdioRowIsWritable() throws {
        let remote = MCPServerRow(name: "remote", command: "", args: "", env: "",
                                  extras: ["type": "http", "url": "https://x/mcp"])
        let entries = try XCTUnwrap(servers([remote, row("local", "node", args: "server.js")]))
        XCTAssertEqual(Set(entries.keys), ["remote", "local"])
    }

    /// A key the page does not edit survives a stdio round trip.
    func testStdioEntryKeepsCwd() throws {
        let stdio: [String: Any] = ["command": "node", "args": ["server.js"], "cwd": "/srv"]
        let rows = MCPServerConfigView.rows(from: ["local": stdio])
        let entry = MCPServerConfigView.entry(for: try XCTUnwrap(rows.first))
        XCTAssertEqual(entry["cwd"] as? String, "/srv")
        XCTAssertEqual(entry["command"] as? String, "node")
        XCTAssertEqual(entry["args"] as? [String], ["server.js"])
    }

    /// One number in the env is read as its text, not a reason to drop the env.
    func testNumericEnvValueLoadsAsText() throws {
        let data = Data(#"{"local": {"command": "node", "env": {"PORT": 8080, "TOKEN": "t"}}}"#.utf8)
        let mcpServers = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let row = try XCTUnwrap(MCPServerConfigView.rows(from: mcpServers).first)
        XCTAssertEqual(MCPServerConfigView.environment(from: row.env), ["PORT": "8080", "TOKEN": "t"])
    }

    /// A row with neither a command nor a url is still refused as before.
    func testRowWithNeitherCommandNorUrlIsRefused() {
        let bare = MCPServerRow(name: "github", command: "", args: "", env: "", extras: ["type": "http"])
        XCTAssertEqual(refusal([bare]), "Row 1 (\"github\") has no command. Give it one or remove the row before saving.")
    }
}
