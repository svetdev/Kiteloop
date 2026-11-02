import XCTest
import KiteloopCore
@testable import Kiteloop

/// A message queued while a slash command's own turns run is sent when the
/// command finishes, not left waiting for the next message typed.
@MainActor
final class ChatViewModelQueuedDuringCommandTests: XCTestCase {
    private var runtime: MockAgentRuntime!
    private var orchestrator: Orchestrator!
    private var vm: ChatViewModel!

    override func setUp() async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "queued-during-command")
        runtime = MockAgentRuntime()
        runtime.events = [
            .result(.init(text: "Done", costUSD: 0.01, durationMs: 500, inputTokens: 100, outputTokens: 50, cacheCreationInputTokens: 0, cacheReadInputTokens: 0, sessionID: "s1", permissionDenials: []))
        ]
        let eventBus = EventBus(eventsURL: tempDir.appending(path: "test-events"))
        let subscriptionEngine = SubscriptionEngine(eventBus: eventBus)
        let project = KiteloopProject(rootURL: tempDir)
        let memoryManager = MemoryManager(project: project)
        orchestrator = Orchestrator(runtime: runtime, eventBus: eventBus, subscriptionEngine: subscriptionEngine, memoryManager: memoryManager)

        let agent = Agent(id: "test-agent", name: "Test", model: "sonnet",
                         systemPrompt: "", tools: [], denied: [],
                         permissionMode: "default", state: .idle)
        orchestrator.addAgent(agent)
        try await orchestrator.startAgent(agent.id, cwd: tempDir)

        vm = ChatViewModel(agentID: "test-agent", projectURL: tempDir, orchestrator: orchestrator)
    }

    /// Sends `text` in the background and returns once its turn is streaming,
    /// so the next `send()` is queued behind it.
    private func startStreaming(_ text: String) async throws -> Task<Void, Never> {
        runtime.startDelay = 300_000_000
        vm.inputText = text
        let running = Task { await vm.send() }
        try await eventually("the turn is streaming") { self.vm.isStreaming }
        return running
    }

    private func type(_ text: String) async {
        vm.inputText = text
        await vm.send()
    }

    func testAMessageQueuedDuringRecapIsSentWhenRecapFinishes() async throws {
        let recap = try await startStreaming("/recap")
        await type("A")
        XCTAssertEqual(vm.queuedMessageCount, 1)

        await recap.value

        XCTAssertEqual(runtime.sentMessages.count, 2)
        XCTAssertTrue(runtime.sentMessages.first?.message.hasPrefix("Provide a brief recap") == true)
        XCTAssertEqual(runtime.sentMessages.last?.message, "A")
        XCTAssertEqual(vm.queuedMessageCount, 0)
    }

    func testMessagesQueuedDuringACommandGoOutInOrderBeforeAnythingTypedAfter() async throws {
        let recap = try await startStreaming("/recap")
        await type("A")
        await type("B")
        await recap.value
        runtime.startDelay = 0

        await type("C")

        XCTAssertEqual(runtime.sentMessages.dropFirst().map(\.message), ["A", "B", "C"])
    }

    func testAReadOnlyCommandMidTurnDoesNotSendTheQueueEarly() async throws {
        let turn = try await startStreaming("first")
        await type("A")

        await type("/cost")

        XCTAssertEqual(runtime.sentMessages.map(\.message), ["first"])
        XCTAssertEqual(vm.queuedMessageCount, 1)
        await turn.value
        XCTAssertEqual(runtime.sentMessages.map(\.message), ["first", "A"])
    }

    func testStopDuringALoopReturnsTheQueuedMessageToTheInput() async throws {
        let loop = try await startStreaming("/loop keep going")
        await type("A")

        vm.interrupt()
        vm.cancelGoal()
        await loop.value

        XCTAssertEqual(runtime.sentMessages.map(\.message), ["keep going"])
        XCTAssertEqual(vm.queuedMessageCount, 0)
        XCTAssertEqual(vm.inputText, "A")
    }

    // MARK: - A turn that drops

    /// Starts a turn whose stream ends with no result — the agent's process
    /// dropped — while every later send finishes.
    private func startDroppingTurn(_ text: String) async throws -> Task<Void, Never> {
        vm.recoveryBackoff = [0, 0, 0]
        runtime.sendEventsQueue = [[]]
        return try await startStreaming(text)
    }

    private func forwardFromATeammate(_ text: String) async throws {
        NotificationCenter.default.post(
            name: .agentTriggered, object: orchestrator,
            userInfo: ["agentID": "test-agent", "message": text]
        )
        try await eventually("the forward is queued") { self.vm.queuedMessageCount == 1 }
    }

    func testAMessageQueuedDuringADroppedTurnComesBackToTheInputUnsent() async throws {
        let turn = try await startDroppingTurn("first")
        await type("A")

        await turn.value

        try await eventually("the reconnect has put the messages back") { self.vm.inputText.contains("A") }
        XCTAssertEqual(runtime.sentMessages.map(\.message), ["first"])
        XCTAssertEqual(vm.queuedMessageCount, 0)
        XCTAssertFalse(vm.isProcessDead)
    }

    func testQueuedMessagesComeBackOldestFirstAfterTheCutOffAndAheadOfADraft() async throws {
        let turn = try await startDroppingTurn("first")
        vm.pendingAttachments = [ChatAttachment(filename: "a.txt", data: Data([0x01]), mimeType: "text/plain")]
        await type("A")
        vm.pendingAttachments = [ChatAttachment(filename: "b.txt", data: Data([0x02]), mimeType: "text/plain")]
        await type("B")
        vm.inputText = "draft"

        await turn.value

        try await eventually("the reconnect has put the messages back") { self.vm.inputText.hasPrefix("first") }
        XCTAssertEqual(vm.inputText, "first\n\nA\n\nB\n\ndraft")
        XCTAssertEqual(vm.pendingAttachments.map(\.filename), ["a.txt", "b.txt"])
        XCTAssertEqual(runtime.sentMessages.map(\.message), ["first"])
    }

    func testATeammatesForwardQueuedDuringADroppedTurnIsSentAfterTheReconnect() async throws {
        let turn = try await startDroppingTurn("first")
        try await forwardFromATeammate("from a teammate")

        await turn.value

        try await eventually("the forward reaches the reconnected agent") { self.runtime.sentMessages.count == 2 }
        XCTAssertTrue(runtime.sentMessages[1].message.contains("from a teammate"))
        XCTAssertEqual(vm.queuedMessageCount, 0)
    }

    func testATeammatesForwardStaysQueuedWhenTheAgentCannotBeRestarted() async throws {
        let turn = try await startDroppingTurn("first")
        try await forwardFromATeammate("from a teammate")
        runtime.startSessionError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "no claude"])

        await turn.value

        try await eventually("every restart has failed") { self.vm.isProcessDead }
        XCTAssertEqual(runtime.sentMessages.map(\.message), ["first"])
        XCTAssertEqual(vm.queuedMessageCount, 1)
    }

    // MARK: - Taking one queued message back

    func testTakingBackTheFirstQueuedMessageLeavesTheRestToBeSent() async throws {
        let turn = try await startStreaming("first")
        await type("A")
        await type("B")
        XCTAssertEqual(vm.queuedTypedMessages, ["A", "B"])

        vm.takeBackQueuedMessage(at: 0)

        XCTAssertEqual(vm.inputText, "A")
        XCTAssertEqual(vm.queuedTypedMessages, ["B"])
        await turn.value
        XCTAssertEqual(runtime.sentMessages.map(\.message), ["first", "B"])
    }

    func testTakingBackAQueuedMessageGoesAheadOfWhatWasTypedSince() async throws {
        let turn = try await startStreaming("first")
        await type("A")
        vm.inputText = "draft"

        vm.takeBackQueuedMessage(at: 0)

        XCTAssertEqual(vm.inputText, "A\n\ndraft")
        await turn.value
    }

    func testTakingBackAQueuedMessageLeavesTheTurnRunning() async throws {
        let turn = try await startStreaming("first")
        await type("A")

        vm.takeBackQueuedMessage(at: 0)

        XCTAssertTrue(vm.isStreaming)
        XCTAssertEqual(runtime.interruptCount, 0)
        await turn.value
    }

    func testTakingBackAQueuedMessageBringsBackItsAttachments() async throws {
        let turn = try await startStreaming("first")
        vm.pendingAttachments = [ChatAttachment(filename: "x.txt", data: Data([0x01]), mimeType: "text/plain")]
        await type("A")
        XCTAssertTrue(vm.pendingAttachments.isEmpty)

        vm.takeBackQueuedMessage(at: 0)

        XCTAssertEqual(vm.pendingAttachments.map(\.filename), ["x.txt"])
        await turn.value
        XCTAssertEqual(runtime.sentMessages.map(\.message), ["first"])
    }

    func testATeammatesQueuedForwardIsNotListedAsTyped() async throws {
        let turn = try await startStreaming("first")
        NotificationCenter.default.post(
            name: .agentTriggered, object: orchestrator,
            userInfo: ["agentID": "test-agent", "message": "from a teammate"]
        )
        try await eventually("the forward is queued") { self.vm.queuedMessageCount == 1 }

        XCTAssertEqual(vm.queuedTypedMessages, [])
        await turn.value
    }

    // MARK: - The input bar's queued strip

    func testTheQueuedStripShowsOnlyWhileATypedMessageWaits() {
        XCTAssertTrue(InputBar.showsQueuedStrip(isStreaming: true, queuedMessages: ["A"]))
        XCTAssertFalse(InputBar.showsQueuedStrip(isStreaming: true, queuedMessages: []))
        XCTAssertFalse(InputBar.showsQueuedStrip(isStreaming: false, queuedMessages: ["A"]))
    }

    func testAQueuedRowShowsTheMessagesFirstLine() {
        XCTAssertEqual(InputBar.queuedPreview("  first line\nsecond"), "first line")
        XCTAssertEqual(InputBar.queuedPreview(""), "")
    }
}
