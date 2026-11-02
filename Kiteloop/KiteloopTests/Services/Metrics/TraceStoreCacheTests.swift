import XCTest
import KiteloopCore
@testable import Kiteloop

/// A trace read costs the bytes appended since the last one, not every day file
/// the project has ever written. `filesRead` is how these cases see a read that
/// did *not* happen — the spans coming back are the same either way, which is
/// exactly why the old scan-everything load went unnoticed as history piled up.
final class TraceStoreCacheTests: XCTestCase {
    private var tempDir: URL!
    private var tracesURL: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "trace-store-cache")
        tracesURL = tempDir.appending(path: "traces")
        try FileManager.default.createDirectory(at: tracesURL, withIntermediateDirectories: true)
    }

    // MARK: - Fixtures

    private func makeDate(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return Calendar.current.date(from: components)!
    }

    private func makeSpan(agentID: String, startTime: Date) -> TraceSpan {
        TraceSpan(
            id: UUID().uuidString,
            agentID: agentID,
            sessionID: "s-\(agentID)",
            startTime: startTime,
            endTime: startTime.addingTimeInterval(1),
            type: .turn,
            metadata: [:]
        )
    }

    private func makeOTelSpan(agentID: String?) -> Span {
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

    private func line<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(data: try encoder.encode(value), encoding: .utf8)! + "\n"
    }

    private func write(_ text: String, to file: String) throws {
        try text.write(to: tracesURL.appending(path: file), atomically: true, encoding: .utf8)
    }

    private func appendRaw(_ text: String, to file: String) throws {
        let handle = try FileHandle(forWritingTo: tracesURL.appending(path: file))
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func modificationDate(of file: String) throws -> Date {
        let attributes = try FileManager.default
            .attributesOfItem(atPath: tracesURL.appending(path: file).path(percentEncoded: false))
        return try XCTUnwrap(attributes[.modificationDate] as? Date)
    }

    private func setModificationDate(_ date: Date, of file: String) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: tracesURL.appending(path: file).path(percentEncoded: false)
        )
    }

    // MARK: - TraceSpan reads

    func testASecondLoadOverAnUnchangedDirectoryReadsNoFiles() async throws {
        try write(try line(makeSpan(agentID: "coder", startTime: makeDate(2026, 5, 20))),
                  to: "2026-05-20.jsonl")
        try write(try line(makeSpan(agentID: "coder", startTime: makeDate(2026, 5, 21))),
                  to: "2026-05-21.jsonl")
        let store = TraceStore(tracesURL: tracesURL)

        let first = await store.loadSpans(for: "coder")
        XCTAssertEqual(first.count, 2)
        let readsAfterFirst = await store.filesRead
        XCTAssertEqual(readsAfterFirst, 2, "one read per day file present")

        let second = await store.loadSpans(for: "coder")
        XCTAssertEqual(second.map(\.id), first.map(\.id), "the same spans, in the same order")
        let readsAfterSecond = await store.filesRead
        XCTAssertEqual(readsAfterSecond, 2, "nothing changed on disk, so nothing was re-read")
    }

    func testASpanAppendedAfterALoadIsReturnedByTheNextLoad() async throws {
        let day = makeDate(2026, 5, 20)
        try write(try line(makeSpan(agentID: "coder", startTime: day)), to: "2026-05-20.jsonl")
        let store = TraceStore(tracesURL: tracesURL)

        let before = await store.loadSpans(for: "coder")
        XCTAssertEqual(before.count, 1)

        try appendRaw(try line(makeSpan(agentID: "coder", startTime: day)), to: "2026-05-20.jsonl")

        let after = await store.loadSpans(for: "coder")
        XCTAssertEqual(after.count, 2, "the cache invalidates when the file changes")
        let reads = await store.filesRead
        XCTAssertEqual(reads, 2, "the changed file was read again")
    }

    func testAppendedSpansAreVisibleToTheNextLoadFromTheSameStore() async throws {
        let day = makeDate(2026, 5, 20)
        let store = TraceStore(tracesURL: tracesURL)
        await store.append(makeSpan(agentID: "coder", startTime: day))
        let afterFirstAppend = await store.loadSpans(for: day)
        XCTAssertEqual(afterFirstAppend.count, 1)

        await store.append(makeSpan(agentID: "coder", startTime: day))

        let afterSecondAppend = await store.loadSpans(for: day)
        XCTAssertEqual(afterSecondAppend.count, 2,
                       "the store's own write does not leave the cache behind")
    }

    func testADeletedDayFileStopsContributingSpansAndItsEntryIsDropped() async throws {
        let kept = try line(makeSpan(agentID: "coder", startTime: makeDate(2026, 5, 20)))
        let removed = try line(makeSpan(agentID: "coder", startTime: makeDate(2026, 5, 21)))
        try write(kept, to: "2026-05-20.jsonl")
        try write(removed, to: "2026-05-21.jsonl")
        let store = TraceStore(tracesURL: tracesURL)

        let both = await store.loadSpans(for: "coder")
        XCTAssertEqual(both.count, 2)
        let stamp = try modificationDate(of: "2026-05-21.jsonl")

        try FileManager.default.removeItem(at: tracesURL.appending(path: "2026-05-21.jsonl"))

        let afterDelete = await store.loadSpans(for: "coder")
        XCTAssertEqual(afterDelete.count, 1, "the deleted day stops contributing spans")
        let readsAfterDelete = await store.filesRead
        XCTAssertEqual(readsAfterDelete, 2, "the surviving file was not re-read")

        // Restored byte-for-byte, with the modification date it had before: a
        // cache entry the delete failed to drop would still match this stamp and
        // answer from memory, so the extra read is what says the entry is gone.
        try write(removed, to: "2026-05-21.jsonl")
        try setModificationDate(stamp, of: "2026-05-21.jsonl")

        let afterRestore = await store.loadSpans(for: "coder")
        XCTAssertEqual(afterRestore.count, 2)
        let readsAfterRestore = await store.filesRead
        XCTAssertEqual(readsAfterRestore, 3, "the restored file was read afresh, not served stale")
    }

    func testADirectoryThatDisappearsDropsEveryEntry() async throws {
        try write(try line(makeSpan(agentID: "coder", startTime: makeDate(2026, 5, 20))),
                  to: "2026-05-20.jsonl")
        let store = TraceStore(tracesURL: tracesURL)
        let before = await store.loadSpans(for: "coder")
        XCTAssertEqual(before.count, 1)

        try FileManager.default.removeItem(at: tracesURL)

        let after = await store.loadSpans(for: "coder")
        XCTAssertEqual(after.count, 0)
        let reads = await store.filesRead
        XCTAssertEqual(reads, 1, "there was nothing left to read")
    }

    // MARK: - OTel reads

    func testASecondOTelLoadOverAnUnchangedDirectoryReadsNoFiles() async throws {
        let content = try line(makeOTelSpan(agentID: "agent-A")) + (try line(makeOTelSpan(agentID: "agent-B")))
        try write(content, to: "2026-05-20.jsonl")
        let store = TraceStore(tracesURL: tracesURL)

        let first = await store.loadOTelSpans()
        XCTAssertEqual(first.count, 2)
        let readsAfterFirst = await store.filesRead
        XCTAssertEqual(readsAfterFirst, 1)

        let second = await store.loadOTelSpans()
        XCTAssertEqual(second.map(\.spanID), first.map(\.spanID))
        let readsAfterSecond = await store.filesRead
        XCTAssertEqual(readsAfterSecond, 1, "nothing changed on disk, so nothing was re-read")
    }

    func testAnOTelSpanAppendedAfterALoadIsReturnedByTheNextLoad() async throws {
        try write(try line(makeOTelSpan(agentID: "agent-A")), to: "2026-05-20.jsonl")
        let store = TraceStore(tracesURL: tracesURL)
        let before = await store.loadOTelSpans()
        XCTAssertEqual(before.count, 1)

        try appendRaw(try line(makeOTelSpan(agentID: "agent-B")), to: "2026-05-20.jsonl")

        let appended = await store.loadOTelSpans(for: "agent-B")
        XCTAssertEqual(appended.count, 1)
        let reads = await store.filesRead
        XCTAssertEqual(reads, 2)
    }

    /// The two decoders disagree about what a line is, so one file's `TraceSpan`
    /// reading must not be handed back as its `Span` reading. Sharing one entry
    /// would answer this file's OTel load with an empty list.
    func testTraceSpanAndOTelReadingsOfOneFileDoNotShareACacheEntry() async throws {
        let content = try line(makeSpan(agentID: "coder", startTime: makeDate(2026, 5, 20)))
            + (try line(makeOTelSpan(agentID: "agent-A")))
        try write(content, to: "2026-05-20.jsonl")
        let store = TraceStore(tracesURL: tracesURL)

        let traceSpans = await store.loadSpans(for: "coder")
        XCTAssertEqual(traceSpans.count, 1, "only the TraceSpan line decodes as one")
        let readsAfterTraceSpans = await store.filesRead
        XCTAssertEqual(readsAfterTraceSpans, 1)

        let otelSpans = await store.loadOTelSpans()
        XCTAssertEqual(otelSpans.map(\.agentID), ["agent-A"], "only the Span line decodes as one")
        let readsAfterOTel = await store.filesRead
        XCTAssertEqual(readsAfterOTel, 2, "the OTel load reads the file itself rather than reusing a decoding of it")
    }
}
