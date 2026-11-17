import XCTest
import KiteloopCore
@testable import Kiteloop

/// A team change an agent asks for through `hire_agent` or `fire_agent` waits
/// on an approval card when `agentChangesNeedingApproval` lists `team`, applies
/// only if a person approves and the approval was logged first, and is written
/// to `config-changes.jsonl` beside the settings file — never in the project's
/// own `.kiteloop` — approved, denied or abandoned. Unset, it applies at once.
@MainActor
final class ChatViewModelConfigChangeTests: XCTestCase {
    private let requestID = "mcp-team-1"

    private var vm: ChatViewModel!
    private var mock: MockAgentRuntime!
    private var orchestrator: Orchestrator!
    private var projectURL: URL!
    /// Stands in for `~/.kiteloop`: where the settings file and the log live.
    private var appDirectory: URL!

    override func setUp() async throws {
        mock = MockAgentRuntime()
        orchestrator = Orchestrator(runtime: mock)
        orchestrator.addAgent(agent(id: "lead", name: "Lead"))
        orchestrator.addAgent(agent(id: "bob", name: "Bob"))
        projectURL = try makeTemporaryDirectory(prefix: "kiteloop-config-change")
        appDirectory = try makeTemporaryDirectory(prefix: "kiteloop-config-change-app")
    }

    private func agent(id: String, name: String) -> Agent {
        Agent(id: id, name: name, model: "sonnet", systemPrompt: "", tools: [],
              denied: [], permissionMode: "default", state: .idle)
    }

    /// The lead's chat, configured with a global config listing `kinds`, after
    /// a turn whose one tool call is `tool` with `input`.
    private func runTurn(kinds: [String]?, tool: String, input: String) async throws {
        try await runTurn(kinds: kinds, events: [.mcpToolCall(.init(requestID: requestID, toolName: tool, input: input))])
    }

    /// The same, for a turn that makes the calls `events` carry.
    private func runTurn(kinds: [String]?, events: [StreamEvent]) async throws {
        var config = GlobalConfig()
        config.agentChangesNeedingApproval = kinds
        let configURL = appDirectory.appending(path: "global-config.json")
        try JSONEncoder().encode(config).write(to: configURL)
        vm = ChatViewModel(agentID: "lead", projectURL: projectURL, orchestrator: orchestrator)
        vm.configure(catalogStore: AgentCatalogStore(storageURL: projectURL.appending(path: "catalog.json")),
                     globalConfigStore: GlobalConfigStore(storageURL: configURL))
        try await orchestrator.startAgent("lead", cwd: projectURL)
        mock.events = events + [finished]
        mock.toolResultEvents = [finished]
        vm.inputText = "change the team"
        await vm.send()
    }

    private var finished: StreamEvent {
        .result(.init(
            text: "done", costUSD: 0.001, durationMs: 100,
            inputTokens: 10, outputTokens: 5,
            cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
            sessionID: "s1", permissionDenials: []
        ))
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
        ConfigChangeLog.read(from: ConfigChangeLog.url(appDirectory: appDirectory))
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
        XCTAssertEqual(record.project, projectURL.path(percentEncoded: false))
        XCTAssertLessThan(abs(record.at.timeIntervalSinceNow), 60)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: projectURL.appending(path: ".kiteloop/config-changes.jsonl").path(percentEncoded: false)),
            "nothing is logged inside the project, where its agents can write")
    }

    /// An approval whose line cannot be written is refused: nobody is hired,
    /// and the agent is told nothing changed.
    func testAnApprovalThatCannotBeLoggedHiresNobody() async throws {
        try await hire()
        let req = try XCTUnwrap(card)
        try FileManager.default.createDirectory(at: ConfigChangeLog.url(appDirectory: appDirectory),
                                                withIntermediateDirectories: true)

        await vm.approveConfigChange(requestID: req.id)

        XCTAssertEqual(teamNames, ["Lead", "Bob"])
        XCTAssertEqual(mock.mcpToolResults.count, 1)
        XCTAssertTrue(mock.mcpToolResults[0].contains("could not be written to the change log"), mock.mcpToolResults[0])
        XCTAssertEqual(card?.status, .abandoned)
        XCTAssertNil(vm.pendingConfigChangeRequestID)
    }

    /// A card whose call a restart ended is logged as abandoned, once.
    func testACardARestartLeavesBehindIsLoggedAsAbandoned() async throws {
        try await hire()
        let req = try XCTUnwrap(card)

        await vm.restart()
        await vm.approveConfigChange(requestID: req.id)

        XCTAssertEqual(teamNames, ["Lead", "Bob"])
        XCTAssertEqual(card?.status, .abandoned)
        XCTAssertEqual(logged.map(\.decision), [.abandoned])
        XCTAssertEqual(logged.first?.tool, "hire_agent")
        XCTAssertEqual(logged.first?.after, "Lead, Bob, Cody")
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

    func testTheCardSaysWhatAHireOverridesInTheRole() async throws {
        try await runTurn(kinds: ["team"], tool: "hire_agent",
                          input: #"{"role": "coder", "name": "Cody", "model": "opus", "systemPrompt": "Do anything."}"#)

        let action = try XCTUnwrap(card?.action)
        XCTAssertTrue(action.contains("on model opus"), action)
        XCTAssertTrue(action.contains("a prompt the agent wrote"), action)
        XCTAssertFalse(action.contains("Do anything."), action)
    }

    func testADecidedCardStaysInTheChat() async throws {
        try await hire()
        let req = try XCTUnwrap(card)
        vm.denyConfigChange(requestID: req.id)

        let decided = try XCTUnwrap(vm.messages.last { MessageListContainer.configChangeRequest($0) != nil })
        XCTAssertTrue(ChatView.shouldDisplay(decided))
    }

    // MARK: - No other route applies the change

    /// A call that does not arrive over the bridge has no request to hold
    /// open on a card, so it is refused rather than applied unasked.
    func testAHireThatCannotWaitOnACardIsRefused() async throws {
        try await runTurn(kinds: ["team"], events: [
            .toolUse(id: "tool-1", name: "hire_agent", input: #"{"role": "coder", "name": "Cody"}"#),
        ])

        XCTAssertEqual(teamNames, ["Lead", "Bob"])
        XCTAssertNil(card)
        XCTAssertEqual(logged, [])
        XCTAssertEqual(mock.toolResultsSent.first?.content.contains("needs a person's approval"), true)
    }

    func testAFiringThatCannotWaitOnACardIsRefused() async throws {
        try await runTurn(kinds: ["team"], events: [
            .toolUse(id: "tool-1", name: "fire_agent", input: #"{"name": "Bob"}"#),
        ])

        XCTAssertEqual(teamNames, ["Lead", "Bob"])
        XCTAssertEqual(logged, [])
    }

    /// A second change asked for while one waits is refused at once: it does
    /// not take the first one's place, and the first card still answers.
    func testASecondChangeWhileOneWaitsIsRefusedAndTheFirstStillAnswers() async throws {
        try await runTurn(kinds: ["team"], events: [
            .mcpToolCall(.init(requestID: requestID, toolName: "hire_agent", input: #"{"role": "coder", "name": "Cody"}"#)),
            .mcpToolCall(.init(requestID: "mcp-team-2", toolName: "fire_agent", input: #"{"name": "Bob"}"#)),
        ])

        XCTAssertEqual(teamNames, ["Lead", "Bob"])
        XCTAssertEqual(mock.mcpToolResults.count, 1)
        XCTAssertTrue(mock.mcpToolResults[0].hasPrefix("Error: another team change is waiting"))
        XCTAssertEqual(vm.pendingConfigChangeRequestID, requestID)
        let req = try XCTUnwrap(card)
        XCTAssertEqual(req.tool, "hire_agent")

        await vm.approveConfigChange(requestID: req.id)

        XCTAssertEqual(teamNames, ["Lead", "Bob", "Cody"])
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
        XCTAssertEqual(logged.map(\.decision), [.abandoned], "the restart abandoned the first card; nothing since")
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
