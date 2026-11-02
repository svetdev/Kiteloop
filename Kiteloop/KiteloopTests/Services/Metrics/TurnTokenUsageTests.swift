import XCTest
import KiteloopCore
@testable import Kiteloop

/// Replays one turn with a chosen set of usage counters, so a test can drive
/// `ChatViewModel.send()` and read back what actually reached the trace store.
private final class UsageRecordingRuntime: AgentRuntime, @unchecked Sendable {
    var usage = TokenUsage()
    var costUSD: Double = 0
    /// Emitted as the session's `init` event when set — the CLI naming the
    /// concrete model it resolved the agent's alias to.
    var reportedModel: String?

    func startSession(agent: Agent, cwd: URL, strategy: ResumeStrategy) async throws -> AgentSession {
        AgentSession(id: "token-usage-session", agentID: agent.id, startedAt: .now)
    }

    func send(_ message: String, attachments: [ChatAttachment], to session: AgentSession) -> AsyncStream<StreamEvent> {
        let initEvents: [StreamEvent] = reportedModel.map {
            [.system(subtype: "init", payload: ["model": $0])]
        } ?? []
        let events: [StreamEvent] = initEvents + [
            .assistantText("Done."),
            .result(.init(
                text: "Done.", costUSD: costUSD, durationMs: 1_000,
                inputTokens: usage.inputTokens, outputTokens: usage.outputTokens,
                cacheCreationInputTokens: usage.cacheCreationTokens,
                cacheReadInputTokens: usage.cacheReadTokens,
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

/// Covers what a turn records about what it consumed, and what a run rolls that
/// up to.
///
/// The defect these exist for: `StreamEvent` parsed all four usage counters, but
/// the turn span kept only `costUSD`, `inputTokens` and `outputTokens`. The two
/// cache counters and the model were dropped on the floor, and
/// `TaskMetricRecord` carried no tokens at all. Spend was therefore one derived
/// number frozen at the rate that applied when it ran — impossible to re-price
/// when rates move, impossible to compare across models, and blind to the cache
/// hit rate, which is the largest single lever on what a long run costs.
///
/// The recurring hazard throughout is nil versus zero: a run the app recorded
/// nothing for must never read as a run that consumed nothing.
@MainActor
final class TurnTokenUsageTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "token-usage")
    }

    // MARK: - Fixtures

    /// Drives one real turn through `ChatViewModel` and returns the spans that
    /// reached the store.
    private func recordTurn(
        usage: TokenUsage,
        costUSD: Double = 1.00,
        agentModel: String = "sonnet",
        reportedModel: String? = nil,
        agentID: String = "worker"
    ) async throws -> [TraceSpan] {
        let runtime = UsageRecordingRuntime()
        runtime.usage = usage
        runtime.costUSD = costUSD
        runtime.reportedModel = reportedModel

        let orchestrator = Orchestrator(runtime: runtime)
        orchestrator.configureTracing(tracesURL: tempDir.appendingPathComponent("traces", isDirectory: true))
        orchestrator.addAgent(Agent(
            id: agentID, name: agentID.capitalized, model: agentModel,
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default", state: .idle
        ))
        try await orchestrator.startAgent(agentID, cwd: tempDir)

        let vm = ChatViewModel(agentID: agentID, projectURL: tempDir, orchestrator: orchestrator)
        vm.inputText = "Do the work"
        await vm.send()

        let store = try XCTUnwrap(orchestrator.traceStore)
        return await store.loadSpans(for: agentID)
    }

    /// A turn span carrying an explicit set of counters, without going through
    /// the runtime — for the rollup arithmetic.
    private func turn(
        executionID: String? = nil,
        role: String? = nil,
        usage: TokenUsage?,
        model: String? = nil,
        costUSD: Double = 1.0,
        derivedCostUSD: Double? = nil,
        priceVersion: String? = nil
    ) -> TraceSpan {
        var metadata = [TraceSpan.MetadataKey.costUSD: String(format: "%.6f", costUSD)]
        if let usage {
            metadata[TraceSpan.MetadataKey.inputTokens] = String(usage.inputTokens)
            metadata[TraceSpan.MetadataKey.outputTokens] = String(usage.outputTokens)
            metadata[TraceSpan.MetadataKey.cacheCreationTokens] = String(usage.cacheCreationTokens)
            metadata[TraceSpan.MetadataKey.cacheReadTokens] = String(usage.cacheReadTokens)
        }
        metadata[TraceSpan.MetadataKey.model] = model
        metadata[TraceSpan.MetadataKey.derivedCostUSD] = derivedCostUSD.map { String(format: "%.6f", $0) }
        metadata[TraceSpan.MetadataKey.priceVersion] = priceVersion
        metadata[TraceSpan.MetadataKey.executionID] = executionID
        metadata[TraceSpan.MetadataKey.role] = role
        let start = Date(timeIntervalSince1970: 1_786_000_000)
        return TraceSpan(
            id: UUID().uuidString, agentID: "worker", sessionID: "s",
            startTime: start, endTime: start.addingTimeInterval(60),
            type: .turn, metadata: metadata
        )
    }

    // MARK: - What a turn records

    /// The change itself: a real turn writes all four counters, not the two it
    /// used to. Asserted after a round trip through the store, so it covers the
    /// encoding as well as the dictionary the recorder built.
    func testTurnSpanRecordsAllFourUsageCounters() async throws {
        let usage = TokenUsage(inputTokens: 94, outputTokens: 25_521,
                               cacheCreationTokens: 12_000, cacheReadTokens: 480_000)
        let spans = try await recordTurn(usage: usage)

        let recorded = try XCTUnwrap(spans.first { $0.type == .turn })
        XCTAssertEqual(recorded.tokenUsage, usage)
        // The cache counters are the two that used to be dropped.
        XCTAssertEqual(recorded.metadata[TraceSpan.MetadataKey.cacheCreationTokens], "12000")
        XCTAssertEqual(recorded.metadata[TraceSpan.MetadataKey.cacheReadTokens], "480000")
    }

    /// The model that produced the turn is recorded, so two runs' spend can be
    /// compared. Before this, nothing on a span said what had produced it.
    func testTurnSpanRecordsTheModelTheCLIReported() async throws {
        let spans = try await recordTurn(usage: TokenUsage(inputTokens: 10, outputTokens: 20),
                                         agentModel: "sonnet", reportedModel: "claude-sonnet-5")
        let recorded = try XCTUnwrap(spans.first { $0.type == .turn })
        XCTAssertEqual(recorded.model, "claude-sonnet-5")
    }

    /// Before the session's `init` event names a concrete id, the agent's own
    /// configured model stands in — an alias still prices, where an empty field
    /// would not.
    func testTurnSpanFallsBackToTheConfiguredModelWhenTheCLINamesNone() async throws {
        let spans = try await recordTurn(usage: TokenUsage(inputTokens: 10, outputTokens: 20),
                                         agentModel: "opus", reportedModel: nil)
        let recorded = try XCTUnwrap(spans.first { $0.type == .turn })
        XCTAssertEqual(recorded.model, "opus")
        XCTAssertNotNil(recorded.derivedCostUSD)
    }

    /// Both figures survive the turn: the one the CLI reported, and the one
    /// derived from the counters. Keeping only the CLI's is what froze spend at
    /// a rate nothing recorded; replacing it would throw away the comparison.
    func testTurnSpanKeepsBothTheReportedAndTheDerivedCost() async throws {
        let usage = TokenUsage(inputTokens: 1_000, outputTokens: 2_000,
                               cacheCreationTokens: 4_000, cacheReadTokens: 100_000)
        let spans = try await recordTurn(usage: usage, costUSD: 4.24, agentModel: "claude-opus-5")

        let recorded = try XCTUnwrap(spans.first { $0.type == .turn })
        XCTAssertEqual(try XCTUnwrap(recorded.reportedCostUSD), 4.24, accuracy: 0.000_001)

        let derived = try XCTUnwrap(recorded.derivedCostUSD)
        let version = try XCTUnwrap(recorded.priceVersion)
        // Whatever card was in force, the derived figure is that card applied to
        // these counters — and it disagrees with the CLI's, which is the signal.
        let expected = try XCTUnwrap(
            ModelPriceTable.current.cost(of: usage, model: "claude-opus-5",
                                         on: try XCTUnwrap(recorded.endTime))
        )
        XCTAssertEqual(derived, expected.usd, accuracy: 0.000_001)
        XCTAssertEqual(version, expected.priceVersion)
        XCTAssertNotEqual(derived, 4.24)
    }

    /// A model the table does not price gets no derived cost at all. $0.00 there
    /// would read as a free turn.
    func testAnUnpricedModelRecordsNoDerivedCost() async throws {
        let spans = try await recordTurn(usage: TokenUsage(inputTokens: 10, outputTokens: 20),
                                         agentModel: "llama3.1")
        let recorded = try XCTUnwrap(spans.first { $0.type == .turn })
        XCTAssertEqual(recorded.model, "llama3.1")
        XCTAssertNil(recorded.derivedCostUSD)
        XCTAssertNil(recorded.priceVersion)
        // The counters are still recorded — only the pricing is unavailable.
        XCTAssertNotNil(recorded.tokenUsage)
    }

    /// A span written before these counters existed reports no usage rather than
    /// four zeroes, so old history cannot masquerade as measured.
    func testASpanWithNoCountersReportsNoUsageRatherThanZero() {
        let legacy = turn(usage: nil)
        XCTAssertNil(legacy.tokenUsage)
        XCTAssertNil(legacy.model)
        XCTAssertNil(legacy.derivedCostUSD)
        XCTAssertNotNil(legacy.reportedCostUSD)
    }

    // MARK: - What a run rolls up to

    /// A run's usage is the sum over the turns stamped with it, and only those —
    /// the same ownership rule the cost attribution uses.
    func testRunUsageSumsOnlyTheTurnsStampedWithTheRun() throws {
        let spans = [
            turn(executionID: "exec-1", role: "worker",
                 usage: TokenUsage(inputTokens: 100, outputTokens: 2_000,
                                   cacheCreationTokens: 5_000, cacheReadTokens: 90_000),
                 model: "claude-opus-5", derivedCostUSD: 0.10, priceVersion: "2026-08-08"),
            turn(executionID: "exec-1", role: "reviewer",
                 usage: TokenUsage(inputTokens: 50, outputTokens: 1_000,
                                   cacheCreationTokens: 1_000, cacheReadTokens: 10_000),
                 model: "claude-opus-5", derivedCostUSD: 0.05, priceVersion: "2026-08-08"),
            turn(executionID: "exec-2", role: "worker",
                 usage: TokenUsage(inputTokens: 999_999, outputTokens: 999_999),
                 model: "claude-fable-5", derivedCostUSD: 99.0, priceVersion: "2026-08-08"),
        ]

        let run = BacklogAutopilot.usageOfTurnSpans(spans, executionID: "exec-1")
        XCTAssertEqual(run.usage, TokenUsage(inputTokens: 150, outputTokens: 3_000,
                                             cacheCreationTokens: 6_000, cacheReadTokens: 100_000))
        XCTAssertEqual(try XCTUnwrap(run.derivedCostUSD), 0.15, accuracy: 0.000_001)
        XCTAssertEqual(run.model, "claude-opus-5")
        XCTAssertEqual(run.priceVersion, "2026-08-08")
    }

    /// Worker and reviewer on different models are both named, rather than one
    /// silently standing for the run.
    func testARunOnTwoModelsNamesBoth() {
        let spans = [
            turn(executionID: "exec-1", usage: TokenUsage(inputTokens: 1), model: "claude-opus-5"),
            turn(executionID: "exec-1", usage: TokenUsage(inputTokens: 1), model: "claude-sonnet-5"),
        ]
        XCTAssertEqual(BacklogAutopilot.usageOfTurnSpans(spans, executionID: "exec-1").model,
                       "claude-opus-5+claude-sonnet-5")
    }

    /// A run whose turns recorded no usage rolls up to nil, not to zero. This is
    /// the acceptance criterion the whole nil-versus-zero discipline serves: a
    /// run of these means the capture is broken, and a wall of `0` would read as
    /// a run that consumed nothing.
    func testARunWithNoRecordedUsageRollsUpToNothingRatherThanZero() {
        let spans = [turn(executionID: "exec-1", usage: nil), turn(executionID: "exec-1", usage: nil)]
        let run = BacklogAutopilot.usageOfTurnSpans(spans, executionID: "exec-1")

        XCTAssertNil(run.usage)
        XCTAssertNil(run.derivedCostUSD)
        XCTAssertNil(run.model)
        XCTAssertNil(run.cacheHitRate)
        XCTAssertEqual(RunTokenUsage.rollUp([]), .none)
        // And the reported cost is untouched by any of it.
        XCTAssertEqual(BacklogAutopilot.costOfTurnSpans(spans, executionID: "exec-1"), 2.0, accuracy: 0.001)
    }

    // MARK: - What a human sees

    /// The cache hit rate reaches the run log, where an unattended marathon is
    /// read back from. A run whose cache stops hitting is a cost regression that
    /// the dollar figure alone never explains.
    func testItemEndLineCarriesTheCacheHitRate() {
        let spans = [
            turn(executionID: "exec-1", role: "worker",
                 usage: TokenUsage(inputTokens: 10_000, outputTokens: 2_000,
                                   cacheCreationTokens: 10_000, cacheReadTokens: 80_000),
                 model: "claude-opus-5", derivedCostUSD: 0.42, priceVersion: "2026-08-08"),
        ]
        let run = BacklogAutopilot.usageOfTurnSpans(spans, executionID: "exec-1")
        let head: [(String, String?)] = [("item", "x")]
        let line = BacklogAutopilot.phaseLine(.itemEnd, head + BacklogAutopilot.usageFields(run))

        XCTAssertTrue(line.contains("cacheHitRate=80%"), line)
        XCTAssertTrue(line.contains("cacheReadTokens=80000"), line)
        XCTAssertTrue(line.contains("cacheWriteTokens=10000"), line)
        XCTAssertTrue(line.contains("model=claude-opus-5"), line)
        XCTAssertTrue(line.contains("derivedCostUSD=0.4200"), line)
        XCTAssertTrue(line.contains("priceVersion=2026-08-08"), line)
    }

    /// With nothing measured, the usage fields drop out of the line entirely.
    /// `cacheHitRate=0%` would be a claim the data never made.
    func testItemEndLineOmitsUsageFieldsWhenNothingWasMeasured() {
        let head: [(String, String?)] = [("item", "x")]
        let line = BacklogAutopilot.phaseLine(.itemEnd, head + BacklogAutopilot.usageFields(.none))
        XCTAssertEqual(line, "phase=item.end item=x")
    }

    // MARK: - What the metric record reports

    /// The record reports what the run consumed and what produced it, and can be
    /// re-priced from those counters at a different card — the three things a
    /// frozen `costUSD` could not do.
    func testMetricRecordCarriesTokensAModelAndCanBeRepriced() throws {
        var record = metricRecord()
        record.inputTokens = 1_000
        record.outputTokens = 2_000
        record.cacheCreationTokens = 4_000
        record.cacheReadTokens = 100_000
        record.model = "claude-sonnet-5"
        record.priceVersion = "2026-08-08"

        XCTAssertEqual(record.tokenUsage, TokenUsage(inputTokens: 1_000, outputTokens: 2_000,
                                                     cacheCreationTokens: 4_000, cacheReadTokens: 100_000))
        XCTAssertEqual(try XCTUnwrap(record.cacheHitRate), 100_000.0 / 105_000.0, accuracy: 0.000_001)

        let asRun = try XCTUnwrap(record.reprice(on: Date(timeIntervalSince1970: 1_786_000_000)))
        let asRepriced = try XCTUnwrap(record.reprice(on: Date(timeIntervalSince1970: 1_789_000_000)))
        XCTAssertEqual(asRun.priceVersion, "2026-08-08")
        XCTAssertEqual(asRepriced.priceVersion, "2026-09-01")
        XCTAssertGreaterThan(asRepriced.usd, asRun.usd)
    }

    /// A record from before any of this decodes with every new field nil, and
    /// reports "not measured" rather than a run that consumed nothing.
    func testARecordWithNoUsageReportsNothingRatherThanZeroTokens() throws {
        let legacy = """
        {"id":"m-1","projectPath":"/tmp/p","projectName":"p","itemID":"i-1","title":"t",\
        "startedAt":"2026-08-01T00:00:00Z","completedAt":"2026-08-01T00:10:00Z",\
        "durationSeconds":600,"costUSD":2.5,"reviewerRetries":0,"outcome":"done"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(TaskMetricRecord.self, from: Data(legacy.utf8))

        XCTAssertNil(record.tokenUsage)
        XCTAssertNil(record.cacheHitRate)
        XCTAssertNil(record.model)
        XCTAssertNil(record.derivedCostUSD)
        XCTAssertNil(record.reprice(on: Date(timeIntervalSince1970: 1_786_000_000)))
        // The cost it does have is untouched.
        XCTAssertEqual(record.costUSD, 2.5, accuracy: 0.000_001)
    }

    /// An unpriced model leaves the derived cost nil while the counters stand —
    /// the run is measured, just not priceable.
    func testARecordOnAnUnpricedModelKeepsItsTokensButHasNoDerivedCost() {
        var record = metricRecord()
        record.inputTokens = 500
        record.outputTokens = 500
        record.model = "llama3.1"
        XCTAssertNotNil(record.tokenUsage)
        XCTAssertNil(record.reprice(on: Date(timeIntervalSince1970: 1_786_000_000)))
    }

    private func metricRecord() -> TaskMetricRecord {
        TaskMetricRecord(
            projectPath: "/tmp/p", projectName: "p", itemID: "i-1", title: "t",
            epic: nil, declaredSize: "M",
            startedAt: Date(timeIntervalSince1970: 1_786_000_000),
            completedAt: Date(timeIntervalSince1970: 1_786_000_600),
            durationSeconds: 600, costUSD: 2.5, reviewerRetries: 0, outcome: "done",
            workerAgent: "worker", reviewerAgent: "reviewer", executionID: "exec-1",
            toolErrors: nil
        )
    }
}
