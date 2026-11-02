import XCTest
import KiteloopCore
@testable import Kiteloop

/// The chat fed the stream `claude` 2.1.281 wrote for a subagent, a background
/// shell and an empty thinking block: the subagent's calls are kept as its
/// `Agent` call's children, and `agentActivity` follows the tasks.
@MainActor
final class ChatViewModelAgentActivityTests: XCTestCase {
    private var tempDir: URL!
    private var orchestrator: Orchestrator!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "kiteloop-agent-activity")
    }

    private func makeVM() async throws -> (ChatViewModel, MockAgentRuntime) {
        let mock = MockAgentRuntime()
        let orchestrator = Orchestrator(runtime: mock)
        self.orchestrator = orchestrator
        let agent = Agent(
            id: "test-agent", name: "TestAgent", model: "sonnet",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default", state: .idle
        )
        orchestrator.addAgent(agent)
        try await orchestrator.startAgent("test-agent", cwd: tempDir)
        let vm = ChatViewModel(agentID: "test-agent", projectURL: tempDir, orchestrator: orchestrator)
        return (vm, mock)
    }

    /// The fixture's first turn — everything up to and including its first
    /// `result` — and what the CLI sent after it.
    private static func fixtureTurns() throws -> (first: [StreamEvent], after: [StreamEvent]) {
        let events = try StreamEventSubagentFixtureTests.fixtureEvents()
        let end = try XCTUnwrap(events.firstIndex { if case .result = $0 { return true } else { return false } })
        return (Array(events[...end]), Array(events[(end + 1)...]))
    }

    private func runFirstTurn() async throws -> ChatViewModel {
        let (vm, mock) = try await makeVM()
        mock.events = try Self.fixtureTurns().first
        vm.inputText = "multiply, list files, run in background"
        await vm.send()
        return vm
    }

    private static func toolCalls(in messages: [Message]) -> [Message.ToolCall] {
        messages.compactMap { if case .toolCall(let call) = $0.content { return call } else { return nil } }
    }

    func testTheSubagentsCallsAreKeptAsChildrenOfTheAgentCallAndNotDrawnAtTheTop() async throws {
        let vm = try await runFirstTurn()
        let calls = Self.toolCalls(in: vm.messages)
        XCTAssertEqual(calls.map(\.name), ["Agent", "Bash", "SubagentHandback", "Bash"])
        XCTAssertEqual(calls.map(\.parentToolUseID),
                       [nil, StreamEventSubagentFixtureTests.agentCallID, StreamEventSubagentFixtureTests.agentCallID, nil])

        let topLevelCalls = Self.toolCalls(in: vm.messages.filter(ChatView.shouldDisplay))
        XCTAssertEqual(topLevelCalls.map(\.name), ["Agent", "Bash"], "the subagent's calls are not the agent's own rows")

        let results = vm.messages.compactMap { if case .toolResult(let r) = $0.content { return r } else { return nil } }
        XCTAssertEqual(results.filter { $0.parentToolUseID == StreamEventSubagentFixtureTests.agentCallID }.count, 2)
    }

    func testTheAgentCallsTaskCompletesAndTheBackgroundShellIsStillRunningWhenTheTurnEnds() async throws {
        let vm = try await runFirstTurn()
        let agentTask = try XCTUnwrap(vm.agentActivity.task(forToolUseID: StreamEventSubagentFixtureTests.agentCallID))
        XCTAssertEqual(agentTask.status, .completed)
        XCTAssertEqual(agentTask.progress?.toolUses, 2)

        let shell = try XCTUnwrap(vm.agentActivity.task(forToolUseID: "toolu_019XTqpLMCQiLwhBGP7wGzhZ"))
        XCTAssertEqual(AgentActivityDisplay.statusLine(for: shell), "running in background")
        XCTAssertEqual(vm.agentActivity.backgroundTasks.map(\.taskID), ["bjhve0mu5"])
    }

    func testWhatTheCLISaysAfterTheTurnFinishesTheShellAndEmptiesTheBackgroundList() async throws {
        let (vm, mock) = try await makeVM()
        let turns = try Self.fixtureTurns()
        mock.events = turns.first
        vm.inputText = "go"
        await vm.send()

        mock.events = turns.after
        vm.inputText = "and then"
        await vm.send()

        let shell = try XCTUnwrap(vm.agentActivity.task(forToolUseID: "toolu_019XTqpLMCQiLwhBGP7wGzhZ"))
        XCTAssertEqual(AgentActivityDisplay.statusLine(for: shell), "finished · exit code 0")
        XCTAssertTrue(vm.agentActivity.backgroundTasks.isEmpty)
    }

    func testTheEmptyThinkingBlockKeepsTheEstimateAndTheRoutineRateLimitSaysNothing() async throws {
        let vm = try await runFirstTurn()
        let thought = try XCTUnwrap(vm.messages.first { if case .thinking = $0.content { return true } else { return false } })
        XCTAssertEqual(thought.thinkingTokenEstimate, 201)
        XCTAssertNil(vm.agentActivity.thinkingTokens, "claimed by the block, not left for the next")
        XCTAssertFalse(vm.messages.contains { $0.sender == .system }, "an `allowed` rate limit is not news")
    }

    func testARateLimitWarningGetsOneSystemLine() async throws {
        let (vm, mock) = try await makeVM()
        let warning: [String: Any] = [
            "type": "rate_limit_event",
            "rate_limit_info": ["status": "allowed_warning", "rateLimitType": "five_hour",
                                "unifiedWindows": ["five_hour": ["utilization": 0.9]]],
        ]
        let notice = StreamEvent.system(subtype: AgentActivityEvent.rateLimitType, payload: warning)
        // A turn ends with its `result`, as a real one does; without it the chat
        // reads the end of the stream as a dropped connection and adds a
        // "Reconnecting…" line of its own.
        let done = StreamEvent.ResultPayload(
            text: "ok", costUSD: 0, durationMs: 1, inputTokens: 1, outputTokens: 1,
            cacheCreationInputTokens: 0, cacheReadInputTokens: 0, sessionID: "s1", permissionDenials: [])
        mock.events = [notice, notice, .assistantText("ok"), .result(done)]
        vm.inputText = "go"
        await vm.send()

        let lines = vm.messages.filter { $0.sender == .system }
        XCTAssertEqual(lines.count, 1)
        guard case .text(let text)? = lines.first?.content else { return XCTFail("no notice line") }
        XCTAssertEqual(text, "Approaching the rate limit (five-hour window) — 90% used")
    }

    /// The stream a `--forward-subagent-text` session writes: the subagent's
    /// thought and report are kept under its `Agent` call, beside its calls,
    /// and the list draws only the agent's own summary.
    func testForwardedSubagentTextAndThinkingNestUnderTheAgentCall() async throws {
        let (vm, mock) = try await makeVM()
        mock.events = try StreamEventSubagentFixtureTests.forwardedTextEvents()
        vm.inputText = "Use a subagent to list files here, then summarise"
        await vm.send()

        let agentCall = StreamEventSubagentFixtureTests.forwardedAgentCallID
        let nested = vm.messages.filter { $0.parentToolUseID == agentCall }
        XCTAssertEqual(nested.count, 2)
        guard case .thinking = nested[0].content, case .text(let report) = nested[1].content else {
            return XCTFail("expected the subagent's thought, then its report: \(nested.map(\.content))")
        }
        XCTAssertTrue(report.hasPrefix("The directory holds only two files."))

        let shownTexts = vm.messages.filter(ChatView.shouldDisplay).compactMap { message -> String? in
            if case .text(let text) = message.content, message.sender != .human { return text } else { return nil }
        }
        XCTAssertEqual(shownTexts.count, 1, "the subagent's report is not the agent's own reply")
        XCTAssertTrue(shownTexts[0].hasPrefix("The directory holds only two small files."))
        XCTAssertFalse(vm.messages.filter(ChatView.shouldDisplay).contains { if case .thinking = $0.content { return true } else { return false } })

        let children = SubagentChild.byParent(in: vm.messages, results: [:])[agentCall] ?? []
        XCTAssertEqual(children.count, 7, "five calls, the thought and the report, in stream order")
        guard case .thinking = children[5].kind, case .text = children[6].kind else {
            return XCTFail("the thought and the report come after the calls they followed")
        }
    }

    /// A stream that ends without its `result` is a dropped connection: the
    /// chat restarts the agent and, once it is back, says the reply was cut
    /// off — a line kept with the chat.
    func testADroppedTurnThatReconnectsSaysTheReplyWasCutOffAndKeepsTheLine() async throws {
        let (vm, mock) = try await makeVM()
        let store = SessionStore(projectDir: tempDir)
        vm.setupSessionStore(store)
        mock.events = [.assistantText("partial")]
        vm.inputText = "go"
        await vm.send()

        let expected = "Reconnected — the reply to your last message was cut off. It is back in the input to send again."
        XCTAssertEqual(vm.inputText, "go", "the cut-off message is back in the input")
        let lastTwo = vm.messages.suffix(2).map(\.content)
        guard lastTwo.count == 2, case .systemEvent(let event) = lastTwo.first, case .text(let text) = lastTwo.last else {
            return XCTFail("expected the reconnecting divider, then a text line: \(lastTwo)")
        }
        XCTAssertEqual(event.kind, .reconnecting)
        XCTAssertEqual(text, expected)
        XCTAssertEqual(vm.messages.last?.sender, .system)
        XCTAssertFalse(vm.isProcessDead)

        try await eventually("the reconnect line to reach the saved chat") {
            let reloaded = ChatViewModel(agentID: "test-agent", projectURL: self.tempDir, orchestrator: Orchestrator(runtime: MockAgentRuntime()))
            reloaded.setupSessionStore(SessionStore(projectDir: self.tempDir))
            return reloaded.messages.contains { if case .text(expected) = $0.content { return true } else { return false } }
        }
    }

    private static let sendAgainLine = "Reconnected — the reply to your last message was cut off. Send it again to retry."

    private static func lastSystemText(_ vm: ChatViewModel) -> String? {
        guard let last = vm.messages.last, last.sender == .system, case .text(let text) = last.content else { return nil }
        return text
    }

    func testADraftTypedDuringADroppedTurnStaysAfterTheCutOffMessage() async throws {
        let (vm, mock) = try await makeVM()
        mock.events = [.assistantText("partial")]
        vm.inputText = "go"
        let turn = Task { await vm.send() }
        try await eventually("the turn to start streaming") { vm.isStreaming }
        vm.inputText = "a draft"
        await turn.value

        XCTAssertEqual(vm.inputText, "go\n\na draft")
        XCTAssertEqual(Self.lastSystemText(vm)?.contains("back in the input"), true)
    }

    func testADroppedForwardFromATeammatePutsNothingInTheInput() async throws {
        let (vm, mock) = try await makeVM()
        mock.events = [.assistantText("partial")]
        NotificationCenter.default.post(
            name: .agentTriggered, object: orchestrator,
            userInfo: ["agentID": "test-agent", "message": "from a teammate"])

        try await eventually("the forward's turn to reconnect") { Self.lastSystemText(vm) == Self.sendAgainLine }
        XCTAssertEqual(vm.inputText, "")
    }

    func testADroppedAnswerToAQuestionPutsNothingInTheInput() async throws {
        let (vm, mock) = try await makeVM()
        let done = StreamEvent.ResultPayload(
            text: "ok", costUSD: 0, durationMs: 1, inputTokens: 1, outputTokens: 1,
            cacheCreationInputTokens: 0, cacheReadInputTokens: 0, sessionID: "s1", permissionDenials: [])
        mock.events = [.toolUse(id: "ask-1", name: "ask_human", input: "{\"question\": \"Which port?\"}"), .result(done)]
        mock.toolResultEvents = [.assistantText("partial")]
        vm.inputText = "start it"
        await vm.send()
        XCTAssertEqual(vm.pendingHumanToolCallID, "ask-1")

        await vm.respondToHuman(requestID: "ask-1", answer: "8080")

        XCTAssertEqual(Self.lastSystemText(vm), Self.sendAgainLine)
        XCTAssertEqual(vm.inputText, "")
    }

    func testATurnThatEndsWithItsResultPostsNoReconnectLine() async throws {
        let (vm, mock) = try await makeVM()
        let done = StreamEvent.ResultPayload(
            text: "ok", costUSD: 0, durationMs: 1, inputTokens: 1, outputTokens: 1,
            cacheCreationInputTokens: 0, cacheReadInputTokens: 0, sessionID: "s1", permissionDenials: [])
        mock.events = [.assistantText("ok"), .result(done)]
        vm.inputText = "go"
        await vm.send()

        XCTAssertFalse(vm.messages.contains { $0.sender == .system }, "a finished turn did not reconnect")
    }

    func testClearingTheChatForgetsTheSessionsTasks() async throws {
        let vm = try await runFirstTurn()
        XCTAssertFalse(vm.agentActivity.tasks.isEmpty)
        await vm.clear()
        XCTAssertEqual(vm.agentActivity, AgentActivity())
    }
}
