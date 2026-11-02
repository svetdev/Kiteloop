import XCTest
import KiteloopCore
@testable import Kiteloop

@MainActor
final class TaskMetricStoreTests: XCTestCase {

    private var tempDir: URL!
    private var metricsURL: URL!
    private var estimatesURL: URL!
    private var approvalsURL: URL!
    private var mergesURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try makeTemporaryDirectory(prefix: "task-metric-store")
        metricsURL = tempDir.appendingPathComponent("task-metrics.jsonl")
        estimatesURL = tempDir.appendingPathComponent("task-estimates.jsonl")
        approvalsURL = tempDir.appendingPathComponent("task-approvals.jsonl")
        mergesURL = tempDir.appendingPathComponent("task-merges.jsonl")
    }

    private func makeStore() -> TaskMetricStore {
        TaskMetricStore(metricsURL: metricsURL, estimatesURL: estimatesURL,
                        approvalsURL: approvalsURL, mergesURL: mergesURL)
    }

    private func record(
        itemID: String = "t-1",
        project: String = "/tmp/proj",
        size: String? = "M",
        epic: String? = "Epic A",
        duration: Double = 480,
        cost: Double = 0.40,
        retries: Int = 1,
        outcome: String = "done"
    ) -> TaskMetricRecord {
        let start = Date()
        return TaskMetricRecord(
            projectPath: project, projectName: "proj", itemID: itemID, title: "Task \(itemID)",
            epic: epic, declaredSize: size, startedAt: start,
            completedAt: start.addingTimeInterval(duration), durationSeconds: duration,
            costUSD: cost, reviewerRetries: retries, outcome: outcome,
            workerAgent: "worker", reviewerAgent: "reviewer", executionID: "e-1", toolErrors: nil
        )
    }

    private func estimate(
        itemID: String = "t-1",
        project: String = "/tmp/proj",
        createdAt: Date = Date(),
        size: String = "M",
        duration: Double = 300,
        cost: Double? = 0.2,
        retries: Int? = 1,
        confidence: Double = 0.5,
        rationale: String = "test"
    ) -> TaskEstimate {
        TaskEstimate(
            itemID: itemID, projectPath: project, createdAt: createdAt,
            estimatedSize: size, predictedDurationSeconds: duration, predictedCostUSD: cost,
            predictedRetries: retries, confidence: confidence, source: "hybrid", rationale: rationale
        )
    }

    private func approvalEvent(itemID: String = "t-1", project: String = "/tmp/proj",
                               kind: ItemApprovalEvent.Kind = .approved,
                               at: Date = Date()) -> ItemApprovalEvent {
        ItemApprovalEvent(projectPath: project, projectName: "proj", itemID: itemID,
                          kind: kind, at: at)
    }

    private func mergeEvent(itemID: String, merged: Bool, project: String = "/tmp/proj",
                            execution: String? = nil, at: Date = Date()) -> ItemMergeEvent {
        ItemMergeEvent(projectPath: project, projectName: "proj", itemID: itemID,
                       merged: merged, at: at, executionID: execution)
    }

    private func lines(of url: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return [] }
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
    }

    // MARK: - Append / persist

    func testEmptyStoreStartsWithNoRecordsOrEstimates() {
        let store = makeStore()
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(store.estimates.isEmpty)
    }

    func testAppendAddsToRecordsInOrderAndWritesOneLinePerRecord() throws {
        let store = makeStore()
        store.append(record(itemID: "a"))
        store.append(record(itemID: "b"))
        store.append(record(itemID: "c"))

        XCTAssertEqual(store.records.map(\.itemID), ["a", "b", "c"])
        // The first append creates the file, later ones append rather than truncate.
        XCTAssertEqual(try lines(of: metricsURL).count, 3)
    }

    func testAppendedRecordsSurviveReload() throws {
        let store = makeStore()
        store.append(record(itemID: "round-1", size: "S", duration: 600, cost: 0.5, retries: 2))
        store.append(record(itemID: "round-2", size: nil, epic: nil, duration: 90, cost: 0.05, retries: 0))

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.records.map(\.itemID), ["round-1", "round-2"])

        let first = try XCTUnwrap(reloaded.records.first)
        XCTAssertEqual(first.projectPath, "/tmp/proj")
        XCTAssertEqual(first.projectName, "proj")
        XCTAssertEqual(first.title, "Task round-1")
        XCTAssertEqual(first.epic, "Epic A")
        XCTAssertEqual(first.declaredSize, "S")
        XCTAssertEqual(first.durationSeconds, 600, accuracy: 0.001)
        XCTAssertEqual(first.costUSD, 0.5, accuracy: 0.001)
        XCTAssertEqual(first.reviewerRetries, 2)
        XCTAssertEqual(first.outcome, "done")
        XCTAssertEqual(first.workerAgent, "worker")
        XCTAssertEqual(first.reviewerAgent, "reviewer")
        XCTAssertEqual(first.executionID, "e-1")

        // Optionals must round-trip as nil, not as a default.
        let second = try XCTUnwrap(reloaded.records.last)
        XCTAssertNil(second.epic)
        XCTAssertNil(second.declaredSize)
        XCTAssertNil(second.toolErrors)
    }

    func testAppendEstimateAddsToEstimatesAndSurvivesReload() throws {
        let store = makeStore()
        store.appendEstimate(estimate(itemID: "est-1", size: "L", duration: 900, confidence: 0.8))

        XCTAssertEqual(store.estimates.count, 1)
        XCTAssertEqual(try lines(of: estimatesURL).count, 1)
        // Estimates and metrics use separate files.
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertEqual(try lines(of: metricsURL).count, 0)

        let reloaded = makeStore()
        let e = try XCTUnwrap(reloaded.estimates.first)
        XCTAssertEqual(e.itemID, "est-1")
        XCTAssertEqual(e.estimatedSize, "L")
        XCTAssertEqual(e.predictedDurationSeconds, 900, accuracy: 0.001)
        XCTAssertEqual(e.confidence, 0.8, accuracy: 0.001)
        XCTAssertEqual(e.source, "hybrid")
    }

    func testAppendEstimateAddsToEstimatesInOrderAndWritesOneLinePerEstimate() throws {
        let store = makeStore()
        store.appendEstimate(estimate(itemID: "a"))
        store.appendEstimate(estimate(itemID: "b"))
        store.appendEstimate(estimate(itemID: "c"))

        XCTAssertEqual(store.estimates.map(\.itemID), ["a", "b", "c"])
        // The first append creates the file, later ones append rather than truncate.
        XCTAssertEqual(try lines(of: estimatesURL).count, 3)

        XCTAssertEqual(makeStore().estimates.map(\.itemID), ["a", "b", "c"])
    }

    func testAppendEstimateRepeatedlyForTheSameItemKeepsEveryEstimate() throws {
        let store = makeStore()
        store.appendEstimate(estimate(itemID: "x", duration: 100))
        store.appendEstimate(estimate(itemID: "x", duration: 200))
        store.appendEstimate(estimate(itemID: "x", duration: 300))

        // The store is append-only — re-estimating an item never rewrites history.
        XCTAssertEqual(store.estimates.map(\.predictedDurationSeconds), [100, 200, 300])
        XCTAssertEqual(try lines(of: estimatesURL).count, 3)
    }

    func testAppendEstimateAcrossStoreInstancesAccumulates() throws {
        let first = makeStore()
        first.appendEstimate(estimate(itemID: "a"))

        let second = makeStore()
        second.appendEstimate(estimate(itemID: "b"))

        XCTAssertEqual(second.estimates.map(\.itemID), ["a", "b"])
        XCTAssertEqual(try lines(of: estimatesURL).count, 2)
    }

    func testAppendedEstimateOptionalsRoundTripAsNil() throws {
        let store = makeStore()
        store.appendEstimate(estimate(itemID: "x", cost: nil, retries: nil))

        let reloaded = makeStore()
        let e = try XCTUnwrap(reloaded.estimates.first)
        XCTAssertNil(e.predictedCostUSD)
        XCTAssertNil(e.predictedRetries)
    }

    func testLoadSkipsUndecodableEstimateLines() throws {
        let store = makeStore()
        store.appendEstimate(estimate(itemID: "good-1"))
        let handle = try FileHandle(forWritingTo: estimatesURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{not json}\n".utf8))
        try handle.close()
        store.appendEstimate(estimate(itemID: "good-2"))

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.estimates.map(\.itemID), ["good-1", "good-2"])
    }

    func testEachAppendedEstimateGetsADistinctID() {
        let store = makeStore()
        store.appendEstimate(estimate(itemID: "x"))
        store.appendEstimate(estimate(itemID: "x"))

        XCTAssertEqual(Set(store.estimates.map(\.id)).count, 2)
    }

    func testAppendAcrossStoreInstancesAccumulates() throws {
        let first = makeStore()
        first.append(record(itemID: "a"))

        let second = makeStore()
        second.append(record(itemID: "b"))

        XCTAssertEqual(second.records.map(\.itemID), ["a", "b"])
        XCTAssertEqual(try lines(of: metricsURL).count, 2)
    }

    func testLoadSkipsUndecodableLines() throws {
        let store = makeStore()
        store.append(record(itemID: "good-1"))
        // A truncated/garbage line must not take the rest of the file down with it.
        let handle = try FileHandle(forWritingTo: metricsURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{not json}\n".utf8))
        try handle.close()
        store.append(record(itemID: "good-2"))

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.records.map(\.itemID), ["good-1", "good-2"])
    }

    // MARK: - The verify verdict

    /// The verdict survives the trip to the ledger and back — the whole point of
    /// putting it there. A run's exit status, the command and its last lines are
    /// what an audit of a green gate has to read months later.
    func testTheVerifyVerdictSurvivesReload() throws {
        var written = record(itemID: "audited")
        written.verify = RunVerifyVerdict(
            exitStatus: 101,
            command: "cd Kiteloop && xcodebuild build-for-testing",
            directory: "/tmp/worktrees/audited",
            outputTail: "** TEST BUILD FAILED **",
            timedOut: false
        )
        let store = makeStore()
        store.append(written)

        let reloaded = try XCTUnwrap(makeStore().records.first)

        XCTAssertEqual(reloaded.verify, written.verify)
        XCTAssertEqual(reloaded.verify?.exitStatus, 101)
        XCTAssertFalse(try XCTUnwrap(reloaded.verify).passed)
    }

    /// Every record already in `~/.kiteloop/task-metrics.jsonl` was written
    /// before this field existed, and they must all still decode — nil, which
    /// says nobody measured, rather than a zero that would read as a pass.
    func testARecordWrittenBeforeTheVerifyFieldStillDecodes() throws {
        let store = makeStore()
        store.append(record(itemID: "older"))
        let line = try XCTUnwrap(lines(of: metricsURL).first)
        XCTAssertFalse(line.contains("\"verify\""), "the field is absent, not null")

        let reloaded = try XCTUnwrap(makeStore().records.first)

        XCTAssertNil(reloaded.verify)
    }

    /// Only the last 40 lines are kept, and trailing blanks do not spend that
    /// budget — a build log runs to megabytes and a note has to stay readable.
    func testTheOutputTailKeepsTheLastFortyLines() {
        let long = (1...500).map { "line \($0)" }.joined(separator: "\n") + "\n\n\n"

        let tail = RunVerifyVerdict.tail(of: long)

        XCTAssertEqual(tail.split(separator: "\n").count, RunVerifyVerdict.outputTailLines)
        XCTAssertTrue(tail.hasSuffix("line 500"), "the end is what a failure is at")
        XCTAssertEqual(tail.split(separator: "\n").first, "line 461")
        XCTAssertEqual(RunVerifyVerdict.tail(of: "short"), "short")
    }

    /// A verify killed at its deadline judged nothing about the tree, and says
    /// so in the words the run log and the item's outcome both use.
    func testATimedOutVerdictSaysItNeverAnswered() {
        let killed = RunVerifyVerdict(exitStatus: WorktreeManager.noExitStatus, command: "make ci",
                                      directory: "/tmp/wt", outputTail: "", timedOut: true)
        XCTAssertEqual(killed.signal, "verify timed out before it answered")
        XCTAssertFalse(killed.passed)

        let failed = RunVerifyVerdict(exitStatus: 2, command: "make ci", directory: "/tmp/wt",
                                      outputTail: "", timedOut: false)
        XCTAssertEqual(failed.signal, "verify failed (exit 2)")
    }

    // MARK: - Unreadable lines

    private func append(raw: String, to url: URL) throws {
        try append(rawBytes: Data(raw.utf8), to: url)
    }

    /// The same, for the lines that are not text at all: bytes a kill left
    /// part-way through a character cannot be spelled as a `String`.
    private func append(rawBytes: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: rawBytes)
    }

    /// The case the counts exist for: `appendLine` writes through a `FileHandle`
    /// with no atomicity, so the app being killed mid-append leaves the newest
    /// line — the run that just finished — half-written. The runs before it still
    /// load, and the one that went is reported rather than silently lowering
    /// every denominator computed over this ledger.
    func testATruncatedLastMetricLineIsReportedAndTheRestStillLoads() throws {
        let store = makeStore()
        store.append(record(itemID: "a"))
        store.append(record(itemID: "b"))
        store.append(record(itemID: "c"))

        // Chop the trailing newline and part of the last record — what a kill
        // mid-append leaves behind.
        let content = try String(contentsOf: metricsURL, encoding: .utf8)
        try Data(String(content.dropLast(20)).utf8).write(to: metricsURL)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.records.map(\.itemID), ["a", "b"])
        XCTAssertEqual(reloaded.undecodableMetricLineCount, 1)
    }

    /// And the record written *after* the crash keeps its own line. Appending
    /// straight onto the remnant would glue the two into something that decodes
    /// as neither, so the attempt `RetryCeiling` counts and the cost
    /// `CostGovernor` predicts from would go down with a crash that happened
    /// before them.
    func testAMetricRecordedAfterATruncatedLineIsReadBackOnTheNextLoad() throws {
        let store = makeStore()
        store.append(record(itemID: "a"))
        store.append(record(itemID: "b"))
        // The shape a kill mid-append leaves: half a record, no newline after it.
        try append(raw: "{\"itemID\":\"cut\",\"costU", to: metricsURL)

        makeStore().append(record(itemID: "c"))

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.records.map(\.itemID), ["a", "b", "c"],
                       "the metric recorded after the crash survives")
        XCTAssertEqual(reloaded.undecodableMetricLineCount, 1,
                       "and the remnant is still counted — not swallowed, and not doubled")
    }

    /// The ordinary append is unchanged by the repair: a ledger already ending in
    /// a newline gains one line, not a blank one before it.
    func testAppendingToALedgerEndingInANewlineAddsNoBlankLine() throws {
        let store = makeStore()
        store.append(record(itemID: "a"))
        let before = try String(contentsOf: metricsURL, encoding: .utf8)

        store.append(record(itemID: "b"))

        let after = try String(contentsOf: metricsURL, encoding: .utf8)
        XCTAssertEqual(after.filter { $0 == "\n" }.count, before.filter { $0 == "\n" }.count + 1)
        XCTAssertFalse(after.contains("\n\n"), "no blank line between the records")
        XCTAssertEqual(makeStore().records.map(\.itemID), ["a", "b"])
    }

    /// Four files, four counts. A ledger that lost a line says so without
    /// implicating the three beside it.
    func testEachLedgerCountsItsOwnUnreadableLinesIndependently() throws {
        let store = makeStore()
        store.append(record(itemID: "a"))
        store.appendEstimate(estimate(itemID: "a"))
        store.appendApprovalEvent(approvalEvent(itemID: "a"))
        store.appendMergeEvent(mergeEvent(itemID: "a", merged: true, execution: "e-1"))

        try append(raw: "{not json}\n", to: metricsURL)
        try append(raw: "{not json}\n{also not}\n", to: estimatesURL)
        try append(raw: "{not json}\n{also not}\n{nor this}\n", to: approvalsURL)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.undecodableMetricLineCount, 1)
        XCTAssertEqual(reloaded.undecodableEstimateLineCount, 2)
        XCTAssertEqual(reloaded.undecodableApprovalLineCount, 3)
        XCTAssertEqual(reloaded.undecodableMergeLineCount, 0, "this one was whole")

        // And the readable line of each ledger is still there.
        XCTAssertEqual(reloaded.records.map(\.itemID), ["a"])
        XCTAssertEqual(reloaded.estimates.map(\.itemID), ["a"])
        XCTAssertEqual(reloaded.approvalEvents.map(\.itemID), ["a"])
        XCTAssertEqual(reloaded.mergeEvents.map(\.itemID), ["a"])
    }

    /// Zero has to mean zero, or the counts say nothing: a ledger nobody
    /// truncated reports none, as does one that was never written at all.
    func testWholeLedgersReportNoUnreadableLines() {
        let store = makeStore()
        XCTAssertEqual(store.undecodableMetricLineCount, 0, "nothing written yet")
        XCTAssertEqual(store.undecodableEstimateLineCount, 0)
        XCTAssertEqual(store.undecodableApprovalLineCount, 0)
        XCTAssertEqual(store.undecodableMergeLineCount, 0)

        store.append(record(itemID: "a"))
        store.appendEstimate(estimate(itemID: "a"))
        store.appendApprovalEvent(approvalEvent(itemID: "a"))
        store.appendMergeEvent(mergeEvent(itemID: "a", merged: true, execution: "e-1"))

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.records.count, 1)
        XCTAssertEqual(reloaded.estimates.count, 1)
        XCTAssertEqual(reloaded.approvalEvents.count, 1)
        XCTAssertEqual(reloaded.mergeEvents.count, 1)
        XCTAssertEqual(reloaded.undecodableMetricLineCount, 0)
        XCTAssertEqual(reloaded.undecodableEstimateLineCount, 0)
        XCTAssertEqual(reloaded.undecodableApprovalLineCount, 0)
        XCTAssertEqual(reloaded.undecodableMergeLineCount, 0)
    }

    /// A blank line is not a line the decoder ever sees — `split(separator:)`
    /// omits empty subsequences — so it must not read as a lost record.
    func testBlankLinesAreNotCountedAsUnreadable() throws {
        let store = makeStore()
        store.append(record(itemID: "a"))
        try append(raw: "\n\n\n", to: metricsURL)
        store.append(record(itemID: "b"))

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.records.map(\.itemID), ["a", "b"])
        XCTAssertEqual(reloaded.undecodableMetricLineCount, 0)
    }

    /// Bytes that are not valid UTF-8 are one unreadable line like any other,
    /// and cost only themselves. Reading the whole file as a string first made
    /// this the one kind of damage that took the ledger down with it: the read
    /// failed outright, so every record around the bad line went and the count
    /// that exists to say so read 0 — the store reporting a ledger that held
    /// nothing and nothing wrong with it.
    func testALineOfInvalidUTF8CostsOnlyItsOwnLineAndIsCounted() throws {
        let store = makeStore()
        store.append(record(itemID: "a"))
        // The leading two bytes of an em dash, a byte short of the character.
        try append(rawBytes: Data([0xE2, 0x80]) + Data("\n".utf8), to: metricsURL)
        store.append(record(itemID: "b"))

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.records.map(\.itemID), ["a", "b"],
                       "both readable lines, in file order")
        XCTAssertEqual(reloaded.undecodableMetricLineCount, 1)
        // And the ledger nobody ever wrote is still simply absent — no records,
        // and no line to have failed on.
        XCTAssertTrue(reloaded.mergeEvents.isEmpty)
        XCTAssertEqual(reloaded.undecodableMergeLineCount, 0)
    }

    /// The same damage in a second ledger, because the read is one generic
    /// function all four go through: a fix shown only for the metrics ledger
    /// would say nothing about the estimates `CostGovernor` predicts from.
    /// Here the file's *last* line is the cut one — the shape an unclean
    /// shutdown actually leaves, since it is the append in flight that is
    /// truncated.
    func testAnEstimateLedgerCutMidCharacterKeepsEveryEarlierEstimate() throws {
        let store = makeStore()
        store.appendEstimate(estimate(itemID: "a"))
        store.appendEstimate(estimate(itemID: "b"))
        // A kill part-way through an estimate whose rationale carries an em
        // dash: the line stops inside that character's three bytes, and no
        // newline follows it.
        try append(rawBytes: Data("{\"itemID\":\"cut\",\"rationale\":\"a dash ".utf8) + Data([0xE2, 0x80]),
                   to: estimatesURL)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.estimates.map(\.itemID), ["a", "b"],
                       "every estimate written before the crash")
        XCTAssertEqual(reloaded.undecodableEstimateLineCount, 1,
                       "and the cut line is reported as the one line that went")
    }

    // MARK: - Writes that never reached disk

    /// A record file inside a directory nobody may write to — the cheapest
    /// stand-in for a full disk that produces the same throw. Put back at
    /// teardown, since a directory that cannot be written cannot be emptied.
    private func unwritableURL(named name: String) throws -> URL {
        let locked = tempDir.appendingPathComponent("locked", isDirectory: true)
        if !FileManager.default.fileExists(atPath: locked.path) {
            try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
            addTeardownBlock {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
            }
        }
        return locked.appendingPathComponent(name)
    }

    /// The mirror of the undecodable-line counts, on the write side: a store
    /// whose ledger cannot be written used to return from `append` exactly as it
    /// does on success. The record stays in `records` — the live view and
    /// `MergeOutcomeFold` are unaffected — but the count says the ledger is
    /// short a line, like `RunRecordStore.failedWriteCount`.
    func testAFailedMetricWriteIsCountedAndTheLiveViewIsUnaffected() throws {
        let store = TaskMetricStore(metricsURL: try unwritableURL(named: "task-metrics.jsonl"),
                                    estimatesURL: estimatesURL, approvalsURL: approvalsURL,
                                    mergesURL: mergesURL)

        store.append(record(itemID: "a"))

        XCTAssertEqual(store.failedWriteCount, 1)
        XCTAssertEqual(store.records.map(\.itemID), ["a"], "the live view still has it")
    }

    /// The count is ledger-agnostic: a failed write on any of the other three
    /// counts the same way, since it is one disk failing whichever append was in
    /// flight, not a property of the file.
    func testAFailedEstimateWriteIsCountedTheSameWay() throws {
        let store = TaskMetricStore(metricsURL: metricsURL,
                                    estimatesURL: try unwritableURL(named: "task-estimates.jsonl"),
                                    approvalsURL: approvalsURL, mergesURL: mergesURL)

        store.appendEstimate(estimate(itemID: "a"))

        XCTAssertEqual(store.failedWriteCount, 1)
        XCTAssertEqual(store.estimates.map(\.itemID), ["a"])
    }

    /// It is a count, not a flag: two failed writes must read as 2.
    func testTwoFailedWritesAcrossLedgersReadAsTwo() throws {
        let locked = try unwritableURL(named: "task-metrics.jsonl")
        let store = TaskMetricStore(metricsURL: locked, estimatesURL: estimatesURL,
                                    approvalsURL: approvalsURL, mergesURL: mergesURL)

        store.append(record(itemID: "a"))
        store.append(record(itemID: "b"))

        XCTAssertEqual(store.failedWriteCount, 2)
    }

    /// Nothing about a writable store ticks the count — an estimate, a run
    /// record and a merge event all land, and the round trip and the fold still
    /// hold with it at zero throughout.
    func testAWritableStoreReportsNoFailedWritesAcrossLedgersAndKeepsTheRoundTrip() throws {
        let store = makeStore()

        store.appendEstimate(estimate(itemID: "a"))
        store.append(record(itemID: "a"))
        store.appendMergeEvent(mergeEvent(itemID: "a", merged: true, execution: "e-1"))

        XCTAssertEqual(store.failedWriteCount, 0)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.estimates.map(\.itemID), ["a"])
        XCTAssertEqual(reloaded.records.map(\.itemID), ["a"])
        XCTAssertEqual(reloaded.records[0].merged, true, "the merge outcome is still folded in")
        XCTAssertEqual(reloaded.failedWriteCount, 0)
    }

    // MARK: - Writes that never reached disk: the inbox

    private func makeInbox(_ name: String = "inbox") -> NotificationStore {
        NotificationStore(notificationsURL: tempDir.appendingPathComponent("\(name).log"))
    }

    /// The loss used to reach os_log and stop there, so a `~/.kiteloop` that had
    /// stopped being writable left every run's row in memory and nothing on
    /// disk — and the person found out by noticing the numbers stopped moving.
    /// Now it files a row in the inbox they already watch, naming the file,
    /// while the count and the live view are what they always were.
    func testAFailedMetricWriteFilesOneInboxRowNamingTheFile() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let locked = try unwritableURL(named: "task-metrics.jsonl")
        let store = TaskMetricStore(metricsURL: locked, estimatesURL: estimatesURL,
                                    approvalsURL: approvalsURL, mergesURL: mergesURL,
                                    reporter: reporter)

        store.append(record(itemID: "a"))
        await reporter.drain()

        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.type, .error)
        XCTAssertEqual(pending.first?.title, "Could not write Task metrics")
        XCTAssertEqual(pending.first?.body.contains(locked.path(percentEncoded: false)), true,
                       "the row names the ledger that could not be written")
        XCTAssertEqual(store.failedWriteCount, 1)
        XCTAssertEqual(store.records.map(\.itemID), ["a"], "the live view still has it")
    }

    /// One disk failing is one problem, however many ledgers it eats: the four
    /// appends share a store name, so they refresh one row rather than filing
    /// four. The count is the other half of the pair — it reads every loss.
    func testFailedAppendsAcrossAllFourLedgersHoldOneRowWhileTheCountReadsFour() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let store = TaskMetricStore(metricsURL: try unwritableURL(named: "task-metrics.jsonl"),
                                    estimatesURL: try unwritableURL(named: "task-estimates.jsonl"),
                                    approvalsURL: try unwritableURL(named: "task-approvals.jsonl"),
                                    mergesURL: try unwritableURL(named: "task-merges.jsonl"),
                                    reporter: reporter)

        store.appendEstimate(estimate(itemID: "a"))
        store.append(record(itemID: "a"))
        store.appendApprovalEvent(approvalEvent(itemID: "a"))
        store.appendMergeEvent(mergeEvent(itemID: "a", merged: true))
        await reporter.drain()

        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 1, "one disk, one row")
        XCTAssertEqual(store.failedWriteCount, 4, "and every loss counted")
    }

    /// The branch above the throw: `JSONEncoder` refuses a non-finite Double, so
    /// the record never reaches the file — and it used to log and return without
    /// counting, leaving the one number that exists to say a measurement was
    /// taken over a ledger short a line reading 0 for that loss.
    func testARecordTheEncoderRefusesIsCountedRatherThanVanishing() throws {
        let store = makeStore()

        store.append(record(itemID: "a", cost: .infinity))

        XCTAssertEqual(store.failedWriteCount, 1)
        XCTAssertEqual(try lines(of: metricsURL), [], "nothing reached the ledger")
    }

    /// The other side of it: a store that can write files nothing and counts
    /// nothing, across an estimate, a run record and a merge event.
    func testAWritableStoreFilesNothingAndKeepsTheCountAtZero() async {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let store = TaskMetricStore(metricsURL: metricsURL, estimatesURL: estimatesURL,
                                    approvalsURL: approvalsURL, mergesURL: mergesURL,
                                    reporter: reporter)

        store.appendEstimate(estimate(itemID: "a"))
        store.append(record(itemID: "a"))
        store.appendMergeEvent(mergeEvent(itemID: "a", merged: true, execution: "e-1"))
        await reporter.drain()

        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 0)
        XCTAssertEqual(store.failedWriteCount, 0)
    }

    // MARK: - summary(forSize:)

    func testSummaryForSizeAveragesDurationCostAndRetries() throws {
        let store = makeStore()
        store.append(record(itemID: "a", size: "M", duration: 400, cost: 0.20, retries: 0))
        store.append(record(itemID: "b", size: "M", duration: 600, cost: 0.40, retries: 3))
        store.append(record(itemID: "c", size: "S", duration: 100, cost: 9.00, retries: 9))

        let summary = try XCTUnwrap(store.summary(forSize: "M", projectPath: nil))
        XCTAssertEqual(summary.sampleCount, 2)
        XCTAssertEqual(summary.avgDurationSeconds, 500, accuracy: 0.001)
        XCTAssertEqual(summary.avgCostUSD, 0.30, accuracy: 0.001)
        XCTAssertEqual(summary.avgReviewerRetries, 1.5, accuracy: 0.001)
    }

    func testSummaryForSizeIsNilWhenNoRecordsMatch() {
        let store = makeStore()
        store.append(record(itemID: "a", size: "M"))

        XCTAssertNil(store.summary(forSize: "XL", projectPath: nil))
        XCTAssertNil(store.summary(forSize: "XL", projectPath: "/tmp/proj"))
    }

    func testSummaryForSizeIsNilOnAnEmptyStore() {
        XCTAssertNil(makeStore().summary(forSize: "M", projectPath: nil))
    }

    func testSummaryForSizeIsSizeMatchExactAndSkipsUnsizedRecords() throws {
        let store = makeStore()
        store.append(record(itemID: "a", size: "M", duration: 400))
        store.append(record(itemID: "b", size: nil, duration: 4000))
        // Sizes are compared as declared — "m" is not "M".
        store.append(record(itemID: "c", size: "m", duration: 4000))

        let summary = try XCTUnwrap(store.summary(forSize: "M", projectPath: nil))
        XCTAssertEqual(summary.sampleCount, 1)
        XCTAssertEqual(summary.avgDurationSeconds, 400, accuracy: 0.001)
    }

    func testSummaryForSizeUsesProjectRecordsWhenEnoughSamples() throws {
        let store = makeStore()
        for i in 0..<3 { store.append(record(itemID: "a\(i)", project: "/A", size: "M", duration: 200, cost: 0.1)) }
        store.append(record(itemID: "b0", project: "/B", size: "M", duration: 1000, cost: 1.0))

        let summary = try XCTUnwrap(store.summary(forSize: "M", projectPath: "/A", minProjectSamples: 3))
        XCTAssertEqual(summary.sampleCount, 3)
        XCTAssertEqual(summary.avgDurationSeconds, 200, accuracy: 0.001)
        XCTAssertEqual(summary.avgCostUSD, 0.1, accuracy: 0.001)
    }

    func testSummaryForSizeFallsBackToAllProjectsWhenProjectSamplesAreSparse() throws {
        let store = makeStore()
        store.append(record(itemID: "a0", project: "/A", size: "M", duration: 1000))
        store.append(record(itemID: "b0", project: "/B", size: "M", duration: 200))
        store.append(record(itemID: "b1", project: "/B", size: "M", duration: 200))

        // /A has 1 of its own (< 3) → averages over all three records.
        let summary = try XCTUnwrap(store.summary(forSize: "M", projectPath: "/A", minProjectSamples: 3))
        XCTAssertEqual(summary.sampleCount, 3)
        XCTAssertEqual(summary.avgDurationSeconds, 1400.0 / 3.0, accuracy: 0.001)
    }

    func testSummaryForSizeIgnoresProjectScopingWhenPathIsNil() throws {
        let store = makeStore()
        store.append(record(itemID: "a0", project: "/A", size: "M", duration: 300))
        store.append(record(itemID: "b0", project: "/B", size: "M", duration: 500))

        let summary = try XCTUnwrap(store.summary(forSize: "M", projectPath: nil))
        XCTAssertEqual(summary.sampleCount, 2)
        XCTAssertEqual(summary.avgDurationSeconds, 400, accuracy: 0.001)
    }

    // MARK: - latestEstimate

    func testLatestEstimateReturnsMostRecentlyAppendedForItem() throws {
        let store = makeStore()
        store.appendEstimate(estimate(itemID: "x", duration: 100, rationale: "first"))
        store.appendEstimate(estimate(itemID: "y", duration: 999, rationale: "other item"))
        store.appendEstimate(estimate(itemID: "x", duration: 300, rationale: "second"))

        let latest = try XCTUnwrap(store.latestEstimate(itemID: "x"))
        XCTAssertEqual(latest.rationale, "second")
        XCTAssertEqual(latest.predictedDurationSeconds, 300, accuracy: 0.001)
    }

    func testLatestEstimateIgnoresLaterEstimatesForOtherItems() throws {
        let store = makeStore()
        store.appendEstimate(estimate(itemID: "x", duration: 300, rationale: "mine"))
        store.appendEstimate(estimate(itemID: "y", duration: 999, rationale: "theirs"))

        let latest = try XCTUnwrap(store.latestEstimate(itemID: "x"))
        XCTAssertEqual(latest.rationale, "mine")
    }

    func testLatestEstimatePrefersAppendOrderOverCreatedAt() throws {
        let store = makeStore()
        let now = Date()
        // Backdated write lands last — "newest" means most recently appended,
        // not the largest `createdAt`.
        store.appendEstimate(estimate(itemID: "x", createdAt: now, rationale: "first"))
        store.appendEstimate(estimate(itemID: "x", createdAt: now.addingTimeInterval(-3600), rationale: "backdated"))

        let latest = try XCTUnwrap(store.latestEstimate(itemID: "x"))
        XCTAssertEqual(latest.rationale, "backdated")
    }

    func testLatestEstimateIsNilOnAnEmptyStore() {
        XCTAssertNil(makeStore().latestEstimate(itemID: "x"))
    }

    func testLatestEstimateIgnoresProjectPath() throws {
        let store = makeStore()
        store.appendEstimate(estimate(itemID: "x", project: "/A", rationale: "a"))
        store.appendEstimate(estimate(itemID: "x", project: "/B", rationale: "b"))

        // Lookup is by item id alone — the newest wins regardless of project.
        let latest = try XCTUnwrap(store.latestEstimate(itemID: "x"))
        XCTAssertEqual(latest.rationale, "b")
    }

    func testLatestEstimateIsNilForUnknownItem() {
        let store = makeStore()
        store.appendEstimate(estimate(itemID: "x"))
        XCTAssertNil(store.latestEstimate(itemID: "nope"))
    }

    func testLatestEstimateMatchesItemIDExactly() {
        let store = makeStore()
        store.appendEstimate(estimate(itemID: "item-10"))
        XCTAssertNil(store.latestEstimate(itemID: "item-1"))
        XCTAssertNotNil(store.latestEstimate(itemID: "item-10"))
    }

    func testLatestEstimateUsesAppendOrderAfterReload() throws {
        let store = makeStore()
        let now = Date()
        store.appendEstimate(estimate(itemID: "x", createdAt: now, duration: 100, rationale: "first"))
        store.appendEstimate(estimate(itemID: "x", createdAt: now.addingTimeInterval(60), duration: 300, rationale: "second"))

        let reloaded = makeStore()
        let latest = try XCTUnwrap(reloaded.latestEstimate(itemID: "x"))
        XCTAssertEqual(latest.rationale, "second")
    }

    // MARK: - latestEstimate(itemID:projectPath:)

    func testProjectScopedLatestEstimateIgnoresOtherProjects() throws {
        let store = makeStore()
        store.appendEstimate(estimate(itemID: "x", project: "/A", rationale: "mine"))
        store.appendEstimate(estimate(itemID: "x", project: "/B", rationale: "theirs"))

        // The unscoped reading takes /B's, appended last; the scoped one does not.
        XCTAssertEqual(try XCTUnwrap(store.latestEstimate(itemID: "x")).rationale, "theirs")
        let scoped = try XCTUnwrap(store.latestEstimate(itemID: "x", projectPath: "/A"))
        XCTAssertEqual(scoped.rationale, "mine")
    }

    func testProjectScopedLatestEstimateIsNilWhenOnlyAnotherProjectHasOne() {
        let store = makeStore()
        store.appendEstimate(estimate(itemID: "x", project: "/B"))

        XCTAssertNil(store.latestEstimate(itemID: "x", projectPath: "/A"))
    }

    func testProjectScopedLatestEstimateTakesTheNewestInThatProject() throws {
        let store = makeStore()
        store.appendEstimate(estimate(itemID: "x", project: "/A", rationale: "first"))
        store.appendEstimate(estimate(itemID: "x", project: "/B", rationale: "other project"))
        store.appendEstimate(estimate(itemID: "x", project: "/A", rationale: "second"))

        let scoped = try XCTUnwrap(store.latestEstimate(itemID: "x", projectPath: "/A"))
        XCTAssertEqual(scoped.rationale, "second")
    }

    func testProjectScopedLatestEstimateCanonicalisesTheProjectPath() throws {
        let store = makeStore()
        store.appendEstimate(estimate(itemID: "x", project: "/tmp/proj/", rationale: "mine"))

        // A trailing slash is how the path arrives from an NSOpenPanel URL — it
        // must not hide the project's own estimate.
        let scoped = try XCTUnwrap(store.latestEstimate(itemID: "x", projectPath: "/tmp/proj"))
        XCTAssertEqual(scoped.rationale, "mine")
    }

    // MARK: - actuals(itemID:projectPath:)

    func testActualsReturnsOnlyThatProjectsRunsOfTheItem() {
        let store = makeStore()
        store.append(record(itemID: "x", project: "/A", duration: 100))
        store.append(record(itemID: "x", project: "/B", duration: 200))
        store.append(record(itemID: "y", project: "/A", duration: 300))
        store.append(record(itemID: "x", project: "/A", duration: 400))

        let scoped = store.actuals(itemID: "x", projectPath: "/A")
        XCTAssertEqual(scoped.map(\.durationSeconds), [100, 400])
    }

    func testActualsIsEmptyWhenOnlyAnotherProjectRanTheItem() {
        let store = makeStore()
        store.append(record(itemID: "x", project: "/B"))

        XCTAssertTrue(store.actuals(itemID: "x", projectPath: "/A").isEmpty)
    }

    func testActualsCanonicalisesTheProjectPath() {
        let store = makeStore()
        store.append(record(itemID: "x", project: "/tmp/proj/", duration: 100))

        XCTAssertEqual(store.actuals(itemID: "x", projectPath: "/tmp/proj").count, 1)
    }

    // MARK: - Trailing-slash project scoping

    func testSummariesBySizeMatchARowRecordedUnderASlashedPath() throws {
        let store = makeStore()
        store.append(record(itemID: "a0", project: "/A/", size: "M", duration: 300))

        let bySize = store.summariesBySize(projectPath: "/A")
        XCTAssertEqual(bySize.count, 1)
        XCTAssertEqual(try XCTUnwrap(bySize.first).size, "M")
        XCTAssertEqual(try XCTUnwrap(bySize.first).summary.sampleCount, 1)
    }

    func testSummariesByEpicMatchARowRecordedUnderASlashedPath() throws {
        let store = makeStore()
        store.append(record(itemID: "a0", project: "/A/", epic: "Epic A", duration: 300))

        let byEpic = store.summariesByEpic(projectPath: "/A")
        XCTAssertEqual(byEpic.count, 1)
        XCTAssertEqual(try XCTUnwrap(byEpic.first).epic, "Epic A")
    }

    func testSummaryForSizeCountsOwnRowsRecordedUnderASlashedPath() throws {
        let store = makeStore()
        for i in 0..<3 { store.append(record(itemID: "a\(i)", project: "/A/", size: "M", duration: 200, cost: 0.1)) }
        store.append(record(itemID: "b0", project: "/B", size: "M", duration: 1000, cost: 1.0))

        // Without canonicalisation /A owns none of these rows and the read falls
        // through to the all-projects pool, averaging /B's run in.
        let summary = try XCTUnwrap(store.summary(forSize: "M", projectPath: "/A", minProjectSamples: 3))
        XCTAssertEqual(summary.sampleCount, 3)
        XCTAssertEqual(summary.avgDurationSeconds, 200, accuracy: 0.001)
    }

    func testCalibrationPairsASlashedRunWithItsEstimate() throws {
        let store = makeStore()
        store.appendEstimate(estimate(itemID: "x", project: "/A/", duration: 100, rationale: "a"))
        store.append(record(itemID: "x", project: "/A/", duration: 120))

        let pairs = store.calibration(projectPath: "/A")
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(try XCTUnwrap(pairs.first).estimate.rationale, "a")
    }

    // MARK: - calibration

    func testCalibrationNeverPairsARunWithAnotherProjectsEstimate() throws {
        let store = makeStore()
        store.appendEstimate(estimate(itemID: "x", project: "/A", duration: 100, rationale: "a"))
        store.appendEstimate(estimate(itemID: "x", project: "/B", duration: 900, rationale: "b"))
        store.append(record(itemID: "x", project: "/A", duration: 120))

        // /B's estimate is the newest for the id; filtering the actuals by
        // project does not stop it reaching /A's run.
        let pairs = store.calibration(projectPath: "/A")
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(try XCTUnwrap(pairs.first).estimate.rationale, "a")
    }

    func testCalibrationAcrossAllProjectsStillPairsWithinAProject() throws {
        let store = makeStore()
        store.appendEstimate(estimate(itemID: "x", project: "/A", duration: 100, rationale: "a"))
        store.appendEstimate(estimate(itemID: "x", project: "/B", duration: 900, rationale: "b"))
        store.append(record(itemID: "x", project: "/A", duration: 120))
        store.append(record(itemID: "x", project: "/B", duration: 950))

        let pairs = store.calibration(projectPath: nil)
        XCTAssertEqual(pairs.count, 2)
        for pair in pairs {
            XCTAssertEqual(pair.estimate.projectPath, pair.actual.projectPath)
        }
    }

    func testCalibrationDropsARunWhoseOnlyEstimateIsAnotherProjects() {
        let store = makeStore()
        store.appendEstimate(estimate(itemID: "x", project: "/B"))
        store.append(record(itemID: "x", project: "/A"))

        XCTAssertTrue(store.calibration(projectPath: "/A").isEmpty)
    }

    func testCalibrationLeavesOutARefusalAtPickup() throws {
        let store = makeStore()
        store.appendEstimate(estimate(itemID: "x", project: "/A", duration: 720, rationale: "a"))
        store.append(record(itemID: "x", project: "/A", duration: 600))
        store.append(record(itemID: "x", project: "/A", duration: 60,
                            outcome: TaskMetricRecord.didNotRunPrefix + "retired"))

        for path in ["/A", nil] as [String?] {
            let pairs = store.calibration(projectPath: path)
            XCTAssertEqual(pairs.count, 1)
            let actual = try XCTUnwrap(pairs.first).actual
            XCTAssertFalse(actual.didNotRun)
            XCTAssertEqual(actual.durationSeconds, 600)
        }
    }

    // MARK: - Records filtered by itemID

    func testRecordsCanBeFilteredByItemID() {
        let store = makeStore()
        store.append(record(itemID: "x", duration: 100))
        store.append(record(itemID: "y", duration: 200))
        store.append(record(itemID: "x", duration: 300))

        let forX = store.records.filter { $0.itemID == "x" }
        XCTAssertEqual(forX.count, 2)
        XCTAssertEqual(forX.map(\.durationSeconds), [100, 300])
        XCTAssertEqual(store.records.filter { $0.itemID == "z" }.count, 0)
    }

    func testLatestActualReturnsMostRecentRecordForItem() throws {
        let store = makeStore()
        store.append(record(itemID: "x", duration: 100, outcome: "failed"))
        store.append(record(itemID: "y", duration: 200))
        store.append(record(itemID: "x", duration: 300, outcome: "done"))

        let latest = try XCTUnwrap(store.latestActual(itemID: "x"))
        XCTAssertEqual(latest.durationSeconds, 300, accuracy: 0.001)
        XCTAssertEqual(latest.outcome, "done")
    }

    func testLatestActualIsNilForUnknownItem() {
        let store = makeStore()
        store.append(record(itemID: "x"))
        XCTAssertNil(store.latestActual(itemID: "nope"))
    }

    // MARK: - Attempts that never ran

    /// A pickup refusal is appended to this ledger so the retry ceiling can
    /// count it, and it is not an actual: its zeroes are the absence of an
    /// execution, so reporting them here would say the item's last attempt took
    /// no time and cost nothing.
    func testLatestActualSkipsAPickupRefusal() throws {
        let store = makeStore()
        store.append(record(itemID: "x", duration: 300, cost: 2.20))
        store.append(refusal(itemID: "x"))

        let latest = try XCTUnwrap(store.latestActual(itemID: "x"))
        XCTAssertEqual(latest.durationSeconds, 300, accuracy: 0.001)
        XCTAssertEqual(latest.costUSD, 2.20, accuracy: 0.001)
    }

    func testLatestActualIsNilForAnItemThatOnlyEverGotRefused() {
        let store = makeStore()
        store.append(refusal(itemID: "x"))

        XCTAssertNil(store.latestActual(itemID: "x"))
        XCTAssertEqual(store.records.count, 1, "the row is still on the ledger to be counted")
    }

    /// A refusal carries the item's size and epic like any other row, so it
    /// lands in these buckets — and averaging its zeroes in would report work of
    /// that size getting quicker and cheaper every time a gate turned an item
    /// away.
    func testSizeAndEpicSummariesAverageOnlyTheRunsThatRan() throws {
        let store = makeStore()
        store.append(record(itemID: "a", size: "M", duration: 400, cost: 0.20, retries: 0))
        store.append(record(itemID: "b", size: "M", duration: 600, cost: 0.40, retries: 2))
        store.append(refusal(itemID: "c"))

        let bySize = try XCTUnwrap(store.summary(forSize: "M", projectPath: nil))
        XCTAssertEqual(bySize.sampleCount, 2)
        XCTAssertEqual(bySize.avgDurationSeconds, 500, accuracy: 0.001)
        XCTAssertEqual(bySize.avgCostUSD, 0.30, accuracy: 0.001)
        XCTAssertEqual(bySize.avgReviewerRetries, 1.0, accuracy: 0.001)

        let byEpic = try XCTUnwrap(store.summariesByEpic(projectPath: nil)
            .first { $0.epic == "Epic A" }?.summary)
        XCTAssertEqual(byEpic.sampleCount, 2)
        XCTAssertEqual(byEpic.avgCostUSD, 0.30, accuracy: 0.001)
    }

    /// A size whose only rows are refusals has nothing measured about it, and
    /// that is "not measured yet" rather than "free and instant".
    func testASizeWithNothingButRefusalsHasNoSummary() {
        let store = makeStore()
        store.append(refusal(itemID: "a"))
        store.append(refusal(itemID: "b"))

        XCTAssertNil(store.summary(forSize: "M", projectPath: nil))
        XCTAssertTrue(store.summariesBySize(projectPath: nil).isEmpty)
    }

    /// The row a pickup gate writes when it refuses the item — same size and
    /// epic as the runs above it, which is what puts it in their buckets.
    private func refusal(itemID: String, project: String = "/tmp/proj") -> TaskMetricRecord {
        RetryCeiling.refusalRecord(
            item: BacklogItem(id: itemID, title: "Task \(itemID)", verify: nil, status: .ready,
                              type: .local, size: .m, queries: nil, cost: nil, completedDate: nil,
                              blockedReason: nil, jiraKey: nil, team: nil, detailPath: nil),
            refusal: .notGrounded, projectPath: project, projectName: "proj", epic: "Epic A")
    }

    func testEachAppendedRecordGetsADistinctID() {
        let store = makeStore()
        store.append(record(itemID: "x"))
        store.append(record(itemID: "x"))

        let ids = Set(store.records.map(\.id))
        XCTAssertEqual(ids.count, 2)
    }

    // MARK: - First pass (metric #3a)

    /// The whole population rule in one case: what lands in the denominator,
    /// what lands in the numerator, and what is in neither.
    func testFirstPassRateCountsOnlyTheRunsAVerdictWasReachedOn() throws {
        let store = makeStore()
        store.append(record(itemID: "a", retries: 0, outcome: "done"))
        store.append(record(itemID: "b", retries: 0, outcome: "awaiting-approval"))
        store.append(record(itemID: "c", retries: 2, outcome: "done"))
        store.append(record(itemID: "d", retries: 0, outcome: "blocked:review did not pass"))
        store.append(record(itemID: "e", retries: 0, outcome: "cancelled"))

        let rate = store.firstPassRate(projectPath: nil)

        XCTAssertEqual(rate.judged, 4, "the cancelled run is out of the denominator")
        XCTAssertEqual(rate.firstPass, 2)
        XCTAssertEqual(try XCTUnwrap(rate.rate), 0.5, accuracy: 0.0001)
    }

    /// A run cut short before any reviewer saw it is still a run review did not
    /// pass first time — otherwise a night of stalls reads as a night of clean
    /// passes.
    func testARunBlockedBeforeReviewCountsAgainstTheRate() throws {
        let store = makeStore()
        store.append(record(itemID: "a", retries: 0, outcome: "done"))
        store.append(record(itemID: "b", retries: 0,
                            outcome: "blocked:stalled: no progress for 20 min on worker"))

        let rate = store.firstPassRate(projectPath: nil)

        XCTAssertEqual(rate.judged, 2)
        XCTAssertEqual(rate.firstPass, 1)
        XCTAssertEqual(try XCTUnwrap(rate.rate), 0.5, accuracy: 0.0001)
    }

    /// Nothing judged is "not measured yet", never "nothing passes".
    func testFirstPassRateIsNilBeforeAnyRunWasJudged() {
        let store = makeStore()
        store.append(record(itemID: "a", outcome: "cancelled"))

        let rate = store.firstPassRate(projectPath: nil)

        XCTAssertEqual(rate.judged, 0)
        XCTAssertEqual(rate.firstPass, 0)
        XCTAssertNil(rate.rate)
    }

    // MARK: - Merge outcomes

    /// The fix this store exists to carry: a run's row is written when the run
    /// ends, and whether its work landed is decided afterwards. The outcome
    /// arrives as its own line and is folded onto the run on the way out.
    func testAMergeOutcomeFoldsOntoTheRunItDescribes() {
        let store = makeStore()
        store.append(record(itemID: "a"))
        XCTAssertNil(store.records[0].merged, "nothing has said yet")

        store.appendMergeEvent(mergeEvent(itemID: "a", merged: true, execution: "e-1"))

        XCTAssertEqual(store.records[0].merged, true)
    }

    /// The ledger stays append-only. The outcome is a *new line in another log*,
    /// never a rewrite of the run's row — which still holds exactly what the run
    /// knew about itself when it ended, with no `merged` key at all.
    func testRecordingAnOutcomeDoesNotRewriteTheRunsLog() throws {
        let store = makeStore()
        store.append(record(itemID: "a"))
        let before = try lines(of: metricsURL)

        store.appendMergeEvent(mergeEvent(itemID: "a", merged: true, execution: "e-1"))

        XCTAssertEqual(try lines(of: metricsURL), before, "the run's log is byte-for-byte what it was")
        XCTAssertEqual(before.count, 1, "and no second row was appended in its place")
        let row = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(try XCTUnwrap(before.first).utf8)) as? [String: Any])
        XCTAssertNil(row["merged"])
        XCTAssertEqual(try lines(of: mergesURL).count, 1, "the outcome went to its own log")
    }

    /// The auto-merge decides *inside* the run, so its outcome is recorded before
    /// the run's row exists. The event names the execution, and the join happens
    /// when the row lands.
    func testAnOutcomeRecordedBeforeTheRunsRowFoldsWhenTheRowLands() {
        let store = makeStore()
        store.appendMergeEvent(mergeEvent(itemID: "a", merged: true, execution: "e-1"))
        XCTAssertTrue(store.records.isEmpty)

        store.append(record(itemID: "a"))

        XCTAssertEqual(store.records[0].merged, true)
    }

    func testMergeOutcomesSurviveReload() {
        let store = makeStore()
        store.append(record(itemID: "a"))
        store.append(record(itemID: "b"))
        store.appendMergeEvent(mergeEvent(itemID: "a", merged: true, execution: "e-1"))

        let reloaded = makeStore()

        XCTAssertEqual(reloaded.mergeEvents.map(\.itemID), ["a"])
        XCTAssertEqual(reloaded.records.first { $0.itemID == "a" }?.merged, true)
    }

    /// Nil keeps meaning unknown. A run whose gate nobody has resolved — most of
    /// them, at any moment — must not read as one that failed to merge.
    func testARunWithNoRecordedOutcomeStaysUnknown() {
        let store = makeStore()
        store.append(record(itemID: "a"))
        store.append(record(itemID: "b"))

        store.appendMergeEvent(mergeEvent(itemID: "a", merged: false, execution: "e-1"))

        XCTAssertEqual(store.records.first { $0.itemID == "a" }?.merged, false,
                       "decided, and the answer was no")
        XCTAssertNil(store.records.first { $0.itemID == "b" }?.merged, "nobody said")
    }

    /// Records written before any of this existed decode unchanged and read as
    /// unknown — the back-compat the `merged` field always documented.
    func testARecordWrittenBeforeMergeOutcomesExistedReadsAsUnknown() throws {
        try Data("""
        {"id":"old-1","projectPath":"/tmp/proj","projectName":"proj","itemID":"old",\
        "title":"Old","startedAt":"2026-01-01T00:00:00Z","completedAt":"2026-01-01T00:10:00Z",\
        "durationSeconds":600,"costUSD":1,"reviewerRetries":0,"outcome":"done"}

        """.utf8).write(to: metricsURL)

        let store = makeStore()

        XCTAssertEqual(store.records.map(\.itemID), ["old"])
        XCTAssertNil(store.records[0].merged)
    }

    /// Scoped like the defect rate beside it, and by canonical path — a record
    /// keeps the raw root it was written with, so a trailing slash must not hide
    /// a project's own runs from its own rate.
    func testFirstPassRateIsScopedByCanonicalProjectPath() throws {
        let store = makeStore()
        store.append(record(itemID: "a", project: "/tmp/alpha/", retries: 0, outcome: "done"))
        store.append(record(itemID: "b", project: "/tmp/beta", retries: 0, outcome: "done"))
        store.append(record(itemID: "c", project: "/tmp/beta", retries: 4, outcome: "done"))

        let alpha = store.firstPassRate(projectPath: "/tmp/alpha")
        XCTAssertEqual(alpha.judged, 1)
        XCTAssertEqual(try XCTUnwrap(alpha.rate), 1.0, accuracy: 0.0001)

        let beta = store.firstPassRate(projectPath: "/tmp/beta")
        XCTAssertEqual(beta.judged, 2)
        XCTAssertEqual(try XCTUnwrap(beta.rate), 0.5, accuracy: 0.0001)
    }

    // MARK: - Insights detail line

    private func summary(samples: Int, retries: Double) -> TaskMetricSummary {
        TaskMetricSummary(sampleCount: samples, avgDurationSeconds: 600, avgCostUSD: 2.27, avgReviewerRetries: retries)
    }

    func testInsightsDetailSaysNoReworkForAZeroAverage() {
        XCTAssertEqual(summary(samples: 4, retries: 0).insightsDetail, "$2.27 · no rework · 4 runs")
    }

    func testInsightsDetailSaysNoReworkWhenTheAverageRoundsToZero() {
        XCTAssertEqual(summary(samples: 4, retries: 0.04).insightsDetail, "$2.27 · no rework · 4 runs")
    }

    func testInsightsDetailUsesTheSingularForAnAverageOfOne() {
        XCTAssertEqual(summary(samples: 4, retries: 1).insightsDetail, "$2.27 · 1 rework loop · 4 runs")
    }

    func testInsightsDetailShowsOneDecimalForAFractionalAverage() {
        XCTAssertEqual(summary(samples: 4, retries: 1.5).insightsDetail, "$2.27 · 1.5 rework loops · 4 runs")
    }

    func testInsightsDetailUsesTheSingularRunForOneSample() {
        XCTAssertEqual(summary(samples: 1, retries: 2).insightsDetail, "$2.27 · 2.0 rework loops · 1 run")
    }
}
