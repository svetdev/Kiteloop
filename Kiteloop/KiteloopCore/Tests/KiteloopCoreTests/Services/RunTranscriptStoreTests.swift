import XCTest
@testable import KiteloopCore

/// The retention and linkage half of run transcripts: that a record says which
/// run and role produced it, that one run's record is not overwritten by the
/// next, that seven days is actually the window, and that a transcript which
/// aged out reports as pruned rather than as one that never existed.
final class RunTranscriptStoreTests: XCTestCase {

    private var baseURL: URL!

    override func setUpWithError() throws {
        baseURL = FileManager.default.temporaryDirectory
            .appending(path: "kiteloop-transcripts-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: baseURL)
    }

    private func makeStore(limits: RunTranscriptStore.Limits = .init()) -> RunTranscriptStore {
        RunTranscriptStore(baseURL: baseURL, limits: limits)
    }

    private func record(
        _ content: Message.Content,
        run: String,
        role: String,
        agent: String = "agent-1",
        at: Date = Date()
    ) -> RunTranscriptStore.Record {
        RunTranscriptStore.Record(
            executionID: run,
            role: role,
            agentID: agent,
            recordedAt: at,
            message: Message(id: UUID(), timestamp: at, sender: .agent(agent), content: content)
        )
    }

    private static let day: TimeInterval = 24 * 60 * 60

    // MARK: - Linkage

    func testEveryRecordCarriesItsRunAndRole() async {
        let store = makeStore()
        await store.append([
            record(.text("starting"), run: "exec-1", role: "worker"),
            record(.toolCall(.init(id: "t1", name: "Bash", input: "{}")), run: "exec-1", role: "worker"),
            record(.toolResult(.init(id: "r1", toolCallID: "t1", output: "ok")), run: "exec-1", role: "worker"),
            record(.thinking("hmm"), run: "exec-1", role: "worker"),
        ])

        let records = await store.records(of: "exec-1")
        XCTAssertEqual(records.count, 4)
        XCTAssertTrue(records.allSatisfy { $0.executionID == "exec-1" },
                      "every record must name the run that produced it")
        XCTAssertTrue(records.allSatisfy { $0.role == "worker" },
                      "every record must name the role that produced it")
        XCTAssertTrue(records.allSatisfy { $0.agentID == "agent-1" })
    }

    func testRolesOfOneRunAreKeptApartButReadBackTogether() async {
        let store = makeStore()
        let start = Date()
        await store.append([
            record(.text("built it"), run: "exec-1", role: "worker", at: start),
            record(.text("looks good"), run: "exec-1", role: "reviewer", at: start.addingTimeInterval(1)),
        ])

        let worker = await store.records(of: "exec-1", role: "worker")
        XCTAssertEqual(worker.count, 1)
        XCTAssertEqual(worker.first?.role, "worker")

        let all = await store.records(of: "exec-1")
        XCTAssertEqual(all.map(\.role), ["worker", "reviewer"], "read back in the order they happened")
    }

    // MARK: - A transcript a kill cut short

    /// And the batch written *after* the crash keeps its own line. Appending
    /// straight onto the remnant would glue the two into something that decodes
    /// as neither, so the first record written after the crash would be lost from
    /// the only evidence of what the agent did.
    func testABatchWrittenAfterATruncatedLineIsReadBackOnTheNextLoad() async throws {
        let store = makeStore()
        let start = Date()
        await store.append([record(.text("built it"), run: "exec-1", role: "worker", at: start)])
        // The shape a kill mid-append leaves: half a record, no newline after it.
        let fileURL = baseURL.appending(path: "exec-1").appending(path: "worker.jsonl")
        try appendRaw("{\"executionID\":\"exec", to: fileURL)

        await store.append([
            record(.text("and then this"), run: "exec-1", role: "worker",
                   at: start.addingTimeInterval(1)),
            record(.text("and this"), run: "exec-1", role: "worker",
                   at: start.addingTimeInterval(2)),
        ])

        let texts = await store.records(of: "exec-1").compactMap { record -> String? in
            guard case .text(let text) = record.message.content else { return nil }
            return text
        }
        XCTAssertEqual(texts, ["built it", "and then this", "and this"],
                       "the records written after the crash survive")
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("{\"executionID\":\"exec\n"),
                      "the remnant is still there, on its own line, and still skipped by the loader")
    }

    /// The ordinary append is unchanged by the repair: a file already ending in a
    /// newline gains its lines, not a blank one before them.
    func testAppendingIntoAFileEndingInANewlineAddsNoBlankLine() async throws {
        let store = makeStore()
        let start = Date()

        await store.append([record(.text("built it"), run: "exec-1", role: "worker", at: start)])
        await store.append([record(.text("looks good"), run: "exec-1", role: "worker",
                                   at: start.addingTimeInterval(1))])

        let fileURL = baseURL.appending(path: "exec-1").appending(path: "worker.jsonl")
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(content.contains("\n\n"), "no blank line between the records")
        let records = await store.records(of: "exec-1")
        XCTAssertEqual(records.count, 2)
    }

    /// A run's directory is made by its first write — the transcripts root itself
    /// doesn't exist until then either, which is what the call site's own
    /// `createDirectory` used to cover.
    func testWritingIntoADirectoryThatDoesNotExistYetStillLands() async throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: baseURL.path(percentEncoded: false)))
        let store = makeStore()

        await store.append([record(.text("built it"), run: "exec-1", role: "worker")])

        let fileURL = baseURL.appending(path: "exec-1").appending(path: "worker.jsonl")
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(content.hasSuffix("\n"), "the line is newline-terminated")
        let records = await store.records(of: "exec-1")
        XCTAssertEqual(records.count, 1, "the record landed, not just the directory")
    }

    /// One byte that is not UTF-8 used to fail the decode of the whole file, so
    /// the role's transcript read back empty and its run indexed with no turns.
    func testALineOfInvalidUTF8CostsOnlyThatLine() async throws {
        let store = makeStore()
        let start = Date()
        await store.append([record(.text("built it"), run: "exec-1", role: "worker", at: start)])
        let fileURL = baseURL.appending(path: "exec-1").appending(path: "worker.jsonl")
        try appendRaw(bytes: Data([0x7B, 0xFF, 0xFE, 0x7D, 0x0A]), to: fileURL)
        await store.append([record(.text("and then this"), run: "exec-1", role: "worker",
                                   at: start.addingTimeInterval(1))])

        let texts = await store.records(of: "exec-1", role: "worker").compactMap { record -> String? in
            guard case .text(let text) = record.message.content else { return nil }
            return text
        }
        XCTAssertEqual(texts, ["built it", "and then this"], "both valid records survive, in order")
        let all = await store.records(of: "exec-1")
        XCTAssertEqual(all.count, 2)
        guard case .present(let count, _, _) = await store.status(of: "exec-1") else {
            return XCTFail("a transcript with valid records must report as present")
        }
        XCTAssertEqual(count, 2, "the record count counts the valid records, not 0")
    }

    func testARunWithNoTranscriptFileReadsBackEmpty() async {
        let records = await makeStore().records(of: "never-ran")
        XCTAssertTrue(records.isEmpty)
    }

    private func appendRaw(_ text: String, to url: URL) throws {
        try appendRaw(bytes: Data(text.utf8), to: url)
    }

    private func appendRaw(bytes: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: bytes)
    }

    // MARK: - Retention

    /// The defect this item exists for: the agent kept one rolling transcript and
    /// its next run overwrote the last one's evidence.
    func testASecondRunBySameAgentDoesNotOverwriteTheFirst() async {
        let store = makeStore()
        await store.append([record(.text("first run"), run: "exec-1", role: "worker")])
        await store.append([record(.text("second run"), run: "exec-2", role: "worker")])

        let first = await store.records(of: "exec-1")
        let second = await store.records(of: "exec-2")
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1)
        if case .text(let text) = first.first?.message.content {
            XCTAssertEqual(text, "first run", "the earlier run's record must survive the later one")
        } else {
            XCTFail("expected the first run's text record")
        }
    }

    func testRetentionWindowIsSevenDays() async {
        let store = makeStore()
        let written = Date()
        await store.append([record(.text("work"), run: "exec-1", role: "worker", at: written)])

        let earlyReport = await store.prune(now: written.addingTimeInterval(6 * Self.day))
        XCTAssertEqual(earlyReport.runsPruned, 0, "six days is inside the window")
        let survivors = await store.records(of: "exec-1")
        XCTAssertEqual(survivors.count, 1)

        let lateReport = await store.prune(now: written.addingTimeInterval(8 * Self.day))
        XCTAssertEqual(lateReport.runsPruned, 1, "eight days is outside the window")
        XCTAssertEqual(lateReport.recordsPruned, 1)
        let remaining = await store.records(of: "exec-1")
        XCTAssertTrue(remaining.isEmpty)
    }

    func testPrunedTranscriptIsReportedAsPrunedNotAbsent() async {
        let store = makeStore()
        let written = Date()
        await store.append([record(.text("work"), run: "exec-1", role: "worker", at: written)])

        let prunedAt = written.addingTimeInterval(8 * Self.day)
        await store.prune(now: prunedAt)

        switch await store.status(of: "exec-1") {
        case .pruned(let at, let retentionDays):
            XCTAssertEqual(at.timeIntervalSince1970, prunedAt.timeIntervalSince1970, accuracy: 1)
            XCTAssertEqual(retentionDays, 7, "the window must be reported, not just applied")
        case .present, .absent:
            XCTFail("an aged-out transcript must report as pruned")
        }
    }

    // MARK: - A tombstone the decoder refuses

    /// The records a tombstone stands in for come off disk the moment it lands,
    /// so bytes that will not decode still say a run aged out. Read as "no
    /// tombstone" the run reports `.absent` instead — "nothing was ever written
    /// under this execution id", the opposite of what happened.
    func testATombstoneThatWillNotDecodeIsReportedAsPrunedNotAbsent() async throws {
        let store = makeStore()
        let written = Date()
        await store.append([record(.text("work"), run: "exec-1", role: "worker", at: written)])
        let prunedAt = written.addingTimeInterval(8 * Self.day)
        await store.prune(now: prunedAt)

        let garbage = try corruptTombstone(of: "exec-1", writtenAt: prunedAt)

        switch await store.status(of: "exec-1") {
        case .pruned(let at, let retentionDays):
            XCTAssertEqual(at.timeIntervalSince1970, prunedAt.timeIntervalSince1970, accuracy: 1,
                           "the date comes from the file it could not read, not from an invented value")
            XCTAssertEqual(retentionDays, 7, "and the window from the store's own limits")
        case .present, .absent:
            XCTFail("a run whose tombstone will not decode aged out; it did not never exist")
        }
        XCTAssertEqual(try Data(contentsOf: tombstoneURL(of: "exec-1")), garbage,
                       "an unreadable record is still somebody's history — it stays exactly where it is")
    }

    /// The window it stands in for is this store's, not the seven days the
    /// default happens to carry.
    func testTheWindowReportedForAnUnreadableTombstoneIsTheStoresOwn() async throws {
        let store = makeStore(limits: .init(retention: 2 * Self.day))
        let written = Date()
        await store.append([record(.text("work"), run: "exec-1", role: "worker", at: written)])
        let prunedAt = written.addingTimeInterval(3 * Self.day)
        await store.prune(now: prunedAt)

        try corruptTombstone(of: "exec-1", writtenAt: prunedAt)

        guard case .pruned(_, let retentionDays) = await store.status(of: "exec-1") else {
            return XCTFail("expected the run to read as pruned")
        }
        XCTAssertEqual(retentionDays, 2, "the store's configured retention, not a constant")
    }

    /// The two readers decide off the same file, so they cannot say opposite
    /// things about one run: `usage()` counted it in `prunedRuns` while
    /// `status(of:)` said it had never been written.
    func testUsageAndStatusAgreeAboutAnUnreadableTombstone() async throws {
        let store = makeStore()
        let written = Date()
        await store.append([record(.text("work"), run: "exec-1", role: "worker", at: written)])
        let prunedAt = written.addingTimeInterval(8 * Self.day)
        await store.prune(now: prunedAt)

        try corruptTombstone(of: "exec-1", writtenAt: prunedAt)

        let usage = await store.usage()
        XCTAssertEqual(usage.prunedRuns, 1, "usage counts the run as pruned…")
        XCTAssertEqual(usage.runs, 0, "…and not as a live transcript")
        guard case .pruned = await store.status(of: "exec-1") else {
            return XCTFail("…so status must read it as pruned too")
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: tombstoneURL(of: "exec-1").path(percentEncoded: false)),
            "neither reader repairs or removes what it could not decode"
        )
    }

    /// And the fallback only stands in for bytes that failed: a tombstone that
    /// decodes reports its own stamps, whatever the file's timestamp says.
    func testATombstoneThatDecodesStillReportsItsOwnStamps() async throws {
        let store = makeStore()
        let written = Date()
        await store.append([record(.text("work"), run: "exec-1", role: "worker", at: written)])
        let prunedAt = written.addingTimeInterval(8 * Self.day)
        await store.prune(now: prunedAt)

        try FileManager.default.setAttributes(
            [.modificationDate: written.addingTimeInterval(-30 * Self.day)],
            ofItemAtPath: tombstoneURL(of: "exec-1").path(percentEncoded: false)
        )

        switch await store.status(of: "exec-1") {
        case .pruned(let at, let retentionDays):
            XCTAssertEqual(at.timeIntervalSince1970, prunedAt.timeIntervalSince1970, accuracy: 1,
                           "the tombstone's own date, not the file's modification time")
            XCTAssertEqual(retentionDays, 7)
        case .present, .absent:
            XCTFail("a readable tombstone must still report as pruned")
        }
    }

    private func tombstoneURL(of run: String) -> URL {
        baseURL.appending(path: run).appending(path: "pruned.json")
    }

    /// Replaces a run's tombstone with bytes the decoder refuses — the shape a
    /// kill mid-write leaves behind — and stamps the file with the moment the
    /// sweep ran, which is all a reader has left to go on.
    @discardableResult
    private func corruptTombstone(of run: String, writtenAt: Date) throws -> Data {
        let url = tombstoneURL(of: run)
        let garbage = Data("{\"executionID\":\"exec".utf8)
        try garbage.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: writtenAt],
                                              ofItemAtPath: url.path(percentEncoded: false))
        return garbage
    }

    func testRunThatNeverWroteAnythingIsAbsent() async {
        let store = makeStore()
        await store.append([record(.text("work"), run: "exec-1", role: "worker")])

        let status = await store.status(of: "never-ran")
        XCTAssertEqual(status, .absent, "\"never existed\" must not read as \"aged out\"")
    }

    func testLiveTranscriptIsReportedAsPresentWithItsSize() async {
        let store = makeStore()
        let at = Date()
        await store.append([
            record(.text("one"), run: "exec-1", role: "worker", at: at),
            record(.text("two"), run: "exec-1", role: "worker", at: at.addingTimeInterval(1)),
        ])

        switch await store.status(of: "exec-1") {
        case .present(let count, let bytes, let last):
            XCTAssertEqual(count, 2)
            XCTAssertGreaterThan(bytes, 0)
            XCTAssertEqual(last?.timeIntervalSince1970 ?? 0,
                           at.addingTimeInterval(1).timeIntervalSince1970, accuracy: 1)
        case .pruned, .absent:
            XCTFail("a transcript just written must report as present")
        }
    }

    func testPruningKeepsRunsInsideTheWindowUntouched() async {
        let store = makeStore()
        let now = Date()
        await store.append([record(.text("old"), run: "old-exec", role: "worker", at: now)])
        await store.prune(now: now.addingTimeInterval(8 * Self.day))
        // Written "later" — i.e. now, well inside the window from the prune's view.
        await store.append([record(.text("new"), run: "new-exec", role: "worker")])
        await store.prune(now: Date())

        let kept = await store.records(of: "new-exec")
        XCTAssertEqual(kept.count, 1)
        let oldStatus = await store.status(of: "old-exec")
        if case .pruned = oldStatus {} else {
            XCTFail("the aged-out run should still read as pruned")
        }
    }

    func testUsageSeparatesLiveBytesFromTombstones() async {
        let store = makeStore()
        let written = Date()
        await store.append([record(.text("aged out"), run: "exec-old", role: "worker", at: written)])
        await store.prune(now: written.addingTimeInterval(8 * Self.day))
        await store.append([record(.text("live"), run: "exec-new", role: "worker")])

        let usage = await store.usage()
        XCTAssertEqual(usage.runs, 1, "only the live run counts against the retention window")
        XCTAssertGreaterThan(usage.bytes, 0)
        XCTAssertEqual(usage.prunedRuns, 1)
        XCTAssertGreaterThan(usage.tombstoneBytes, 0)
        XCTAssertLessThan(usage.tombstoneBytes, 512, "a tombstone is what outlives retention; keep it tiny")
    }

    // MARK: - A tombstone that could not be written

    /// The tombstone is what tells "aged out" apart from "never existed", so a
    /// sweep that cannot write one must not remove the records it would have
    /// stood in for — the run would afterwards read as `.absent`, which says the
    /// opposite of what happened.
    func testARunWhoseTombstoneCannotBeWrittenKeepsItsRecords() async throws {
        let store = makeStore()
        let written = Date()
        await store.append([record(.text("work"), run: "exec-1", role: "worker", at: written)])

        // `pruned.json` is already a directory, so writing the tombstone over it
        // fails while the `.jsonl` files beside it stay perfectly removable.
        let runDirectory = baseURL.appending(path: "exec-1")
        try FileManager.default.createDirectory(
            at: runDirectory.appending(path: "pruned.json"), withIntermediateDirectories: false
        )

        let report = await store.prune(now: written.addingTimeInterval(8 * Self.day))

        XCTAssertEqual(report.runsNotPruned, 1, "a sweep must say what it could not do")
        XCTAssertEqual(report.runsPruned, 0, "nothing was pruned")
        XCTAssertEqual(report.recordsPruned, 0, "no records were removed, so none were reclaimed")
        XCTAssertEqual(report.bytesReclaimed, 0)

        let fileURL = runDirectory.appending(path: "worker.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)),
                      "the records outlive the tombstone that could not replace them")
        let status = await store.status(of: "exec-1")
        guard case .present(let count, _, _) = status else {
            return XCTFail("a run that kept its records must still read as present, got \(status)")
        }
        XCTAssertEqual(count, 1)
        let survivors = await store.records(of: "exec-1")
        XCTAssertEqual(survivors.count, 1, "and are still readable")
    }

    /// The same on the failure the item names: a run directory nothing can write
    /// into. Here the removal would fail too, so what the reordering buys is the
    /// report — a run left intact must not be counted as one that was pruned.
    func testAnUnwritableRunDirectoryIsReportedAsNotPruned() async throws {
        let store = makeStore()
        let written = Date()
        await store.append([record(.text("work"), run: "exec-1", role: "worker", at: written)])

        let runDirectory = baseURL.appending(path: "exec-1")
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: runDirectory.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: runDirectory.path(percentEncoded: false))
        }

        let report = await store.prune(now: written.addingTimeInterval(8 * Self.day))

        XCTAssertEqual(report.runsNotPruned, 1)
        XCTAssertEqual(report.runsPruned, 0, "a run still holding its records was not pruned")
        XCTAssertEqual(report.recordsPruned, 0)
        XCTAssertEqual(report.bytesReclaimed, 0, "nothing came off disk, so nothing was reclaimed")

        let status = await store.status(of: "exec-1")
        guard case .present = status else {
            return XCTFail("the records are still there, so the run is present, got \(status)")
        }
    }

    /// And the obstruction is not permanent: once the tombstone can be written,
    /// the next sweep prunes the run it had to leave alone.
    func testARunLeftInPlaceIsPrunedByTheNextSweepThatCanWriteItsTombstone() async throws {
        let store = makeStore()
        let written = Date()
        await store.append([record(.text("work"), run: "exec-1", role: "worker", at: written)])

        let blocker = baseURL.appending(path: "exec-1").appending(path: "pruned.json")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: false)
        let blocked = await store.prune(now: written.addingTimeInterval(8 * Self.day))
        XCTAssertEqual(blocked.runsNotPruned, 1)

        try FileManager.default.removeItem(at: blocker)
        let report = await store.prune(now: written.addingTimeInterval(9 * Self.day))

        XCTAssertEqual(report.runsNotPruned, 0)
        XCTAssertEqual(report.runsPruned, 1)
        XCTAssertEqual(report.recordsPruned, 1)
        XCTAssertGreaterThan(report.bytesReclaimed, 0)
        guard case .pruned = await store.status(of: "exec-1") else {
            return XCTFail("the run should now read as pruned")
        }
    }

    /// The ordinary path says nothing was left behind, so the new field cannot be
    /// read as "some runs always are".
    func testAnOrdinarySweepReportsNothingLeftBehind() async {
        let store = makeStore()
        let written = Date()
        await store.append([record(.text("work"), run: "exec-1", role: "worker", at: written)])

        let report = await store.prune(now: written.addingTimeInterval(8 * Self.day))

        XCTAssertEqual(report.runsPruned, 1)
        XCTAssertEqual(report.runsNotPruned, 0)
    }

    // MARK: - Volume

    func testLargeToolResultKeepsBothItsHeadAndItsTail() async {
        let store = makeStore(limits: .init(maxRecordBytes: 512))
        let output = "START-OF-BUILD\n" + String(repeating: "x", count: 20_000) + "\nerror: THE-THING-THAT-FAILED"
        await store.append([
            record(.toolResult(.init(id: "r", toolCallID: "t", output: output)), run: "exec-1", role: "worker")
        ])

        guard case .toolResult(let stored)? = await store.records(of: "exec-1").first?.message.content else {
            return XCTFail("expected a tool result")
        }
        XCTAssertTrue(stored.output.hasPrefix("START-OF-BUILD"), "the command that ran must survive")
        XCTAssertTrue(stored.output.hasSuffix("error: THE-THING-THAT-FAILED"),
                      "the failure a log ends on is the half worth keeping")
        XCTAssertTrue(stored.output.contains("bytes elided"), "an elision must be visible as one")
        XCTAssertLessThan(stored.output.utf8.count, 700)
    }

    func testThinkingShedsBeforeEverythingElse() async {
        let store = makeStore()
        let long = String(repeating: "y", count: 4_000)
        await store.append([
            record(.thinking(long), run: "exec-1", role: "worker"),
            record(.toolResult(.init(id: "r", toolCallID: "t", output: long)), run: "exec-1", role: "worker"),
        ])

        let records = await store.records(of: "exec-1")
        guard case .thinking(let thinking)? = records.first?.message.content,
              case .toolResult(let result)? = records.last?.message.content else {
            return XCTFail("expected a thinking record and a tool result")
        }
        XCTAssertLessThan(thinking.utf8.count, long.utf8.count, "thinking is capped tightest")
        XCTAssertEqual(result.output, long, "a tool result of the same size is kept whole")
    }

    func testImagePayloadIsNotStored() async {
        let store = makeStore()
        let screenshot = Data(repeating: 0xAB, count: 200_000)
        await store.append([record(.image(screenshot), run: "exec-1", role: "worker")])

        guard case .text(let text)? = await store.records(of: "exec-1").first?.message.content else {
            return XCTFail("expected the image to be replaced by a note")
        }
        XCTAssertTrue(text.contains("200000"), "the note should say what was dropped")
        let usage = await store.usage()
        XCTAssertLessThan(usage.bytes, 1_000, "a base64 screenshot must not land in a transcript")
    }

    // MARK: - Safety

    func testRunAndRoleCannotEscapeTheTranscriptsDirectory() async {
        let store = makeStore()
        await store.append([record(.text("hi"), run: "../../escaped", role: "../roles")])

        let escaped = baseURL.deletingLastPathComponent().appending(path: "escaped")
        XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path(percentEncoded: false)))
        let usage = await store.usage()
        XCTAssertEqual(usage.runs, 1, "the record still lands, inside the directory")
    }

    /// Writing must never be the thing that fails a run: a base directory that
    /// cannot be created is logged and swallowed, not raised.
    func testAnUnwritableDirectoryIsSurvivedNotRaised() async throws {
        let blocker = FileManager.default.temporaryDirectory
            .appending(path: "kiteloop-blocker-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }

        let store = RunTranscriptStore(baseURL: blocker.appending(path: "transcripts"))
        await store.append([record(.text("work"), run: "exec-1", role: "worker")])

        let status = await store.status(of: "exec-1")
        XCTAssertEqual(status, .absent)
    }
}

// MARK: - Boundaries: the retention window, the sweep cadence, and the caps

extension RunTranscriptStoreTests {

    /// A run whose newest write is exactly as old as the window is still
    /// inside it: retention prunes what is *older* than seven days.
    func testARunExactlyAtTheRetentionWindowIsNotPruned() async throws {
        let store = makeStore()
        await store.append([record(.text("work"), run: "exec-1", role: "worker")])
        let fileURL = baseURL.appending(path: "exec-1").appending(path: "worker.jsonl")
        let written = Date(timeIntervalSince1970: 1_770_000_000)
        try FileManager.default.setAttributes([.modificationDate: written],
                                              ofItemAtPath: fileURL.path(percentEncoded: false))

        let report = await store.prune(now: written.addingTimeInterval(7 * Self.day))

        XCTAssertEqual(report.runsPruned, 0, "exactly seven days old is not yet outside the window")
        let records = await store.records(of: "exec-1")
        XCTAssertEqual(records.count, 1, "the run keeps its records")
    }

    /// The sweep cadence is measured from the last sweep: a write one full
    /// interval later sweeps again. Retention is enforced by the app writing
    /// over time, not only by the first write after launch.
    func testAWriteOneFullIntervalAfterTheLastSweepPrunesAgain() async throws {
        let store = makeStore(limits: .init(retention: 60, pruneInterval: 3600))
        let t0 = Date()
        await store.append([record(.text("old work"), run: "exec-old", role: "worker")], now: t0)
        let fileURL = baseURL.appending(path: "exec-old").appending(path: "worker.jsonl")
        try FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(-120)],
                                              ofItemAtPath: fileURL.path(percentEncoded: false))

        await store.append([record(.text("new work"), run: "exec-new", role: "worker")],
                           now: t0.addingTimeInterval(3600))

        guard case .pruned = await store.status(of: "exec-old") else {
            return XCTFail("the sweep due at the interval must prune the aged-out run")
        }
    }

    /// A transcripts root with a space in its path — a project under
    /// "~/Documents/My Project" — still reads its pruned runs as pruned, in
    /// `status` and `usage` both.
    func testAPathWithASpaceStillReportsPrunedRuns() async throws {
        let store = RunTranscriptStore(baseURL: baseURL.appending(path: "My Project"))
        let written = Date()
        await store.append([record(.text("work"), run: "exec-1", role: "worker", at: written)])
        await store.prune(now: written.addingTimeInterval(8 * Self.day))

        guard case .pruned = await store.status(of: "exec-1") else {
            return XCTFail("the tombstone is on disk; a percent-encoded path must not hide it")
        }
        let usage = await store.usage()
        XCTAssertEqual(usage.prunedRuns, 1)
        XCTAssertEqual(usage.runs, 0)
    }

    /// A record exactly at the cap is stored whole — the cap bounds what is
    /// *over* it. Multibyte text is the case that could go wrong: the head
    /// and tail land on character boundaries, so an at-cap refit could shed
    /// bytes it had no need to.
    func testTextExactlyAtTheCapIsKeptWhole() {
        XCTAssertEqual(RunTranscriptStore.clip("€€x", to: 7), "€€x")
    }

    /// A cap of zero or below disables clipping rather than eliding
    /// everything.
    func testANonPositiveCapMeansUnclipped() {
        XCTAssertEqual(RunTranscriptStore.clip("anything at all", to: 0), "anything at all")
    }

    /// The split is three fifths head, the rest tail, either side of a marker
    /// naming the elided byte count — and a character that exactly fills its
    /// half is included, not dropped.
    func testClipKeepsThreeFifthsHeadAndTwoFifthsTail() {
        XCTAssertEqual(RunTranscriptStore.clip("abcdefghijk", to: 10),
                       "abcdef\n… 1 bytes elided …\nhijk")
    }
}
