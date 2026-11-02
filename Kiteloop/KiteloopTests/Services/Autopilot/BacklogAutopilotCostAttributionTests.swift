import XCTest
import KiteloopCore
@testable import Kiteloop

/// A runtime that replays a fixed turn — one assistant reply and one `result`
/// carrying the cost — so a test can drive `ChatViewModel.send()` to completion
/// and then read back what was written to the trace store.
private final class TurnRecordingRuntime: AgentRuntime, @unchecked Sendable {
    var costUSD: Double = 0

    func startSession(agent: Agent, cwd: URL, strategy: ResumeStrategy) async throws -> AgentSession {
        AgentSession(id: "cost-attribution-session", agentID: agent.id, startedAt: .now)
    }

    func send(_ message: String, attachments: [ChatAttachment], to session: AgentSession) -> AsyncStream<StreamEvent> {
        let events: [StreamEvent] = [
            .assistantText("Done."),
            .result(.init(
                text: "Done.", costUSD: costUSD, durationMs: 1_000,
                inputTokens: 94, outputTokens: 25_521,
                cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                sessionID: "s1", permissionDenials: []
            ))
        ]
        return AsyncStream { continuation in
            Task {
                for event in events {
                    continuation.yield(event)
                    await Task.yield()
                }
                continuation.finish()
            }
        }
    }

    func sendToolResult(toolCallID: String, content: String, to session: AgentSession) -> AsyncStream<StreamEvent> {
        AsyncStream { $0.finish() }
    }

    func sendMCPToolResult(requestID: String, result: String, to session: AgentSession) {}
    func interrupt(session: AgentSession) {}
    func stop(session: AgentSession) {}
}

/// Covers how a run's cost is attributed to it — the stamp `ChatViewModel` writes
/// onto every turn span, and the selection `BacklogAutopilot` makes on it.
///
/// The defect these exist for: attribution was *reconstructed* rather than
/// recorded. `costForItem` loaded every turn span belonging to the worker and
/// reviewer agents and kept the ones whose `startTime` happened to fall inside
/// the item's window. Nothing on the span said which run it belonged to, so
/// ownership was inferred — and when the inference missed, the item silently read
/// `$0`. It missed on 9 of 31 runs on 2026-08-08.
///
/// A `$0` that means "unattributed" is not cosmetic: `effectiveCostCap` compares
/// against zero, so the ceiling is inert for that run, and `isNoWorkBlock`
/// (cost < $0.05 ⇒ the agent did nothing) takes a false positive straight into the
/// circuit breaker. Both consequences are covered below.
@MainActor
final class BacklogAutopilotCostAttributionTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "cost-attribution")
    }

    // MARK: - Fixtures

    /// A turn span as the recorder writes one: stamped with the run that owns it
    /// and the node that ran it, or with neither when no run does.
    private func turn(
        agentID: String,
        executionID: String? = nil,
        role: String? = nil,
        start: Date = Date(timeIntervalSince1970: 1_775_000_000),
        durationSec: TimeInterval = 60,
        costUSD: Double,
        costDeltaUSD: Double? = nil
    ) -> TraceSpan {
        var metadata = [
            "costUSD": String(format: "%.6f", costUSD),
            "inputTokens": "94",
            "outputTokens": "25521"
        ]
        metadata[TraceSpan.MetadataKey.executionID] = executionID
        metadata[TraceSpan.MetadataKey.role] = role
        if let costDeltaUSD {
            metadata[TraceSpan.MetadataKey.costDeltaUSD] = String(format: "%.6f", costDeltaUSD)
        }
        return TraceSpan(
            id: UUID().uuidString,
            agentID: agentID,
            sessionID: "session-\(agentID)",
            startTime: start,
            endTime: start.addingTimeInterval(durationSec),
            type: .turn,
            metadata: metadata
        )
    }

    /// Drives one real turn through `ChatViewModel` with the agent sitting on
    /// `nodeID` of a live workflow, and returns the spans that reached the store.
    ///
    /// `workflowEngine.start` is called directly rather than through the
    /// orchestrator so the node is *reserved* without being activated — activation
    /// would send the node prompt and consume the replayed stream.
    private func recordTurn(
        nodeID: String?,
        agentID: String = "worker",
        costUSD: Double
    ) async throws -> (spans: [TraceSpan], executionID: String?) {
        let runtime = TurnRecordingRuntime()
        runtime.costUSD = costUSD
        let orchestrator = Orchestrator(runtime: runtime)
        orchestrator.configureTracing(tracesURL: tempDir.appendingPathComponent("traces", isDirectory: true))
        orchestrator.addAgent(Agent(
            id: agentID, name: agentID.capitalized, model: "sonnet",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default", state: .idle
        ))
        try await orchestrator.startAgent(agentID, cwd: tempDir)

        var executionID: String?
        if let nodeID {
            let graph = WorkflowGraph(
                id: "attribution-graph", name: "Attribution", version: 1,
                nodes: [nodeID: WorkflowNode(id: nodeID, agentID: agentID, prompt: "work")],
                edges: [], entryNode: nodeID, terminalNodes: [nodeID], metadata: .empty
            )
            await orchestrator.workflowEngine.register(graph: graph)
            executionID = try await orchestrator.workflowEngine.start(graphID: graph.id, initialState: [:])
        }

        let vm = ChatViewModel(agentID: agentID, projectURL: tempDir, orchestrator: orchestrator)
        vm.inputText = "Do the work"
        await vm.send()

        let store = try XCTUnwrap(orchestrator.traceStore)
        return (await store.loadSpans(for: agentID), executionID)
    }

    // MARK: - The stamp is written

    /// Every turn emitted during a run carries the run's execution id and the role
    /// that ran it — the whole point of the change, and the assertion that fails
    /// against the reconstruction the code used to do.
    func testTurnDuringARunIsStampedWithTheExecutionAndRole() async throws {
        let (spans, startedExecution) = try await recordTurn(nodeID: "worker", costUSD: 4.24)
        let executionID = try XCTUnwrap(startedExecution)

        let recorded = try XCTUnwrap(spans.first { $0.type == .turn })
        XCTAssertEqual(recorded.metadata[TraceSpan.MetadataKey.executionID], executionID)
        XCTAssertEqual(recorded.metadata[TraceSpan.MetadataKey.role], "worker")
        // Attribution changed; the price did not.
        XCTAssertEqual(Double(recorded.metadata["costUSD"] ?? "") ?? 0, 4.24, accuracy: 0.001)

        // And it is selectable — a round trip through the store, not just the
        // dictionary the recorder built.
        XCTAssertEqual(BacklogAutopilot.costOfTurnSpans(spans, executionID: executionID),
                       4.24, accuracy: 0.001)
    }

    /// The reviewer's turns carry the reviewer role, so a run's spend can be split
    /// by who incurred it.
    func testReviewerTurnIsStampedWithTheReviewerRole() async throws {
        let (spans, startedExecution) = try await recordTurn(nodeID: "reviewer", agentID: "reviewer", costUSD: 1.46)
        let executionID = try XCTUnwrap(startedExecution)

        let recorded = try XCTUnwrap(spans.first { $0.type == .turn })
        XCTAssertEqual(recorded.metadata[TraceSpan.MetadataKey.executionID], executionID)
        XCTAssertEqual(recorded.metadata[TraceSpan.MetadataKey.role], "reviewer")
    }

    /// A human chatting to an agent has no owning run. Such a turn is stamped with
    /// neither key, which is what keeps it out of every item's total — under the
    /// old window match it was swept in whenever it overlapped a run.
    func testHumanChatTurnCarriesNoOwningRun() async throws {
        let (spans, _) = try await recordTurn(nodeID: nil, costUSD: 3.10)

        let recorded = try XCTUnwrap(spans.first { $0.type == .turn })
        XCTAssertNil(recorded.metadata[TraceSpan.MetadataKey.executionID])
        XCTAssertNil(recorded.metadata[TraceSpan.MetadataKey.role])
        XCTAssertEqual(BacklogAutopilot.costOfTurnSpans(spans, executionID: "exec-1"), 0, accuracy: 0.0001)
    }

    // MARK: - The stamp is what is selected on

    /// The run's cost is the sum of the turns stamped with it — the worker's
    /// included. Under the window match this case read $1.46, the reviewer's span
    /// alone, because the worker's turn began in the same wall-clock second the
    /// item did and the stored timestamp floored below the window start.
    func testCostIsTheSumOfTheTurnsStampedWithTheRun() {
        let spans = [
            turn(agentID: "worker", executionID: "exec-1", role: "worker", costUSD: 4.24),
            turn(agentID: "reviewer", executionID: "exec-1", role: "reviewer", costUSD: 1.46)
        ]
        XCTAssertEqual(BacklogAutopilot.costOfTurnSpans(spans, executionID: "exec-1"),
                       5.70, accuracy: 0.001)
    }

    /// Two runs overlapping in time do not contaminate each other. Time says
    /// nothing about ownership here, which is the property the window match could
    /// not offer at all.
    func testOverlappingRunsDoNotContaminateEachOther() {
        let sameInstant = Date(timeIntervalSince1970: 1_775_000_000.734)
        let spans = [
            turn(agentID: "worker", executionID: "exec-1", role: "worker",
                 start: sameInstant, durationSec: 600, costUSD: 4.24),
            turn(agentID: "worker", executionID: "exec-2", role: "worker",
                 start: sameInstant, durationSec: 600, costUSD: 9.99),
            turn(agentID: "reviewer", executionID: "exec-2", role: "reviewer",
                 start: sameInstant.addingTimeInterval(30), durationSec: 60, costUSD: 0.50)
        ]
        XCTAssertEqual(BacklogAutopilot.costOfTurnSpans(spans, executionID: "exec-1"),
                       4.24, accuracy: 0.001)
        XCTAssertEqual(BacklogAutopilot.costOfTurnSpans(spans, executionID: "exec-2"),
                       10.49, accuracy: 0.001)
    }

    /// Non-turn spans carry no cost of their own — counting them would
    /// double-charge the turn that contains them.
    func testOnlyTurnSpansAreCounted() {
        let spans = [
            turn(agentID: "worker", executionID: "exec-1", role: "worker", costUSD: 1.00),
            TraceSpan(id: UUID().uuidString, agentID: "worker", sessionID: "s",
                      startTime: Date(timeIntervalSince1970: 1_775_000_005), endTime: nil,
                      type: .toolCall,
                      metadata: ["costUSD": "5.00",
                                 TraceSpan.MetadataKey.executionID: "exec-1"])
        ]
        XCTAssertEqual(BacklogAutopilot.costOfTurnSpans(spans, executionID: "exec-1"),
                       1.00, accuracy: 0.001)
    }

    // MARK: - The reported total is a running total, not a per-turn amount

    /// `costUSD` on a span is the CLI's session-level running total at that
    /// turn, not what the turn itself cost — summing it raw over a
    /// multi-turn session roughly doubles the recorded spend. A span that
    /// carries the delta key sums on that instead, recovering the session's
    /// true final total.
    func testCostSumsTheDeltaKeyWhenSpansCarryOne() {
        let spans = [
            // A three-turn session whose running totals are 1.0, 3.0, 7.0 —
            // recorded here as the recorder now writes them: the raw total
            // beside the turn's own delta.
            turn(agentID: "worker", executionID: "exec-1", role: "worker", costUSD: 1.0, costDeltaUSD: 1.0),
            turn(agentID: "worker", executionID: "exec-1", role: "worker", costUSD: 3.0, costDeltaUSD: 2.0),
            turn(agentID: "worker", executionID: "exec-1", role: "worker", costUSD: 7.0, costDeltaUSD: 4.0)
        ]
        XCTAssertEqual(BacklogAutopilot.costOfTurnSpans(spans, executionID: "exec-1"),
                       7.0, accuracy: 0.001,
                       "the session's true total, not 1.0 + 3.0 + 7.0 = 11.0")
    }

    /// A span written before the delta key existed carries only the raw
    /// reported total — summing must fall back to it unchanged rather than
    /// reading it as zero contribution.
    func testCostFallsBackToTheReportedTotalForSpansWithoutADeltaKey() {
        let spans = [
            turn(agentID: "worker", executionID: "exec-1", role: "worker", costUSD: 4.24),
            turn(agentID: "reviewer", executionID: "exec-1", role: "reviewer", costUSD: 1.46)
        ]
        XCTAssertEqual(BacklogAutopilot.costOfTurnSpans(spans, executionID: "exec-1"),
                       5.70, accuracy: 0.001, "unchanged from before the delta key was recorded")
    }

    /// A run whose spans mix old (no delta key) and new (delta key present)
    /// turns — the case a run spanning the rollout actually produces — sums
    /// each span on whichever figure it carries.
    func testCostMixesDeltaAndFallbackFiguresAcrossSpansInTheSameRun() {
        let spans = [
            turn(agentID: "worker", executionID: "exec-1", role: "worker", costUSD: 4.24), // pre-existing, no delta key
            turn(agentID: "worker", executionID: "exec-1", role: "worker", costUSD: 9.00, costDeltaUSD: 1.50) // recorded after the fix
        ]
        XCTAssertEqual(BacklogAutopilot.costOfTurnSpans(spans, executionID: "exec-1"),
                       5.74, accuracy: 0.001)
    }

    // MARK: - Cost per role

    /// A run is otherwise one number. The role stamp is what makes "is review a
    /// third of the spend?" answerable.
    func testCostBreaksDownByRole() {
        let spans = [
            turn(agentID: "worker", executionID: "exec-1", role: "worker", costUSD: 4.00),
            turn(agentID: "worker", executionID: "exec-1", role: "worker", costUSD: 0.24),
            turn(agentID: "reviewer", executionID: "exec-1", role: "reviewer", costUSD: 1.46),
            turn(agentID: "reviewer", executionID: "exec-2", role: "reviewer", costUSD: 8.88),
            turn(agentID: "worker", costUSD: 3.10)   // human chat, no owning run
        ]
        let byRole = BacklogAutopilot.costByRole(spans, executionID: "exec-1")

        XCTAssertEqual(byRole["worker"] ?? 0, 4.24, accuracy: 0.001)
        XCTAssertEqual(byRole["reviewer"] ?? 0, 1.46, accuracy: 0.001)
        XCTAssertEqual(byRole.count, 2, "no other run's spend, and no unowned turn, appears")
        XCTAssertEqual(byRole.values.reduce(0, +),
                       BacklogAutopilot.costOfTurnSpans(spans, executionID: "exec-1"),
                       accuracy: 0.001,
                       "the split must add up to the run's total")
    }

    // MARK: - What the fix must not do

    /// A run that genuinely did nothing still reports ~$0, and still trips the
    /// no-work detector. Recording ownership must not invent spend.
    func testGenuinelyIdleRunStillReportsZero() {
        XCTAssertEqual(BacklogAutopilot.costOfTurnSpans([], executionID: "exec-1"), 0, accuracy: 0.0001)

        // A dead session still emits result events, just $0 ones.
        let zeroCostTurns = BacklogAutopilot.costOfTurnSpans(
            [turn(agentID: "worker", executionID: "exec-1", role: "worker", costUSD: 0),
             turn(agentID: "reviewer", executionID: "exec-1", role: "reviewer", costUSD: 0)],
            executionID: "exec-1"
        )
        XCTAssertEqual(zeroCostTurns, 0, accuracy: 0.0001)
        XCTAssertTrue(BacklogAutopilot.isNoWorkBlock(blocked: true, costUSD: zeroCostTurns),
                      "a run that really did nothing must still trip the no-work detector")
    }

    // MARK: - The consequences

    /// The per-item cap evaluates against the recorded total. Unattributed spend is
    /// what made the ceiling inert: $0 — or the $1.46 the window match salvaged —
    /// sits under a $2 cap that the true $5.70 blows straight through.
    func testPerItemCapEvaluatesAgainstTheAttributedTotal() {
        let total = BacklogAutopilot.costOfTurnSpans(
            [turn(agentID: "worker", executionID: "exec-1", role: "worker", costUSD: 4.24),
             turn(agentID: "reviewer", executionID: "exec-1", role: "reviewer", costUSD: 1.46)],
            executionID: "exec-1"
        )

        let budget = AutopilotCostBudget(sessionCapUSD: nil)
        XCTAssertEqual(budget.breach(itemSpend: total, itemCap: 2.0),
                       .item(cap: 2.0, spent: total),
                       "the attributed total must trip the per-item ceiling")
        // The unattributed figure did not — the ceiling never fired.
        XCTAssertNil(budget.breach(itemSpend: 0, itemCap: 2.0))
    }

    /// `isNoWorkBlock` no longer reads a worked item as no-work. The circuit
    /// breaker escalates on a run of these, so an attribution miss fed a false
    /// positive into a safety signal.
    func testWorkedItemIsNotClassifiedAsNoWork() {
        // The worker spent real money and the item still blocked — a rejected
        // review, not a dead session.
        let total = BacklogAutopilot.costOfTurnSpans(
            [turn(agentID: "worker", executionID: "exec-1", role: "worker", costUSD: 3.35)],
            executionID: "exec-1"
        )
        XCTAssertFalse(BacklogAutopilot.isNoWorkBlock(blocked: true, costUSD: total),
                       "an item that spent $3.35 is not a no-work block")
    }
}
