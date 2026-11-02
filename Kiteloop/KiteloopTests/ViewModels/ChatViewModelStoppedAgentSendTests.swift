import XCTest
import KiteloopCore
@testable import Kiteloop

/// A message to an agent with no live session — one stopped from the
/// sidebar — starts the session and reaches it, instead of going into an
/// empty stream the chat then reads as a crash.
@MainActor
final class ChatViewModelStoppedAgentSendTests: XCTestCase {
    private var projectURL: URL!

    override func setUpWithError() throws {
        projectURL = try makeTemporaryDirectory(prefix: "stopped-agent-send")
    }

    func testSendToStoppedAgentStartsItAndDeliversTheMessage() async {
        let runtime = MockAgentRuntime()
        runtime.events = [Self.result]
        let vm = makeViewModel(runtime: runtime)

        vm.inputText = "are you there?"
        await vm.send()

        XCTAssertEqual(runtime.lastSentMessage, "are you there?")
        XCTAssertNotNil(runtime.lastSessionOptions, "the send started a session")
        XCTAssertFalse(vm.isStreaming)
    }

    func testSendToStoppedAgentTakesNoCrashPath() async {
        let runtime = MockAgentRuntime()
        runtime.events = [Self.result]
        let vm = makeViewModel(runtime: runtime)

        vm.inputText = "hello"
        await vm.send()

        XCTAssertFalse(vm.messages.contains { $0.systemEventKind == .reconnecting })
        XCTAssertFalse(vm.messages.contains { $0.errorText?.contains("terminated unexpectedly") == true })
    }

    func testSendToStoppedAgentSaysItIsStartingBeforeTheReply() async throws {
        let runtime = MockAgentRuntime()
        runtime.events = [Self.result]
        let vm = makeViewModel(runtime: runtime)

        vm.inputText = "hello"
        await vm.send()

        let startIndex = try XCTUnwrap(vm.messages.firstIndex { $0.systemText == "Starting the agent…" })
        let replyIndex = try XCTUnwrap(vm.messages.firstIndex { $0.sender == .agent("test-agent") && $0.plainText == "Done" })
        XCTAssertLessThan(startIndex, replyIndex)
    }

    func testStartThatThrowsIsReportedAndNothingIsSent() async {
        let runtime = FailingStartRuntime()
        let vm = makeViewModel(runtime: runtime)

        vm.inputText = "hello"
        await vm.send()

        XCTAssertTrue(runtime.sent.isEmpty)
        XCTAssertFalse(vm.isStreaming)
        XCTAssertTrue(vm.messages.contains { $0.errorText?.contains(FailingStartRuntime.reason) == true },
                      "the error names the reason: \(vm.messages.map(\.content))")
        XCTAssertFalse(vm.messages.contains { $0.systemEventKind == .reconnecting })
    }

    func testSendToLiveSessionStartsNothing() async throws {
        let runtime = MockAgentRuntime()
        runtime.events = [Self.result]
        let orchestrator = makeOrchestrator(runtime: runtime)
        try await orchestrator.startAgent("test-agent", cwd: projectURL)
        runtime.lastSessionOptions = nil
        let vm = ChatViewModel(agentID: "test-agent", projectURL: projectURL, orchestrator: orchestrator)

        vm.inputText = "hello"
        await vm.send()

        XCTAssertEqual(runtime.lastSentMessage, "hello")
        XCTAssertNil(runtime.lastSessionOptions, "no second start")
        XCTAssertFalse(vm.messages.contains { $0.systemText == "Starting the agent…" })
    }

    // MARK: - Commands that send a turn of their own

    func testRecapOnStoppedAgentStartsItAndShowsTheReply() async throws {
        let runtime = MockAgentRuntime()
        runtime.events = [Self.result]
        let vm = makeViewModel(runtime: runtime)

        vm.inputText = "/recap"
        await vm.send()

        XCTAssertNotNil(runtime.lastSessionOptions, "/recap started a session")
        XCTAssertTrue(runtime.lastSentMessage?.hasPrefix("Provide a brief recap") == true,
                      "the recap prompt reached the runtime: \(runtime.lastSentMessage ?? "nil")")
        let startIndex = try XCTUnwrap(vm.messages.firstIndex { $0.systemText == "Starting the agent…" })
        let replyIndex = try XCTUnwrap(vm.messages.firstIndex { $0.sender == .agent("test-agent") && $0.plainText == "Done" })
        XCTAssertLessThan(startIndex, replyIndex)
        XCTAssertFalse(vm.isStreaming)
    }

    func testLoopOnAgentWhoseStartThrowsRunsNothing() async {
        let runtime = FailingStartRuntime()
        let vm = makeViewModel(runtime: runtime)

        vm.inputText = "/loop keep going"
        await vm.send()

        XCTAssertTrue(runtime.sent.isEmpty)
        XCTAssertNil(vm.activeGoal)
        XCTAssertTrue(vm.messages.contains { $0.errorText?.contains(FailingStartRuntime.reason) == true },
                      "the error names the reason: \(vm.messages.map(\.content))")
        XCTAssertFalse(vm.messages.contains { $0.plainText?.hasPrefix("Loop started") == true })
        XCTAssertFalse(vm.messages.contains { $0.plainText?.hasPrefix("Loop ended after") == true })
    }

    func testGoalOnAgentWhoseStartThrowsRunsNothing() async {
        let runtime = FailingStartRuntime()
        let vm = makeViewModel(runtime: runtime)

        vm.inputText = "/goal the tests pass"
        await vm.send()

        XCTAssertTrue(runtime.sent.isEmpty)
        XCTAssertNil(vm.activeGoal)
        XCTAssertTrue(vm.messages.contains { $0.errorText?.contains(FailingStartRuntime.reason) == true },
                      "the error names the reason: \(vm.messages.map(\.content))")
        XCTAssertFalse(vm.messages.contains { $0.plainText?.hasPrefix("Goal set") == true })
        XCTAssertFalse(vm.messages.contains { $0.plainText?.hasPrefix("Goal loop ended") == true })
    }

    func testCompactOnStoppedAgentWithAStoredSessionStartsItFirst() async throws {
        try storeSessionID("s-compact")
        let runtime = MockAgentRuntime()
        runtime.events = [Self.result]
        let vm = makeViewModel(runtime: runtime)

        vm.inputText = "/compact"
        await vm.send()

        XCTAssertNotNil(runtime.lastSessionOptions, "/compact started a session")
        XCTAssertEqual(runtime.lastSentMessage, "/compact")
        XCTAssertTrue(vm.messages.contains { $0.systemText == "Starting the agent…" })
    }

    func testCompactInAChatWithNoTurnYetStartsNothing() async {
        let runtime = MockAgentRuntime()
        let vm = makeViewModel(runtime: runtime)

        vm.inputText = "/compact"
        await vm.send()

        XCTAssertTrue(vm.messages.contains { $0.systemText == "No session to compact — send at least one message first." })
        XCTAssertNil(runtime.lastSessionOptions, "no start")
        XCTAssertNil(runtime.lastSentMessage)
        XCTAssertFalse(vm.messages.contains { $0.systemText == "Starting the agent…" })
    }

    func testRecapCompactAndGoalOnALiveSessionStartNothing() async throws {
        try storeSessionID("s-live")
        let runtime = MockAgentRuntime()
        runtime.events = [Self.goalCompleteResult]
        let vm = try await makeLiveViewModel(runtime: runtime)

        for command in ["/recap", "/compact", "/goal the tests pass"] {
            vm.inputText = command
            await vm.send()
        }

        XCTAssertEqual(runtime.sentMessages.count, 3, "each command sent one turn")
        XCTAssertNil(runtime.lastSessionOptions, "no second start")
        XCTAssertFalse(vm.messages.contains { $0.systemText == "Starting the agent…" })
    }

    func testLoopOnALiveSessionStartsNothing() async throws {
        let runtime = MockAgentRuntime()
        runtime.events = [Self.result]
        let vm = try await makeLiveViewModel(runtime: runtime)

        vm.inputText = "/loop keep going"
        let running = Task { await vm.send() }
        try await eventually("the loop's first prompt to reach the runtime") {
            vm.activeGoal != nil && runtime.lastSentMessage != nil
        }
        vm.cancelGoal()
        await running.value

        XCTAssertEqual(runtime.sentMessages.first?.message, "keep going")
        XCTAssertNil(runtime.lastSessionOptions, "no second start")
        XCTAssertFalse(vm.messages.contains { $0.systemText == "Starting the agent…" })
    }

    // MARK: - Helpers

    private static let result = StreamEvent.result(.init(
        text: "Done", costUSD: 0.01, durationMs: 500, inputTokens: 100, outputTokens: 50,
        cacheCreationInputTokens: 0, cacheReadInputTokens: 0, sessionID: "s1", permissionDenials: []
    ))

    private static let goalCompleteResult = StreamEvent.result(.init(
        text: "GOAL_COMPLETE", costUSD: 0.01, durationMs: 500, inputTokens: 100, outputTokens: 50,
        cacheCreationInputTokens: 0, cacheReadInputTokens: 0, sessionID: "s-live", permissionDenials: []
    ))

    /// A view model over an agent whose session is already running, with its
    /// start cleared so a second one shows.
    private func makeLiveViewModel(runtime: MockAgentRuntime) async throws -> ChatViewModel {
        let orchestrator = makeOrchestrator(runtime: runtime)
        try await orchestrator.startAgent("test-agent", cwd: projectURL)
        runtime.lastSessionOptions = nil
        return ChatViewModel(agentID: "test-agent", projectURL: projectURL, orchestrator: orchestrator)
    }

    /// The Claude session id a past turn would have left in the project config
    /// — what `/compact` needs before it sends anything.
    private func storeSessionID(_ sessionID: String) throws {
        let project = KiteloopProject(rootURL: projectURL)
        var config = project.loadConfig()
        config.agentSessionIDs = ["Test": sessionID]
        try project.saveConfig(config)
    }

    /// A view model over an agent that was added but never started — the state
    /// Stop Agent leaves behind.
    private func makeViewModel(runtime: any AgentRuntime) -> ChatViewModel {
        ChatViewModel(agentID: "test-agent", projectURL: projectURL, orchestrator: makeOrchestrator(runtime: runtime))
    }

    private func makeOrchestrator(runtime: any AgentRuntime) -> Orchestrator {
        let eventBus = EventBus(eventsURL: projectURL.appending(path: "events"))
        let orchestrator = Orchestrator(
            runtime: runtime, eventBus: eventBus,
            subscriptionEngine: SubscriptionEngine(eventBus: eventBus),
            memoryManager: MemoryManager(project: KiteloopProject(rootURL: projectURL))
        )
        orchestrator.addAgent(Agent(id: "test-agent", name: "Test", model: "sonnet",
                                    systemPrompt: "", tools: [], denied: [],
                                    permissionMode: "default", state: .idle))
        return orchestrator
    }
}

private extension Message {
    var systemEventKind: SystemEvent.Kind? {
        if case .systemEvent(let event) = content { return event.kind }
        return nil
    }

    var errorText: String? {
        if case .error(let text) = content { return text }
        return nil
    }

    var plainText: String? {
        if case .text(let text) = content { return text }
        return nil
    }

    var systemText: String? { sender == .system ? plainText : nil }
}

/// A runtime whose start fails, recording any message that reaches it anyway.
private final class FailingStartRuntime: AgentRuntime, @unchecked Sendable {
    static let reason = "the CLI is not installed"
    var sent: [String] = []

    func startSession(agent: Agent, cwd: URL, strategy: ResumeStrategy) async throws -> AgentSession {
        throw RuntimeError.processSpawnFailed(Self.reason)
    }

    func send(_ message: String, attachments: [ChatAttachment], to session: AgentSession) -> AsyncStream<StreamEvent> {
        sent.append(message)
        return AsyncStream { $0.finish() }
    }

    func sendToolResult(toolCallID: String, content: String, to session: AgentSession) -> AsyncStream<StreamEvent> {
        AsyncStream { $0.finish() }
    }

    func sendMCPToolResult(requestID: String, result: String, to session: AgentSession) {}
    func interrupt(session: AgentSession) {}
    func stop(session: AgentSession) {}
}
