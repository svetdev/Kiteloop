import XCTest
import KiteloopCore
@testable import Kiteloop

/// The init line a session opens with says which MCP servers started; the
/// chat hands that to its orchestrator, which keeps the newest per server.
@MainActor
final class ChatViewModelConnectorStatusTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "kiteloop-connector-status")
    }

    private func makeVM() async throws -> (ChatViewModel, MockAgentRuntime, Orchestrator) {
        let mock = MockAgentRuntime()
        let orchestrator = Orchestrator(runtime: mock)
        orchestrator.addAgent(Agent(
            id: "test-agent", name: "TestAgent", model: "sonnet",
            systemPrompt: "", tools: [], denied: [], permissionMode: "default", state: .idle
        ))
        try await orchestrator.startAgent("test-agent", cwd: tempDir)
        let vm = ChatViewModel(agentID: "test-agent", projectURL: tempDir, orchestrator: orchestrator)
        return (vm, mock, orchestrator)
    }

    private static func turn(opening payload: [String: Any]) -> [StreamEvent] {
        [.system(subtype: "init", payload: payload),
         .result(StreamEvent.ResultPayload(
            text: "ok", costUSD: 0.01, durationMs: 1, inputTokens: 1, outputTokens: 1,
            cacheCreationInputTokens: 0, cacheReadInputTokens: 0, sessionID: "s1", permissionDenials: []))]
    }

    func testTheInitLineRecordsEachServersStatusAndTools() async throws {
        let (vm, mock, orchestrator) = try await makeVM()
        mock.events = Self.turn(opening: [
            "type": "system", "subtype": "init", "model": "claude-opus-test",
            "mcp_servers": [["name": "tracker", "status": "connected"], ["name": "mail", "status": "failed"]],
            "tools": ["Bash", "mcp__tracker__search"]
        ])
        vm.inputText = "go"
        await vm.send()
        try await eventually("the turn to end") { !vm.isStreaming }

        XCTAssertEqual(orchestrator.connectorStatus(named: "tracker")?.state, "connected")
        XCTAssertEqual(orchestrator.connectorStatus(named: "tracker")?.tools, ["search"])
        XCTAssertEqual(orchestrator.connectorStatus(named: "mail")?.state, "failed")
        XCTAssertEqual(vm.currentModel, "claude-opus-test")
    }

    func testAnInitLineWithNoServersRecordsNothingAndStillReadsTheModel() async throws {
        let (vm, mock, orchestrator) = try await makeVM()
        mock.events = Self.turn(opening: ["type": "system", "subtype": "init", "model": "claude-sonnet-test",
                                          "context_window_size": 123_000, "tools": ["mcp__tracker__search"]])
        vm.inputText = "go"
        await vm.send()
        try await eventually("the turn to end") { !vm.isStreaming }

        XCTAssertNil(orchestrator.connectorStatus(named: "tracker"))
        XCTAssertEqual(vm.currentModel, "claude-sonnet-test")
        XCTAssertEqual(vm.contextWindowSize, 123_000)
    }

    func testTheOrchestratorKeepsTheNewerReportOfAServer() {
        let orchestrator = Orchestrator(runtime: MockAgentRuntime())
        let older = Date(timeIntervalSince1970: 1_000), newer = Date(timeIntervalSince1970: 2_000)

        orchestrator.recordConnectorStatuses([ConnectorStatus(name: "tracker", state: "connected", tools: ["a"], reportedAt: newer)])
        orchestrator.recordConnectorStatuses([ConnectorStatus(name: "tracker", state: "failed", tools: [], reportedAt: older)])
        XCTAssertEqual(orchestrator.connectorStatus(named: "tracker")?.state, "connected", "an older report does not replace a newer one")

        let newest = Date(timeIntervalSince1970: 3_000)
        orchestrator.recordConnectorStatuses([ConnectorStatus(name: "tracker", state: "needs-auth", tools: [], reportedAt: newest)])
        XCTAssertEqual(orchestrator.connectorStatus(named: "tracker")?.state, "needs-auth")
    }
}
