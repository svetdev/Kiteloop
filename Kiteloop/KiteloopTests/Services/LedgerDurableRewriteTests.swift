import XCTest
import KiteloopCore
@testable import Kiteloop

/// The two JSONL ledgers that replace their whole file when they compact —
/// `RunRecordStore` at every launch and after every retention trim,
/// `GroomingLedger` after a trim — and what that replacement has to survive.
///
/// The write itself used to be `Data.write(options: .atomic)`, which renames a
/// temp file into place but never flushes it: on a panic or power loss the
/// rename reaches disk while the contents are still in the page cache, and what
/// the next launch reads is a zero-length file where months of run history were.
/// `AtomicFileWriter` is the writer that closes that gap, and it is now the one
/// both rewrites go through.
///
/// A power loss is not something a unit test can stage, so what is asserted here
/// is the observable half: a compaction still puts back exactly what it read —
/// including the lines it could not decode — and a compaction that cannot be
/// written leaves the file that was there before it, rather than an empty one in
/// its place.
@MainActor
final class LedgerDurableRewriteTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try makeTemporaryDirectory(prefix: "ledger-durable-rewrite")
    }

    override func tearDownWithError() throws {
        // A test that made the directory read-only restores it itself; this is
        // the belt-and-braces so a failure mid-test cannot leave it undeletable.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: tempDir.path(percentEncoded: false))
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - RunRecordStore

    /// Past the count bound, so a trim forces the whole file to be rewritten, and
    /// then read back through a fresh store: the same records, in the same order,
    /// with the line nobody could decode still there byte for byte at the end.
    func testARunRecordTrimRewritesAFileAFreshStoreReadsBackUnchanged() throws {
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let url = tempDir.appendingPathComponent("control-runs.jsonl")
        let store = RunRecordStore(url: url, clock: { now })
        for index in 0..<RunRecordStore.retentionLimit {
            store.upsert(finishedRecord(runId: "run-\(index)",
                                        startedAt: now.addingTimeInterval(-Double(1000 - index))))
        }
        // The shape a kill mid-append leaves behind, which a rewrite must carry.
        try appendRaw(truncatedRunLine, to: url)
        let loaded = RunRecordStore(url: url, clock: { now })
        XCTAssertEqual(loaded.undecodableLineCount, 1)

        // One more record than the bound allows: the trim is what calls rewrite().
        loaded.upsert(finishedRecord(runId: "over", startedAt: now.addingTimeInterval(-1)))

        let reloaded = RunRecordStore(url: url, clock: { now })
        XCTAssertEqual(reloaded.records, loaded.records,
                       "the compacted file holds exactly what the store did")
        XCTAssertEqual(reloaded.records.count, RunRecordStore.retentionLimit)
        XCTAssertNil(reloaded.record(runId: "run-0"), "the trim happened, so the file was rewritten")
        XCTAssertNotNil(reloaded.record(runId: "over"))
        XCTAssertEqual(reloaded.undecodableLineCount, 1)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.last.map(String.init), truncatedRunLine, "verbatim, after the records")
        XCTAssertEqual(try directoryEntries(), ["control-runs.jsonl"],
                       "no draft left beside it — ~/.kiteloop is a directory people read")
    }

    /// The half of durability a test can stage: a rewrite that cannot be written
    /// at all must leave the previous file alone. An empty file here is the whole
    /// run history gone.
    func testARunRecordRewriteThatCannotBeWrittenLeavesThePreviousFileInPlace() throws {
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let url = tempDir.appendingPathComponent("control-runs.jsonl")
        let store = RunRecordStore(url: url, clock: { now })
        for index in 0..<RunRecordStore.retentionLimit {
            store.upsert(finishedRecord(runId: "run-\(index)",
                                        startedAt: now.addingTimeInterval(-Double(1000 - index))))
        }
        let before = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(before.isEmpty)
        try setDirectoryWritable(false)
        defer { try? setDirectoryWritable(true) }

        // Over the bound, so the trim asks for a rewrite the directory refuses.
        store.upsert(finishedRecord(runId: "over", startedAt: now.addingTimeInterval(-1)))

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), before,
                       "the history that was on disk is still on disk")
        XCTAssertEqual(try directoryEntries(), ["control-runs.jsonl"], "and no half-written draft")
    }

    // MARK: - GroomingLedger

    /// The same round trip for the grooming ledger: over the limit, trimmed,
    /// rewritten, and read back by the next launch as the records it kept.
    func testAGroomingTrimRewritesAFileAFreshLedgerReadsBackUnchanged() throws {
        let url = tempDir.appendingPathComponent("grooming.jsonl")
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let ledger = GroomingLedger(url: url)
        ledger.recordRelease(itemID: "item-1", projectPath: "/tmp/kiteloop", projectName: "kiteloop",
                             reason: "released by hand (backlog)", at: at)
        for index in 0...GroomingLedger.retentionLimit {
            ledger.recordCheckFailure(itemID: "noise-\(index)", projectPath: "/tmp/kiteloop",
                                      projectName: "kiteloop",
                                      check: GroomingRecord.Check.definitionOfReady,
                                      reason: "no verify: command",
                                      at: at.addingTimeInterval(TimeInterval(index + 1)))
        }

        let reloaded = GroomingLedger(url: url)

        XCTAssertEqual(reloaded.records.map(\.id), ledger.records.map(\.id),
                       "the compacted file holds exactly what the ledger did")
        XCTAssertEqual(reloaded.records.map(\.at), ledger.records.map(\.at))
        XCTAssertEqual(reloaded.latestRelease(itemID: "item-1", projectPath: "/tmp/kiteloop"), at,
                       "including the release the trim went out of its way to keep")
        XCTAssertEqual(try directoryEntries(), ["grooming.jsonl"], "no draft left beside it")
    }

    func testAGroomingRewriteThatCannotBeWrittenLeavesThePreviousFileInPlace() throws {
        let url = tempDir.appendingPathComponent("grooming.jsonl")
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let ledger = GroomingLedger(url: url)
        for index in 0..<GroomingLedger.retentionLimit {
            ledger.recordCheckFailure(itemID: "noise-\(index)", projectPath: "/tmp/kiteloop",
                                      projectName: "kiteloop",
                                      check: GroomingRecord.Check.definitionOfReady,
                                      reason: "no verify: command",
                                      at: at.addingTimeInterval(TimeInterval(index)))
        }
        let before = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(before.isEmpty)
        try setDirectoryWritable(false)
        defer { try? setDirectoryWritable(true) }

        ledger.recordCheckFailure(itemID: "over", projectPath: "/tmp/kiteloop",
                                  projectName: "kiteloop",
                                  check: GroomingRecord.Check.definitionOfReady,
                                  reason: "no verify: command",
                                  at: at.addingTimeInterval(TimeInterval(GroomingLedger.retentionLimit)))

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), before,
                       "the ledger that was on disk is still on disk")
        XCTAssertEqual(try directoryEntries(), ["grooming.jsonl"], "and no half-written draft")
    }

    // MARK: - Helpers

    /// Half a JSON object, the way a process killed mid-append leaves the last
    /// line — `RunRecordStore` keeps it rather than compacting it away.
    private let truncatedRunLine = #"{"runId":"run-half","projectID":"/tmp/alpha","itemI"#

    private func finishedRecord(runId: String, startedAt: Date) -> PersistedRunRecord {
        var record = PersistedRunRecord(runId: runId, projectID: "/tmp/alpha", itemID: "item-1",
                                        title: "Ship the thing", startedAt: startedAt)
        record.outcome = .done
        record.durationSec = 42
        return record
    }

    private func appendRaw(_ line: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    /// A read-only directory is how a write is made to fail without touching the
    /// file itself: the temp sibling cannot be created at all.
    private func setDirectoryWritable(_ writable: Bool) throws {
        try FileManager.default.setAttributes([.posixPermissions: writable ? 0o755 : 0o500],
                                              ofItemAtPath: tempDir.path(percentEncoded: false))
    }

    private func directoryEntries() throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: tempDir.path(percentEncoded: false))
            .sorted()
    }
}
