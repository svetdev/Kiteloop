import XCTest
import KiteloopCore
@testable import Kiteloop

/// A turn the CLI cut short — on the turn limit, the spend cap or an error —
/// says so in the chat, instead of ending as if the agent had finished.
@MainActor
final class ChatViewModelTurnStopNoteTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "kiteloop-turn-stop")
    }

    // MARK: - Helpers

    private func makeVM(ending subtype: String?, numTurns: Int? = nil) async throws -> ChatViewModel {
        var result = StreamEvent.ResultPayload(
            text: "", costUSD: 0.01, durationMs: 10,
            inputTokens: 1, outputTokens: 1,
            cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
            sessionID: "s-stop", permissionDenials: []
        )
        result.subtype = subtype
        result.numTurns = numTurns
        let mock = MockAgentRuntime()
        mock.events = [.assistantText("Working on it"), .result(result)]
        let orchestrator = Orchestrator(runtime: mock)
        orchestrator.addAgent(Agent(
            id: "test-agent", name: "TestAgent", model: "sonnet",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default", state: .idle
        ))
        try await orchestrator.startAgent("test-agent", cwd: tempDir)
        return ChatViewModel(agentID: "test-agent", projectURL: tempDir, orchestrator: orchestrator)
    }

    private func systemLines(_ messages: [Message]) -> [String] {
        messages.compactMap { message in
            guard message.sender == .system, case .text(let text) = message.content else { return nil }
            return text
        }
    }

    private func turn(ending subtype: String?, numTurns: Int? = nil) async throws -> [String] {
        let vm = try await makeVM(ending: subtype, numTurns: numTurns)
        vm.inputText = "Do the long task"
        await vm.send()
        return systemLines(vm.messages)
    }

    // MARK: - A turn cut short says why

    func testATurnStoppedOnTheTurnLimitNamesTheLimitAndTheTurnsUsed() async throws {
        let lines = try await turn(ending: "error_max_turns", numTurns: 50)

        let note = try XCTUnwrap(lines.first { $0.contains("turn limit") })
        XCTAssertTrue(note.contains("50 turns"), note)
        XCTAssertTrue(note.contains("continue"), note)
    }

    func testATurnStoppedOnTheSpendCapNamesTheCap() async throws {
        let lines = try await turn(ending: "error_max_budget_usd")

        XCTAssertTrue(lines.contains { $0.contains("spend cap") }, "\(lines)")
    }

    func testATurnEndedByAnErrorSaysSo() async throws {
        let lines = try await turn(ending: "error_during_execution")

        XCTAssertTrue(lines.contains { $0.contains("ended with an error") }, "\(lines)")
    }

    // MARK: - A finished turn is unchanged

    func testASuccessfulTurnAddsNoLine() async throws {
        let lines = try await turn(ending: "success", numTurns: 3)

        XCTAssertTrue(lines.isEmpty, "\(lines)")
    }

    func testATurnWithNoSubtypeAddsNoLine() async throws {
        let lines = try await turn(ending: nil)

        XCTAssertTrue(lines.isEmpty, "\(lines)")
    }

    // MARK: - Saved with the chat

    func testTheLineIsStillThereAfterTheChatIsReloaded() async throws {
        let vm = try await makeVM(ending: "error_max_turns", numTurns: 50)
        let sessionsDir = try makeTemporaryDirectory(prefix: "kiteloop-turn-stop-sessions")
        let store = SessionStore(projectDir: sessionsDir)
        var session = store.createSession(agentID: "test-agent")
        session.title = "Named"
        store.updateSession(session)
        vm.setupSessionStore(store)

        vm.inputText = "Do the long task"
        await vm.send()

        try await eventually("the turn-limit line on disk") {
            self.systemLines(SessionStore(projectDir: sessionsDir).loadMessages(for: session))
                .contains { $0.contains("turn limit") && $0.contains("50 turns") }
        }
    }
}
