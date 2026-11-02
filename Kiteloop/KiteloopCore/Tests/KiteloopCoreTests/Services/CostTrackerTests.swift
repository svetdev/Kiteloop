import XCTest
@testable import KiteloopCore

final class CostTrackerTests: XCTestCase {
    private var tempDir: URL!
    private var costsURL: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "cost-tracker")
        costsURL = tempDir.appending(path: "costs.jsonl")
    }

    func testRecordAndRetrieve() async {
        let tracker = CostTracker(costsURL: costsURL)
        let entry = CostEntry(agentID: "coder", costUSD: 0.05, inputTokens: 1000, outputTokens: 500, durationMs: 2000)
        await tracker.record(entry)

        let entries = await tracker.allEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.agentID, "coder")
        XCTAssertEqual(entries.first?.costUSD, 0.05)
    }

    func testCostTodayAggregation() async {
        let tracker = CostTracker(costsURL: costsURL)
        await tracker.record(CostEntry(agentID: "coder", costUSD: 0.10, inputTokens: 2000, outputTokens: 1000, durationMs: 3000))
        await tracker.record(CostEntry(agentID: "coder", costUSD: 0.05, inputTokens: 1000, outputTokens: 500, durationMs: 1500))
        await tracker.record(CostEntry(agentID: "reviewer", costUSD: 0.03, inputTokens: 500, outputTokens: 200, durationMs: 800))

        let totalToday = await tracker.costToday(agent: nil)
        XCTAssertEqual(totalToday, 0.18, accuracy: 0.001)

        let coderToday = await tracker.costToday(agent: "coder")
        XCTAssertEqual(coderToday, 0.15, accuracy: 0.001)
    }

    func testCostByAgent() async {
        let tracker = CostTracker(costsURL: costsURL)
        await tracker.record(CostEntry(agentID: "coder", costUSD: 0.10, inputTokens: 2000, outputTokens: 1000, durationMs: 3000))
        await tracker.record(CostEntry(agentID: "reviewer", costUSD: 0.03, inputTokens: 500, outputTokens: 200, durationMs: 800))
        await tracker.record(CostEntry(agentID: "coder", costUSD: 0.07, inputTokens: 1500, outputTokens: 700, durationMs: 2200))

        let byAgent = await tracker.costByAgent()
        XCTAssertEqual(byAgent["coder"]!, 0.17, accuracy: 0.001)
        XCTAssertEqual(byAgent["reviewer"]!, 0.03, accuracy: 0.001)
    }

    func testPersistenceAcrossInstances() async {
        let tracker1 = CostTracker(costsURL: costsURL)
        await tracker1.record(CostEntry(agentID: "coder", costUSD: 0.10, inputTokens: 2000, outputTokens: 1000, durationMs: 3000))
        await tracker1.record(CostEntry(agentID: "reviewer", costUSD: 0.05, inputTokens: 1000, outputTokens: 500, durationMs: 1500))

        let tracker2 = CostTracker(costsURL: costsURL)
        let entries = await tracker2.allEntries()
        XCTAssertEqual(entries.count, 2)
    }

    func testEmptyFile() async {
        let tracker = CostTracker(costsURL: costsURL)
        let entries = await tracker.allEntries()
        XCTAssertEqual(entries.count, 0)

        let cost = await tracker.costToday(agent: nil)
        XCTAssertEqual(cost, 0)
    }

    /// And the entry recorded *after* the crash keeps its own line. Appending
    /// straight onto the remnant would glue the two into something that decodes
    /// as neither, so the spend would go down with a crash that happened before
    /// it and every cap read off this file would be under-counted by it.
    func testAnEntryRecordedAfterATruncatedLineIsReadBackOnTheNextLoad() async throws {
        let tracker1 = CostTracker(costsURL: costsURL)
        await tracker1.record(CostEntry(agentID: "coder", costUSD: 0.10, inputTokens: 2000, outputTokens: 1000, durationMs: 3000))
        // The shape a kill mid-append leaves: half an entry, no newline after it.
        try appendRaw("{\"agentID\":\"cut\",\"costU", to: costsURL)

        await CostTracker(costsURL: costsURL)
            .record(CostEntry(agentID: "reviewer", costUSD: 0.05, inputTokens: 1000, outputTokens: 500, durationMs: 1500))

        let entries = await CostTracker(costsURL: costsURL).allEntries()
        XCTAssertEqual(entries.map(\.agentID), ["coder", "reviewer"],
                       "the spend recorded after the crash survives")
        let content = try String(contentsOf: costsURL, encoding: .utf8)
        XCTAssertTrue(content.contains("{\"agentID\":\"cut\",\"costU\n"),
                      "the remnant is still there, on its own line, and still skipped by the loader")
    }

    /// The ordinary append is unchanged by the repair: a file already ending in
    /// a newline gains one line, not a blank one before it.
    func testRecordingIntoAFileEndingInANewlineAddsNoBlankLine() async throws {
        let tracker = CostTracker(costsURL: costsURL)
        await tracker.record(CostEntry(agentID: "coder", costUSD: 0.10, inputTokens: 2000, outputTokens: 1000, durationMs: 3000))
        await tracker.record(CostEntry(agentID: "reviewer", costUSD: 0.05, inputTokens: 1000, outputTokens: 500, durationMs: 1500))

        let content = try String(contentsOf: costsURL, encoding: .utf8)
        XCTAssertFalse(content.contains("\n\n"), "no blank line between the entries")
        let reloaded = await CostTracker(costsURL: costsURL).allEntries()
        XCTAssertEqual(reloaded.count, 2)
    }

    /// The file the first entry of a fresh install lands in doesn't exist yet.
    func testRecordingIntoAFileThatDoesNotExistYetWritesOneTerminatedLine() async throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: costsURL.path(percentEncoded: false)))

        await CostTracker(costsURL: costsURL)
            .record(CostEntry(agentID: "coder", costUSD: 0.10, inputTokens: 2000, outputTokens: 1000, durationMs: 3000))

        let content = try String(contentsOf: costsURL, encoding: .utf8)
        XCTAssertTrue(content.hasSuffix("\n"), "the line is newline-terminated")
        XCTAssertEqual(content.components(separatedBy: .newlines).filter { !$0.isEmpty }.count, 1)
        let reloaded = await CostTracker(costsURL: costsURL).allEntries()
        XCTAssertEqual(reloaded.count, 1)
    }

    /// One byte that is not UTF-8 used to fail the decode of the whole ledger,
    /// so the day's spend read 0 and every cap read off it went blind.
    func testALineOfInvalidUTF8BetweenTwoEntriesCostsOnlyThatLine() async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = Data()
        data.append(try encoder.encode(
            CostEntry(agentID: "coder", costUSD: 0.10, inputTokens: 2000, outputTokens: 1000, durationMs: 3000)))
        data.append(contentsOf: [0x0A, 0x7B, 0xFF, 0xFE, 0x7D, 0x0A])
        data.append(try encoder.encode(
            CostEntry(agentID: "reviewer", costUSD: 0.05, inputTokens: 1000, outputTokens: 500, durationMs: 1500)))
        data.append(0x0A)
        try data.write(to: costsURL)

        let tracker = CostTracker(costsURL: costsURL)
        let entries = await tracker.allEntries()
        XCTAssertEqual(entries.map(\.agentID), ["coder", "reviewer"])
        let today = await tracker.costToday(agent: nil)
        XCTAssertEqual(today, 0.15, accuracy: 0.001)
    }

    private func appendRaw(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}
