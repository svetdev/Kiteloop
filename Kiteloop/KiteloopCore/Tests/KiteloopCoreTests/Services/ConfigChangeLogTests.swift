import XCTest
@testable import KiteloopCore

/// The log of configuration changes an agent asked for and a person decided
/// on: one JSON line per decision, in one file in the app's own directory,
/// each line naming its project and chained to the line before it.
final class ConfigChangeLogTests: XCTestCase {

    private var appDirectory: URL!
    private var url: URL { ConfigChangeLog.url(appDirectory: appDirectory) }

    override func setUp() async throws {
        appDirectory = try makeTemporaryDirectory(prefix: "config-change-log")
    }

    func testReadingAMissingLogIsEmpty() {
        XCTAssertEqual(ConfigChangeLog.read(from: url), [])
        XCTAssertNil(ConfigChangeLog.firstBrokenLine(in: url))
    }

    /// A project's change and the app's own go to the same file; the line
    /// says which project, so nothing is written inside the project folder.
    func testEveryProjectsLinesShareTheOneFileAndNameTheirProject() throws {
        let inProject = ConfigChangeLog.Record(requestedBy: "Lead", kind: "team", tool: "hire_agent", before: "Lead",
                                               after: "Lead, Coder", decision: .approved,
                                               at: Date(timeIntervalSince1970: 1_756_684_800), project: "/work/site")
        let appWide = record(decision: .denied, at: 1)

        try ConfigChangeLog.append(inProject, to: url)
        try ConfigChangeLog.append(appWide, to: url)

        XCTAssertEqual(ConfigChangeLog.read(from: url).map(\.project), ["/work/site", nil])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: appDirectory.path), ["config-changes.jsonl"])
    }

    /// A line written before lines named a project still reads back.
    func testALineWithoutAProjectReadsBack() throws {
        let old = #"{"requestedBy":"Lead","kind":"team","tool":"hire_agent","before":"Lead","after":"Lead, Coder","#
            + #""decision":"approved","at":"2025-09-01T00:00:00Z"}"# + "\n"
        try Data(old.utf8).write(to: url)

        XCTAssertEqual(ConfigChangeLog.read(from: url), [record(decision: .approved, at: 0)])
    }

    // MARK: - The chain

    private func lines() throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    private func write(_ lines: [String]) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    private func appendThree() throws {
        for offset in 0..<3 { try ConfigChangeLog.append(record(decision: .approved, at: TimeInterval(offset)), to: url) }
    }

    func testEachLineAfterTheFirstCarriesTheHashOfTheLineBeforeIt() throws {
        try appendThree()

        let written = try lines()
        XCTAssertFalse(written[0].contains(#""prev""#))
        XCTAssertTrue(written[1].contains(#""prev""#))
        XCTAssertTrue(written[2].contains(#""prev""#))
        XCTAssertNil(ConfigChangeLog.firstBrokenLine(in: url))
    }

    func testAnEditedLineBreaksTheChainAtTheLineAfterIt() throws {
        try appendThree()
        var written = try lines()
        written[1] = written[1].replacingOccurrences(of: "approved", with: "denied")
        try write(written)

        XCTAssertEqual(ConfigChangeLog.firstBrokenLine(in: url), 3)
    }

    func testARemovedLineBreaksTheChain() throws {
        try appendThree()
        var written = try lines()
        written.remove(at: 1)
        try write(written)
        XCTAssertEqual(ConfigChangeLog.firstBrokenLine(in: url), 2)

        try write(Array(try lines().dropFirst()))
        XCTAssertEqual(ConfigChangeLog.firstBrokenLine(in: url), 1, "a first line that points at one before it")
    }

    /// What the chain does not show: a log cut short at its end.
    func testALogCutShortAtItsEndStillChains() throws {
        try appendThree()
        try write(Array(try lines().dropLast()))

        XCTAssertNil(ConfigChangeLog.firstBrokenLine(in: url))
    }

    /// Lines from before lines were chained are passed over; the chain is
    /// checked from the first line that carries a hash.
    func testUnchainedLinesFromAnOlderLogArePassedOver() throws {
        let old = #"{"requestedBy":"Lead","kind":"team","tool":"hire_agent","before":"","after":"","#
            + #""decision":"approved","at":"2025-09-01T00:00:00Z"}"#
        try write([old, old])
        try ConfigChangeLog.append(record(decision: .denied, at: 5), to: url)
        try ConfigChangeLog.append(record(decision: .denied, at: 6), to: url)

        XCTAssertNil(ConfigChangeLog.firstBrokenLine(in: url))
        XCTAssertEqual(ConfigChangeLog.read(from: url).count, 4)
    }

    func testAppendedRecordsRoundTripInOrder() throws {
        let first = record(decision: .approved, at: 0)
        let second = record(decision: .denied, at: 1)

        try ConfigChangeLog.append(first, to: url)
        try ConfigChangeLog.append(second, to: url)

        XCTAssertEqual(ConfigChangeLog.read(from: url), [first, second])
    }

    /// A kill mid-append leaves a last line cut short; it costs only itself.
    func testATruncatedLastLineIsSkipped() throws {
        let first = record(decision: .approved, at: 0)
        try ConfigChangeLog.append(first, to: url)
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data(#"{"requestedBy":"Lead","kind":"team","tool":"fire_"#.utf8))
        try handle.close()

        XCTAssertEqual(ConfigChangeLog.read(from: url), [first])
    }

    /// A change asked for over the control API is one more line of the same
    /// log: the credential as who asked, the call as the tool.
    func testAnAPIChangeRoundTripsAsAnAbandonedRecord() throws {
        let asked = ConfigChangeLog.Record(caller: "operator", route: "PUT /v1/settings", summary: "{}",
                                           decision: .abandoned, at: Date(timeIntervalSince1970: 1_756_684_800))

        try ConfigChangeLog.append(record(decision: .approved, at: 0), to: url)
        try ConfigChangeLog.append(asked, to: url)

        let read = ConfigChangeLog.read(from: url)
        XCTAssertEqual(read.last, asked)
        XCTAssertEqual(read.last?.requestedBy, "operator")
        XCTAssertEqual(read.last?.kind, "api")
        XCTAssertEqual(read.last?.tool, "PUT /v1/settings")
        XCTAssertEqual(read.last?.after, "{}")
    }

    func testTheAppsOwnLogLivesInTheDirectoryItIsGiven() {
        XCTAssertEqual(url, appDirectory.appending(path: "config-changes.jsonl"))
    }

    private func record(decision: ConfigChangeLog.Decision, at offset: TimeInterval) -> ConfigChangeLog.Record {
        ConfigChangeLog.Record(requestedBy: "Lead", kind: "team", tool: "hire_agent",
                               before: "Lead", after: "Lead, Coder", decision: decision,
                               at: Date(timeIntervalSince1970: 1_756_684_800 + offset))
    }
}
