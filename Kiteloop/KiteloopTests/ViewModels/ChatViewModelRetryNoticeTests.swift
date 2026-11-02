import XCTest
import KiteloopCore
@testable import Kiteloop

/// A retried API call shows one divider saying how long until the next try,
/// and further retries in a row rewrite it instead of stacking.
@MainActor
final class ChatViewModelRetryNoticeTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "kiteloop-retry-notice")
    }

    // MARK: - Helpers

    private func retry(_ attempt: Int, delayMs: Int? = 12_000, status: Any? = 429) -> StreamEvent {
        var payload: [String: Any] = [
            "attempt": attempt, "max_retries": 10, "error": "rate_limit",
        ]
        if let delayMs { payload["retry_delay_ms"] = delayMs }
        payload["error_status"] = status ?? NSNull()
        return .system(subtype: "api_retry", payload: payload)
    }

    private func turn(_ events: [StreamEvent]) async throws -> ChatViewModel {
        let result = StreamEvent.ResultPayload(
            text: "", costUSD: 0.01, durationMs: 10,
            inputTokens: 1, outputTokens: 1,
            cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
            sessionID: "s-retry", permissionDenials: []
        )
        let mock = MockAgentRuntime()
        mock.events = events + [.result(result)]
        let orchestrator = Orchestrator(runtime: mock)
        orchestrator.addAgent(Agent(
            id: "test-agent", name: "TestAgent", model: "sonnet",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default", state: .idle
        ))
        try await orchestrator.startAgent("test-agent", cwd: tempDir)
        let vm = ChatViewModel(agentID: "test-agent", projectURL: tempDir, orchestrator: orchestrator)
        vm.inputText = "Do the task"
        await vm.send()
        return vm
    }

    private func retryDividers(_ vm: ChatViewModel) -> [String] {
        vm.messages.compactMap { message in
            guard case .systemEvent(let event) = message.content, event.kind == .apiRetry else { return nil }
            return event.detail
        }
    }

    // MARK: - What the divider says

    func testTheDividerNamesTheWaitTheAttemptAndTheStatus() async throws {
        let vm = try await turn([retry(2)])

        let detail = try XCTUnwrap(retryDividers(vm).first)
        XCTAssertTrue(detail.contains("12s"), detail)
        XCTAssertTrue(detail.contains("attempt 2 of 10"), detail)
        XCTAssertTrue(detail.contains("429"), detail)
        XCTAssertTrue(detail.contains("rate_limit"), detail)
    }

    func testAPayloadWithoutDelayOrStatusStillShowsADividerWithoutThem() async throws {
        let vm = try await turn([retry(1, delayMs: nil, status: nil)])

        let detail = try XCTUnwrap(retryDividers(vm).first)
        XCTAssertTrue(detail.contains("attempt 1 of 10"), detail)
        XCTAssertFalse(detail.contains(" in "), detail)
        XCTAssertFalse(detail.contains("HTTP"), detail)
    }

    // MARK: - One line per bad stretch

    func testRetriesInARowLeaveOneDividerShowingTheLatestAttempt() async throws {
        let vm = try await turn([retry(1), retry(2), retry(3, delayMs: 30_000)])

        let dividers = retryDividers(vm)
        XCTAssertEqual(dividers.count, 1, "\(dividers)")
        XCTAssertTrue(dividers[0].contains("attempt 3 of 10"), dividers[0])
        XCTAssertTrue(dividers[0].contains("30s"), dividers[0])
    }

    func testARetryAfterOtherMessagesAddsANewDivider() async throws {
        let vm = try await turn([retry(1), .assistantText("Partial answer"), retry(2)])

        let dividers = retryDividers(vm)
        XCTAssertEqual(dividers.count, 2, "\(dividers)")
        XCTAssertTrue(dividers[0].contains("attempt 1 of 10"), dividers[0])
        XCTAssertTrue(dividers[1].contains("attempt 2 of 10"), dividers[1])
    }
}
