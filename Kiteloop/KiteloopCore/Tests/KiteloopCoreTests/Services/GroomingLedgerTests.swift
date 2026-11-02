import XCTest
@testable import KiteloopCore

/// What `GroomingLedger` does with a line its decoder refuses.
///
/// The ledger reads like an append-only file and mostly is one, but `append`
/// calls `rewrite()` once the retention limit is passed, and `rewrite()` writes
/// the file from `records` alone. A line that failed to decode is in neither, so
/// before this it was skipped in silence at load and deleted by the next trim —
/// including, potentially, a `released` record, the one thing here that is read
/// back rather than merely reported: `RetryCeiling` discounts attempts from it,
/// so losing one re-retires an item a human deliberately released, with nothing
/// left in the file to say why.
@MainActor
final class GroomingLedgerTests: XCTestCase {

    private var tempDir: URL!
    private var url: URL!

    /// The shape a kill mid-append leaves behind: half a record, and the half
    /// that is missing is the half that would have made it decodable.
    private let truncatedLine = #"{"id":"half","at":"2027-01-15T00:00:00Z","projectPath":"/tmp/kit"#

    /// A kill partway through a project name with an em dash in it: the line
    /// stops after the first two of the dash's three bytes, so it is not UTF-8.
    private let cutOffEmDashLine = Data(#"{"id":"half","projectName":"kite"#.utf8) + Data([0xE2, 0x80])

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "grooming-ledger")
        url = tempDir.appendingPathComponent("grooming.jsonl")
    }

    // MARK: - Load

    /// The line nobody can read costs neither the records around it nor the
    /// caller's knowledge that it was there.
    func testAnUnreadableLineIsCountedAndCostsNoRecordAroundIt() throws {
        let seed = GroomingLedger(url: url)
        seed.recordFiled(itemID: "before", projectPath: "/tmp/kiteloop", projectName: "kiteloop",
                         ready: true, at: at(0))
        seed.recordFiled(itemID: "after", projectPath: "/tmp/kiteloop", projectName: "kiteloop",
                         ready: false, at: at(2))
        try spliceUnreadableLine(at: 1)

        let ledger = GroomingLedger(url: url)

        XCTAssertEqual(ledger.records.map(\.itemID), ["before", "after"],
                       "the records on either side of it are read as they always were")
        XCTAssertEqual(ledger.undecodableLineCount, 1,
                       "and the ledger says it is short a line rather than looking whole")
    }

    /// A kill partway through an em dash leaves bytes that are not UTF-8. Read as
    /// one string, the whole file failed and loaded empty — the release after the
    /// bad line gone with it, and the ledger reporting itself whole.
    func testALineOfInvalidUTF8CostsOnlyItsLine() throws {
        let seed = GroomingLedger(url: url)
        seed.recordFiled(itemID: "before", projectPath: "/tmp/kiteloop", projectName: "kiteloop",
                         ready: true, at: at(0))
        try appendRawBytes(cutOffEmDashLine)
        seed.recordRelease(itemID: "after", projectPath: "/tmp/kiteloop", projectName: "kiteloop",
                           reason: "released by hand (backlog)", at: at(2))

        let ledger = GroomingLedger(url: url)

        XCTAssertEqual(ledger.records.map(\.itemID), ["before", "after"],
                       "both records around the bad bytes load, in order")
        XCTAssertEqual(ledger.records.last?.event, .released,
                       "the release after the bad line is still visible")
        XCTAssertEqual(ledger.undecodableLineCount, 1,
                       "and the ledger says it is short a line rather than looking whole")
    }

    /// A missing file is a fresh install, not a damaged ledger.
    func testAMissingFileLoadsAsAnEmptyWholeLedger() {
        let ledger = GroomingLedger(url: url)

        XCTAssertTrue(ledger.records.isEmpty)
        XCTAssertEqual(ledger.undecodableLineCount, 0)
    }

    /// Every unreadable line is counted, and counted once — one number per load,
    /// which is what the single os_log error reports. The count is the observable
    /// half of that line: a test cannot read the unified log, but a count that
    /// aggregates rather than accumulating per record is the same reading.
    func testEveryUnreadableLineIsCountedOnceInOneNumber() throws {
        let seed = GroomingLedger(url: url)
        seed.recordFiled(itemID: "kept", projectPath: "/tmp/kiteloop", projectName: "kiteloop",
                         ready: true, at: at(0))
        try appendRaw("{not json}")
        try appendRaw("")           // blank — dropped by the split, not a line
        try appendRaw(truncatedLine)

        let ledger = GroomingLedger(url: url)

        XCTAssertEqual(ledger.records.map(\.itemID), ["kept"])
        XCTAssertEqual(ledger.undecodableLineCount, 2,
                       "two unreadable lines, and the blank one is not a line at all")
    }

    func testAWholeLedgerReportsNoUnreadableLines() {
        let seed = GroomingLedger(url: url)
        seed.recordFiled(itemID: "kept", projectPath: "/tmp/kiteloop", projectName: "kiteloop",
                         ready: true, at: at(0))

        XCTAssertEqual(GroomingLedger(url: url).undecodableLineCount, 0)
    }

    // MARK: - Trim

    /// The trim is the only thing that ever replaces the whole file, so it is the
    /// only thing that could erase a line the decoder refused — on the strength of
    /// a decoder that had already admitted it could not read it.
    func testATrimWritesTheUnreadableLineBackVerbatim() throws {
        try writeFile(checkFailureLines(count: GroomingLedger.retentionLimit) + [truncatedLine])
        let ledger = GroomingLedger(url: url)
        XCTAssertEqual(ledger.records.count, GroomingLedger.retentionLimit)

        appendOnePastTheLimit(to: ledger)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.split(separator: "\n").map(String.init).contains(truncatedLine),
                      "the line the trim could not read is still in the file, byte for byte")
        XCTAssertEqual(GroomingLedger(url: url).undecodableLineCount, 1,
                       "and the next launch still reports it")
    }

    /// A trim over a ledger holding bytes that are not UTF-8 keeps that line — as
    /// lossy text, the bad bytes become replacement characters — and every record
    /// the trim keeps. Loaded empty, the trim would have written out only its own
    /// record and deleted the rest.
    func testATrimKeepsALineOfInvalidUTF8AsLossyText() throws {
        var body = Data((try checkFailureLines(count: GroomingLedger.retentionLimit)
            .joined(separator: "\n") + "\n").utf8)
        body.append(cutOffEmDashLine + Data("\n".utf8))
        try body.write(to: url)
        let ledger = GroomingLedger(url: url)
        XCTAssertEqual(ledger.records.count, GroomingLedger.retentionLimit)

        appendOnePastTheLimit(to: ledger)

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.last, String(decoding: cutOffEmDashLine, as: UTF8.self),
                       "the bad line is still in the file, as lossy text")
        let reloaded = GroomingLedger(url: url)
        XCTAssertEqual(reloaded.records.count, GroomingLedger.retentionLimit,
                       "and the records the trim kept are still there")
        XCTAssertEqual(reloaded.records.last?.itemID, "over")
        XCTAssertEqual(reloaded.undecodableLineCount, 1)
    }

    /// The case the ledger exists to protect, with both halves of it in one file:
    /// a release the trim keeps deliberately, and a line the trim cannot read.
    /// Either one going takes with it the answer to "why did this retired item run
    /// again" — the first from `latestRelease`, the second from the file itself.
    func testAReleaseAndAnUnreadableLineBothSurviveATrim() throws {
        let released = at(0)
        let release = GroomingRecord(at: released, projectPath: "/tmp/kiteloop",
                                     projectName: "kiteloop", itemID: "item-1", event: .released,
                                     check: GroomingRecord.Check.retryCeiling,
                                     reason: "released by hand (backlog)")
        try writeFile([try encode(release)]
                      + checkFailureLines(count: GroomingLedger.retentionLimit - 1)
                      + [truncatedLine])

        appendOnePastTheLimit(to: GroomingLedger(url: url))

        let ledger = GroomingLedger(url: url)
        XCTAssertEqual(ledger.latestRelease(itemID: "item-1", projectPath: "/tmp/kiteloop"), released,
                       "the release the trim went out of its way to keep is still readable")
        XCTAssertEqual(ledger.undecodableLineCount, 1)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.last, truncatedLine, "verbatim, after the records")
        XCTAssertEqual(try FileManager.default
                        .contentsOfDirectory(atPath: tempDir.path(percentEncoded: false)).sorted(),
                       ["grooming.jsonl"], "no draft left beside it")
    }

    // MARK: - Record & query

    /// Filing at `ready: true` is the numerator this whole ledger exists to
    /// support: it must land as `.filedReady`, not merely as "filed".
    func testRecordFiledReadyProducesFiledReadyAndIsFiled() {
        let ledger = GroomingLedger(url: url)

        ledger.recordFiled(itemID: "item-1", projectPath: "/tmp/kiteloop", projectName: "kiteloop",
                           ready: true, at: at(0))

        let record = ledger.records[0]
        XCTAssertEqual(record.event, .filedReady)
        XCTAssertTrue(record.isFiled)
    }

    /// Filing at `ready: false` lands as `.filedDraft` — still a filing, so
    /// `isFiled` stays true, but not the runnable kind.
    func testRecordFiledDraftProducesFiledDraftAndIsFiled() {
        let ledger = GroomingLedger(url: url)

        ledger.recordFiled(itemID: "item-1", projectPath: "/tmp/kiteloop", projectName: "kiteloop",
                           ready: false, at: at(0))

        let record = ledger.records[0]
        XCTAssertEqual(record.event, .filedDraft)
        XCTAssertTrue(record.isFiled)
    }

    /// A check failure carries which check refused the item and why, in the
    /// words the verdict gave — the two fields a filing never sets.
    func testRecordCheckFailureCarriesCheckAndReason() {
        let ledger = GroomingLedger(url: url)

        ledger.recordCheckFailure(itemID: "item-1", projectPath: "/tmp/kiteloop", projectName: "kiteloop",
                                  check: GroomingRecord.Check.grounding,
                                  reason: "`Foo.swift` names nothing in the repo", at: at(0))

        let record = ledger.records[0]
        XCTAssertEqual(record.event, .checkFailed)
        XCTAssertEqual(record.check, GroomingRecord.Check.grounding)
        XCTAssertEqual(record.reason, "`Foo.swift` names nothing in the repo")
    }

    /// A second ledger over the same file reads back what the first one wrote —
    /// the encoder is ISO-8601, so the date has to survive the round trip too,
    /// not just the strings.
    func testASecondLedgerDecodesWhatTheFirstWrote() {
        let first = GroomingLedger(url: url)
        first.recordFiled(itemID: "item-1", projectPath: "/tmp/kiteloop", projectName: "kiteloop",
                          ready: true, at: at(0))
        first.recordCheckFailure(itemID: "item-2", projectPath: "/tmp/kiteloop", projectName: "kiteloop",
                                 check: GroomingRecord.Check.retryCeiling,
                                 reason: "attempted its fill of times", at: at(1))

        let second = GroomingLedger(url: url)

        XCTAssertEqual(second.records.map(\.event), first.records.map(\.event))
        XCTAssertEqual(second.records.map(\.check), first.records.map(\.check))
        XCTAssertEqual(second.records.map(\.reason), first.records.map(\.reason))
        XCTAssertEqual(second.records.map(\.at), first.records.map(\.at))
    }

    /// The window `PortfolioReport` reads through is inclusive at both ends: a
    /// record stamped exactly at `from` or exactly at `to` is in it, and one a
    /// second outside either side is not.
    func testRecordsFromToIsInclusiveAtBothBounds() throws {
        try writeFile([
            try encode(GroomingRecord(at: at(-1), projectPath: "/tmp/kiteloop", projectName: "kiteloop",
                                      itemID: "before", event: .filedReady)),
            try encode(GroomingRecord(at: at(0), projectPath: "/tmp/kiteloop", projectName: "kiteloop",
                                      itemID: "at-start", event: .filedReady)),
            try encode(GroomingRecord(at: at(5), projectPath: "/tmp/kiteloop", projectName: "kiteloop",
                                      itemID: "at-end", event: .filedReady)),
            try encode(GroomingRecord(at: at(6), projectPath: "/tmp/kiteloop", projectName: "kiteloop",
                                      itemID: "after", event: .filedReady)),
        ])
        let ledger = GroomingLedger(url: url)

        let window = ledger.records(from: at(0), to: at(5))

        XCTAssertEqual(window.map(\.itemID), ["at-start", "at-end"],
                       "both bounds are in the window, and neither neighbor a second outside is")
    }

    // MARK: - Writes that never reached the file

    /// The mirror of the undecodable-line count, on the write side. A ledger whose
    /// file cannot be written used to return from `append` exactly as it does on
    /// success — the verdict sat in `records` and nothing was on disk, so a
    /// `released` record lost that way would come back at the next launch as if it
    /// had never happened. It says so now, and the live view is still whole: the
    /// count is what changed, not the records.
    func testAWriteThatCannotReachTheFileIsCounted() throws {
        let ledger = GroomingLedger(url: try unwritableLedgerURL())

        ledger.recordFiled(itemID: "item-1", projectPath: "/tmp/kiteloop", projectName: "kiteloop",
                           ready: true, at: at(0))

        XCTAssertEqual(ledger.failedWriteCount, 1, "the write that never landed is reported, not swallowed")
        XCTAssertEqual(ledger.records.map(\.itemID), ["item-1"], "the live view is unaffected — only the file is missing it")
    }

    /// It is a count, not a flag: a directory that stays unwritable loses every
    /// record written into it, and a ledger that reported "1" after two of them
    /// would understate the hole by one.
    func testASecondFailedWriteIncrementsTheCount() throws {
        let ledger = GroomingLedger(url: try unwritableLedgerURL())

        ledger.recordFiled(itemID: "item-1", projectPath: "/tmp/kiteloop", projectName: "kiteloop",
                           ready: true, at: at(0))
        ledger.recordFiled(itemID: "item-2", projectPath: "/tmp/kiteloop", projectName: "kiteloop",
                           ready: true, at: at(1))

        XCTAssertEqual(ledger.failedWriteCount, 2)
    }

    /// A trim-triggered rewrite that cannot land is counted too, not read as a trim
    /// that happened only in memory.
    func testARewriteThatCannotReachTheFileIsCounted() throws {
        try writeFile(checkFailureLines(count: GroomingLedger.retentionLimit))
        let ledger = GroomingLedger(url: url)
        XCTAssertEqual(ledger.records.count, GroomingLedger.retentionLimit)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: tempDir.path(percentEncoded: false))
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                    ofItemAtPath: self.tempDir.path(percentEncoded: false))
        }

        ledger.recordCheckFailure(itemID: "over", projectPath: "/tmp/kiteloop", projectName: "kiteloop",
                                  check: GroomingRecord.Check.definitionOfReady, reason: "no verify: command",
                                  at: at(GroomingLedger.retentionLimit + 1))

        XCTAssertEqual(ledger.failedWriteCount, 1, "the rewrite that never landed is reported")
        XCTAssertEqual(ledger.records.count, GroomingLedger.retentionLimit,
                       "the trim still happened in memory — only the file missed it")
    }

    /// And nothing about the ordinary file counts as a failure — the line that
    /// creates it, an append onto it, and the whole-file rewrite a trim asks for. A
    /// count that ticked on a healthy ledger would make the number meaningless.
    func testAWritableLedgerReportsNoFailedWrites() throws {
        try writeFile(checkFailureLines(count: GroomingLedger.retentionLimit - 1))
        let ledger = GroomingLedger(url: url)
        ledger.recordFiled(itemID: "early", projectPath: "/tmp/kiteloop", projectName: "kiteloop",
                           ready: true, at: at(0))          // appends onto it

        appendOnePastTheLimit(to: ledger)                    // trim-triggered rewrite

        XCTAssertEqual(ledger.failedWriteCount, 0)
    }

    // MARK: - Helpers

    private func at(_ offset: Int) -> Date {
        Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(TimeInterval(offset))
    }

    /// The one record that takes the ledger past `retentionLimit`, which is what
    /// makes `append` trim and rewrite the whole file. A full ledger is written
    /// straight to disk rather than appended a record at a time: every append
    /// forces its line to the platter, and 2000 of those buy nothing this is
    /// asking about.
    private func appendOnePastTheLimit(to ledger: GroomingLedger) {
        ledger.recordCheckFailure(itemID: "over", projectPath: "/tmp/kiteloop",
                                  projectName: "kiteloop",
                                  check: GroomingRecord.Check.definitionOfReady,
                                  reason: "no verify: command",
                                  at: at(GroomingLedger.retentionLimit + 1))
        XCTAssertEqual(ledger.records.count, GroomingLedger.retentionLimit,
                       "the trim happened, so the file was rewritten")
    }

    private func checkFailureLines(count: Int) throws -> [String] {
        try (0..<count).map { index in
            try encode(GroomingRecord(at: at(index + 1), projectPath: "/tmp/kiteloop",
                                      projectName: "kiteloop", itemID: "noise-\(index)",
                                      event: .checkFailed,
                                      check: GroomingRecord.Check.definitionOfReady,
                                      reason: "no verify: command"))
        }
    }

    /// The ledger's own encoding, so a seeded line is one the ledger would have
    /// written itself.
    private func encode(_ record: GroomingRecord) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(record), as: UTF8.self)
    }

    private func writeFile(_ lines: [String]) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    private func appendRaw(_ line: String) throws {
        try appendRawBytes(Data(line.utf8))
    }

    private func appendRawBytes(_ line: Data) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: line + Data("\n".utf8))
    }

    /// Puts the unreadable line *between* records rather than after them, so a
    /// load that stopped at the bad line rather than stepping over it would show.
    private func spliceUnreadableLine(at position: Int) throws {
        var lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        lines.insert(truncatedLine, at: position)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    /// A ledger file inside a directory nobody may write to — a `~/.kiteloop` whose
    /// permissions have been tightened, and the cheapest stand-in for the full disk
    /// that produces the same throw. The mode is put back at teardown, since a
    /// directory that cannot be written cannot be emptied either.
    private func unwritableLedgerURL() throws -> URL {
        let locked = tempDir.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        }
        return locked.appendingPathComponent("grooming.jsonl")
    }
}
