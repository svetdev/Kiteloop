import XCTest
import KiteloopCore
@testable import Kiteloop

/// What the app-wide MCP Servers tab's Save writes.
///
/// Add used to write `npx -y ""` straight to the global config, and the tab
/// had no way to edit a server afterwards. Rows are now edited in place and
/// written only on Save, through `AppPreferencesView.globalMCPServersToWrite`,
/// which refuses what the project pane refuses and keeps each entry's extras.
@MainActor
final class GlobalMCPServerSaveTests: XCTestCase {

    private func row(_ name: String, _ command: String, args: String = "", env: String = "") -> GlobalMCPServerRow {
        GlobalMCPServerRow(fields: MCPServerRow(name: name, command: command, args: args, env: env))
    }

    private func refusal(_ rows: [GlobalMCPServerRow]) -> String? {
        if case .refused(let message) = AppPreferencesView.globalMCPServersToWrite(from: rows) { return message }
        return nil
    }

    private func servers(_ rows: [GlobalMCPServerRow]) -> [String: ClaudeMCPServerEntry]? {
        if case .servers(let entries) = AppPreferencesView.globalMCPServersToWrite(from: rows) { return entries }
        return nil
    }

    func testNamelessRowIsRefusedByItsPosition() {
        let rows = [row("github", "npx"), row("", "node")]
        XCTAssertEqual(refusal(rows), "Row 2 has no server name. Name it or remove it before saving.")
        XCTAssertNil(servers(rows))
    }

    /// A freshly added row has a name and no command until one is typed.
    func testRowWithNoCommandIsRefusedNamingTheRow() {
        let rows = [row("github", "")]
        XCTAssertEqual(refusal(rows), "Row 1 (\"github\") has no command. Give it one or remove the row before saving.")
        XCTAssertNil(servers(rows))
    }

    func testTwoRowsSharingANameAreRefused() {
        let rows = [row("github", "npx"), row("github", "node")]
        XCTAssertEqual(refusal(rows), "Two rows are named \"github\". Rename one before saving.")
        XCTAssertNil(servers(rows))
    }

    /// Saved, then loaded as rows again the way reopening Settings does: the
    /// command, a quoted argument with a space and the environment all survive.
    func testSavedRowComesBackIdenticalWhenReloaded() throws {
        let typed = row("github", "npx", args: "-y @example/server --root \"/My Project\"", env: "A=1\nTOKEN=abc")
        let entries = try XCTUnwrap(servers([typed]))
        let entry = try XCTUnwrap(entries["github"])
        XCTAssertEqual(entry.command, "npx")
        XCTAssertEqual(entry.args, ["-y", "@example/server", "--root", "/My Project"])
        XCTAssertEqual(entry.env, ["A": "1", "TOKEN": "abc"])

        let reloaded = try XCTUnwrap(AppPreferencesView.globalMCPRows(from: entries).first)
        XCTAssertEqual(reloaded.fields.name, "github")
        XCTAssertEqual(reloaded.fields.command, "npx")
        XCTAssertEqual(ShellArguments.tokenize(reloaded.fields.args), ["-y", "@example/server", "--root", "/My Project"])
        XCTAssertEqual(reloaded.fields.env, "A=1\nTOKEN=abc")
    }

    /// A remote server has no command; editing another row and saving writes
    /// it back with its extras as they were, and it is not refused.
    func testRemoteServerExtrasSurviveSavingAnotherRow() throws {
        let remote = ClaudeMCPServerEntry(extras: ["type": .string("http"), "url": .string("https://example.com/mcp")])
        var rows = AppPreferencesView.globalMCPRows(from: [
            "local": ClaudeMCPServerEntry(command: "node", args: ["server.js"]),
            "remote": remote,
        ])
        XCTAssertTrue(rows[1].isRemote)
        rows[0].fields.args = "server.js --verbose"

        let entries = try XCTUnwrap(servers(rows))
        XCTAssertEqual(entries["local"]?.args, ["server.js", "--verbose"])
        XCTAssertNil(entries["remote"]?.command)
        XCTAssertEqual(entries["remote"]?.extras, remote.extras)
    }

    /// A command server's own extras are carried across an edit too.
    func testEditedServerKeepsItsExtras() throws {
        let saved = ClaudeMCPServerEntry(command: "npx", args: ["-y", "a"], extras: ["timeout": .int(30)])
        var rows = AppPreferencesView.globalMCPRows(from: ["a": saved])
        rows[0].fields.command = "node"
        let entries = try XCTUnwrap(servers(rows))
        XCTAssertEqual(entries["a"]?.command, "node")
        XCTAssertEqual(entries["a"]?.extras, saved.extras)
    }

    /// A deleted row is absent from what Save writes.
    func testDeletedRowIsNotWritten() throws {
        var rows = AppPreferencesView.globalMCPRows(from: [
            "a": ClaudeMCPServerEntry(command: "npx"),
            "b": ClaudeMCPServerEntry(command: "node"),
        ])
        rows.removeAll { $0.fields.name == "a" }
        XCTAssertEqual(try XCTUnwrap(servers(rows)).keys.sorted(), ["b"])
    }
}
