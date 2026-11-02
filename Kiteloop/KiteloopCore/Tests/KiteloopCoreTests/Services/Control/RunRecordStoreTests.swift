import XCTest
@testable import KiteloopCore

/// What `appendLine` writes onto.
///
/// The file is append-only through a `FileHandle` with no atomicity, so a kill
/// mid-append leaves a last line with no newline on the end of it. Seeking to end
/// and writing the next record then glues the two together into a single line
/// that decodes as neither — and the one that loses its record is the *new* one:
/// the truncated half is already accounted for as undecodable, while the run
/// written after the crash simply isn't there when someone comes back to ask how
/// it ended. `load` only heals that on a launch that happens to ask for a
/// rewrite, which a file of already-closed, already-collapsed runs does not.
///
/// The interruption and retention behaviour around these lines is covered by
/// `KiteloopControlServerRunHistoryTests`; this is the append itself.
@MainActor
final class RunRecordStoreTests: XCTestCase {

    private var tempDir: URL!
    private var recordsURL: URL!
    private static let now = Date(timeIntervalSince1970: 1_770_000_000)
    /// The shape a kill mid-append leaves behind: half a JSON object.
    private let truncatedLine = "{\"runId\":\"run-cut\",\"projectID\":\"/tmp/al"

    override func setUp() async throws {
        try redirectSharedLoggerToTemporaryDirectory(prefix: "run-records-log")
        tempDir = try makeTemporaryDirectory(prefix: "run-records")
        recordsURL = tempDir.appendingPathComponent("control-runs.jsonl")
    }

    /// The bug, at the level it costs someone an answer: record a run after a
    /// truncated line and the record has to be readable back at the next launch.
    func testARecordAppendedAfterATruncatedLineIsStillReadableBack() throws {
        try seedClosedRecordThenTruncatedLine()

        let store = RunRecordStore(url: recordsURL, clock: { Self.now })
        // The load that does *not* rewrite — every run in the file is closed and
        // collapsed already, which is the state a launch rewrite leaves behind.
        // That is why the glued line used to survive to the next launch.
        store.upsert(closedRecord(runId: "run-after", startedAt: Self.now.addingTimeInterval(-60)))

        let reloaded = RunRecordStore(url: recordsURL, clock: { Self.now })
        XCTAssertEqual(reloaded.record(runId: "run-after")?.outcome, .done,
                       "the run recorded after the crash has a record of its own")
        XCTAssertEqual(reloaded.record(runId: "run-first")?.outcome, .done,
                       "and the runs recorded before it are untouched")
    }

    /// And the repair costs the truncated line nothing: it is still there, byte
    /// for byte, and still counted — a newline in front of the next record is not
    /// licence to tidy away what came before it.
    func testTheTruncatedLineSurvivesVerbatimAndIsStillCounted() throws {
        try seedClosedRecordThenTruncatedLine()

        let store = RunRecordStore(url: recordsURL, clock: { Self.now })
        XCTAssertEqual(store.undecodableLineCount, 1)
        store.upsert(closedRecord(runId: "run-after", startedAt: Self.now.addingTimeInterval(-60)))

        let lines = try String(contentsOf: recordsURL, encoding: .utf8).split(separator: "\n")
        XCTAssertTrue(lines.contains { $0 == truncatedLine }, "byte for byte, on a line of its own")
        XCTAssertEqual(RunRecordStore(url: recordsURL, clock: { Self.now }).undecodableLineCount, 1,
                       "still one unreadable line — not zero, and not two")
    }

    /// The ordinary append is unchanged: a file already ending in a newline gains
    /// one line, not a blank one before it.
    func testAppendingToAFileEndingInANewlineAddsNoBlankLine() throws {
        let store = RunRecordStore(url: recordsURL, clock: { Self.now })
        store.upsert(closedRecord(runId: "run-1", startedAt: Self.now.addingTimeInterval(-3600)))
        let before = try String(contentsOf: recordsURL, encoding: .utf8)

        store.upsert(closedRecord(runId: "run-2", startedAt: Self.now.addingTimeInterval(-60)))

        let after = try String(contentsOf: recordsURL, encoding: .utf8)
        XCTAssertEqual(after.filter { $0 == "\n" }.count, before.filter { $0 == "\n" }.count + 1)
        XCTAssertFalse(after.contains("\n\n"), "no blank line between the records")
    }

    /// And the first line written to a file that isn't there yet keeps its shape:
    /// one record, newline-terminated, nothing in front of it.
    func testTheFirstRecordWrittenToAMissingFileIsUnchangedInShape() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordsURL.path))

        RunRecordStore(url: recordsURL, clock: { Self.now })
            .upsert(closedRecord(runId: "run-1", startedAt: Self.now.addingTimeInterval(-3600)))

        let contents = try String(contentsOf: recordsURL, encoding: .utf8)
        XCTAssertTrue(contents.hasPrefix("{"), "the record starts the file")
        XCTAssertTrue(contents.hasSuffix("}\n"), "and ends terminated")
        XCTAssertEqual(contents.filter { $0 == "\n" }.count, 1)
        XCTAssertEqual(RunRecordStore(url: recordsURL, clock: { Self.now }).records.map(\.runId), ["run-1"])
    }

    // MARK: - Fixtures

    /// A file in the state a crash leaves: one closed run that reads fine, then a
    /// half-written line with no newline on the end of it. Written by hand — no
    /// sequence of `upsert` calls can produce a truncated line.
    private func seedClosedRecordThenTruncatedLine() throws {
        let stamp = ISO8601DateFormatter().string(from: Self.now.addingTimeInterval(-3600))
        let first = "{\"runId\":\"run-first\",\"projectID\":\"/tmp/alpha\",\"itemID\":\"item-1\"," +
                    "\"title\":\"Ship the thing\",\"startedAt\":\"\(stamp)\",\"outcome\":\"done\"}"
        try (first + "\n" + truncatedLine).write(to: recordsURL, atomically: true, encoding: .utf8)
    }

    private func closedRecord(runId: String, startedAt: Date) -> PersistedRunRecord {
        var record = PersistedRunRecord(runId: runId, projectID: "/tmp/alpha", itemID: "item-1",
                                        title: "Ship the thing", startedAt: startedAt)
        record.endedAt = startedAt.addingTimeInterval(42)
        record.outcome = .done
        record.durationSec = 42
        return record
    }
}

// MARK: - The write-twice contract, and what each launch does to the file

extension RunRecordStoreTests {

    /// The store's write-twice contract: a run puts an opening line down when
    /// it starts and a closing line when it ends — appended, so the file says
    /// what happened in the order it happened — and the closing record is the
    /// one the store answers with.
    func testClosingARunReplacesItsOpenRecordAndAppendsAClosingLine() throws {
        let store = RunRecordStore(url: recordsURL, clock: { Self.now })
        let started = Self.now.addingTimeInterval(-120)
        store.upsert(PersistedRunRecord(runId: "run-1", projectID: "/tmp/alpha",
                                        itemID: "item-1", title: "Ship the thing",
                                        startedAt: started))
        store.upsert(closedRecord(runId: "run-1", startedAt: started))

        XCTAssertEqual(store.record(runId: "run-1")?.outcome, .done,
                       "the closing record is the one the store answers with")
        let lines = try String(contentsOf: recordsURL, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2, "opened and closed: two appended lines, not a rewrite")
    }

    /// A record identical to the one already held writes nothing — the control
    /// server re-derives a closing record on every poll, and each request must
    /// not become a line in the file.
    func testAnUnchangedRecordWritesNothing() throws {
        let store = RunRecordStore(url: recordsURL, clock: { Self.now })
        let record = closedRecord(runId: "run-1", startedAt: Self.now.addingTimeInterval(-3600))
        store.upsert(record)
        let before = try String(contentsOf: recordsURL, encoding: .utf8)

        store.upsert(record)

        XCTAssertEqual(try String(contentsOf: recordsURL, encoding: .utf8), before,
                       "an identical upsert must not grow the file")
    }

    /// The next launch collapses an opened-and-closed run's two lines back to
    /// one — that is what keeps the launch after it cheap.
    func testALaunchCompactsAnOpenedAndClosedRunToOneLine() throws {
        let started = Self.now.addingTimeInterval(-120)
        let first = RunRecordStore(url: recordsURL, clock: { Self.now })
        first.upsert(PersistedRunRecord(runId: "run-1", projectID: "/tmp/alpha",
                                        itemID: "item-1", title: "Ship the thing",
                                        startedAt: started))
        first.upsert(closedRecord(runId: "run-1", startedAt: started))

        _ = RunRecordStore(url: recordsURL, clock: { Self.now })

        let lines = try String(contentsOf: recordsURL, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1, "one record per run after the launch rewrite")
    }

    /// A launch that finds nothing to change writes nothing: the file's bytes
    /// — spacing a hand edit left, the absence of a trailing newline — stay
    /// exactly as they were.
    func testALaunchOverAnAlreadyCollapsedFileLeavesItByteIdentical() throws {
        let stamp = ISO8601DateFormatter().string(from: Self.now.addingTimeInterval(-3600))
        let seeded = "{\"runId\": \"run-1\", \"projectID\": \"/tmp/alpha\", \"itemID\": \"item-1\", " +
                     "\"title\": \"Ship the thing\", \"startedAt\": \"\(stamp)\", \"outcome\": \"done\"}"
        try seeded.write(to: recordsURL, atomically: true, encoding: .utf8)

        _ = RunRecordStore(url: recordsURL, clock: { Self.now })

        XCTAssertEqual(try String(contentsOf: recordsURL, encoding: .utf8), seeded,
                       "a launch with nothing to compact must not touch the file")
    }

    /// A run still open in the file at launch is closed as `interrupted`, and
    /// the file is rewritten to say so — the statement must survive to disk,
    /// not only into this process's memory.
    func testAnInterruptedRunIsCompactedIntoTheFileAtLaunch() throws {
        let stamp = ISO8601DateFormatter().string(from: Self.now.addingTimeInterval(-3600))
        let open = "{\"runId\":\"run-1\",\"projectID\":\"/tmp/alpha\",\"itemID\":\"item-1\"," +
                   "\"title\":\"Ship the thing\",\"startedAt\":\"\(stamp)\"}\n"
        try open.write(to: recordsURL, atomically: true, encoding: .utf8)

        let store = RunRecordStore(url: recordsURL, clock: { Self.now })

        XCTAssertEqual(store.record(runId: "run-1")?.outcome, .interrupted)
        XCTAssertTrue(try String(contentsOf: recordsURL, encoding: .utf8).contains("interrupted"),
                      "the interruption is written down, not just held in memory")
    }

    /// A launch that reads no file writes no file: a fresh install must not
    /// leave an empty ledger behind just for having looked.
    func testALaunchWithNoFileCreatesNone() {
        _ = RunRecordStore(url: recordsURL, clock: { Self.now })
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordsURL.path),
                       "no records, no file")
    }

    // MARK: - Retention on the write path

    /// The age bound is applied on every write, and what it drops leaves the
    /// file too — an always-running app must not keep storing records months
    /// past `retentionAge`.
    func testAWriteDropsAgedOutRecordsFromTheFileAsWell() throws {
        var now = Self.now
        let store = RunRecordStore(url: recordsURL, clock: { now })
        store.upsert(closedRecord(runId: "run-old",
                                  startedAt: now.addingTimeInterval(-RunRecordStore.retentionAge + 60)))

        now = Self.now.addingTimeInterval(120)   // the old run is now past the bound
        store.upsert(closedRecord(runId: "run-new", startedAt: now.addingTimeInterval(-60)))

        XCTAssertNil(store.record(runId: "run-old"))
        let contents = try String(contentsOf: recordsURL, encoding: .utf8)
        XCTAssertFalse(contents.contains("run-old"), "the trim reaches the file, not just memory")
        XCTAssertTrue(contents.contains("run-new"))
    }

    /// A record exactly at the age bound is still inside it: retention drops
    /// what is *older* than thirty days, not what has just turned thirty.
    func testARecordExactlyAtTheAgeBoundIsKept() {
        let store = RunRecordStore(url: recordsURL, clock: { Self.now })
        store.upsert(closedRecord(runId: "run-edge",
                                  startedAt: Self.now.addingTimeInterval(-RunRecordStore.retentionAge)))
        XCTAssertNotNil(store.record(runId: "run-edge"))
    }
}

// MARK: - Non-finite Doubles

extension RunRecordStoreTests {

    /// `JSONEncoder`'s default strategy throws on a non-finite Double, which used
    /// to erase the whole record silently: `appendLine` never reached
    /// `AtomicFileWriter`, and no counter said so. The field should cost itself,
    /// not the run — and the write must not be counted as failed, since it did
    /// reach the file.
    func testANonFiniteQualityScoreIsDroppedNotTheWholeRecord() throws {
        let store = RunRecordStore(url: recordsURL, clock: { Self.now })
        var record = closedRecord(runId: "run-nan-score", startedAt: Self.now.addingTimeInterval(-60))
        record.qualityScore = .nan
        store.upsert(record)

        XCTAssertEqual(store.failedWriteCount, 0)
        let reloaded = RunRecordStore(url: recordsURL, clock: { Self.now })
        let reloadedRecord = reloaded.record(runId: "run-nan-score")
        XCTAssertEqual(reloadedRecord?.outcome, .done, "every other field survives")
        XCTAssertNil(reloadedRecord?.qualityScore, "the non-finite field alone is dropped")
        XCTAssertEqual(reloaded.undecodableLineCount, 0)
        XCTAssertEqual(reloaded.failedWriteCount, 0)
    }

    /// The same sanitisation applies to `costUSD`, `costCapUSD`, and to a value
    /// inside `judgeDimensions` — every non-finite Double field this store
    /// carries, not just the one the bug report happened to name first.
    func testNonFiniteCostFieldsAndJudgeDimensionsAreDroppedNotTheWholeRecord() throws {
        let store = RunRecordStore(url: recordsURL, clock: { Self.now })
        var record = closedRecord(runId: "run-nan-cost", startedAt: Self.now.addingTimeInterval(-60))
        record.costUSD = .infinity
        record.costCapUSD = -.infinity
        record.judgeDimensions = ["clarity": 0.9, "correctness": .nan]
        store.upsert(record)

        XCTAssertEqual(store.failedWriteCount, 0)
        let reloaded = RunRecordStore(url: recordsURL, clock: { Self.now })
        let reloadedRecord = reloaded.record(runId: "run-nan-cost")
        XCTAssertEqual(reloadedRecord?.outcome, .done)
        XCTAssertNil(reloadedRecord?.costUSD)
        XCTAssertNil(reloadedRecord?.costCapUSD)
        XCTAssertNil(reloadedRecord?.judgeDimensions)
        XCTAssertEqual(reloaded.undecodableLineCount, 0)
        XCTAssertEqual(reloaded.failedWriteCount, 0)
    }

    /// Retention forces a `rewrite()` rather than an `appendLine` — the sanitised
    /// record must survive that path too, not fall out with `compactMap`'s old
    /// silent drop of anything `encode` refused.
    func testARewriteKeepsASanitisedRecordRatherThanDroppingIt() throws {
        var now = Self.now
        let store = RunRecordStore(url: recordsURL, clock: { now })
        store.upsert(closedRecord(runId: "run-very-old",
                                  startedAt: now.addingTimeInterval(-RunRecordStore.retentionAge + 50)))
        var sanitisedRecord = closedRecord(runId: "run-nan-score", startedAt: now)
        sanitisedRecord.qualityScore = .nan
        store.upsert(sanitisedRecord)

        now = Self.now.addingTimeInterval(200)   // ages "run-very-old" out, not "run-nan-score"
        store.upsert(closedRecord(runId: "run-new", startedAt: now))

        XCTAssertNil(store.record(runId: "run-very-old"), "the trim did fire, forcing a rewrite")
        XCTAssertEqual(store.failedWriteCount, 0)
        let reloaded = RunRecordStore(url: recordsURL, clock: { now })
        let survivor = reloaded.record(runId: "run-nan-score")
        XCTAssertEqual(survivor?.outcome, .done, "the sanitised record survives the rewrite")
        XCTAssertNil(survivor?.qualityScore)
        XCTAssertEqual(reloaded.failedWriteCount, 0)
    }
}

// MARK: - A write that never landed reaches the inbox

/// `failedWriteCount` counts the losses and os_log names them, and neither is a
/// place anyone looks: a `~/.kiteloop` that had stopped being writable left every
/// run in `records` for as long as the process lived, nothing on disk, and the
/// discovery deferred to the next launch answering 404 for work that had merged.
/// These pin the row a person actually sees.
extension RunRecordStoreTests {

    /// The failure the store exists to end, told where it is read: one row naming
    /// the store and the write — and still counted, since the count is what a
    /// caller reads and keeps its present meaning.
    func testAWriteThatCannotReachTheFileFilesARow() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let locked = try lockedRecordsURL()
        let store = RunRecordStore(url: locked, clock: { Self.now }, reporter: reporter)

        store.upsert(closedRecord(runId: "run-1", startedAt: Self.now.addingTimeInterval(-60)))
        await reporter.drain()

        XCTAssertEqual(store.failedWriteCount, 1, "the loss is still counted")
        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.title, "Could not write \(RunRecordStore.storeName)")
        XCTAssertEqual(pending.first?.type, .error)
        XCTAssertTrue(pending.first?.body.contains(locked.path(percentEncoded: false)) == true,
                      "and names the file that the run did not reach")
    }

    /// A store failing every write is one problem, not one per run: the reporter
    /// refreshes its row rather than filing a queue of identical ones — which is
    /// only true while this store spells its name the same way each time.
    func testASecondFailedWriteHoldsOneRowNotTwo() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let store = RunRecordStore(url: try lockedRecordsURL(), clock: { Self.now }, reporter: reporter)

        store.upsert(closedRecord(runId: "run-1", startedAt: Self.now.addingTimeInterval(-120)))
        store.upsert(closedRecord(runId: "run-2", startedAt: Self.now.addingTimeInterval(-60)))
        await reporter.drain()

        XCTAssertEqual(store.failedWriteCount, 2, "both losses are counted")
        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 1, "one row for the one problem, refreshed")
    }

    /// The rewrite path is reported too, and it is the more expensive loss: a
    /// whole-file write that does not land leaves the file disagreeing with
    /// `records` rather than one run missing from it.
    func testARewriteThatCannotLandFilesARow() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let directory = try lockableDirectory()
        let store = RunRecordStore(url: directory.appendingPathComponent("control-runs.jsonl"),
                                   clock: { Self.now }, reporter: reporter)
        fill(store, upTo: RunRecordStore.retentionLimit)
        try lock(directory)

        // One past the limit: the trim drops a record, so the append is a whole-file
        // rewrite — and that is what cannot land.
        store.upsert(closedRecord(runId: "run-over", startedAt: Self.now))
        await reporter.drain()

        XCTAssertEqual(store.failedWriteCount, 1)
        XCTAssertEqual(store.records.count, RunRecordStore.retentionLimit,
                       "the trim still happened in memory — only the file missed it")
        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.title, "Could not write \(RunRecordStore.storeName)")
    }

    /// And nothing about the ordinary file files anything — the line that creates
    /// it, an append onto it, and the whole-file rewrite a trim asks for. A row on
    /// a healthy store would teach the human to ignore the row.
    func testAWritableStoreFilesNothing() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let store = RunRecordStore(url: recordsURL, clock: { Self.now }, reporter: reporter)

        fill(store, upTo: RunRecordStore.retentionLimit)     // creates it, then appends onto it
        store.upsert(closedRecord(runId: "run-over", startedAt: Self.now))   // trim-triggered rewrite
        await reporter.drain()

        XCTAssertEqual(store.failedWriteCount, 0)
        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 0)
    }

    /// The round trip the reporting must not have disturbed: what one store wrote
    /// is what the next one reads back, one record per run.
    func testARecordUpsertedByOneStoreIsReadBackByAnother() async throws {
        let reporter = StoreProblemReporter(notifications: makeInbox())
        let store = RunRecordStore(url: recordsURL, clock: { Self.now }, reporter: reporter)
        let started = Self.now.addingTimeInterval(-120)
        store.upsert(PersistedRunRecord(runId: "run-1", projectID: "/tmp/alpha",
                                        itemID: "item-1", title: "Ship the thing",
                                        startedAt: started))
        store.upsert(closedRecord(runId: "run-1", startedAt: started))

        let reloaded = RunRecordStore(url: recordsURL, clock: { Self.now }, reporter: reporter)

        XCTAssertEqual(reloaded.records.map(\.runId), ["run-1"], "one record per run")
        XCTAssertEqual(reloaded.record(runId: "run-1")?.outcome, .done)
        XCTAssertEqual(reloaded.failedWriteCount, 0)
    }

    // MARK: - The verify verdict on the record

    /// The verdict that decided the run makes the trip to disk and back. It used
    /// to live only in the running app's metric store, so the record a driver
    /// reads the next morning said nothing about the one gate the run was
    /// accepted or blocked on.
    func testTheVerifyVerdictSurvivesAWriteAndAReload() throws {
        let store = RunRecordStore(url: recordsURL, clock: { Self.now })
        var record = closedRecord(runId: "run-1", startedAt: Self.now.addingTimeInterval(-120))
        record.verifyExitStatus = 65
        record.verifyCommand = "make ci"
        record.verifyOutputTail = "1 test failed"
        record.verifyTimedOut = false
        record.verifyDirectory = "/tmp/worktrees/item-1"
        store.upsert(record)

        let reloaded = RunRecordStore(url: recordsURL, clock: { Self.now }).record(runId: "run-1")

        XCTAssertEqual(reloaded?.verifyExitStatus, 65)
        XCTAssertEqual(reloaded?.verifyCommand, "make ci")
        XCTAssertEqual(reloaded?.verifyOutputTail, "1 test failed")
        XCTAssertEqual(reloaded?.verifyTimedOut, false)
        XCTAssertEqual(reloaded?.verifyDirectory, "/tmp/worktrees/item-1")
    }

    /// And the case the two newer fields exist for: a verify the deadline killed
    /// returns no exit status at all, so `-1` alone cannot say whether the clock
    /// took it or the shell could not be spawned. The record has to carry the
    /// answer across a reload, not just the status that can't tell them apart.
    func testAKilledVerifySurvivesAsTimedOutRatherThanJustANegativeStatus() throws {
        let store = RunRecordStore(url: recordsURL, clock: { Self.now })
        var record = closedRecord(runId: "run-1", startedAt: Self.now.addingTimeInterval(-120))
        record.verifyExitStatus = -1
        record.verifyCommand = "make ci"
        record.verifyOutputTail = "building…"
        record.verifyTimedOut = true
        record.verifyDirectory = "/tmp/worktrees/item-1"
        store.upsert(record)

        let reloaded = RunRecordStore(url: recordsURL, clock: { Self.now }).record(runId: "run-1")

        XCTAssertEqual(reloaded?.verifyExitStatus, -1)
        XCTAssertEqual(reloaded?.verifyTimedOut, true, "the deadline is what ended it")
        XCTAssertEqual(reloaded?.verifyDirectory, "/tmp/worktrees/item-1")
    }

    /// A run nobody took a verdict on keeps none: nil rather than a zero, which
    /// on the wire would read as a verify that passed.
    func testARecordWithNoVerdictKeepsNone() throws {
        let store = RunRecordStore(url: recordsURL, clock: { Self.now })
        store.upsert(closedRecord(runId: "run-1", startedAt: Self.now.addingTimeInterval(-120)))

        let reloaded = RunRecordStore(url: recordsURL, clock: { Self.now }).record(runId: "run-1")

        XCTAssertNil(reloaded?.verifyExitStatus)
        XCTAssertNil(reloaded?.verifyCommand)
        XCTAssertNil(reloaded?.verifyOutputTail)
        XCTAssertNil(reloaded?.verifyTimedOut)
        XCTAssertNil(reloaded?.verifyDirectory)
    }

    /// The compatibility half: a line written before these keys existed is every
    /// line already in someone's `control-runs.jsonl`. It has to decode — with
    /// all three nil — and a rewrite must not put keys into it that the run never
    /// measured.
    func testALineWrittenBeforeTheVerifyFieldsDecodesWithoutThem() throws {
        let stamp = ISO8601DateFormatter().string(from: Self.now.addingTimeInterval(-3600))
        let head = "{\"runId\":\"run-old\",\"projectID\":\"/tmp/alpha\",\"itemID\":\"item-1\"," +
                   "\"title\":\"Ship the thing\",\"startedAt\":\"\(stamp)\""
        // The two lines a run of that vintage left: the opening one and the
        // closing one. Collapsing them is what makes the launch rewrite the file,
        // which is where an invented key would appear.
        try (head + "}\n" + head + ",\"outcome\":\"done\"}\n")
            .write(to: recordsURL, atomically: true, encoding: .utf8)

        let store = RunRecordStore(url: recordsURL, clock: { Self.now })
        let record = try XCTUnwrap(store.record(runId: "run-old"))

        XCTAssertEqual(store.undecodableLineCount, 0, "an older line is still a readable line")
        XCTAssertEqual(record.outcome, .done, "and the ending it did record is unchanged")
        XCTAssertNil(record.verifyExitStatus)
        XCTAssertNil(record.verifyCommand)
        XCTAssertNil(record.verifyOutputTail)
        XCTAssertNil(record.verifyTimedOut)
        XCTAssertNil(record.verifyDirectory)

        let written = try String(contentsOf: recordsURL, encoding: .utf8)
        XCTAssertEqual(written.filter { $0 == "\n" }.count, 1, "the launch rewrote the file")
        XCTAssertFalse(written.contains("verify"), "nothing measured, nothing written")
    }

    /// The narrower compatibility case the two newer keys add: a line that *did*
    /// keep a verdict, written when the record held only three of its five facts.
    /// It has to decode with the three intact and the two nil — a run of that
    /// vintage measured them, nobody wrote them down — and the rewrite must not
    /// invent a `false` for `verifyTimedOut`, which would claim the command
    /// answered when nothing on the line says it did.
    func testALineWrittenBeforeTheTimedOutAndDirectoryFieldsDecodesWithoutThem() throws {
        let stamp = ISO8601DateFormatter().string(from: Self.now.addingTimeInterval(-3600))
        let line = "{\"runId\":\"run-old\",\"projectID\":\"/tmp/alpha\",\"itemID\":\"item-1\"," +
                   "\"title\":\"Ship the thing\",\"startedAt\":\"\(stamp)\",\"outcome\":\"done\"," +
                   "\"verifyExitStatus\":65,\"verifyCommand\":\"make ci\"," +
                   "\"verifyOutputTail\":\"1 test failed\"}\n"
        try (line + line).write(to: recordsURL, atomically: true, encoding: .utf8)

        let store = RunRecordStore(url: recordsURL, clock: { Self.now })
        let record = try XCTUnwrap(store.record(runId: "run-old"))

        XCTAssertEqual(store.undecodableLineCount, 0, "an older line is still a readable line")
        XCTAssertEqual(record.verifyExitStatus, 65, "the verdict it did keep is unchanged")
        XCTAssertEqual(record.verifyCommand, "make ci")
        XCTAssertEqual(record.verifyOutputTail, "1 test failed")
        XCTAssertNil(record.verifyTimedOut)
        XCTAssertNil(record.verifyDirectory)

        let written = try String(contentsOf: recordsURL, encoding: .utf8)
        XCTAssertEqual(written.filter { $0 == "\n" }.count, 1, "the launch rewrote the file")
        XCTAssertFalse(written.contains("verifyTimedOut"), "nothing recorded, nothing written")
        XCTAssertFalse(written.contains("verifyDirectory"))
    }

    // MARK: - Fixtures

    private func makeInbox() -> NotificationStore {
        NotificationStore(notificationsURL: tempDir.appendingPathComponent("inbox.log"))
    }

    /// A directory of its own, writable, whose mode is put back at teardown —
    /// since a directory that cannot be written cannot be emptied either.
    private func lockableDirectory() throws -> URL {
        let directory = tempDir.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? Self.setMode(0o700, on: directory) }
        return directory
    }

    /// A records file inside a directory nobody may write to — a `~/.kiteloop`
    /// whose permissions have been tightened, and the cheapest stand-in for the
    /// full disk that produces the same throw.
    private func lockedRecordsURL() throws -> URL {
        let directory = try lockableDirectory()
        try lock(directory)
        return directory.appendingPathComponent("control-runs.jsonl")
    }

    private func lock(_ directory: URL) throws { try Self.setMode(0o500, on: directory) }

    /// A history file that is there and cannot be opened — the read half's
    /// counterpart to `lockedRecordsURL`, and the cheapest stand-in for the
    /// unreadable disk that produces the same throw. Its mode is put back at
    /// teardown so the temporary directory can be emptied.
    private func unreadableRecordsURL() throws -> URL {
        try seedClosedRecordThenTruncatedLine()
        let url = recordsURL!
        try Self.setMode(0o000, on: url)
        addTeardownBlock { try? Self.setMode(0o600, on: url) }
        return url
    }

    private static func setMode(_ mode: Int, on item: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode],
                                              ofItemAtPath: item.path(percentEncoded: false))
    }

    /// `count` closed records, each one second apart and all well inside the age
    /// bound, so the store sits exactly on `retentionLimit` with the next write
    /// forcing a trim.
    private func fill(_ store: RunRecordStore, upTo count: Int) {
        for index in 0..<count {
            store.upsert(closedRecord(runId: "run-\(index)",
                                      startedAt: Self.now.addingTimeInterval(-Double(count - index))))
        }
    }
}

// MARK: - The read half: a bad line, and a file that cannot be read at all

/// The file is decoded a line at a time, over its bytes. It used to be read as
/// one string, so a single truncated multi-byte character — a kill part-way
/// through appending a title or a reason carrying an em dash, which the store's
/// own comments describe — made the read fail outright and the store came up
/// empty: every finished run 404ing, an unattended night reading as an install
/// that has never run anything, and the only trace an os_log line.
extension RunRecordStoreTests {

    /// The bug: one line of bad bytes costs its own line, and the complete
    /// records in front of it are still there.
    func testALineCutThroughAMultiByteCharacterCostsOnlyItself() throws {
        try seedClosedRecordThenLineCutThroughAnEmDash()

        let store = RunRecordStore(url: recordsURL, clock: { Self.now })

        XCTAssertEqual(store.records.map(\.runId), ["run-first"],
                       "the complete record before the bad bytes still reads back")
        XCTAssertEqual(store.record(runId: "run-first")?.outcome, .done)
        XCTAssertEqual(store.undecodableLineCount, 1, "and the bad line is counted, not the file")
    }

    /// And the bad line is still in the file the launch read — held as the text it
    /// can be held as, with replacement characters where the bytes were, rather
    /// than compacted away by the rewrite that read past it.
    func testTheLineOfBadBytesIsStillInTheFileAfterTheLaunchThatReadIt() throws {
        try seedClosedRecordThenLineCutThroughAnEmDash()

        _ = RunRecordStore(url: recordsURL, clock: { Self.now })

        let reloaded = RunRecordStore(url: recordsURL, clock: { Self.now })
        XCTAssertEqual(reloaded.undecodableLineCount, 1, "still one — not zero, and not two")
        XCTAssertEqual(reloaded.records.map(\.runId), ["run-first"])
        let written = try Data(contentsOf: recordsURL)
        XCTAssertTrue(String(decoding: written, as: UTF8.self).contains("run-cut"),
                      "the line nobody could read is still there")
    }

    /// A history that is there and cannot be opened is the one genuine read
    /// failure, and it goes where the write half's losses already go: one row in
    /// the inbox, naming the store, the read and the file.
    func testAHistoryThatCannotBeReadFilesARow() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let unreadable = try unreadableRecordsURL()

        let store = RunRecordStore(url: unreadable, clock: { Self.now }, reporter: reporter)
        await reporter.drain()

        XCTAssertTrue(store.records.isEmpty, "it answers as empty rather than trapping")
        XCTAssertNil(store.record(runId: "run-first"))
        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.title, "Could not read \(RunRecordStore.storeName)")
        XCTAssertEqual(pending.first?.type, .error)
        XCTAssertTrue(pending.first?.body.contains(unreadable.path(percentEncoded: false)) == true,
                      "and names the file whose history nobody could read")
    }

    /// A launch that finds no file at all says nothing: a fresh install has no
    /// history, and reporting that as a failure would teach the human to ignore
    /// the row.
    func testALaunchWithNoHistoryFileFilesNothing() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)

        _ = RunRecordStore(url: recordsURL, clock: { Self.now }, reporter: reporter)
        await reporter.drain()

        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 0, "missing is not unreadable")
    }

    /// Two launches over the same unreadable file are one problem, not two: the
    /// reporter's key is the store and the operation, so the second refreshes the
    /// row the first filed.
    func testASecondFailedReadHoldsOneRowNotTwo() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let unreadable = try unreadableRecordsURL()

        _ = RunRecordStore(url: unreadable, clock: { Self.now }, reporter: reporter)
        _ = RunRecordStore(url: unreadable, clock: { Self.now }, reporter: reporter)
        await reporter.drain()

        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 1, "one row for the one problem, refreshed")
    }

    /// And a file that reads fine files nothing — including the line nobody could
    /// decode inside it, which cost its own line and was never a read failure.
    func testAReadableHistoryFilesNothing() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        try seedClosedRecordThenLineCutThroughAnEmDash()

        let store = RunRecordStore(url: recordsURL, clock: { Self.now }, reporter: reporter)
        await reporter.drain()

        XCTAssertEqual(store.records.count, 1)
        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 0)
    }

    // MARK: - Fixtures

    /// A file in the state the store's own comments describe: one closed run that
    /// reads fine, then a line the kill cut through the em dash in a title —
    /// bytes that are not valid UTF-8 from end to end, which is what used to cost
    /// every record in the file.
    private func seedClosedRecordThenLineCutThroughAnEmDash() throws {
        let stamp = ISO8601DateFormatter().string(from: Self.now.addingTimeInterval(-3600))
        let first = "{\"runId\":\"run-first\",\"projectID\":\"/tmp/alpha\",\"itemID\":\"item-1\"," +
                    "\"title\":\"Ship the thing\",\"startedAt\":\"\(stamp)\",\"outcome\":\"done\"}"
        var bytes = Data((first + "\n" + "{\"runId\":\"run-cut\",\"title\":\"Ship it ").utf8)
        // The first two bytes of the em dash's three, and then the kill.
        bytes.append(contentsOf: [0xE2, 0x80])
        try bytes.write(to: recordsURL)
        XCTAssertNil(String(data: bytes, encoding: .utf8),
                     "the file is not valid UTF-8 from end to end — that is the fixture")
    }
}
