import XCTest
@testable import Kiteloop

/// The MCP panel reads `.claude/settings.json` as absent, unreadable or
/// settings — and only the last is a list Save may write over.
@MainActor
final class MCPServerSettingsFileTests: XCTestCase {
    private func read(_ text: String) -> MCPServerConfigView.SettingsRead {
        MCPServerConfigView.readSettings(from: Data(text.utf8))
    }

    private func isUnreadable(_ read: MCPServerConfigView.SettingsRead) -> Bool {
        if case .unreadable = read { return true }
        return false
    }

    func testBytesThatAreNotAJSONObjectAreUnreadableNotEmpty() {
        XCTAssertTrue(isUnreadable(read("{ \"mcpServers\": {")))
        XCTAssertTrue(isUnreadable(read("[1, 2]")))
        XCTAssertTrue(isUnreadable(read("{\"mcpServers\": [\"a\"]}")))
    }

    func testAFileWithNoServersIsSettingsAndKeepsItsOtherKeysOnSave() throws {
        guard case .settings(let json) = read(#"{"permissions": {"allow": ["Bash"]}, "hooks": {}}"#) else {
            return XCTFail("expected settings")
        }
        let written = MCPServerConfigView.merged(servers: ["s": ["command": "npx"]], into: json)
        XCTAssertNotNil(written["permissions"])
        XCTAssertNotNil(written["hooks"])
        XCTAssertEqual((written["mcpServers"] as? [String: Any])?.keys.sorted(), ["s"])
    }

    func testNoFileIsAbsentAndAnUnreadableFileIsLeftAlone() throws {
        let dir = try makeTemporaryDirectory(prefix: "mcp-settings-file")
        let url = dir.appending(path: "settings.json")
        guard case .absent = MCPServerConfigView.readSettings(at: url) else { return XCTFail("expected absent") }

        let bytes = Data("not json".utf8)
        try bytes.write(to: url)
        XCTAssertTrue(isUnreadable(MCPServerConfigView.readSettings(at: url)))
        XCTAssertEqual(try Data(contentsOf: url), bytes, "reading never rewrites")
    }
}
