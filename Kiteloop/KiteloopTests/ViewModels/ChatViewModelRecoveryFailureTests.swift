import XCTest
import KiteloopCore
@testable import Kiteloop

/// A turn that ends with no result sends the chat into reconnect attempts;
/// when every one fails, the chat names the error the last restart threw
/// instead of only saying the process terminated.
@MainActor
final class ChatViewModelRecoveryFailureTests: XCTestCase {
    private var projectURL: URL!

    override func setUpWithError() throws {
        projectURL = try makeTemporaryDirectory(prefix: "recovery-failure")
    }

    func testEveryRestartFailingNamesTheReasonInTheFinalError() async throws {
        let runtime = CrashingRuntime()
        let vm = try await makeLiveViewModel(runtime: runtime)
        runtime.failStarts = true

        vm.inputText = "hello"
        await vm.send()

        let error = try XCTUnwrap(vm.messages.last?.errorText, "\(vm.messages.map(\.content))")
        XCTAssertTrue(error.contains(CrashingRuntime.reason), error)
        XCTAssertTrue(error.contains("Click Restart"), error)
        XCTAssertTrue(vm.isProcessDead)
        XCTAssertTrue(vm.lastRecoveryFailure?.contains(CrashingRuntime.reason) == true)
        XCTAssertEqual(vm.inputText, "", "no reconnect, so nothing is put back in the input")
    }

    func testSuccessfulRestartClearsTheReason() async throws {
        let runtime = CrashingRuntime()
        let vm = try await makeLiveViewModel(runtime: runtime)
        runtime.failStarts = true
        vm.inputText = "hello"
        await vm.send()
        XCTAssertNotNil(vm.lastRecoveryFailure)

        runtime.failStarts = false
        await vm.restart()

        XCTAssertFalse(vm.isProcessDead)
        XCTAssertNil(vm.lastRecoveryFailure)
    }

    func testReconnectThatSucceedsShowsNoErrorAndKeepsNoReason() async throws {
        let runtime = CrashingRuntime()
        let vm = try await makeLiveViewModel(runtime: runtime)

        vm.inputText = "hello"
        await vm.send()

        XCTAssertTrue(vm.messages.contains { $0.systemEventKind == .reconnecting })
        XCTAssertFalse(vm.messages.contains { $0.errorText != nil }, "\(vm.messages.map(\.content))")
        XCTAssertFalse(vm.isProcessDead)
        XCTAssertNil(vm.lastRecoveryFailure)
    }

    // MARK: - Helpers

    private func makeLiveViewModel(runtime: CrashingRuntime) async throws -> ChatViewModel {
        let eventBus = EventBus(eventsURL: projectURL.appending(path: "events"))
        let orchestrator = Orchestrator(
            runtime: runtime, eventBus: eventBus,
            subscriptionEngine: SubscriptionEngine(eventBus: eventBus),
            memoryManager: MemoryManager(project: KiteloopProject(rootURL: projectURL))
        )
        orchestrator.addAgent(Agent(id: "test-agent", name: "Test", model: "sonnet",
                                    systemPrompt: "", tools: [], denied: [],
                                    permissionMode: "default", state: .idle))
        try await orchestrator.startAgent("test-agent", cwd: projectURL)
        let vm = ChatViewModel(agentID: "test-agent", projectURL: projectURL, orchestrator: orchestrator)
        vm.recoveryBackoff = [0, 0, 0]
        return vm
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
}

/// A runtime whose turns end with no result — what a crashed CLI leaves — and
/// whose starts throw a known reason while `failStarts` is set.
private final class CrashingRuntime: AgentRuntime, @unchecked Sendable {
    static let reason = "the login has expired"
    var failStarts = false

    func startSession(agent: Agent, cwd: URL, strategy: ResumeStrategy) async throws -> AgentSession {
        if failStarts { throw RuntimeError.processSpawnFailed(Self.reason) }
        return AgentSession(id: "crashing-session", agentID: agent.id, startedAt: .now)
    }

    func send(_ message: String, attachments: [ChatAttachment], to session: AgentSession) -> AsyncStream<StreamEvent> {
        AsyncStream { $0.finish() }
    }

    func sendToolResult(toolCallID: String, content: String, to session: AgentSession) -> AsyncStream<StreamEvent> {
        AsyncStream { $0.finish() }
    }

    func sendMCPToolResult(requestID: String, result: String, to session: AgentSession) {}
    func interrupt(session: AgentSession) {}
    func stop(session: AgentSession) {}
}
