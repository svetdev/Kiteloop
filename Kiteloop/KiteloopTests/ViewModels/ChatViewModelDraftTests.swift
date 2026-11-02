import XCTest
import KiteloopCore
@testable import Kiteloop

/// Each chat keeps its own unsent message: it survives a relaunch, comes back
/// when you return to its chat, stays out of every other chat, and goes once
/// it is sent.
@MainActor
final class ChatViewModelDraftTests: XCTestCase {
    private var vm: ChatViewModel!
    private var store: SessionStore!
    private var tmpDir: URL!

    override func setUp() async throws {
        let mock = MockAgentRuntime()
        // A turn ends with its `result`, as a real one does; without it the
        // chat reads the send as cut off and puts the message back in the input.
        let done = StreamEvent.ResultPayload(
            text: "ok", costUSD: 0, durationMs: 1, inputTokens: 1, outputTokens: 1,
            cacheCreationInputTokens: 0, cacheReadInputTokens: 0, sessionID: "s1", permissionDenials: [])
        mock.events = [.assistantText("ok"), .result(done)]
        let orchestrator = Orchestrator(runtime: mock)
        orchestrator.addAgent(Agent(
            id: "test", name: "Test", model: "sonnet",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default", state: .idle
        ))
        tmpDir = try makeTemporaryDirectory(prefix: "kiteloop-chat-draft")
        vm = ChatViewModel(agentID: "test", projectURL: tmpDir, orchestrator: orchestrator)
        try await orchestrator.startAgent("test", cwd: tmpDir)
        store = SessionStore(projectDir: tmpDir)
    }

    /// The chat as a relaunch would read it: from the index on disk.
    private func storedSession(_ id: UUID?) -> ChatSession? {
        SessionStore(projectDir: tmpDir).sessions(for: "test").first { $0.id == id }
    }

    func testSwitchingChatsKeepsEachChatsOwnDraft() async throws {
        let b = store.createSession(agentID: "test")
        let a = store.createSession(agentID: "test")
        vm.setupSessionStore(store)
        XCTAssertEqual(vm.currentSession?.id, a.id)

        vm.inputText = "half a message for A"
        await vm.switchToSession(b)
        XCTAssertEqual(vm.inputText, "")

        vm.inputText = "B's own"
        await vm.switchToSession(a)
        XCTAssertEqual(vm.inputText, "half a message for A")

        await vm.switchToSession(b)
        XCTAssertEqual(vm.inputText, "B's own")
    }

    func testANewChatStartsWithAnEmptyInput() async throws {
        vm.setupSessionStore(store)
        let first = try XCTUnwrap(vm.currentSession)
        vm.inputText = "not for the new chat"

        await vm.startNewChat()

        XCTAssertEqual(vm.inputText, "")
        XCTAssertEqual(storedSession(first.id)?.draft, "not for the new chat")
    }

    func testSetupShowsTheLatestChatsDraft() {
        var latest = store.createSession(agentID: "test")
        latest.draft = "typed before the quit"
        store.updateSession(latest)

        vm.setupSessionStore(SessionStore(projectDir: tmpDir))

        XCTAssertEqual(vm.inputText, "typed before the quit")
    }

    /// No switch, no send: the draft reaches disk on its own once typing stops.
    func testTypingSavesTheDraftWithoutMovingTheChat() async throws {
        _ = store.createSession(agentID: "test")
        vm.setupSessionStore(store)
        let open = try XCTUnwrap(vm.currentSession)
        let before = try XCTUnwrap(storedSession(open.id)).lastMessageAt
        let order = store.sessions(for: "test").map(\.id)

        vm.inputText = "still typing"

        try await eventually("the draft is saved") { self.storedSession(open.id)?.draft == "still typing" }
        XCTAssertEqual(storedSession(open.id)?.lastMessageAt, before)
        XCTAssertEqual(store.sessions(for: "test").map(\.id), order)
    }

    func testSendingClearsTheStoredDraft() async throws {
        vm.setupSessionStore(store)
        let open = try XCTUnwrap(vm.currentSession)
        vm.inputText = "Hello"
        try await eventually("the draft is saved") { self.storedSession(open.id)?.draft == "Hello" }

        await vm.send()

        XCTAssertEqual(vm.inputText, "")
        XCTAssertNil(storedSession(open.id)?.draft)
        vm.setupSessionStore(SessionStore(projectDir: tmpDir))
        XCTAssertEqual(vm.inputText, "")
    }
}
