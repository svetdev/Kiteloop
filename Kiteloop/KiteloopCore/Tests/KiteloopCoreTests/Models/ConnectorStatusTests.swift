import XCTest
@testable import KiteloopCore

final class ConnectorStatusTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_000)

    func testEachServerGetsItsStatusAndItsOwnToolsWithoutThePrefix() {
        let payload: [String: Any] = [
            "mcp_servers": [["name": "tracker", "status": "connected"], ["name": "mail", "status": "needs-auth"]],
            "tools": ["Bash", "mcp__tracker__search", "mcp__tracker__create"]
        ]

        let statuses = ConnectorStatus.fromInitPayload(payload, at: date)

        XCTAssertEqual(statuses, [
            ConnectorStatus(name: "tracker", state: "connected", tools: ["create", "search"], reportedAt: date),
            ConnectorStatus(name: "mail", state: "needs-auth", tools: [], reportedAt: date)
        ])
    }

    func testAMissingOrMalformedServerListGivesNothing() {
        XCTAssertEqual(ConnectorStatus.fromInitPayload(["tools": ["mcp__tracker__search"]], at: date), [])
        XCTAssertEqual(ConnectorStatus.fromInitPayload(["mcp_servers": "tracker"], at: date), [])
        XCTAssertEqual(ConnectorStatus.fromInitPayload(["mcp_servers": ["name": "tracker"]], at: date), [])
    }

    func testAnUnknownStatusIsKeptVerbatim() {
        let statuses = ConnectorStatus.fromInitPayload(
            ["mcp_servers": [["name": "tracker", "status": "disabled"]]], at: date)

        XCTAssertEqual(statuses.map(\.state), ["disabled"])
    }

    func testNonMCPToolsAndServersNamedOnlyByAToolAreNotAttributed() {
        let payload: [String: Any] = [
            "mcp_servers": [["name": "tracker", "status": "connected"]],
            "tools": ["Bash", "Read", "tracker", "mcp__tracker", "mcp__mail__send", "mcp__trackerx__go"]
        ]

        let statuses = ConnectorStatus.fromInitPayload(payload, at: date)

        XCTAssertEqual(statuses.map(\.name), ["tracker"], "mail is named only by a tool")
        XCTAssertEqual(statuses.first?.tools, [])
    }
}
