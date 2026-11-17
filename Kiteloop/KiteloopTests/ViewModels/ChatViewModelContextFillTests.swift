import XCTest
import KiteloopCore
@testable import Kiteloop

/// An agent told to compact as its context fills: after a turn that leaves
/// the window at or past its `contextCompactPercent`, the chat compacts the
/// session the way `/compact` does — once per crossing.
@MainActor
final class ChatViewModelContextFillTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "kiteloop-context-fill")
    }

    // MARK: - Helpers

    private func makeVM(compactPercent: Int?) async throws -> (ChatViewModel, MockAgentRuntime) {
        let mock = MockAgentRuntime()
        let orchestrator = Orchestrator(runtime: mock)
        var agent = Agent(
            id: "test-agent", name: "TestAgent", model: "sonnet",
            systemPrompt: "", tools: [], denied: [], permissionMode: "default", state: .idle
        )
        agent.contextCompactPercent = compactPercent
        orchestrator.addAgent(agent)
        try await orchestrator.startAgent("test-agent", cwd: tempDir)
        let vm = ChatViewModel(agentID: "test-agent", projectURL: tempDir, orchestrator: orchestrator)
        vm.contextWindowDefaults = UserDefaults(suiteName: "ChatViewModelContextFillTests.\(UUID().uuidString)") ?? .standard
        return (vm, mock)
    }

    /// A turn whose result leaves `tokens` of a 100k window in use.
    private func turn(using tokens: Int, compacted: Bool = false) -> [StreamEvent] {
        var result = StreamEvent.ResultPayload(
            text: "ack", costUSD: 0.001, durationMs: 10, inputTokens: tokens, outputTokens: 1,
            cacheCreationInputTokens: 0, cacheReadInputTokens: 0, sessionID: "s-fill", permissionDenials: [])
        result.contextWindows = ["claude-sonnet-5-5": 100_000]
        let boundary: [StreamEvent] = compacted ? [.system(subtype: "compact_boundary", payload: [:])] : []
        return boundary + [.assistantText("ack"), .result(result)]
    }

    private func say(_ text: String, to vm: ChatViewModel) async {
        vm.inputText = text
        await vm.send()
    }

    private func compactSends(_ mock: MockAgentRuntime) -> Int {
        mock.sentMessages.filter { $0.message == "/compact" }.count
    }

    private func systemTexts(_ vm: ChatViewModel) -> [String] {
        vm.messages.compactMap { message in
            guard case .system = message.sender, case .text(let text) = message.content else { return nil }
            return text
        }
    }

    // MARK: - Cases

    func testATurnPastTheThresholdCompactsAndSaysWhy() async throws {
        let (vm, mock) = try await makeVM(compactPercent: 80)
        mock.sendEventsQueue = [turn(using: 90_000), turn(using: 10_000, compacted: true)]

        await say("hello", to: vm)

        XCTAssertEqual(mock.lastSentMessage, "/compact", "The session should be sent /compact after the turn")
        XCTAssertEqual(compactSends(mock), 1)
        let texts = systemTexts(vm)
        let notice = try XCTUnwrap(texts.firstIndex { $0.contains("90%") && $0.contains("80%") },
                                   "Expected a line naming the occupancy and the threshold: \(texts)")
        let outcome = try XCTUnwrap(texts.firstIndex(of: "Context compacted."), "\(texts)")
        XCTAssertLessThan(notice, outcome, "The notice comes before the compaction's result")
    }

    func testWithTheSettingOffNothingIsCompacted() async throws {
        let (vm, mock) = try await makeVM(compactPercent: nil)
        mock.sendEventsQueue = [turn(using: 90_000)]

        await say("hello", to: vm)

        XCTAssertEqual(compactSends(mock), 0)
        XCTAssertFalse(systemTexts(vm).contains { $0.contains("threshold") }, "\(systemTexts(vm))")
    }

    func testTwoTurnsPastTheThresholdCompactOnce() async throws {
        let (vm, mock) = try await makeVM(compactPercent: 80)
        // The compaction leaves the window full; the next turn is still past it.
        mock.sendEventsQueue = [turn(using: 90_000), turn(using: 90_000), turn(using: 92_000)]

        await say("hello", to: vm)
        await say("again", to: vm)

        XCTAssertEqual(compactSends(mock), 1, "One crossing compacts once")
        XCTAssertEqual(mock.lastSentMessage, "again")
    }

    func testATurnBelowTheThresholdArmsTheNextCrossing() async throws {
        let (vm, mock) = try await makeVM(compactPercent: 80)
        mock.sendEventsQueue = [
            turn(using: 90_000), turn(using: 90_000), // first crossing and its compaction
            turn(using: 40_000),                       // drops below: re-armed
            turn(using: 85_000), turn(using: 20_000, compacted: true),
        ]

        await say("one", to: vm)
        await say("two", to: vm)
        await say("three", to: vm)

        XCTAssertEqual(compactSends(mock), 2)
    }

    func testTheAutomaticCompactionAddsNoHumanMessage() async throws {
        let (vm, mock) = try await makeVM(compactPercent: 80)
        mock.sendEventsQueue = [turn(using: 90_000), turn(using: 10_000, compacted: true)]

        await say("hello", to: vm)

        let humanTexts = vm.messages.compactMap { message -> String? in
            guard case .human = message.sender, case .text(let text) = message.content else { return nil }
            return text
        }
        XCTAssertEqual(humanTexts, ["hello"])
    }
}
