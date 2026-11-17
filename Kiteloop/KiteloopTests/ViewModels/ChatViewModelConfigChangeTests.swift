import XCTest
import KiteloopCore
@testable import Kiteloop

/// A team change an agent asks for through `hire_agent` or `fire_agent` waits
/// on an approval card when `agentChangesNeedingApproval` lists `team`, applies
/// only if a person approves, and is written to the project's
/// `.kiteloop/config-changes.jsonl` either way. Unset, it applies at once.
@MainActor
final class ChatViewModelConfigChangeTests: XCTestCase {
    private let requestID = "mcp-team-1"

    private var vm: ChatViewModel!
    private var mock: MockAgentRuntime!
    private var orchestrator: Orchestrator!
    private var projectURL: URL!

    override func setUp() async throws {
        mock = MockAgentRuntime()
        orchestrator = Orchestrator(runtime: mock)
        orchestrator.addAgent(agent(id: "lead", name: "Lead"))
        orchestrator.addAgent(agent(id: "bob", name: "Bob"))
        projectURL = try makeTemporaryDirectory(prefix: "kiteloop-config-change")
    }

    private func agent(id: String, name: String) -> Agent {
        Agent(id: id, name: name, model: "sonnet", systemPrompt: "", tools: [],
              denied: [], permissionMode: "default", state: .idle)
    }

    /// The lead's chat, configured with a global config listing `kinds`, after
    /// a turn whose one tool call is `tool` with `input`.
    private func runTurn(kinds: [String]?, tool: String, input: String) async throws {
        var config = GlobalConfig()
        config.agentChangesNeedingApproval = kinds
        let configURL = projectURL.appending(path: "global-config.json")
        try JSONEncoder().encode(config).write(to: configURL)
        vm = ChatViewModel(agentID: "lead", projectURL: projectURL, orchestrator: orchestrator)
        vm.configure(catalogStore: AgentCatalogStore(storageURL: projectURL.appending(path: "catalog.json")),
                     globalConfigStore: GlobalConfigStore(storageURL: configURL))
        try await orchestrator.startAgent("lead", cwd: projectURL)
        mock.events = [
            .mcpToolCall(.init(requestID: requestID, toolName: tool, input: input)),
            .result(.init(
                text: "done", costUSD: 0.001, durationMs: 100,
                inputTokens: 10, outputTokens: 5,
                cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                sessionID: "s1", permissionDenials: []
            )),
        ]
        vm.inputText = "change the team"
        await vm.send()
    }

    private func hire() async throws {
        try await runTurn(kinds: ["team"], tool: "hire_agent", input: #"{"role": "coder", "name": "Cody"}"#)
    }

    private func fire() async throws {
        try await runTurn(kinds: ["team"], tool: "fire_agent", input: #"{"name": "Bob"}"#)
    }

    private var card: Message.ApprovalRequest? {
        for message in vm.messages.reversed() {
            if case .approval(let req) = message.content, req.tool == "hire_agent" || req.tool == "fire_agent" {
                return req
            }
        }
        return nil
    }

    private var teamNames: [String] { orchestrator.teamAgents.map(\.name) }

    private var logged: [ConfigChangeLog.Record] {
        ConfigChangeLog.read(from: ConfigChangeLog.url(projectPath: projectURL.path(percentEncoded: false)))
    }

    // MARK: - Unset: as today

    func testUnsetHiresAtOnceAndLogsNothing() async throws {
        try await runTurn(kinds: nil, tool: "hire_agent", input: #"{"role": "coder", "name": "Cody"}"#)

        XCTAssertTrue(teamNames.contains("Cody"))
        XCTAssertEqual(mock.mcpToolResults.count, 1)
        XCTAssertTrue(mock.mcpToolResults[0].hasPrefix("Hired 'Cody'"))
        XCTAssertNil(card)
        XCTAssertNil(vm.pendingConfigChangeRequestID)
        XCTAssertEqual(logged, [])
    }

    func testAnEmptyListHiresAtOnce() async throws {
        try await runTurn(kinds: [], tool: "hire_agent", input: #"{"role": "coder", "name": "Cody"}"#)

        XCTAssertTrue(teamNames.contains("Cody"))
        XCTAssertNil(card)
        XCTAssertEqual(logged, [])
    }

    // MARK: - Listed: the call waits on a card

    func testAHireWaitsOnACardWithTheRosterBeforeAndAfter() async throws {
        try await hire()

        XCTAssertFalse(teamNames.contains("Cody"))
        XCTAssertEqual(mock.mcpToolResults, [])
        let req = try XCTUnwrap(card)
        XCTAssertEqual(req.status, .pending)
        XCTAssertEqual(req.before, "Lead, Bob")
        XCTAssertEqual(req.after, "Lead, Bob, Cody")
        XCTAssertEqual(vm.pendingConfigChangeRequestID, requestID)
        XCTAssertEqual(logged, [])
    }

    func testAnApprovedHireJoinsTheTeamAndIsLogged() async throws {
        try await hire()
        let req = try XCTUnwrap(card)

        await vm.approveConfigChange(requestID: req.id)

        XCTAssertTrue(teamNames.contains("Cody"))
        XCTAssertEqual(mock.mcpToolResults.count, 1)
        XCTAssertTrue(mock.mcpToolResults[0].hasPrefix("Hired 'Cody'"))
        XCTAssertEqual(card?.status, .approved)
        XCTAssertNil(vm.pendingConfigChangeRequestID)
        let record = try XCTUnwrap(logged.first)
        XCTAssertEqual(logged.count, 1)
        XCTAssertEqual(record.decision, .approved)
        XCTAssertEqual(record.requestedBy, "Lead")
        XCTAssertEqual(record.kind, "team")
        XCTAssertEqual(record.tool, "hire_agent")
        XCTAssertEqual(record.before, "Lead, Bob")
        XCTAssertEqual(record.after, "Lead, Bob, Cody")
        XCTAssertLessThan(abs(record.at.timeIntervalSinceNow), 60)
    }

    func testADeniedHireLeavesTheTeamAndIsLogged() async throws {
        try await hire()
        let req = try XCTUnwrap(card)

        vm.denyConfigChange(requestID: req.id)

        XCTAssertEqual(teamNames, ["Lead", "Bob"])
        XCTAssertEqual(mock.mcpToolResults, ["Denied by the user: \(req.action)"])
        XCTAssertEqual(card?.status, .denied)
        XCTAssertEqual(logged.map(\.decision), [.denied])
    }

    func testAFiringWaitsAndAnApprovedOneRemovesTheAgent() async throws {
        try await fire()
        let req = try XCTUnwrap(card)
        XCTAssertEqual(teamNames, ["Lead", "Bob"])
        XCTAssertEqual(mock.mcpToolResults, [])
        XCTAssertEqual(req.before, "Lead, Bob")
        XCTAssertEqual(req.after, "Lead")

        await vm.approveConfigChange(requestID: req.id)

        XCTAssertEqual(teamNames, ["Lead"])
        XCTAssertEqual(mock.mcpToolResults.count, 1)
        XCTAssertTrue(mock.mcpToolResults[0].hasPrefix("Fired 'Bob'"))
        XCTAssertEqual(card?.status, .approved)
        XCTAssertEqual(logged.map(\.decision), [.approved])
        XCTAssertEqual(logged.first?.tool, "fire_agent")
    }

    func testADeniedFiringKeepsTheAgentAndIsLogged() async throws {
        try await fire()
        let req = try XCTUnwrap(card)

        vm.denyConfigChange(requestID: req.id)

        XCTAssertEqual(teamNames, ["Lead", "Bob"])
        XCTAssertEqual(mock.mcpToolResults, ["Denied by the user: \(req.action)"])
        XCTAssertEqual(card?.status, .denied)
        XCTAssertEqual(logged.map(\.decision), [.denied])
    }

    // MARK: - Only the card drawn for the pending request answers it

    /// A card left pending by a restart, with a newer request now waiting on
    /// its own card: the older card answers nothing, and the newer still waits.
    func testACardThatIsNotThePendingOneAppliesNothing() async throws {
        try await hire()
        let stale = try XCTUnwrap(card)
        await vm.restart()
        XCTAssertNil(vm.pendingConfigChangeRequestID)
        vm.inputText = "change the team again"
        await vm.send()
        let current = try XCTUnwrap(card)
        XCTAssertNotEqual(current.id, stale.id)

        await vm.approveConfigChange(requestID: stale.id)
        vm.denyConfigChange(requestID: stale.id)

        XCTAssertFalse(teamNames.contains("Cody"))
        XCTAssertEqual(mock.mcpToolResults, [])
        XCTAssertEqual(vm.pendingConfigChangeRequestID, requestID)
        XCTAssertEqual(vm.pendingConfigChangeCardID, current.id)
        XCTAssertEqual(logged, [])
    }

    func testACardAnsweredOnceCannotBeAnsweredAgain() async throws {
        try await hire()
        let req = try XCTUnwrap(card)
        vm.denyConfigChange(requestID: req.id)

        await vm.approveConfigChange(requestID: req.id)

        XCTAssertFalse(teamNames.contains("Cody"))
        XCTAssertEqual(mock.mcpToolResults.count, 1)
        XCTAssertEqual(logged.count, 1)
    }
}
