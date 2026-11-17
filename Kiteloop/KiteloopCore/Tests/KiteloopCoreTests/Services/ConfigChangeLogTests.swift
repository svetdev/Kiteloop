import XCTest
@testable import KiteloopCore

/// The project-local log of configuration changes an agent asked for and a
/// person decided on: one JSON line per decision.
final class ConfigChangeLogTests: XCTestCase {

    private var project: URL!

    override func setUp() async throws {
        project = try makeTemporaryDirectory(prefix: "config-change-log")
    }

    func testTheLogLivesInTheProjectsKiteloopDirectory() {
        XCTAssertEqual(ConfigChangeLog.url(projectPath: project.path),
                       project.appending(path: ".kiteloop").appending(path: "config-changes.jsonl"))
    }

    func testReadingAMissingLogIsEmpty() {
        XCTAssertEqual(ConfigChangeLog.read(from: ConfigChangeLog.url(projectPath: project.path)), [])
    }

    func testAppendedRecordsRoundTripInOrder() throws {
        let url = ConfigChangeLog.url(projectPath: project.path)
        let first = record(decision: .approved, at: 0)
        let second = record(decision: .denied, at: 1)

        try ConfigChangeLog.append(first, to: url)
        try ConfigChangeLog.append(second, to: url)

        XCTAssertEqual(ConfigChangeLog.read(from: url), [first, second])
    }

    /// A kill mid-append leaves a last line cut short; it costs only itself.
    func testATruncatedLastLineIsSkipped() throws {
        let url = ConfigChangeLog.url(projectPath: project.path)
        let first = record(decision: .approved, at: 0)
        try ConfigChangeLog.append(first, to: url)
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data(#"{"requestedBy":"Lead","kind":"team","tool":"fire_"#.utf8))
        try handle.close()

        XCTAssertEqual(ConfigChangeLog.read(from: url), [first])
    }

    private func record(decision: ConfigChangeLog.Decision, at offset: TimeInterval) -> ConfigChangeLog.Record {
        ConfigChangeLog.Record(requestedBy: "Lead", kind: "team", tool: "hire_agent",
                               before: "Lead", after: "Lead, Coder", decision: decision,
                               at: Date(timeIntervalSince1970: 1_756_684_800 + offset))
    }
}
