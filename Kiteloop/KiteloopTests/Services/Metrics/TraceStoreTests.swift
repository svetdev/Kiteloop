import XCTest
import KiteloopCore
@testable import Kiteloop

final class TraceStoreTests: XCTestCase {
    private var tempDir: URL!
    private var tracesURL: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "trace-store")
        tracesURL = tempDir.appending(path: "traces")
        try FileManager.default.createDirectory(at: tracesURL, withIntermediateDirectories: true)
    }

    private func writeSpan(_ span: TraceSpan, to file: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(span)
        let line = String(data: data, encoding: .utf8)! + "\n"
        let fileURL = tracesURL.appending(path: file)
        if FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
            let handle = try FileHandle(forWritingTo: fileURL)
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try line.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    private func makeDate(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return Calendar.current.date(from: components)!
    }

    private func makeSpan(
        agentID: String,
        sessionID: String,
        startTime: Date,
        duration: TimeInterval? = nil,
        type: TraceSpan.SpanType = .turn,
        metadata: [String: String] = [:]
    ) -> TraceSpan {
        TraceSpan(
            id: UUID().uuidString,
            agentID: agentID,
            sessionID: sessionID,
            startTime: startTime,
            endTime: duration.map { startTime.addingTimeInterval($0) },
            type: type,
            metadata: metadata
        )
    }

    private func lines(inFile file: String, at url: URL) throws -> [String] {
        let content = try String(contentsOf: url.appending(path: file), encoding: .utf8)
        return content.components(separatedBy: .newlines).filter { !$0.isEmpty }
    }

    private func appendRaw(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    // MARK: - append

    func testAppendCreatesTracesDirectoryAndDatedFile() async throws {
        let freshURL = tempDir.appending(path: "nested/traces")
        XCTAssertFalse(FileManager.default.fileExists(atPath: freshURL.path(percentEncoded: false)))

        let store = TraceStore(tracesURL: freshURL)
        await store.append(makeSpan(agentID: "coder", sessionID: "s1", startTime: makeDate(2026, 5, 20)))

        let fileURL = freshURL.appending(path: "2026-05-20.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(content.hasSuffix("\n"), "the line is newline-terminated")
        let loaded = await store.loadSpans(for: makeDate(2026, 5, 20))
        XCTAssertEqual(loaded.map(\.agentID), ["coder"], "the span landed, not just the file")
    }

    func testAppendRoundTripsSpanThroughLoad() async throws {
        let start = makeDate(2026, 5, 20)
        let span = makeSpan(
            agentID: "coder",
            sessionID: "s1",
            startTime: start,
            duration: 5,
            type: .toolCall,
            metadata: ["tool": "Edit", "costUSD": "0.05"]
        )

        let store = TraceStore(tracesURL: tracesURL)
        await store.append(span)

        let loaded = await store.loadSpans(for: start)
        XCTAssertEqual(loaded.count, 1)
        let round = try XCTUnwrap(loaded.first)
        XCTAssertEqual(round.id, span.id)
        XCTAssertEqual(round.agentID, "coder")
        XCTAssertEqual(round.sessionID, "s1")
        XCTAssertEqual(round.type, .toolCall)
        XCTAssertEqual(round.metadata["tool"], "Edit")
        XCTAssertEqual(round.duration ?? 0, 5, accuracy: 0.001)
    }

    func testAppendAccumulatesSpansAsSeparateLines() async throws {
        let start = makeDate(2026, 5, 20)
        let store = TraceStore(tracesURL: tracesURL)

        for index in 0..<3 {
            await store.append(
                makeSpan(agentID: "coder", sessionID: "s1", startTime: start.addingTimeInterval(Double(index)))
            )
        }

        XCTAssertEqual(try lines(inFile: "2026-05-20.jsonl", at: tracesURL).count, 3)
        let loaded = await store.loadSpans(for: start)
        XCTAssertEqual(loaded.count, 3)
    }

    func testAppendFromNewStoreInstancePreservesExistingLines() async throws {
        let start = makeDate(2026, 5, 20)

        let first = TraceStore(tracesURL: tracesURL)
        await first.append(makeSpan(agentID: "coder", sessionID: "s1", startTime: start))

        let second = TraceStore(tracesURL: tracesURL)
        await second.append(makeSpan(agentID: "reviewer", sessionID: "s2", startTime: start))

        XCTAssertEqual(try lines(inFile: "2026-05-20.jsonl", at: tracesURL).count, 2)
        let agents = await second.loadSpans(for: start).map(\.agentID).sorted()
        XCTAssertEqual(agents, ["coder", "reviewer"])
    }

    /// And the span appended *after* the crash keeps its own line. Appending
    /// straight onto the remnant would glue the two into something that decodes
    /// as neither, so the span recorded after the crash would be missing from the
    /// traces and the turn it belonged to unaccounted for.
    func testASpanAppendedAfterATruncatedLineIsReadBackOnTheNextLoad() async throws {
        let start = makeDate(2026, 5, 20)
        let fileURL = tracesURL.appending(path: "2026-05-20.jsonl")

        let store = TraceStore(tracesURL: tracesURL)
        await store.append(makeSpan(agentID: "coder", sessionID: "s1", startTime: start))
        // The shape a kill mid-append leaves: half a span, no newline after it.
        try appendRaw("{\"agentID\":\"cu", to: fileURL)

        await TraceStore(tracesURL: tracesURL)
            .append(makeSpan(agentID: "reviewer", sessionID: "s2", startTime: start))

        let loaded = await TraceStore(tracesURL: tracesURL).loadSpans(for: start)
        XCTAssertEqual(loaded.map(\.agentID).sorted(), ["coder", "reviewer"],
                       "the span recorded after the crash survives")
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("{\"agentID\":\"cu\n"),
                      "the remnant is still there, on its own line, and still skipped by the loader")
    }

    /// The ordinary append is unchanged by the repair: a file already ending in a
    /// newline gains one line, not a blank one before it.
    func testAppendingIntoAFileEndingInANewlineAddsNoBlankLine() async throws {
        let start = makeDate(2026, 5, 20)
        let store = TraceStore(tracesURL: tracesURL)

        await store.append(makeSpan(agentID: "coder", sessionID: "s1", startTime: start))
        await store.append(makeSpan(agentID: "reviewer", sessionID: "s2", startTime: start))

        let content = try String(contentsOf: tracesURL.appending(path: "2026-05-20.jsonl"),
                                 encoding: .utf8)
        XCTAssertFalse(content.contains("\n\n"), "no blank line between the spans")
        let loaded = await store.loadSpans(for: start)
        XCTAssertEqual(loaded.count, 2)
    }

    func testAppendPartitionsSpansByStartDate() async throws {
        let dayOne = makeDate(2026, 5, 20)
        let dayTwo = makeDate(2026, 5, 21)
        let store = TraceStore(tracesURL: tracesURL)

        await store.append(makeSpan(agentID: "coder", sessionID: "s1", startTime: dayOne))
        await store.append(makeSpan(agentID: "reviewer", sessionID: "s2", startTime: dayTwo))

        XCTAssertEqual(try lines(inFile: "2026-05-20.jsonl", at: tracesURL).count, 1)
        XCTAssertEqual(try lines(inFile: "2026-05-21.jsonl", at: tracesURL).count, 1)

        let dayOneSpans = await store.loadSpans(for: dayOne)
        XCTAssertEqual(dayOneSpans.map(\.agentID), ["coder"])
        let dayTwoSpans = await store.loadSpans(for: dayTwo)
        XCTAssertEqual(dayTwoSpans.map(\.agentID), ["reviewer"])
    }

    func testAppendedSpansAggregateIntoSessions() async throws {
        let start = makeDate(2026, 5, 20)
        let store = TraceStore(tracesURL: tracesURL)

        await store.append(makeSpan(
            agentID: "coder", sessionID: "session-1", startTime: start,
            duration: 5, metadata: ["costUSD": "0.05", "costDeltaUSD": "0.05"]
        ))
        await store.append(makeSpan(
            agentID: "coder", sessionID: "session-1", startTime: start.addingTimeInterval(10),
            duration: 3, metadata: ["costUSD": "0.08", "costDeltaUSD": "0.03"]
        ))

        let sessions = await store.allSessions()
        XCTAssertEqual(sessions.count, 1)
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.id, "session-1")
        XCTAssertEqual(session.agentID, "coder")
        XCTAssertEqual(session.spanCount, 2)
        XCTAssertEqual(session.totalCost, 0.08, accuracy: 0.001)
        XCTAssertEqual(session.duration, 8, accuracy: 0.001)
        XCTAssertEqual(session.date, start)
    }

    /// `costUSD` is the session's running total at the time of the turn, so
    /// summing it counts every earlier turn again: three turns whose totals
    /// climb to $0.30 cost $0.30, not the $0.60 their totals add up to.
    func testAllSessionsSumsPerTurnDeltasNotRunningTotals() async throws {
        let start = makeDate(2026, 5, 20)
        let store = TraceStore(tracesURL: tracesURL)

        let turns = [("0.05", "0.05"), ("0.18", "0.13"), ("0.30", "0.12")]
        for (index, turn) in turns.enumerated() {
            await store.append(makeSpan(
                agentID: "coder", sessionID: "s1",
                startTime: start.addingTimeInterval(Double(index) * 10),
                duration: 2, metadata: ["costUSD": turn.0, "costDeltaUSD": turn.1]
            ))
        }

        let sessions = await store.allSessions()
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.totalCost, 0.30, accuracy: 0.001)
    }

    /// A session written before the delta was recorded: every span carries the
    /// running total as of its turn, and each already contains the ones before
    /// it, so the largest counts once.
    func testAllSessionsCountsALegacyRunningTotalOnce() async throws {
        let start = makeDate(2026, 5, 20)
        let store = TraceStore(tracesURL: tracesURL)

        for (index, total) in ["0.05", "0.18", "0.30"].enumerated() {
            await store.append(makeSpan(
                agentID: "coder", sessionID: "s1",
                startTime: start.addingTimeInterval(Double(index) * 10),
                duration: 2, metadata: ["costUSD": total]
            ))
        }

        let sessions = await store.allSessions()
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.totalCost, 0.30, accuracy: 0.001)
    }

    // MARK: - loadSpans(for: Date)

    func testLoadSpansForDateExcludesOtherDays() async throws {
        let target = makeDate(2026, 5, 20)
        try writeSpan(makeSpan(agentID: "coder", sessionID: "s1", startTime: target), to: "a.jsonl")
        try writeSpan(makeSpan(agentID: "coder", sessionID: "s1", startTime: makeDate(2026, 5, 21)), to: "a.jsonl")
        try writeSpan(makeSpan(agentID: "coder", sessionID: "s1", startTime: makeDate(2026, 5, 19)), to: "a.jsonl")

        let store = TraceStore(tracesURL: tracesURL)
        let spans = await store.loadSpans(for: target)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.startTime, target)
    }

    func testLoadSpansForDateIgnoresTimeOfDay() async throws {
        let store = TraceStore(tracesURL: tracesURL)
        await store.append(makeSpan(agentID: "coder", sessionID: "s1", startTime: makeDate(2026, 5, 20, hour: 0)))
        await store.append(makeSpan(agentID: "coder", sessionID: "s1", startTime: makeDate(2026, 5, 20, hour: 23)))

        let spans = await store.loadSpans(for: makeDate(2026, 5, 20, hour: 8))
        XCTAssertEqual(spans.count, 2)
    }

    func testLoadSpansMergesAcrossFiles() async throws {
        let target = makeDate(2026, 5, 20)
        try writeSpan(makeSpan(agentID: "coder", sessionID: "s1", startTime: target), to: "a.jsonl")
        try writeSpan(makeSpan(agentID: "reviewer", sessionID: "s2", startTime: target), to: "b.jsonl")

        let store = TraceStore(tracesURL: tracesURL)
        let spans = await store.loadSpans(for: target)
        XCTAssertEqual(spans.map(\.agentID).sorted(), ["coder", "reviewer"])
    }

    func testLoadSpansIgnoresNonJSONLFiles() async throws {
        let target = makeDate(2026, 5, 20)
        try writeSpan(makeSpan(agentID: "coder", sessionID: "s1", startTime: target), to: "a.jsonl")
        try "not a trace".write(to: tracesURL.appending(path: "notes.txt"), atomically: true, encoding: .utf8)

        let store = TraceStore(tracesURL: tracesURL)
        let spans = await store.loadSpans(for: target)
        XCTAssertEqual(spans.count, 1)
    }

    // MARK: - allSessions

    func testAllSessionsExcludesNonTurnSpans() async throws {
        let start = makeDate(2026, 5, 20)
        let store = TraceStore(tracesURL: tracesURL)

        await store.append(makeSpan(agentID: "coder", sessionID: "s1", startTime: start, duration: 5, type: .turn))
        await store.append(makeSpan(agentID: "coder", sessionID: "s1", startTime: start, duration: 1, type: .toolCall))
        await store.append(makeSpan(agentID: "coder", sessionID: "s1", startTime: start, duration: 2, type: .thinking))

        let sessions = await store.allSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.spanCount, 1)
        XCTAssertEqual(sessions.first?.duration ?? 0, 5, accuracy: 0.001)
    }

    func testAllSessionsHasNoSessionsWhenOnlyNonTurnSpansExist() async throws {
        let store = TraceStore(tracesURL: tracesURL)
        await store.append(makeSpan(
            agentID: "coder", sessionID: "s1", startTime: makeDate(2026, 5, 20), duration: 1, type: .toolCall
        ))

        let sessions = await store.allSessions()
        XCTAssertTrue(sessions.isEmpty)
    }

    func testAllSessionsSortedByDateDescending() async throws {
        let store = TraceStore(tracesURL: tracesURL)
        await store.append(makeSpan(agentID: "coder", sessionID: "oldest", startTime: makeDate(2026, 5, 18)))
        await store.append(makeSpan(agentID: "coder", sessionID: "newest", startTime: makeDate(2026, 5, 22)))
        await store.append(makeSpan(agentID: "coder", sessionID: "middle", startTime: makeDate(2026, 5, 20)))

        let sessions = await store.allSessions()
        XCTAssertEqual(sessions.map(\.id), ["newest", "middle", "oldest"])
    }

    func testAllSessionsUsesEarliestTurnForDateAndAgent() async throws {
        let start = makeDate(2026, 5, 20)
        let store = TraceStore(tracesURL: tracesURL)

        // Appended out of chronological order on purpose.
        await store.append(makeSpan(agentID: "reviewer", sessionID: "s1", startTime: start.addingTimeInterval(60)))
        await store.append(makeSpan(agentID: "coder", sessionID: "s1", startTime: start))

        let sessions = await store.allSessions()
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.date, start)
        XCTAssertEqual(session.agentID, "coder")
    }

    func testAllSessionsTreatsMissingCostAsZero() async throws {
        let start = makeDate(2026, 5, 20)
        let store = TraceStore(tracesURL: tracesURL)

        await store.append(makeSpan(agentID: "coder", sessionID: "s1", startTime: start, duration: 2))
        await store.append(makeSpan(
            agentID: "coder", sessionID: "s1", startTime: start.addingTimeInterval(10), duration: 2,
            metadata: ["costUSD": "0.04", "costDeltaUSD": "0.04"]
        ))

        let sessions = await store.allSessions()
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.totalCost, 0.04, accuracy: 0.001)
    }

    func testAllSessionsIgnoresOpenTurnsInDuration() async throws {
        let start = makeDate(2026, 5, 20)
        let store = TraceStore(tracesURL: tracesURL)

        await store.append(makeSpan(agentID: "coder", sessionID: "s1", startTime: start, duration: 4))
        await store.append(makeSpan(agentID: "coder", sessionID: "s1", startTime: start, duration: nil))

        let sessions = await store.allSessions()
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.spanCount, 2)
        XCTAssertEqual(session.duration, 4, accuracy: 0.001)
    }

    func testLoadSpansFromFile() async throws {
        var span = TraceSpan(agentID: "coder", sessionID: "s1", type: .turn, metadata: ["costUSD": "0.05"])
        span.endTime = span.startTime.addingTimeInterval(5)
        try writeSpan(span, to: "2026-05-20.jsonl")

        let store = TraceStore(tracesURL: tracesURL)
        let spans = await store.loadSpans(for: Date())
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.agentID, "coder")
    }

    func testLoadSpansByAgent() async throws {
        var s1 = TraceSpan(agentID: "coder", sessionID: "s1", type: .turn)
        s1.endTime = s1.startTime.addingTimeInterval(3)
        var s2 = TraceSpan(agentID: "reviewer", sessionID: "s2", type: .turn)
        s2.endTime = s2.startTime.addingTimeInterval(2)
        var s3 = TraceSpan(agentID: "coder", sessionID: "s1", type: .toolCall, metadata: ["tool": "Edit"])
        s3.endTime = s3.startTime.addingTimeInterval(1)

        try writeSpan(s1, to: "trace.jsonl")
        try writeSpan(s2, to: "trace.jsonl")
        try writeSpan(s3, to: "trace.jsonl")

        let store = TraceStore(tracesURL: tracesURL)
        let coderSpans = await store.loadSpans(for: "coder")
        XCTAssertEqual(coderSpans.count, 2)
    }

    func testAllSessions() async throws {
        var s1 = TraceSpan(agentID: "coder", sessionID: "session-1", type: .turn,
                           metadata: ["costUSD": "0.05", "costDeltaUSD": "0.05"])
        s1.endTime = s1.startTime.addingTimeInterval(5)
        var s2 = TraceSpan(agentID: "coder", sessionID: "session-1", type: .turn,
                           metadata: ["costUSD": "0.08", "costDeltaUSD": "0.03"])
        s2.endTime = s2.startTime.addingTimeInterval(3)
        var s3 = TraceSpan(agentID: "reviewer", sessionID: "session-2", type: .turn,
                           metadata: ["costUSD": "0.10", "costDeltaUSD": "0.10"])
        s3.endTime = s3.startTime.addingTimeInterval(10)

        try writeSpan(s1, to: "trace.jsonl")
        try writeSpan(s2, to: "trace.jsonl")
        try writeSpan(s3, to: "trace.jsonl")

        let store = TraceStore(tracesURL: tracesURL)
        let sessions = await store.allSessions()
        XCTAssertEqual(sessions.count, 2)

        let session1 = sessions.first(where: { $0.id == "session-1" })
        XCTAssertEqual(session1?.spanCount, 2)
        XCTAssertEqual(session1?.totalCost ?? 0, 0.08, accuracy: 0.001)
    }

    func testEmptyDirectory() async {
        let store = TraceStore(tracesURL: tracesURL)
        let spans = await store.loadSpans(for: Date())
        XCTAssertEqual(spans.count, 0)
        let sessions = await store.allSessions()
        XCTAssertEqual(sessions.count, 0)
    }

    func testMalformedLinesSkipped() async throws {
        let fileURL = tracesURL.appending(path: "mixed.jsonl")
        let content = """
        {"not valid json
        \(try! String(data: JSONEncoder().withDateStrategy().encode(TraceSpan(agentID: "coder", sessionID: "s1", type: .turn)), encoding: .utf8)!)
        also garbage
        """
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = TraceStore(tracesURL: tracesURL)
        let spans = await store.loadSpans(for: "coder")
        XCTAssertEqual(spans.count, 1)
    }

    // MARK: - A line that is not valid UTF-8

    /// The first two bytes of an em dash (E2 80 94), the shape a kill partway
    /// through an append leaves behind.
    private var truncatedEmDashLine: Data {
        Data("{\"agentID\":\"coder\",\"note\":\"cut ".utf8) + Data([0xE2, 0x80]) + Data("\n".utf8)
    }

    private func encodedLine<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value) + Data("\n".utf8)
    }

    private func makeOTelSpan(agentID: String) -> Span {
        Span(
            traceID: OTelIDs.newTraceID(),
            spanID: OTelIDs.newSpanID(),
            parentSpanID: nil,
            name: "turn",
            spanType: .turn,
            agentID: agentID,
            startTime: makeDate(2026, 5, 20),
            endTime: nil,
            status: .unset,
            attributes: [:],
            events: [],
            links: []
        )
    }

    func testAnInvalidUTF8LineCostsOnlyItselfForTraceSpans() async throws {
        let start = makeDate(2026, 5, 20)
        let before = makeSpan(agentID: "coder", sessionID: "s1", startTime: start, metadata: ["costUSD": "0.05"])
        let after = makeSpan(agentID: "coder", sessionID: "s1", startTime: start, metadata: ["costUSD": "0.08"])
        let content = try encodedLine(before) + truncatedEmDashLine + encodedLine(after)
        try content.write(to: tracesURL.appending(path: "2026-05-20.jsonl"))

        let spans = await TraceStore(tracesURL: tracesURL).loadSpans(for: "coder")
        XCTAssertEqual(spans.map(\.id), [before.id, after.id],
                       "the spans on either side of the bad line both load")
    }

    func testAnInvalidUTF8LineCostsOnlyItselfForOTelSpans() async throws {
        let before = makeOTelSpan(agentID: "agent-A")
        let after = makeOTelSpan(agentID: "agent-B")
        let content = try encodedLine(before) + truncatedEmDashLine + encodedLine(after)
        try content.write(to: tracesURL.appending(path: "2026-05-20.jsonl"))

        let spans = await TraceStore(tracesURL: tracesURL).loadOTelSpans()
        XCTAssertEqual(spans.map(\.spanID), [before.spanID, after.spanID])
    }

    func testAFileWithOneInvalidUTF8LineIsStillCached() async throws {
        let start = makeDate(2026, 5, 20)
        let content = try encodedLine(makeSpan(agentID: "coder", sessionID: "s1", startTime: start))
            + truncatedEmDashLine
            + encodedLine(makeSpan(agentID: "coder", sessionID: "s1", startTime: start))
        try content.write(to: tracesURL.appending(path: "2026-05-20.jsonl"))
        let store = TraceStore(tracesURL: tracesURL)

        let first = await store.loadSpans(for: "coder")
        XCTAssertEqual(first.count, 2)
        let readsAfterFirst = await store.filesRead
        XCTAssertEqual(readsAfterFirst, 1)

        let second = await store.loadSpans(for: "coder")
        XCTAssertEqual(second.count, 2)
        let readsAfterSecond = await store.filesRead
        XCTAssertEqual(readsAfterSecond, 1, "an unchanged file with a bad line is not re-read")
    }

    func testAMissingTracesDirectoryLoadsAsNoSpans() async {
        let store = TraceStore(tracesURL: tempDir.appending(path: "no-such-traces"))
        let spans = await store.loadSpans(for: "coder")
        XCTAssertTrue(spans.isEmpty)
        let otelSpans = await store.loadOTelSpans()
        XCTAssertTrue(otelSpans.isEmpty)
    }
}

private extension JSONEncoder {
    func withDateStrategy() -> JSONEncoder {
        self.dateEncodingStrategy = .iso8601
        return self
    }
}
