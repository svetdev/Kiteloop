import XCTest
import KiteloopCore
@testable import Kiteloop

/// A turn the CLI starts by itself — its answer to background work finishing
/// after the turn that launched it ended — is shown as a turn of its own,
/// with no human message before it, and nothing of it reaches a chat that
/// was cleared or switched since.
@MainActor
final class ChatViewModelUnpromptedTurnTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "kiteloop-unprompted-turn")
    }

    /// `beforeChat` runs before the chat exists — a workflow started there
    /// does not auto-send its node's prompt to it.
    private func makeVM(
        beforeChat: (Orchestrator) async throws -> Void = { _ in }
    ) async throws -> (ChatViewModel, MockAgentRuntime, Orchestrator) {
        let mock = MockAgentRuntime()
        let orchestrator = Orchestrator(runtime: mock)
        orchestrator.addAgent(Agent(
            id: "test-agent", name: "TestAgent", model: "sonnet",
            systemPrompt: "", tools: [], denied: [], permissionMode: "default", state: .idle
        ))
        try await orchestrator.startAgent("test-agent", cwd: tempDir)
        try await beforeChat(orchestrator)
        let vm = ChatViewModel(agentID: "test-agent", projectURL: tempDir, orchestrator: orchestrator)
        return (vm, mock, orchestrator)
    }

    private static func result(_ text: String, totalCost: Double) -> StreamEvent {
        .result(StreamEvent.ResultPayload(
            text: text, costUSD: totalCost, durationMs: 1, inputTokens: 1, outputTokens: 1,
            cacheCreationInputTokens: 0, cacheReadInputTokens: 0, sessionID: "s1", permissionDenials: []))
    }

    private static let initLine = StreamEvent.system(subtype: "init", payload: ["type": "system", "subtype": "init"])

    private static func texts(in messages: [Message]) -> [String] {
        messages.compactMap { message in
            guard case .text(let text) = message.content else { return nil }
            return message.sender == .human ? "human: \(text)" : "\(text)"
        }
    }

    /// A sent turn, then one the session started on its own after its
    /// `result`: the second's text follows the first's with no human message
    /// between, and its cost — a running total on the line — counts once.
    func testAnUnpromptedTurnShowsItsTextWithNoHumanMessageBeforeItAndCountsItsCostOnce() async throws {
        let (vm, mock, orchestrator) = try await makeVM()
        mock.events = [.assistantText("started it"), Self.result("started it", totalCost: 0.01)]
        vm.inputText = "go"
        await vm.send()

        mock.startUnpromptedTurn([Self.initLine, .assistantText("it finished"), Self.result("it finished", totalCost: 0.03)])
        try await eventually("the unprompted turn to be shown and to end") {
            vm.messages.count == 3 && !vm.isStreaming
        }

        XCTAssertEqual(Self.texts(in: vm.messages), ["human: go", "started it", "it finished"])
        XCTAssertEqual(vm.costUSD, 0.03, accuracy: 1e-9)
        XCTAssertEqual(vm.lastTurnCostUSD, 0.02, accuracy: 1e-9)
        XCTAssertEqual(mock.sentMessages.count, 1, "nothing was sent for it")
        XCTAssertEqual(orchestrator.agents.first?.state, .idle)
    }

    /// While the turn streams the chat reads as working; a message typed then
    /// is queued like one typed during any turn, and sent once it ends.
    func testASendDuringAnUnpromptedTurnIsQueuedThenSent() async throws {
        let (vm, mock, orchestrator) = try await makeVM()
        let slow = [Self.initLine] + (1...6).map { StreamEvent.assistantText(" part \($0)") }
            + [Self.result("", totalCost: 0.01)]
        mock.events = [.assistantText("the reply"), Self.result("the reply", totalCost: 0.02)]

        mock.startUnpromptedTurn(slow)
        try await eventually("the unprompted turn to start streaming") { vm.isStreaming && !vm.messages.isEmpty }
        XCTAssertEqual(orchestrator.agents.first?.state, .working)

        vm.inputText = "while you were at it"
        await vm.send()
        XCTAssertEqual(vm.queuedMessageCount, 1)
        XCTAssertTrue(mock.sentMessages.isEmpty, "not sent while the turn runs")

        try await eventually("the queued message to be sent and answered") {
            vm.messages.last.map { if case .text("the reply") = $0.content { return true } else { return false } } ?? false
        }
        XCTAssertEqual(mock.sentMessages.map(\.message).last?.hasSuffix("while you were at it"), true)
        XCTAssertEqual(Self.texts(in: vm.messages).suffix(2), ["human: while you were at it", "the reply"])
        XCTAssertEqual(vm.queuedMessageCount, 0)
    }

    /// A turn the session that was cleared away starts afterwards reaches no
    /// chat: the next turn the new session starts is shown, the late one not.
    func testClearingTheChatDropsALateUnpromptedTurnFromTheOldSession() async throws {
        let (vm, mock, _) = try await makeVM()
        mock.events = [.assistantText("before"), Self.result("before", totalCost: 0.01)]
        vm.inputText = "go"
        await vm.send()
        await vm.clear()

        mock.startUnpromptedTurn([Self.initLine, .assistantText("late"), Self.result("late", totalCost: 0.02)],
                                 onListener: 0)
        mock.startUnpromptedTurn([Self.initLine, .assistantText("fresh"), Self.result("fresh", totalCost: 0.01)])
        try await eventually("the new session's turn to be shown") {
            Self.texts(in: vm.messages).contains("fresh") && !vm.isStreaming
        }
        XCTAssertEqual(Self.texts(in: vm.messages), ["fresh"])
    }

    /// Cleared while the turn is still streaming: nothing more of it is
    /// written, and the chat stops reading as busy.
    func testClearingTheChatMidTurnStopsWritingIt() async throws {
        let (vm, mock, _) = try await makeVM()
        let long = [Self.initLine, .assistantText("first")]
            + (1...10).map { StreamEvent.toolUse(id: "t\($0)", name: "Read", input: "{}") }
            + [.assistantText("never shown"), Self.result("", totalCost: 0.01)]
        mock.startUnpromptedTurn(long)
        try await eventually("the turn to have started writing") { Self.texts(in: vm.messages) == ["first"] }

        await vm.clear()
        // `clear` leaves `isStreaming` alone: it goes false only when the
        // turn's own runner stops, after which nothing of it can be written.
        try await eventually("the abandoned turn to stop reading as streaming") { !vm.isStreaming }
        XCTAssertTrue(vm.messages.isEmpty, "\(vm.messages.map(\.content))")
        XCTAssertEqual(vm.costUSD, 0)
    }

    // MARK: - Workflow nodes

    private func graph(agentID: String) -> WorkflowGraph {
        WorkflowGraph(
            id: "unprompted-turn-graph", name: "Test", version: 1,
            nodes: ["worker": WorkflowNode(id: "worker", agentID: agentID, prompt: "Do the work")],
            edges: [], entryNode: "worker", terminalNodes: ["worker"], metadata: .empty
        )
    }

    /// A worker's turn ended on a background agent it launched, so its node
    /// waits for a later turn. The turn the CLI starts when that agent reports
    /// is that later turn: its reply hands the node off, and no nudge is sent.
    func testAnUnpromptedTurnAfterAPendingLaunchHandsTheNodeOff() async throws {
        var execID = ""
        let (vm, mock, orchestrator) = try await makeVM { orchestrator in
            execID = try await orchestrator.startWorkflow(graph: self.graph(agentID: "test-agent"), initialState: [:])
        }
        mock.events = [
            .toolUse(id: "launch-1", name: "Agent", input: "{}"),
            .toolResult(id: "launch-1", output: "Async agent launched successfully. It will run in the background."),
            Self.result("Waiting for its report.", totalCost: 0.01),
        ]
        vm.inputText = "Investigate"
        await vm.send()
        XCTAssertEqual(orchestrator.pendingBackgroundAgentCount(for: "test-agent"), 1)

        mock.startUnpromptedTurn([Self.initLine, .assistantText("The report is in; fixed."),
                                  Self.result("The report is in; fixed.", totalCost: 0.02)])
        try await eventually("the unprompted turn to complete the node") {
            await orchestrator.workflowEngine.execution(id: execID)?.status == .completed
        }
        let execution = await orchestrator.workflowEngine.execution(id: execID)
        let closing = execution?.steps.last { $0.nodeID == "worker" }?.output?[RunClosingMessage.outputKey]?.stringValue
        XCTAssertEqual(closing, "The report is in; fixed.")
        XCTAssertEqual(orchestrator.pendingBackgroundAgentCount(for: "test-agent"), 0)
        XCTAssertEqual(mock.sentMessages.count, 1, "no nudge: the report came by itself")
    }

    /// With no launch pending, an unprompted turn — a background shell
    /// reporting in — is shown and nothing more: it does not complete the
    /// node the agent is on.
    func testAnUnpromptedTurnWithNothingPendingLeavesTheNodeAlone() async throws {
        var execID = ""
        let (vm, mock, orchestrator) = try await makeVM { orchestrator in
            execID = try await orchestrator.startWorkflow(graph: self.graph(agentID: "test-agent"), initialState: [:])
        }

        mock.startUnpromptedTurn([Self.initLine, .assistantText("the shell finished"),
                                  Self.result("the shell finished", totalCost: 0.01)])
        try await eventually("the unprompted turn to be shown and to end") {
            Self.texts(in: vm.messages) == ["the shell finished"] && !vm.isStreaming
        }
        let status = await orchestrator.workflowEngine.execution(id: execID)?.status
        XCTAssertEqual(status, .running)
    }

    /// The 2.1.281 fixture end to end: its first turn sent, and everything the
    /// CLI wrote after that `result` — the shell's notices, then a turn of its
    /// own — as the runtime hands it over. Both turns' text is shown, the
    /// second with no human message before it.
    func testTheFixturesTwoTurnsBothShow() async throws {
        let (vm, mock, _) = try await makeVM()
        let events = try StreamEventSubagentFixtureTests.fixtureEvents()
        let end = try XCTUnwrap(events.firstIndex { if case .result = $0 { return true } else { return false } })
        mock.events = Array(events[...end])
        vm.inputText = "multiply, list files, run in background"
        await vm.send()

        mock.startUnpromptedTurn(Array(events[(end + 1)...]))
        try await eventually(timeout: .seconds(10), "the CLI's own turn to be shown and to end") {
            Self.texts(in: vm.messages).contains { $0.hasPrefix("I did all three steps") } && !vm.isStreaming
        }

        let texts = Self.texts(in: vm.messages)
        XCTAssertEqual(texts.filter { $0.hasPrefix("human:") }.count, 1)
        XCTAssertTrue(texts.contains { $0.hasPrefix("17 × 23 = 391") })
        XCTAssertTrue(texts.contains { $0.hasPrefix("I started the background command") })
        XCTAssertEqual(vm.costUSD, 0.22322, accuracy: 1e-6, "the session's running total, counted once")
        XCTAssertTrue(vm.agentActivity.backgroundTasks.isEmpty)
    }
}
