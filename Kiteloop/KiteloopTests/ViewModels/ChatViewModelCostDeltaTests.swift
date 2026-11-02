import XCTest
import KiteloopCore
@testable import Kiteloop

/// Covers the fix for the CLI's `result.total_cost_usd` being treated as a
/// per-turn amount: it is the session's running total, monotonically
/// nondecreasing turn over turn, so summing it raw roughly doubles a
/// multi-turn session's recorded cost. `ChatViewModel.costDelta(for:lastSeenBySession:)`
/// recovers each turn's own contribution — the increase since the last total
/// that session reported — and both the main stream loop and the
/// mention-handling (consult) loop go through it, so they cannot drift apart
/// on the rule again.
@MainActor
final class ChatViewModelCostDeltaTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "kiteloop-cost-delta")
    }

    // MARK: - The shared helper itself

    /// Three turns of the same session reporting running totals 1.0, 3.0, 7.0
    /// recover as deltas 1.0, 2.0, 4.0 — summing to 7.0, not the raw 11.0 a
    /// naive accumulation would produce.
    func testSharedHelperRecoversDeltasFromASessionsRunningTotal() {
        var lastSeen: [String: Double] = [:]
        let totals: [Double] = [1.0, 3.0, 7.0]
        var deltas: [Double] = []
        for total in totals {
            let payload = Self.resultPayload(costUSD: total, sessionID: "s1")
            deltas.append(ChatViewModel.costDelta(for: payload, lastSeenBySession: &lastSeen))
        }
        XCTAssertEqual(deltas, [1.0, 2.0, 4.0])
        XCTAssertEqual(deltas.reduce(0, +), 7.0, accuracy: 0.0001)
    }

    /// A later total lower than the last seen means the session itself
    /// restarted (`/clear`, resume) and the CLI's own total reset near zero —
    /// the fresh total is recorded as its own delta, never as negative spend.
    func testSharedHelperTreatsALowerTotalAsAFreshDeltaNeverNegative() {
        var lastSeen: [String: Double] = [:]
        let first = ChatViewModel.costDelta(for: Self.resultPayload(costUSD: 5.0, sessionID: "s1"), lastSeenBySession: &lastSeen)
        XCTAssertEqual(first, 5.0, accuracy: 0.0001)

        let reset = ChatViewModel.costDelta(for: Self.resultPayload(costUSD: 0.3, sessionID: "s1"), lastSeenBySession: &lastSeen)
        XCTAssertEqual(reset, 0.3, accuracy: 0.0001, "the post-reset total is recorded as its own delta")
        XCTAssertGreaterThanOrEqual(reset, 0, "a session reset must never read as negative spend")
    }

    /// Two sessions tracked through the same dictionary — a host agent's own
    /// session and a consulted specialist's guest session — do not interfere
    /// with each other's running total.
    func testSharedHelperKeepsDistinctSessionsIndependent() {
        var lastSeen: [String: Double] = [:]
        let host1 = ChatViewModel.costDelta(for: Self.resultPayload(costUSD: 4.0, sessionID: "host"), lastSeenBySession: &lastSeen)
        let guest1 = ChatViewModel.costDelta(for: Self.resultPayload(costUSD: 0.02, sessionID: "guest"), lastSeenBySession: &lastSeen)
        let host2 = ChatViewModel.costDelta(for: Self.resultPayload(costUSD: 6.0, sessionID: "host"), lastSeenBySession: &lastSeen)

        XCTAssertEqual(host1, 4.0, accuracy: 0.0001)
        XCTAssertEqual(guest1, 0.02, accuracy: 0.0001)
        XCTAssertEqual(host2, 2.0, accuracy: 0.0001, "the guest session's total must not shift the host's baseline")
    }

    // MARK: - The main stream loop

    /// The literal acceptance scenario: a simulated session whose result
    /// events report totals 1.0, 3.0, 7.0 records a session cost of 7.0, not
    /// the 11.0 a raw sum of the reported totals would give.
    func testMainStreamLoopRecordsTheSessionsFinalTotalNotTheSumOfReportedTotals() async throws {
        let (vm, mock) = try await makeVM()

        for total in [1.0, 3.0, 7.0] {
            mock.events = [
                .assistantText("turn"),
                .result(Self.resultPayload(costUSD: total, sessionID: "s1"))
            ]
            vm.inputText = "go"
            await vm.send()
        }

        XCTAssertEqual(vm.costUSD, 7.0, accuracy: 0.0001)
    }

    /// A session reset mid-stream — a later reported total lower than the
    /// last one seen — adds the new total as a fresh delta instead of
    /// producing a negative contribution.
    func testMainStreamLoopSessionResetMidStreamNeverGoesNegative() async throws {
        let (vm, mock) = try await makeVM()

        mock.events = [.assistantText("turn"), .result(Self.resultPayload(costUSD: 5.0, sessionID: "s1"))]
        vm.inputText = "go"
        await vm.send()
        XCTAssertEqual(vm.costUSD, 5.0, accuracy: 0.0001)

        mock.events = [.assistantText("turn"), .result(Self.resultPayload(costUSD: 0.3, sessionID: "s1"))]
        vm.inputText = "go again after a reset"
        await vm.send()

        XCTAssertEqual(vm.costUSD, 5.3, accuracy: 0.0001, "the reset turn's own total is added, not subtracted")
    }

    // MARK: - Turn spans carry the delta

    /// `recordTurnSpan` stores the delta alongside the raw reported total, so
    /// a reader can sum spans without re-deriving session grouping.
    func testTurnSpanCarriesBothTheReportedTotalAndItsOwnDelta() async throws {
        let mock = MockAgentRuntime()
        let orchestrator = Orchestrator(runtime: mock)
        orchestrator.configureTracing(tracesURL: tempDir.appendingPathComponent("traces", isDirectory: true))
        let agent = Agent(
            id: "test-agent", name: "TestAgent", model: "sonnet",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default", state: .idle
        )
        orchestrator.addAgent(agent)
        try await orchestrator.startAgent("test-agent", cwd: tempDir)
        let vm = ChatViewModel(agentID: "test-agent", projectURL: tempDir, orchestrator: orchestrator)

        mock.events = [.assistantText("turn"), .result(Self.resultPayload(costUSD: 5.0, sessionID: "s1"))]
        vm.inputText = "go"
        await vm.send()

        mock.events = [.assistantText("turn"), .result(Self.resultPayload(costUSD: 8.0, sessionID: "s1"))]
        vm.inputText = "go again"
        await vm.send()

        let store = try XCTUnwrap(orchestrator.traceStore)
        let spans = await store.loadSpans(for: "test-agent").filter { $0.type == .turn }
        XCTAssertEqual(spans.count, 2)

        XCTAssertEqual(spans[0].reportedCostUSD ?? -1, 5.0, accuracy: 0.0001)
        XCTAssertEqual(spans[0].costDeltaUSD ?? -1, 5.0, accuracy: 0.0001)

        XCTAssertEqual(spans[1].reportedCostUSD ?? -1, 8.0, accuracy: 0.0001)
        XCTAssertEqual(spans[1].costDeltaUSD ?? -1, 3.0, accuracy: 0.0001,
                       "the second turn's own contribution is the increase over the session total, not the raw 8.0")
    }

    // MARK: - A turn's own cost

    /// Two turns with different costs: after the second, `lastTurnCostUSD`
    /// reads the second turn's delta alone, not the session's running total.
    func testLastTurnCostIsTheMostRecentTurnsDeltaNotTheSessionTotal() async throws {
        let (vm, mock) = try await makeVM()

        mock.events = [.assistantText("turn"), .result(Self.resultPayload(costUSD: 1.5, sessionID: "s1"))]
        vm.inputText = "go"
        await vm.send()
        XCTAssertEqual(vm.lastTurnCostUSD, 1.5, accuracy: 0.0001)

        mock.events = [.assistantText("turn"), .result(Self.resultPayload(costUSD: 1.75, sessionID: "s1"))]
        vm.inputText = "go again"
        await vm.send()

        XCTAssertEqual(vm.lastTurnCostUSD, 0.25, accuracy: 0.0001, "the second turn's delta, not the 1.75 session total")
        XCTAssertEqual(vm.costUSD, 1.75, accuracy: 0.0001)
    }

    /// A three-turn /goal on a session that has already spent $2.00, each turn
    /// costing $0.10, reports $0.30 — the sum of its own turns — not the
    /// $6.60 that re-adding the session total every turn produced.
    func testGoalReportsTheSumOfItsOwnTurnsOnASessionWithPriorCost() async throws {
        let (vm, mock) = try await makeVM()

        mock.events = [.assistantText("earlier work"), .result(Self.resultPayload(costUSD: 2.0, sessionID: "s1"))]
        vm.inputText = "earlier"
        await vm.send()
        XCTAssertEqual(vm.costUSD, 2.0, accuracy: 0.0001)

        mock.sendEventsQueue = [
            [.assistantText("step one"), .result(Self.resultPayload(costUSD: 2.1, sessionID: "s1"))],
            [.assistantText("step two"), .result(Self.resultPayload(costUSD: 2.2, sessionID: "s1"))],
            [.assistantText("done\nGOAL_COMPLETE"), .result(Self.resultPayload(costUSD: 2.3, sessionID: "s1"))],
        ]
        vm.inputText = "/goal the work is done"
        await vm.send()

        let report = vm.messages.compactMap { message -> String? in
            guard case .text(let text) = message.content, text.hasPrefix("Goal achieved") else { return nil }
            return text
        }.last
        let achieved = try XCTUnwrap(report)
        XCTAssertTrue(achieved.hasPrefix("Goal achieved in 3 turns"), achieved)
        XCTAssertTrue(achieved.hasSuffix("$0.3000)"), "the goal's own turns cost $0.30: \(achieved)")
    }

    // MARK: - Fixtures

    private func makeVM() async throws -> (ChatViewModel, MockAgentRuntime) {
        let mock = MockAgentRuntime()
        let orchestrator = Orchestrator(runtime: mock)
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

    private static func resultPayload(costUSD: Double, sessionID: String) -> StreamEvent.ResultPayload {
        StreamEvent.ResultPayload(
            text: "done", costUSD: costUSD, durationMs: 100,
            inputTokens: 10, outputTokens: 5,
            cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
            sessionID: sessionID, permissionDenials: []
        )
    }
}
