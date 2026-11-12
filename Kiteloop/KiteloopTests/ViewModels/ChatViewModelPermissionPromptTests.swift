import XCTest
import KiteloopCore
@testable import Kiteloop

/// What a session stops to ask becomes a card in its chat; the card's answer
/// goes back to the session, and the agent reads as waiting on you until it
/// does — with no limit on the wait.
@MainActor
final class ChatViewModelPermissionPromptTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "kiteloop-permission-prompt")
    }

    // MARK: - Helpers

    private func makeVM(permissionMode: String = "default") async throws -> (ChatViewModel, MockAgentRuntime, Orchestrator) {
        let mock = MockAgentRuntime()
        let orchestrator = Orchestrator(runtime: mock)
        orchestrator.configureNotifications(notificationsURL: tempDir.appending(path: "notifications.log"))
        orchestrator.addAgent(Agent(id: "builder", name: "Builder", model: "sonnet", systemPrompt: "", tools: [],
                                    denied: [], permissionMode: permissionMode, state: .idle))
        try await orchestrator.startAgent("builder", cwd: tempDir)
        let vm = ChatViewModel(agentID: "builder", projectURL: tempDir, orchestrator: orchestrator)
        return (vm, mock, orchestrator)
    }

    private let offer = PermissionPrompt.Suggestion(label: "Always allow Bash(make) in this project",
                                                    json: #"{"behavior":"allow","type":"addRules"}"#)

    private func leave(_ id: String = "req-1", subagentTask: String? = nil) -> PermissionPrompt.Line {
        .request(PermissionPrompt.Request(id: id, toolName: "Bash", input: #"{"command":"make"}"#,
                                          subagentTaskID: subagentTask, suggestions: [offer]))
    }

    private func cards(_ vm: ChatViewModel) -> [Message.PermissionRequest] {
        vm.messages.compactMap { message in
            if case .permission(let request) = message.content { return request }
            return nil
        }
    }

    private func state(_ orchestrator: Orchestrator) -> Agent.AgentState? {
        orchestrator.agents.first { $0.id == "builder" }?.state
    }

    /// The answer written to the session for request `id`, as its inner object.
    private func answer(to id: String, in mock: MockAgentRuntime, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let written = try XCTUnwrap(mock.controlLines.last { $0.contains(id) }, "no answer was written for \(id)", file: file, line: line)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(written.utf8)) as? [String: Any], file: file, line: line)
        let outer = try XCTUnwrap(json["response"] as? [String: Any], file: file, line: line)
        return try XCTUnwrap(outer["response"] as? [String: Any], file: file, line: line)
    }

    private func opened(_ vm: ChatViewModel, _ mock: MockAgentRuntime, _ prompt: PermissionPrompt.Line, count: Int = 1) async throws {
        mock.prompt(prompt)
        try await eventually("the card to open") { vm.openPromptCount == count }
    }

    // MARK: - Opening

    func testARequestOpensACardAndTheAgentWaitsOnYou() async throws {
        let (vm, mock, orchestrator) = try await makeVM()

        try await opened(vm, mock, leave())

        let card = try XCTUnwrap(cards(vm).first)
        XCTAssertEqual(card.id, "req-1")
        XCTAssertEqual(card.toolName, "Bash")
        XCTAssertEqual(card.summary, "make")
        XCTAssertNil(card.answer)
        XCTAssertEqual(state(orchestrator), .waitingForHuman)
        XCTAssertTrue(mock.controlLines.isEmpty, "nothing is answered until you answer")
    }

    func testASubagentsRequestNamesTheTaskItWasGiven() async throws {
        let (vm, mock, _) = try await makeVM()
        mock.events = [
            .system(subtype: "task_started", payload: ["task_id": "task-9", "tool_use_id": "toolu_agent",
                                                       "description": "Run the tests", "task_type": "local_agent"]),
            .result(.init(text: "started", costUSD: 0, durationMs: 1, inputTokens: 1, outputTokens: 1,
                          cacheCreationInputTokens: 0, cacheReadInputTokens: 0, sessionID: "s", permissionDenials: [])),
        ]
        vm.inputText = "run them in the background"
        await vm.send()

        try await opened(vm, mock, leave(subagentTask: "task-9"))

        XCTAssertEqual(cards(vm).first?.subagent, "Run the tests")
        XCTAssertEqual(PermissionCard.title(for: try XCTUnwrap(cards(vm).first)), "Subagent “Run the tests” asks to use Bash")
    }

    // MARK: - Answering

    func testAllowOnceAnswersTheSessionAndReleasesTheAgent() async throws {
        let (vm, mock, orchestrator) = try await makeVM()
        try await opened(vm, mock, leave())

        XCTAssertTrue(vm.answerPermission(requestID: "req-1", allow: true))

        let sent = try answer(to: "req-1", in: mock)
        XCTAssertEqual(sent["behavior"] as? String, "allow")
        XCTAssertEqual((sent["updatedInput"] as? [String: Any])?["command"] as? String, "make")
        XCTAssertNil(sent["updatedPermissions"])
        XCTAssertEqual(cards(vm).first?.answer, .allowed)
        XCTAssertEqual(vm.openPromptCount, 0)
        XCTAssertEqual(state(orchestrator), .idle)
    }

    func testAlwaysAllowHandsTheOfferBackToBeRemembered() async throws {
        let (vm, mock, _) = try await makeVM()
        try await opened(vm, mock, leave())

        XCTAssertTrue(vm.answerPermission(requestID: "req-1", allow: true, remembering: 0))

        let remembered = try XCTUnwrap(try answer(to: "req-1", in: mock)["updatedPermissions"] as? [[String: Any]])
        XCTAssertEqual(remembered.first?["type"] as? String, "addRules")
        XCTAssertEqual(cards(vm).first?.answer, .allowedAlways)
    }

    func testDenyTellsTheSessionToStop() async throws {
        let (vm, mock, _) = try await makeVM()
        try await opened(vm, mock, leave())

        XCTAssertTrue(vm.answerPermission(requestID: "req-1", allow: false))

        let sent = try answer(to: "req-1", in: mock)
        XCTAssertEqual(sent["behavior"] as? String, "deny")
        XCTAssertEqual(sent["message"] as? String, PermissionPrompt.declined)
        XCTAssertEqual(cards(vm).first?.answer, .denied)
    }

    func testACardIsAnsweredOnceAndAnUnknownOneNotAtAll() async throws {
        let (vm, mock, _) = try await makeVM()
        try await opened(vm, mock, leave())
        XCTAssertTrue(vm.answerPermission(requestID: "req-1", allow: false))

        XCTAssertFalse(vm.answerPermission(requestID: "req-1", allow: true))
        XCTAssertFalse(vm.answerPermission(requestID: "req-7", allow: true))

        XCTAssertEqual(mock.controlLines.count, 1, "only the first answer reached the session")
        XCTAssertEqual(cards(vm).first?.answer, .denied)
    }

    func testTwoSubagentsWaitingAreAnsweredEachOnItsOwn() async throws {
        let (vm, mock, orchestrator) = try await makeVM()
        try await opened(vm, mock, leave("req-1"))
        try await opened(vm, mock, leave("req-2"), count: 2)

        XCTAssertTrue(vm.answerPermission(requestID: "req-2", allow: true))

        XCTAssertEqual(vm.openPromptCount, 1)
        XCTAssertEqual(state(orchestrator), .waitingForHuman, "one card still waits")
        XCTAssertEqual(cards(vm).map(\.answer), [nil, .allowed])
    }

    /// The session lists a call you refused among its denials when the turn
    /// ends. The card already says Denied; only a call nobody was asked
    /// about earns the line that points at Settings.
    func testACallDeniedOnItsCardGetsNoSecondPermissionDeniedLine() async throws {
        let (vm, mock, _) = try await makeVM()
        try await opened(vm, mock, leave())
        XCTAssertTrue(vm.answerPermission(requestID: "req-1", allow: false))
        mock.events = [.result(.init(
            text: "stopped", costUSD: 0, durationMs: 1, inputTokens: 1, outputTokens: 1,
            cacheCreationInputTokens: 0, cacheReadInputTokens: 0, sessionID: "s",
            permissionDenials: [.init(toolName: "Bash", detail: "make"), .init(toolName: "WebFetch", detail: "")]))]

        vm.inputText = "go on"
        await vm.send()

        let errors = vm.messages.compactMap { message -> String? in
            if case .error(let text) = message.content { return text }
            return nil
        }
        XCTAssertEqual(errors.count, 1, "one line, for the call nobody was asked about")
        XCTAssertTrue(errors[0].contains("WebFetch"))
    }

    // MARK: - Lapsing

    func testAQuestionTheSessionTakesBackLapsesItsCard() async throws {
        let (vm, mock, orchestrator) = try await makeVM()
        try await opened(vm, mock, leave())

        mock.prompt(.cancelled(requestID: "req-1"))

        try await eventually("the card to lapse") { vm.openPromptCount == 0 }
        XCTAssertEqual(cards(vm).first?.answer, .lapsed)
        XCTAssertEqual(state(orchestrator), .idle)
        XCTAssertFalse(vm.answerPermission(requestID: "req-1", allow: true), "a lapsed card answers nothing")
        XCTAssertTrue(mock.controlLines.isEmpty)
    }

    func testStoppingTheAgentLapsesWhatItsSessionWasAsking() async throws {
        let (vm, mock, orchestrator) = try await makeVM()
        try await opened(vm, mock, leave())

        orchestrator.stopAgent("builder")

        XCTAssertEqual(vm.openPromptCount, 0)
        XCTAssertEqual(cards(vm).first?.answer, .lapsed)
        XCTAssertTrue(mock.controlLines.isEmpty, "the session is gone; nothing is written to it")
    }

    // MARK: - The model's own questions

    func testTheModelsQuestionsOpenAChoicesCardAndTheAnswersGoBack() async throws {
        let (vm, mock, _) = try await makeVM()
        let input = #"{"questions":[{"question":"Tea or coffee?","header":"Drink","multiSelect":false,"options":[{"label":"Tea","description":""},{"label":"Coffee","description":""}]}]}"#
        try await opened(vm, mock, .request(PermissionPrompt.Request(id: "req-q", toolName: "AskUserQuestion", input: input, needsAnswer: true)))

        XCTAssertFalse(vm.answerChoices(requestID: "req-q", answers: []), "no answer for the question asked")
        XCTAssertTrue(vm.answerChoices(requestID: "req-q", answers: ["Coffee"]))

        let sent = try answer(to: "req-q", in: mock)
        XCTAssertEqual(sent["behavior"] as? String, "allow")
        XCTAssertEqual((sent["updatedInput"] as? [String: Any])?["answers"] as? [String: String], ["Tea or coffee?": "Coffee"])
        XCTAssertEqual(vm.openPromptCount, 0)
    }

    // MARK: - An offered plan

    private func offeredPlan(_ vm: ChatViewModel, _ mock: MockAgentRuntime) async throws -> UUID {
        let input = #"{"plan":"1. Build it","planFilePath":"/tmp/plan.md"}"#
        try await opened(vm, mock, .request(PermissionPrompt.Request(id: "req-plan", toolName: "ExitPlanMode", input: input, needsAnswer: true)))
        return try XCTUnwrap(vm.messages.last { if case .plan = $0.content { return true } else { return false } }).id
    }

    func testApprovingAnOfferedPlanAnswersTheSessionAndMovesTheAgentToThatMode() async throws {
        let (vm, mock, orchestrator) = try await makeVM(permissionMode: "plan")
        let cardID = try await offeredPlan(vm, mock)
        mock.lastStartedAgent = nil

        await vm.answerPlan(messageID: cardID, with: .approveAcceptEdits)

        let sent = try answer(to: "req-plan", in: mock)
        XCTAssertEqual(sent["behavior"] as? String, "allow")
        XCTAssertEqual((sent["updatedInput"] as? [String: Any])?["planFilePath"] as? String, "/tmp/plan.md")
        XCTAssertEqual((sent["updatedPermissions"] as? [[String: Any]])?.first?["mode"] as? String, "acceptEdits")
        XCTAssertEqual(orchestrator.agents.first?.permissionMode, "acceptEdits")
        XCTAssertNil(mock.lastStartedAgent, "the session that offered the plan builds it; nothing restarts")
        XCTAssertTrue(mock.sentMessages.isEmpty, "and no message is sent: the turn that offered the plan goes on")
        XCTAssertEqual(vm.openPromptCount, 0)
    }

    func testKeepPlanningHandsBackWhatShouldChange() async throws {
        let (vm, mock, orchestrator) = try await makeVM(permissionMode: "plan")
        let cardID = try await offeredPlan(vm, mock)

        await vm.answerPlan(messageID: cardID, with: .keepPlanning, feedback: " smaller steps ")

        let sent = try answer(to: "req-plan", in: mock)
        XCTAssertEqual(sent["behavior"] as? String, "deny")
        XCTAssertEqual(sent["message"] as? String, "smaller steps")
        XCTAssertEqual(orchestrator.agents.first?.permissionMode, "plan")
        XCTAssertTrue(mock.sentMessages.isEmpty)
    }

    func testTypingPastAnOfferedPlanRefusesItRatherThanLeavingTheSessionWaiting() async throws {
        let (vm, mock, _) = try await makeVM(permissionMode: "plan")
        _ = try await offeredPlan(vm, mock)

        vm.inputText = "actually, do something else"
        await vm.send()

        XCTAssertEqual(try answer(to: "req-plan", in: mock)["behavior"] as? String, "deny")
        XCTAssertEqual(vm.openPromptCount, 0)
    }

    // MARK: - Mode and tasks

    func testTheAgentsModeFollowsWhatTheSessionSaysItIsIn() async throws {
        let (vm, mock, orchestrator) = try await makeVM(permissionMode: "default")
        mock.events = [
            .system(subtype: "status", payload: ["status": NSNull(), "permissionMode": "acceptEdits"]),
            .system(subtype: "status", payload: ["status": NSNull(), "permissionMode": "something-new"]),
            .result(.init(text: "ok", costUSD: 0, durationMs: 1, inputTokens: 1, outputTokens: 1,
                          cacheCreationInputTokens: 0, cacheReadInputTokens: 0, sessionID: "s", permissionDenials: [])),
        ]
        vm.inputText = "go"
        await vm.send()

        XCTAssertEqual(orchestrator.agents.first?.permissionMode, "acceptEdits",
                       "a mode the session moved to is the agent's; one Kiteloop has no name for is not")
    }

    func testStoppingOneTaskTellsTheSessionWhichAndOnlyWhileItRuns() async throws {
        let (vm, mock, _) = try await makeVM()
        mock.events = [
            .system(subtype: "task_started", payload: ["task_id": "task-9", "tool_use_id": "toolu_agent",
                                                       "description": "Run the tests", "task_type": "local_agent"]),
            .result(.init(text: "started", costUSD: 0, durationMs: 1, inputTokens: 1, outputTokens: 1,
                          cacheCreationInputTokens: 0, cacheReadInputTokens: 0, sessionID: "s", permissionDenials: [])),
        ]
        vm.inputText = "run them"
        await vm.send()
        XCTAssertEqual(vm.runningTasks.map(\.taskID), ["task-9"])

        XCTAssertFalse(vm.stopTask("task-1"), "no such task runs")
        XCTAssertTrue(mock.controlLines.isEmpty)
        XCTAssertTrue(vm.stopTask("task-9"))

        let line = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(mock.controlLines.last).utf8)) as? [String: Any])
        XCTAssertEqual((line["request"] as? [String: Any])?["subtype"] as? String, "stop_task")
        XCTAssertEqual((line["request"] as? [String: Any])?["task_id"] as? String, "task-9")
    }

    // MARK: - Streaming beside a card

    /// A card that lands while the agent is mid-sentence is not written over
    /// by the rest of the sentence.
    func testTextStreamingPastACardStillWritesIntoItsOwnMessage() async throws {
        let (vm, mock, _) = try await makeVM()
        mock.events = (1...8).map { StreamEvent.assistantText("part \($0) ") } + [
            .result(.init(text: "", costUSD: 0, durationMs: 1, inputTokens: 1, outputTokens: 1,
                          cacheCreationInputTokens: 0, cacheReadInputTokens: 0, sessionID: "s", permissionDenials: [])),
        ]
        vm.inputText = "go"
        async let turn: Void = vm.send()
        try await eventually("the reply to start streaming") { vm.messages.contains { $0.sender == .agent("builder") } }
        mock.prompt(leave())
        await turn

        XCTAssertEqual(cards(vm).count, 1, "the card is still a card")
        let said = vm.messages.compactMap { message -> String? in
            if case .text(let text) = message.content, message.sender == .agent("builder") { return text }
            return nil
        }
        XCTAssertEqual(said, [(1...8).map { "part \($0) " }.joined()], "and the reply is one message, whole")
    }
}
