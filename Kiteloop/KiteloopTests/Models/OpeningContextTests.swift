import XCTest
@testable import Kiteloop

/// What a run's opening context is measured to be, and — the part that took the
/// measurement three attempts to get right — *which* turn it is read off.
final class OpeningContextTests: XCTestCase {

    // MARK: - Reading the opening call out of the stream

    func testAssistantLineYieldsItsOwnUsage() {
        let line = """
        {"type":"assistant","message":{"usage":{"input_tokens":2,\
        "cache_creation_input_tokens":22846,"cache_read_input_tokens":17519,"output_tokens":813}},\
        "session_id":"s1"}
        """
        let usage = StreamEvent.assistantUsage(inLine: line)
        XCTAssertEqual(usage?.inputTokens, 2)
        XCTAssertEqual(usage?.cacheCreationTokens, 22_846)
        XCTAssertEqual(usage?.cacheReadTokens, 17_519)
    }

    /// The `result` line carries the whole leg's counters, which is exactly the
    /// figure this measurement exists to avoid. Reading it as an opening call
    /// would report a worker's twenty file reads as its opening context.
    func testResultLineIsNotAnOpeningCall() {
        let line = """
        {"type":"result","usage":{"input_tokens":53,"cache_creation_input_tokens":62870,\
        "cache_read_input_tokens":1646664,"output_tokens":18663},"total_cost_usd":4.2}
        """
        XCTAssertNil(StreamEvent.assistantUsage(inLine: line))
    }

    func testLineWithoutUsageIsNotAnOpeningCall() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}"#
        XCTAssertNil(StreamEvent.assistantUsage(inLine: line))
    }

    /// A usage block of zeroes is a runtime that reports the field without
    /// filling it — Ollama, the Copilot bridge. Nil, not an opening context of
    /// nothing: 525 of the 1,008 turn spans on disk are in that state, and each
    /// would otherwise have claimed its run opened with 0 tokens.
    func testAllZeroUsageIsNotMeasured() {
        let line = """
        {"type":"assistant","message":{"usage":{"input_tokens":0,\
        "cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}
        """
        XCTAssertNil(StreamEvent.assistantUsage(inLine: line))
    }

    // MARK: - What the figure is

    func testPromptTokensIsEverythingSentAndBilledIsWhatItCost() {
        let context = OpeningContext(inputTokens: 2, cacheCreationTokens: 22_846, cacheReadTokens: 17_519)
        XCTAssertEqual(context.promptTokens, 40_367)
        XCTAssertEqual(context.billedTokens, 22_848)
    }

    /// The same opening context on a warm session: nearly all of it served from
    /// cache. Its *size* is unchanged; only what it cost moved. A single figure
    /// would have made a cache hit look like a slimmer prompt.
    func testWarmSessionChangesTheCostAndNotTheSize() {
        let cold = OpeningContext(inputTokens: 2, cacheCreationTokens: 40_365, cacheReadTokens: 0)
        let warm = OpeningContext(inputTokens: 2, cacheCreationTokens: 0, cacheReadTokens: 40_365)
        XCTAssertEqual(cold.promptTokens, warm.promptTokens)
        XCTAssertEqual(cold.billedTokens, 40_367)
        XCTAssertEqual(warm.billedTokens, 2)
    }

    // MARK: - First-turn attribution

    /// The acceptance criterion: the figure is the **first** turn each role
    /// recorded, not the last one and not a sum. Every later turn re-sends the
    /// same rules on top of a conversation that has grown, so any other choice
    /// measures something else.
    func testFigureIsTheFirstTurnOfEachRole() {
        let spans = [
            turn(role: "worker", startOffset: 0, opening: .init(inputTokens: 2, cacheCreationTokens: 40_000, cacheReadTokens: 0)),
            turn(role: "worker", startOffset: 600, opening: .init(inputTokens: 4, cacheCreationTokens: 900, cacheReadTokens: 380_000)),
            turn(role: "reviewer", startOffset: 900, opening: .init(inputTokens: 2, cacheCreationTokens: 31_000, cacheReadTokens: 0)),
        ]
        let byRole = OpeningContext.byRole(spans)
        XCTAssertEqual(byRole["worker"]?.promptTokens, 40_002)
        XCTAssertEqual(byRole["reviewer"]?.promptTokens, 31_002)
    }

    /// Order in the array is not order in time — spans are loaded per agent and
    /// concatenated, so the reviewer's file can arrive before the worker's.
    func testEarliestWinsRegardlessOfArrayOrder() {
        let spans = [
            turn(role: "worker", startOffset: 600, opening: .init(inputTokens: 4, cacheCreationTokens: 900, cacheReadTokens: 380_000)),
            turn(role: "worker", startOffset: 0, opening: .init(inputTokens: 2, cacheCreationTokens: 40_000, cacheReadTokens: 0)),
        ]
        XCTAssertEqual(OpeningContext.byRole(spans)["worker"]?.promptTokens, 40_002)
    }

    /// A role whose first turn measured nothing falls through to the first one
    /// that did, rather than reporting the run as unmeasured.
    func testUnmeasuredTurnsAreSkippedNotCountedAsZero() {
        let spans = [
            turn(role: "worker", startOffset: 0, opening: nil),
            turn(role: "worker", startOffset: 300, opening: .init(inputTokens: 2, cacheCreationTokens: 38_000, cacheReadTokens: 0)),
        ]
        XCTAssertEqual(OpeningContext.byRole(spans)["worker"]?.promptTokens, 38_002)
    }

    func testRoleThatMeasuredNothingIsAbsentRatherThanZero() {
        let byRole = OpeningContext.byRole([turn(role: "reviewer", startOffset: 0, opening: nil)])
        XCTAssertNil(byRole["reviewer"])
        XCTAssertTrue(byRole.isEmpty)
    }

    /// Turns belonging to another run are not this run's opening context — the
    /// same write-time attribution the cost figures use.
    func testOnlyThisExecutionsTurnsAreRead() {
        let mine = turn(role: "worker", startOffset: 300, executionID: "exec-a",
                        opening: .init(inputTokens: 2, cacheCreationTokens: 40_000, cacheReadTokens: 0))
        let theirs = turn(role: "worker", startOffset: 0, executionID: "exec-b",
                          opening: .init(inputTokens: 2, cacheCreationTokens: 9, cacheReadTokens: 0))
        let byRole = BacklogAutopilot.openingContextByRole([mine, theirs], executionID: "exec-a")
        XCTAssertEqual(byRole["worker"]?.promptTokens, 40_002)
    }

    // MARK: - The aggregate

    func testPercentilesPerRoleOverRuns() {
        let records = [10_000, 20_000, 30_000, 40_000, 50_000].map {
            record(worker: OpeningContext(inputTokens: 0, cacheCreationTokens: $0, cacheReadTokens: 0))
        }
        let stats = OpeningContextStats.byRole(records)
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats[0].role, "worker")
        XCTAssertEqual(stats[0].runs, 5)
        XCTAssertEqual(stats[0].prompt.p50, 30_000)
        XCTAssertEqual(stats[0].prompt.p90, 46_000)
    }

    /// Records written before the capture existed carry none, and must not be
    /// counted as runs that opened with nothing.
    func testRecordsWithoutAnOpeningContextAreNotInTheSample() {
        var bare = record(worker: nil)
        bare.openingContext = nil
        let stats = OpeningContextStats.byRole([
            bare,
            record(worker: OpeningContext(inputTokens: 0, cacheCreationTokens: 40_000, cacheReadTokens: 0))
        ])
        XCTAssertEqual(stats.first?.runs, 1)
    }

    func testRolesAreReportedBusiestFirst() {
        let records = [
            record(worker: .init(inputTokens: 0, cacheCreationTokens: 40_000, cacheReadTokens: 0),
                   reviewer: .init(inputTokens: 0, cacheCreationTokens: 30_000, cacheReadTokens: 0)),
            record(worker: .init(inputTokens: 0, cacheCreationTokens: 41_000, cacheReadTokens: 0))
        ]
        XCTAssertEqual(OpeningContextStats.byRole(records).map(\.role), ["worker", "reviewer"])
    }

    // MARK: - Round trip

    func testRecordCarriesTheFigureThroughItsLog() throws {
        let original = record(worker: .init(inputTokens: 2, cacheCreationTokens: 22_846, cacheReadTokens: 17_519))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TaskMetricRecord.self, from: data)
        XCTAssertEqual(decoded.openingContext?["worker"]?.promptTokens, 40_367)
    }

    /// A record from before the field existed still decodes, with nobody's
    /// opening context invented for it.
    func testRecordWrittenBeforeTheFieldExistedStillDecodes() throws {
        var bare = record(worker: nil)
        bare.openingContext = nil
        let data = try JSONEncoder().encode(bare)
        XCTAssertNil(try JSONDecoder().decode(TaskMetricRecord.self, from: data).openingContext)
    }

    // MARK: - Fixtures

    private func turn(role: String, startOffset: TimeInterval, executionID: String = "exec-a",
                      opening: OpeningContext?) -> TraceSpan {
        var metadata = [
            TraceSpan.MetadataKey.executionID: executionID,
            TraceSpan.MetadataKey.role: role,
            TraceSpan.MetadataKey.inputTokens: "94"
        ]
        if let opening {
            metadata[TraceSpan.MetadataKey.openingInputTokens] = String(opening.inputTokens)
            metadata[TraceSpan.MetadataKey.openingCacheCreationTokens] = String(opening.cacheCreationTokens)
            metadata[TraceSpan.MetadataKey.openingCacheReadTokens] = String(opening.cacheReadTokens)
        }
        let start = Date(timeIntervalSince1970: 1_775_000_000).addingTimeInterval(startOffset)
        return TraceSpan(
            id: UUID().uuidString, agentID: "agent-\(role)", sessionID: "session-\(role)",
            startTime: start, endTime: start.addingTimeInterval(60), type: .turn, metadata: metadata
        )
    }

    private func record(worker: OpeningContext?, reviewer: OpeningContext? = nil) -> TaskMetricRecord {
        var record = TaskMetricRecord(
            projectPath: "/tmp/p", projectName: "p", itemID: "i", title: "t", epic: nil,
            declaredSize: "M", startedAt: Date(timeIntervalSince1970: 1_775_000_000),
            completedAt: Date(timeIntervalSince1970: 1_775_003_600), durationSeconds: 3_600,
            costUSD: 4.2, reviewerRetries: 0, outcome: "done",
            workerAgent: "Claude", reviewerAgent: "Reviewer", executionID: "exec-a"
        )
        var byRole: [String: OpeningContext] = [:]
        if let worker { byRole["worker"] = worker }
        if let reviewer { byRole["reviewer"] = reviewer }
        record.openingContext = byRole.isEmpty ? nil : byRole
        return record
    }
}
