import XCTest
import KiteloopCore
@testable import Kiteloop

/// Run records outliving the app that made them.
///
/// A headless driver keys everything on the `runId` it was handed. That id used
/// to be a key into a dictionary that died with the process: restart the app and
/// `GET /v1/runs/{id}/result` answered 404 for work that had merged, or was
/// sitting at its approval gate with the item still there in the backlog file.
/// These tests exercise the durable half — the record written at finalization,
/// read back at launch, and the interruption a restart leaves behind.
///
/// The store tests run against a temp file directly; the API tests run a second
/// server over the same file, which is what a restart actually is.
@MainActor
final class KiteloopControlServerRunHistoryTests: XCTestCase {

    private var tempDir: URL!
    private var recordsURL: URL!
    private var registry: ControlSessionRegistry!
    /// The servers `startServer` bound to a port, each with its client.
    private var harnesses: [ControlServerHarness] = []
    /// The servers `makeServer` built and never started.
    private var servers: [KiteloopControlServer] = []
    private let token = "control-history-token-" + UUID().uuidString

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-history")
        recordsURL = tempDir.appendingPathComponent("control-runs.jsonl")
        registry = ControlSessionRegistry()
    }

    override func tearDown() async throws {
        harnesses.forEach { $0.stop() }
        harnesses = []
        servers.forEach { $0.stop() }
        servers = []
        registry = nil
    }

    // MARK: - The store

    /// The acceptance criterion, at the level it is actually decided: a finalized
    /// record survives being written and read back by a different instance. Every
    /// field the API answers from has to make the trip, not just the outcome —
    /// the cost and the pull request are most of why a driver comes back for a
    /// finished run at all.
    func testFinalizedRecordRoundTripsThroughPersistenceAndReload() throws {
        // Relative to now, not a fixed epoch. The store prunes anything older
        // than `retentionAge` on load, so a hard-coded date silently ages out of
        // the window and the reload finds nothing — these tests began failing on
        // 2026-03-04 for that reason alone, five months before anyone ran them.
        let started = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3600).rounded())
        var record = PersistedRunRecord(runId: "run-1", projectID: "/tmp/alpha", itemID: "item-1",
                                        title: "Ship the thing", startedAt: started)
        record.endedAt = started.addingTimeInterval(412)
        record.outcome = .awaitingApproval
        record.durationSec = 412
        record.itemStatus = "awaiting-approval"
        record.branch = "kiteloop/item-1"
        record.pullRequestURL = "https://github.com/acme/kiteloop/pull/42"
        record.costUSD = 2.13
        record.costCapUSD = 4.50
        record.predictionSource = "own history"
        record.qualityScore = 0.86
        record.judgeDimensions = ["scope_respected": 1.0, "tests_meaningful": 0.8]
        RunRecordStore(url: recordsURL).upsert(record)

        let reloaded = try XCTUnwrap(RunRecordStore(url: recordsURL).record(runId: "run-1"))

        XCTAssertEqual(reloaded, record, "every field a driver reads has to survive the trip")
    }

    /// The closing line supersedes the opening one — the file is a log, not a
    /// table, and the last word about a run is the one that counts.
    func testClosingLineSupersedesTheOpeningOne() throws {
        let store = RunRecordStore(url: recordsURL)
        store.upsert(openRecord(runId: "run-1"))
        var closed = openRecord(runId: "run-1")
        closed.outcome = .done
        closed.durationSec = 90
        store.upsert(closed)

        let reloaded = try XCTUnwrap(RunRecordStore(url: recordsURL).record(runId: "run-1"))

        XCTAssertEqual(reloaded.outcome, .done)
        XCTAssertEqual(reloaded.durationSec, 90)
        XCTAssertEqual(RunRecordStore(url: recordsURL).records.count, 1, "one record per run, not one per line")
    }

    /// A record still open when it is read back belongs to a process that is
    /// gone: nothing else could have left it that way, because the server writes
    /// a closing line for every ending it knows how to reach.
    func testRecordStillOpenAtLaunchReadsAsInterrupted() throws {
        RunRecordStore(url: recordsURL).upsert(openRecord(runId: "run-1"))

        let reloaded = try XCTUnwrap(RunRecordStore(url: recordsURL).record(runId: "run-1"))

        XCTAssertEqual(reloaded.outcome, .interrupted)
        // No end time and no duration invented for it: nobody watched it finish,
        // and a made-up number here is worse than an absent one.
        XCTAssertNil(reloaded.endedAt)
        XCTAssertNil(reloaded.durationSec)
    }

    /// And it stays interrupted. A second restart must not re-open the question —
    /// the interruption is written back, so the file says what the API says.
    func testAnInterruptionIsWrittenBackAndSurvivesTheNextLaunch() throws {
        RunRecordStore(url: recordsURL).upsert(openRecord(runId: "run-1"))
        _ = RunRecordStore(url: recordsURL)   // the launch that closes it

        let contents = try String(contentsOf: recordsURL, encoding: .utf8)

        XCTAssertTrue(contents.contains("\"outcome\":\"interrupted\""))
        XCTAssertEqual(RunRecordStore(url: recordsURL).record(runId: "run-1")?.outcome, .interrupted)
    }

    /// Launch cost stays flat however long the app has been in use: the newest
    /// `retentionLimit` runs are kept and the rest go.
    func testHistoryIsBoundedByCount() throws {
        let store = RunRecordStore(url: recordsURL)
        // Relative to now, not a fixed epoch. The store prunes anything older
        // than `retentionAge` on load, so a hard-coded date silently ages out of
        // the window and the reload finds nothing — these tests began failing on
        // 2026-03-04 for that reason alone, five months before anyone ran them.
        let base = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - Double(RunRecordStore.retentionLimit + 60)).rounded())
        for index in 0..<(RunRecordStore.retentionLimit + 20) {
            var record = openRecord(runId: "run-\(index)", startedAt: base.addingTimeInterval(Double(index)))
            record.outcome = .done
            store.upsert(record)
        }

        let reloaded = RunRecordStore(url: recordsURL)

        XCTAssertEqual(reloaded.records.count, RunRecordStore.retentionLimit)
        XCTAssertNil(reloaded.record(runId: "run-0"), "the oldest runs are the ones dropped")
        XCTAssertNotNil(reloaded.record(runId: "run-\(RunRecordStore.retentionLimit + 19)"))
    }

    /// The other bound: an idle install never hits the count, so age retires its
    /// history instead.
    func testHistoryIsBoundedByAge() throws {
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let staleStart = now.addingTimeInterval(-RunRecordStore.retentionAge - 60)
        // Both are written while both are still inside the window, so what the
        // reload drops is the load path's doing. The sibling below is the same
        // bound on the write path.
        let store = RunRecordStore(url: recordsURL, clock: { staleStart })
        var stale = openRecord(runId: "stale", startedAt: staleStart)
        stale.outcome = .done
        var recent = openRecord(runId: "recent", startedAt: now.addingTimeInterval(-60))
        recent.outcome = .done
        store.upsert(stale)
        store.upsert(recent)

        let reloaded = RunRecordStore(url: recordsURL, clock: { now })

        XCTAssertNil(reloaded.record(runId: "stale"))
        XCTAssertNotNil(reloaded.record(runId: "recent"))
    }

    /// The same bound without the relaunch — which is the only way an always-running
    /// Kiteloop ever meets it. The age cutoff used to be applied by `load` alone, so
    /// an app left up for weeks (the normal way it runs) kept serving records months
    /// past `retentionAge` from `GET /v1/runs` until someone quit it.
    func testARecordAgingOutIsDroppedByTheNextWriteWithoutARelaunch() throws {
        var clockNow = Date(timeIntervalSince1970: 1_770_000_000)
        let started = clockNow
        let store = RunRecordStore(url: recordsURL, clock: { clockNow })
        var early = openRecord(runId: "early", startedAt: started)
        early.outcome = .done
        store.upsert(early)

        // Weeks pass with the same process still up, and then another run lands.
        clockNow = started.addingTimeInterval(RunRecordStore.retentionAge + 60)
        var later = openRecord(runId: "later", startedAt: clockNow)
        later.outcome = .done
        store.upsert(later)

        XCTAssertNil(store.record(runId: "early"), "it aged out, and no relaunch came to notice")
        XCTAssertNotNil(store.record(runId: "later"))
        // Memory and the file stay in step: reloading finds the same set, and does
        // not resurrect what the trim dropped.
        let reloaded = RunRecordStore(url: recordsURL, clock: { clockNow })
        XCTAssertEqual(reloaded.records.map(\.runId), ["later"])
    }

    /// Both bounds at once, with each record leaving for exactly one reason: the
    /// oldest ten are past the age, the ten after them past the count. Trimming for
    /// age with a count computed before it would take twenty too many.
    func testBothBoundsTogetherDropEachRecordOnce() throws {
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let store = RunRecordStore(url: recordsURL, clock: { now })
        let total = RunRecordStore.retentionLimit + 20
        for index in 0..<total {
            let startedAt = index < 10
                ? now.addingTimeInterval(-RunRecordStore.retentionAge - Double(60 - index))
                : now.addingTimeInterval(-Double(total - index))
            var record = openRecord(runId: "run-\(index)", startedAt: startedAt)
            record.outcome = .done
            store.upsert(record)
        }

        XCTAssertEqual(store.records.count, RunRecordStore.retentionLimit)
        XCTAssertNil(store.record(runId: "run-0"), "aged out")
        XCTAssertNil(store.record(runId: "run-19"), "inside the window, but past the count")
        XCTAssertNotNil(store.record(runId: "run-20"))
        XCTAssertEqual(RunRecordStore(url: recordsURL, clock: { now }).records.map(\.runId),
                       store.records.map(\.runId), "the file matches memory after a trim")
    }

    /// The other side of the trim: a store inside both bounds writes exactly what it
    /// wrote before. Each `upsert` is still an append — the file keeps the opening
    /// line as well as the closing one, and is collapsed at load, not at write.
    func testAWriteInsideBothBoundsAppendsAsBefore() throws {
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let store = RunRecordStore(url: recordsURL, clock: { now })
        let startedAt = now.addingTimeInterval(-3600)
        store.upsert(openRecord(runId: "run-1", startedAt: startedAt))
        var closed = openRecord(runId: "run-1", startedAt: startedAt)
        closed.outcome = .done
        store.upsert(closed)
        var second = openRecord(runId: "run-2", startedAt: startedAt.addingTimeInterval(60))
        second.outcome = .done
        store.upsert(second)

        XCTAssertEqual(store.records.map(\.runId), ["run-1", "run-2"])
        let lines = try String(contentsOf: recordsURL, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 3, "three writes, three appended lines — nothing was rewritten")
        XCTAssertEqual(RunRecordStore(url: recordsURL, clock: { now }).record(runId: "run-1")?.outcome, .done)
    }

    // MARK: - Lines that cannot be read

    /// The shape a kill mid-append leaves: `appendLine` writes through a
    /// `FileHandle` with no atomicity, so the last line is half a JSON object.
    /// Everything written before it still loads, and the store says out loud that
    /// one line was unreadable rather than swallowing it.
    func testATruncatedLastLineIsCountedAndCostsNoRecords() throws {
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let store = RunRecordStore(url: recordsURL, clock: { now })
        var done = openRecord(runId: "run-1", startedAt: now.addingTimeInterval(-3600))
        done.outcome = .done
        store.upsert(done)
        try append(truncatedLine, terminated: false)

        let reloaded = RunRecordStore(url: recordsURL, clock: { now })

        XCTAssertEqual(reloaded.records.map(\.runId), ["run-1"])
        XCTAssertEqual(reloaded.record(runId: "run-1")?.outcome, .done)
        XCTAssertEqual(reloaded.undecodableLineCount, 1, "the line nobody could read is reported, not dropped in silence")
    }

    /// And the records after it. A single bad line in the middle of the file used
    /// to be harmless only by luck of where it landed; it has to stay harmless.
    func testAnUndecodableLineDoesNotStopTheRecordsAfterIt() throws {
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let started = now.addingTimeInterval(-3600)
        try append(jsonLine(runId: "run-1", startedAt: started))
        try append(truncatedLine)
        try append(jsonLine(runId: "run-2", startedAt: started.addingTimeInterval(60)))

        let reloaded = RunRecordStore(url: recordsURL, clock: { now })

        XCTAssertEqual(reloaded.records.map(\.runId), ["run-1", "run-2"], "the reader carries on past what it cannot read")
        XCTAssertEqual(reloaded.undecodableLineCount, 1)
    }

    /// The half of the bug that actually destroyed history: `load` usually leads to
    /// a `rewrite()`, and a rewrite built from the records alone erases the line
    /// that failed to decode — on the same launch that failed to read it. It goes
    /// back into the file exactly as it came out.
    func testCompactionKeepsTheLineItCouldNotRead() throws {
        var clockNow = Date(timeIntervalSince1970: 1_770_000_000)
        let store = RunRecordStore(url: recordsURL, clock: { clockNow })
        var early = openRecord(runId: "early", startedAt: clockNow)
        early.outcome = .done
        store.upsert(early)
        try append(truncatedLine, terminated: false)

        // A launch that reads the bad line, then a write weeks later that ages
        // `early` out — the trim is what calls `rewrite()`.
        let reloaded = RunRecordStore(url: recordsURL, clock: { clockNow })
        XCTAssertEqual(reloaded.undecodableLineCount, 1)
        clockNow = clockNow.addingTimeInterval(RunRecordStore.retentionAge + 60)
        var later = openRecord(runId: "later", startedAt: clockNow)
        later.outcome = .done
        reloaded.upsert(later)

        let lines = try String(contentsOf: recordsURL, encoding: .utf8).split(separator: "\n")
        XCTAssertNil(reloaded.record(runId: "early"), "the trim happened, so the file was rewritten")
        XCTAssertEqual(lines.last.map(String.init), truncatedLine, "byte for byte, after the records")
        // And it is still there — and still counted — for the launch after that.
        XCTAssertEqual(RunRecordStore(url: recordsURL, clock: { clockNow }).undecodableLineCount, 1)
    }

    /// The ordinary file is untouched by any of this: same records, same collapse
    /// to one per run, a count of zero, and nothing appended that wasn't a record.
    func testAFileWithNothingUnreadableIsUnchanged() throws {
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let startedAt = now.addingTimeInterval(-3600)
        let store = RunRecordStore(url: recordsURL, clock: { now })
        store.upsert(openRecord(runId: "run-1", startedAt: startedAt))
        var closed = openRecord(runId: "run-1", startedAt: startedAt)
        closed.outcome = .done
        store.upsert(closed)

        let reloaded = RunRecordStore(url: recordsURL, clock: { now })

        XCTAssertEqual(reloaded.records.map(\.runId), ["run-1"], "two lines, one run")
        XCTAssertEqual(reloaded.undecodableLineCount, 0)
        // The launch collapsed the file, and wrote back the one record and no more.
        let lines = try String(contentsOf: recordsURL, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("\"runId\":\"run-1\""))
    }

    // MARK: - Writes that never reached the file

    /// The mirror of the undecodable-line count, on the write side. A store whose
    /// file cannot be written used to return from `upsert` exactly as it does on
    /// success — the run sat in `records` and nothing was on disk, so the next
    /// launch answered 404 for work that had merged. It says so now, and the live
    /// view is still whole: the count is what changed, not the records.
    func testAWriteThatCannotReachTheFileIsCounted() throws {
        let store = RunRecordStore(url: try unwritableRecordsURL())
        var done = openRecord(runId: "run-1")
        done.outcome = .done

        store.upsert(done)

        XCTAssertEqual(store.failedWriteCount, 1, "the write that never landed is reported, not swallowed")
        XCTAssertEqual(store.record(runId: "run-1"), done, "the live view is unaffected — only the file is missing it")
    }

    /// It is a count, not a flag: a directory that stays unwritable loses every
    /// record written into it, and a store that reported "1" after ten of them
    /// would understate the hole by nine.
    func testASecondFailedWriteIncrementsTheCount() throws {
        let store = RunRecordStore(url: try unwritableRecordsURL())
        var first = openRecord(runId: "run-1")
        first.outcome = .done
        var second = openRecord(runId: "run-2")
        second.outcome = .done

        store.upsert(first)
        store.upsert(second)

        XCTAssertEqual(store.failedWriteCount, 2)
    }

    /// And nothing about the ordinary file counts as a failure — the line that
    /// creates it, an append onto it, and the whole-file rewrite a trim asks for.
    /// A count that ticked on a healthy store would make the number meaningless.
    func testAWritableStoreReportsNoFailedWrites() throws {
        var clockNow = Date(timeIntervalSince1970: 1_770_000_000)
        let store = RunRecordStore(url: recordsURL, clock: { clockNow })
        var early = openRecord(runId: "early", startedAt: clockNow)
        early.outcome = .done
        store.upsert(early)                       // creates the file
        store.upsert(openRecord(runId: "run-2", startedAt: clockNow))   // appends onto it

        // Weeks on, a write that ages `early` out — the trim is what rewrites.
        clockNow = clockNow.addingTimeInterval(RunRecordStore.retentionAge + 60)
        var later = openRecord(runId: "later", startedAt: clockNow)
        later.outcome = .done
        store.upsert(later)

        XCTAssertNil(store.record(runId: "early"), "the trim happened, so the rewrite ran")
        XCTAssertEqual(store.failedWriteCount, 0)
        XCTAssertEqual(RunRecordStore(url: recordsURL, clock: { clockNow }).failedWriteCount, 0,
                       "including the rewrite the next launch asks for")
    }

    // MARK: - Across a restart

    /// The whole point, end to end: run it, land it, restart, ask again. The
    /// driver's `runId` still answers — with the outcome, the branch and the bill,
    /// not a 404.
    func testFinishedRunAnswersAfterARestart() async throws {
        let (first, firstPort) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | awaiting-approval")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        first.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                          title: "Ship the thing", startedAt: Date()))
        land(autopilot, itemId: "item-1", title: "Ship the thing",
             outcome: .awaitingApproval, branch: "kiteloop/item-1")
        // The request that finalizes the run — and, now, writes it down.
        let (liveStatus, liveBody) = try await get("/v1/runs/run-1/result", port: firstPort)
        XCTAssertEqual(liveStatus, 200)
        XCTAssertEqual(liveBody["historical"] as? Bool, false)

        // The restart: a new process, a new registry, nothing open, the same file.
        registry = ControlSessionRegistry()
        let (_, secondPort) = try await startServer()

        let (status, body) = try await get("/v1/runs/run-1/result", port: secondPort)

        XCTAssertEqual(status, 200, "a runId that outlived the app must not 404")
        XCTAssertEqual(body["historical"] as? Bool, true)
        XCTAssertEqual(body["state"] as? String, "finished")
        XCTAssertEqual(body["outcome"] as? String, "awaiting_approval")
        XCTAssertEqual(body["branch"] as? String, "kiteloop/item-1")
        XCTAssertEqual(body["durationSec"] as? Int, 42)
        // Read from the record, since the project it belonged to isn't open.
        XCTAssertEqual(body["itemStatus"] as? String, "awaiting-approval")
    }

    /// `GET /v1/runs` after a restart, with the finished run in it and marked as
    /// what it is — a driver that lost its id has to be able to find the run, and
    /// to tell a record from something still moving.
    func testListingAfterARestartCarriesTheRunMarkedHistorical() async throws {
        let (first, firstPort) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | done")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        first.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                          title: "Ship the thing", startedAt: Date()))
        land(autopilot, itemId: "item-1", title: "Ship the thing", outcome: .done)
        _ = try await get("/v1/runs/run-1/result", port: firstPort)

        registry = ControlSessionRegistry()
        let (_, secondPort) = try await startServer()

        let (status, body) = try await get("/v1/runs", port: secondPort)

        XCTAssertEqual(status, 200)
        let runs = try XCTUnwrap(body["runs"] as? [[String: Any]])
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0]["runId"] as? String, "run-1")
        XCTAssertEqual(runs[0]["historical"] as? Bool, true)
        XCTAssertEqual(runs[0]["state"] as? String, "finished")
        XCTAssertEqual(runs[0]["outcome"] as? String, "done")
        // Derived from the stored path, so a closed project is still named.
        XCTAssertEqual(runs[0]["project"] as? String, "alpha")
    }

    /// A run that was live when the app stopped never reached an ending. It reads
    /// `interrupted` — not `finished`, which would claim an outcome nobody
    /// recorded, and not 404, which is what sent drivers looking for work that
    /// had already merged.
    func testRunLiveAtTheRestartReadsAsInterrupted() async throws {
        let (first, _) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | active")
        // Tracked and never finalized — the app died under it.
        first.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                          title: "Ship the thing", startedAt: Date()))

        registry = ControlSessionRegistry()
        let (_, secondPort) = try await startServer()

        let (status, body) = try await get("/v1/runs/run-1/result", port: secondPort)

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["state"] as? String, "interrupted")
        XCTAssertEqual(body["historical"] as? Bool, true)
        XCTAssertNil(body["outcome"], "an interruption is not an outcome the run reached")
        XCTAssertNil(body["durationSec"])
        XCTAssertNil(body["endedAt"], "it reached no ending, so there is no time to report — absent, not null")
    }

    /// The backlog is the live truth about where the item stands and it outlives
    /// the run, so a reopened project answers from the file rather than from
    /// whatever the record froze. Here the item was approved by hand after the
    /// restart.
    func testReopenedProjectReportsTheItemsCurrentStatusNotTheFrozenOne() async throws {
        let (first, firstPort) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | awaiting-approval")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        first.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                          title: "Ship the thing", startedAt: Date()))
        land(autopilot, itemId: "item-1", title: "Ship the thing", outcome: .awaitingApproval)
        _ = try await get("/v1/runs/run-1/result", port: firstPort)

        registry = ControlSessionRegistry()
        let (_, secondPort) = try await startServer()
        try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | done")

        let (_, body) = try await get("/v1/runs/run-1/result", port: secondPort)

        XCTAssertEqual(body["itemStatus"] as? String, "done", "the file moved on; the record didn't")
        XCTAssertEqual(body["outcome"] as? String, "awaiting_approval", "how the run ended is still how it ended")
    }

    /// `GET /v1/runs/{id}` answers for a historical run too, with an empty event
    /// list: bus history isn't durable, and this endpoint has never promised more
    /// than the last 20 events.
    func testStatusEndpointAnswersForAHistoricalRun() async throws {
        try await landAndRestart()
        let (_, port) = try await startServer()

        let (status, body) = try await get("/v1/runs/run-1", port: port)

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["historical"] as? Bool, true)
        XCTAssertEqual(body["outcome"] as? String, "done")
        XCTAssertEqual((body["events"] as? [[String: Any]])?.count, 0)
        XCTAssertNil(body["autopilot"], "no project open, so there is no autopilot to report")
    }

    /// The endpoints that only mean something for a live run say so, and say
    /// which run they mean. A 404 there would be the old lie in a new place: the
    /// id is real, and the server can prove it.
    func testLiveOnlyEndpointsRefuseAHistoricalRunWithA409() async throws {
        try await landAndRestart()
        let (_, port) = try await startServer()

        for path in ["/v1/runs/run-1/events", "/v1/runs/run-1/log"] {
            let (status, body) = try await get(path, port: port)
            XCTAssertEqual(status, 409, "\(path) should refuse, not deny the run exists")
            XCTAssertTrue((body["error"] as? String)?.contains("finished and not live") == true,
                          "\(path): \(body["error"] ?? "no error")")
        }
        let (cancelStatus, _) = try await post("/v1/runs/run-1/cancel", port: port)
        XCTAssertEqual(cancelStatus, 409)
        // Approving points at the path that does still work — the item's own gate.
        let (approveStatus, approveBody) = try await post("/v1/runs/run-1/approve", port: port)
        XCTAssertEqual(approveStatus, 409)
        XCTAssertTrue((approveBody["error"] as? String)?.contains("POST /v1/backlog/approve") == true,
                      approveBody["error"] as? String ?? "no error")
    }

    /// The line the whole feature has to stay behind: an id nothing ever issued
    /// is still unknown. Persistence answers for runs that happened, not for
    /// anything a caller cares to type.
    func testUnknownRunIdStill404s() async throws {
        try await landAndRestart()
        let (_, port) = try await startServer()

        for path in ["/v1/runs/nope", "/v1/runs/nope/result", "/v1/runs/nope/log", "/v1/runs/nope/events"] {
            let (status, body) = try await get(path, port: port)
            XCTAssertEqual(status, 404, path)
            XCTAssertEqual(body["error"] as? String, "Unknown run: nope", path)
        }
    }

    /// A server with no store attached is the server every other test builds, and
    /// it must keep behaving exactly as it did — no writes into the developer's
    /// real history, and the same 404 as before.
    func testServerWithoutAStoreKeepsTheOldBehaviour() async throws {
        let (_, port) = try await startServer(attachStore: false)

        let (status, _) = try await get("/v1/runs/run-1/result", port: port)

        XCTAssertEqual(status, 404)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordsURL.path(percentEncoded: false)))
    }

    // MARK: - When the run ended

    /// The gap this closes: `endedAt` was written on every closing record and
    /// emitted from exactly one place — the historical readout — so a driver
    /// polling a run to its end was told when it ended only after the app had
    /// been restarted. `durationSec` is no substitute: it is the autopilot's
    /// measure of the item, not the wall clock between `startedAt` and the close,
    /// so a night read back the next morning could not be laid against the app's
    /// logs.
    func testRunFinishedInThisSessionReportsWhenItEnded() async throws {
        let (server, port) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | done")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                           title: "Ship the thing", startedAt: Date()))
        land(autopilot, itemId: "item-1", title: "Ship the thing", outcome: .done)

        let (status, body) = try await get("/v1/runs/run-1/result", port: port)

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["historical"] as? Bool, false, "the process that ran it is still up")
        let closed = try XCTUnwrap(RunRecordStore(url: recordsURL).record(runId: "run-1")?.endedAt)
        XCTAssertEqual(body["endedAt"] as? String, ISO8601DateFormatter().string(from: closed),
                       "the instant the record was closed at, not a fresh reading of the clock")
    }

    /// And `GET /v1/runs/{id}` says it too: that is the endpoint a poll loop with
    /// a runId sits on, and being told the ending only by a sibling endpoint is
    /// the same gap one endpoint further along.
    func testTheStatusOfARunFinishedInThisSessionReportsWhenItEnded() async throws {
        let (server, port) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | done")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                           title: "Ship the thing", startedAt: Date()))
        land(autopilot, itemId: "item-1", title: "Ship the thing", outcome: .done)

        let (status, body) = try await get("/v1/runs/run-1", port: port)

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["historical"] as? Bool, false)
        let closed = try XCTUnwrap(RunRecordStore(url: recordsURL).record(runId: "run-1")?.endedAt)
        XCTAssertEqual(body["endedAt"] as? String, ISO8601DateFormatter().string(from: closed))
    }

    /// The claim in full: one run reports one instant, whoever is asked. Reading
    /// the ending off the durable record on both sides is what makes that true —
    /// a fresh `Date()` on the live side would have the same run reporting a
    /// later ending before the restart than after it.
    func testTheEndingTimeIsIdenticalBeforeAndAfterARestart() async throws {
        let (first, firstPort) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | done")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        first.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                          title: "Ship the thing", startedAt: Date()))
        land(autopilot, itemId: "item-1", title: "Ship the thing", outcome: .done)
        let (_, live) = try await get("/v1/runs/run-1/result", port: firstPort)

        registry = ControlSessionRegistry()
        let (_, secondPort) = try await startServer()
        let (status, historical) = try await get("/v1/runs/run-1/result", port: secondPort)

        XCTAssertEqual(status, 200)
        XCTAssertNotNil(live["endedAt"], "the live readout is the one that used to have none")
        XCTAssertEqual(live["endedAt"] as? String, historical["endedAt"] as? String,
                       "the same run ended once, so both readouts report the one instant")
    }

    /// A run still working has not ended, and neither the 202 nor the status it
    /// is polled with may put a time on it — absent, never null. Its record is no
    /// way in either: `track` opens one as the run begins and an open record
    /// holds no ending.
    func testRunStillWorkingReportsNoEndingTime() async throws {
        let (server, port) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Working | active")
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                           title: "Working", startedAt: Date()))

        let (pendingStatus, pending) = try await get("/v1/runs/run-1/result", port: port)
        let (_, live) = try await get("/v1/runs/run-1", port: port)
        let (_, listing) = try await get("/v1/runs", port: port)

        XCTAssertEqual(pendingStatus, 202, "it is still in flight")
        XCTAssertNil(pending["endedAt"])
        XCTAssertNil(live["endedAt"])
        XCTAssertNil(try XCTUnwrap((listing["runs"] as? [[String: Any]])?.first)["endedAt"])
        XCTAssertNil(RunRecordStore(url: recordsURL).record(runId: "run-1")?.endedAt,
                     "the record it would have been read from is still open")
    }

    // MARK: - Which execution the run turned out to be

    /// The night nobody watched. The scheduler mints an `auto-…` id before any
    /// workflow exists to name the run after, but everything the run leaves
    /// behind is filed under the execution it became — transcripts at
    /// `.kiteloop/transcripts/<executionID>/`, and the metric record `GET
    /// /v1/metrics` reports the execution id as its own `runId`. A record that
    /// dropped that id could be joined to neither once the process was gone.
    func testSchedulerOpenedRunRecordsTheExecutionItTurnedOutToBe() async throws {
        let (server, firstPort) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | done")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        let runId = server.openRun(projectID: projectID, itemID: "item-1",
                                   title: "Ship the thing", startedAt: Date())
        XCTAssertTrue(runId.hasPrefix("auto-"), "a run nobody asked for is marked as one")
        land(autopilot, itemId: "item-1", title: "Ship the thing", outcome: .done)

        await server.closeRun(runId, execution: "exec-7B02")

        let reloaded = try XCTUnwrap(RunRecordStore(url: recordsURL).record(runId: runId))
        XCTAssertEqual(reloaded.executionID, "exec-7B02")
        XCTAssertNotEqual(reloaded.executionID, reloaded.runId,
                          "the whole point: for a scheduled run the two ids are different")

        let (_, listing) = try await get("/v1/runs", port: firstPort)
        let row = try XCTUnwrap((listing["runs"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["executionId"] as? String, "exec-7B02")

        // The endpoints a poll loop is actually sitting on say it too, and say the
        // execution rather than the minted id it is addressed by.
        let (_, live) = try await get("/v1/runs/\(runId)/result", port: firstPort)
        XCTAssertEqual(live["historical"] as? Bool, false)
        XCTAssertEqual(live["executionId"] as? String, "exec-7B02")
        let (_, liveStatus) = try await get("/v1/runs/\(runId)", port: firstPort)
        XCTAssertEqual(liveStatus["executionId"] as? String, "exec-7B02")

        // And after a restart, when the record is all that is left of it.
        registry = ControlSessionRegistry()
        let (_, secondPort) = try await startServer()
        let (_, result) = try await get("/v1/runs/\(runId)/result", port: secondPort)
        XCTAssertEqual(result["historical"] as? Bool, true)
        XCTAssertEqual(result["executionId"] as? String, "exec-7B02")
        let (_, status) = try await get("/v1/runs/\(runId)", port: secondPort)
        XCTAssertEqual(status["executionId"] as? String, "exec-7B02")
    }

    /// A run started through `POST /v1/runs` *is* its workflow execution — the id
    /// the caller was handed was taken from the execution — so the field reports
    /// that same id rather than being left empty. `track` is what `POST /v1/runs`
    /// does once the execution has spun up.
    func testControlAPIRunReportsItsOwnIdAsTheExecution() async throws {
        let (first, firstPort) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | done")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        first.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                          title: "Ship the thing", startedAt: Date()))
        land(autopilot, itemId: "item-1", title: "Ship the thing", outcome: .done)
        _ = try await get("/v1/runs/run-1/result", port: firstPort)

        XCTAssertEqual(RunRecordStore(url: recordsURL).record(runId: "run-1")?.executionID, "run-1")

        registry = ControlSessionRegistry()
        let (_, secondPort) = try await startServer()
        let (_, body) = try await get("/v1/runs/run-1/result", port: secondPort)

        XCTAssertEqual(body["executionId"] as? String, "run-1")
    }

    /// Every line already in `~/.kiteloop/control-runs.jsonl` was written before
    /// this field existed. Such a line still has to load — the alternative is a
    /// launch that silently drops the history it was meant to preserve — and the
    /// field has to read as *absent*, not as the `runId` standing in for an
    /// execution that would name a transcript directory nobody wrote.
    func testRecordWrittenBeforeTheFieldExistedLoadsWithoutOne() async throws {
        let started = Date().addingTimeInterval(-3600)
        let iso = ISO8601DateFormatter()
        let olderLine = """
        {"runId":"auto-old","projectID":"/tmp/alpha","itemID":"item-1",\
        "title":"Ship the thing","startedAt":"\(iso.string(from: started))",\
        "endedAt":"\(iso.string(from: started.addingTimeInterval(90)))",\
        "outcome":"done","durationSec":90}

        """
        try Data(olderLine.utf8).write(to: recordsURL)

        let reloaded = try XCTUnwrap(RunRecordStore(url: recordsURL).record(runId: "auto-old"))
        XCTAssertEqual(reloaded.outcome, .done, "the rest of the record still decodes")
        XCTAssertNil(reloaded.executionID)

        let (_, port) = try await startServer()
        let (status, body) = try await get("/v1/runs/auto-old/result", port: port)

        XCTAssertEqual(status, 200)
        XCTAssertNil(body["executionId"], "absent, not an invented id")
        let (_, listing) = try await get("/v1/runs", port: port)
        let row = try XCTUnwrap((listing["runs"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["runId"] as? String, "auto-old")
        XCTAssertNil(row["executionId"])
    }

    /// A run whose start the pickup gates refused never reached a workflow, so
    /// there is no execution to report — and its minted `auto-…` id must not be
    /// offered as one. This is the case the fallback to `runId` would get wrong.
    func testRunThatNeverReachedAWorkflowReportsNoExecution() async throws {
        let (server, port) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | ready")
        let runId = server.openRun(projectID: projectID, itemID: "item-1",
                                   title: "Ship the thing", startedAt: Date())

        await server.closeRun(runId)

        let reloaded = try XCTUnwrap(RunRecordStore(url: recordsURL).record(runId: runId))
        XCTAssertEqual(reloaded.outcome, .didNotRun, "it was closed, not left to read as interrupted — "
                       + "and a refusal that never reached the item is not `blocked`")
        XCTAssertNil(reloaded.executionID)

        // The live bodies leave the key out too, rather than sending null or the
        // minted id: there is no transcript for either to point at.
        let (_, result) = try await get("/v1/runs/\(runId)/result", port: port)
        XCTAssertEqual(result["historical"] as? Bool, false)
        XCTAssertNil(result["executionId"], "absent, not an invented id")
        let (_, status) = try await get("/v1/runs/\(runId)", port: port)
        XCTAssertNil(status["executionId"], "absent, not an invented id")
    }

    /// The item ran once and failed; it was targeted again and the pickup gates
    /// refused the second start, which returns before the autopilot clears its
    /// results. Closing that record through the finalization pass matched the
    /// first attempt by item id and wrote its outcome, duration, branch and PR
    /// into the refused start's record. A caller that has already said nothing
    /// ran is believed.
    func testARefusedStartIsNotClosedWithTheEarlierAttemptsResult() async throws {
        let (server, port) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | ready")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        let runId = server.openRun(projectID: projectID, itemID: "item-1",
                                   title: "Ship the thing", startedAt: Date())
        // Still sitting in `results` from the attempt before this one.
        land(autopilot, itemId: "item-1", title: "Ship the thing", outcome: .done,
             branch: "kiteloop/item-1", duration: 42, executionID: nil)

        await server.closeRun(runId, didNotRunReason: "item-1: needs:other is not done")

        let (status, body) = try await get("/v1/runs/\(runId)/result", port: port)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["outcome"] as? String, "did_not_run",
                       "the gate refused this start; the earlier attempt is not its ending")
        XCTAssertEqual(body["reason"] as? String, "item-1: needs:other is not done")
        XCTAssertNil(body["branch"], "and none of that attempt's work is attributed to it")
        XCTAssertNil(body["pullRequestUrl"])

        // And the same read back off the record after a restart, which is all
        // that is left of the run then.
        let reloaded = try XCTUnwrap(RunRecordStore(url: recordsURL).record(runId: runId))
        XCTAssertEqual(reloaded.outcome, .didNotRun)
        XCTAssertEqual(reloaded.reason, "item-1: needs:other is not done")
        XCTAssertNil(reloaded.branch)
        XCTAssertNil(reloaded.pullRequestURL)
    }

    /// The other half of the same rule: a scheduler run that genuinely ended is
    /// still closed with its own result — outcome, duration and branch — since
    /// its caller passes no reason.
    func testASchedulerRunThatEndedIsStillClosedWithItsOwnResult() async throws {
        let (server, port) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | done")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        let runId = server.openRun(projectID: projectID, itemID: "item-1",
                                   title: "Ship the thing", startedAt: Date())
        land(autopilot, itemId: "item-1", title: "Ship the thing", outcome: .done,
             branch: "kiteloop/item-1", duration: 42, executionID: nil)

        await server.closeRun(runId, execution: "exec-4C11")

        let (status, body) = try await get("/v1/runs/\(runId)/result", port: port)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["outcome"] as? String, "done")
        XCTAssertEqual(body["durationSec"] as? Int, 42)
        XCTAssertEqual(body["branch"] as? String, "kiteloop/item-1")
    }

    /// The run a driver is holding right now. `executionId` is what its transcript
    /// directory and its metric row are keyed by, so the endpoint the poll loop
    /// sits on has to report it — waiting for a restart to learn which execution
    /// the run was is no answer at all. The value is the one `GET /v1/runs`
    /// already reports for the same run.
    func testRunFinishedInThisSessionReportsItsExecutionOnTheLiveResult() async throws {
        let (server, port) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | done")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                           title: "Ship the thing", startedAt: Date()))
        land(autopilot, itemId: "item-1", title: "Ship the thing", outcome: .done)

        let (status, body) = try await get("/v1/runs/run-1/result", port: port)

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["historical"] as? Bool, false, "answered from the live run, not the record")
        XCTAssertEqual(body["executionId"] as? String, "run-1")
        let (_, listing) = try await get("/v1/runs", port: port)
        let row = try XCTUnwrap((listing["runs"] as? [[String: Any]])?.first)
        XCTAssertEqual(body["executionId"] as? String, row["executionId"] as? String,
                       "the two readouts of the same run disagree about which execution it was")
    }

    /// The same, one poll earlier: the 202 a loop waits on, and the status
    /// endpoint beside it, name the execution while the run is still going.
    func testRunStillInFlightReportsItsExecutionOnThePendingBodyAndTheStatus() async throws {
        let (server, port) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | active")
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                           title: "Ship the thing", startedAt: Date()))

        let (status, pending) = try await get("/v1/runs/run-1/result", port: port)

        XCTAssertEqual(status, 202, "nothing has landed, so the run is still in flight")
        XCTAssertEqual(pending["executionId"] as? String, "run-1")
        let (_, live) = try await get("/v1/runs/run-1", port: port)
        XCTAssertEqual(live["executionId"] as? String, "run-1")
    }

    // MARK: - Which run's ending a record is closed with

    /// The item that ran twice. A rejected run returns its item to `ready` and the
    /// next pass picks it up again, so one session's result list holds two entries
    /// under the same item id — and a record still open when the second landed was
    /// closed with the second run's outcome, duration and branch. Records only
    /// close when a request arrives, which makes an unattended night exactly the
    /// window where the first record is still open.
    func testTwoRunsOfTheSameItemEachKeepTheirOwnEnding() async throws {
        let (server, port) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | done")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                           title: "Ship the thing", startedAt: Date()))
        server.track(.init(runId: "run-2", projectID: projectID, itemId: "item-1",
                           title: "Ship the thing", startedAt: Date()))
        // The rejected attempt, then the pass that followed it.
        land(autopilot, itemId: "item-1", title: "Ship the thing",
             outcome: .blocked("reviewer rejected: AC 3 unimplemented"),
             branch: "kiteloop/item-1-first", duration: 90, executionID: "run-1")
        land(autopilot, itemId: "item-1", title: "Ship the thing",
             outcome: .done, branch: "kiteloop/item-1-second", duration: 42, executionID: "run-2")

        // Both records close in the single finalization pass this request runs.
        let (firstStatus, first) = try await get("/v1/runs/run-1/result", port: port)
        let (secondStatus, second) = try await get("/v1/runs/run-2/result", port: port)

        XCTAssertEqual(firstStatus, 200)
        XCTAssertEqual(first["outcome"] as? String, "blocked",
                       "the first record must carry the run it names, not whichever attempt finished last")
        XCTAssertEqual(first["reason"] as? String, "reviewer rejected: AC 3 unimplemented")
        XCTAssertEqual(first["durationSec"] as? Int, 90)
        XCTAssertEqual(first["branch"] as? String, "kiteloop/item-1-first")

        XCTAssertEqual(secondStatus, 200)
        XCTAssertEqual(second["outcome"] as? String, "done")
        XCTAssertEqual(second["durationSec"] as? Int, 42)
        XCTAssertEqual(second["branch"] as? String, "kiteloop/item-1-second")

        let store = RunRecordStore(url: recordsURL)
        XCTAssertEqual(store.record(runId: "run-1")?.outcome, .blocked, "and the same on disk, after the app is gone")
        XCTAssertEqual(store.record(runId: "run-1")?.branch, "kiteloop/item-1-first")
        XCTAssertEqual(store.record(runId: "run-2")?.outcome, .done)
        XCTAssertEqual(store.record(runId: "run-2")?.branch, "kiteloop/item-1-second")
    }

    /// The same rule where there is nothing to fall back to: a result stamped with
    /// another execution is that run's ending, so this run stays open rather than
    /// borrowing it. Being wrongly closed is worse than being open — an open run is
    /// still driving toward an ending of its own.
    func testARunIsNotClosedWithAnotherRunsResult() async throws {
        let (server, port) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | active")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                           title: "Ship the thing", startedAt: Date()))
        land(autopilot, itemId: "item-1", title: "Ship the thing", outcome: .done, executionID: "run-2")

        let (status, body) = try await get("/v1/runs/run-1/result", port: port)

        XCTAssertEqual(status, 202)
        XCTAssertEqual(body["state"] as? String, "running")
        XCTAssertNil(body["outcome"])
    }

    /// The fallback, for everything already in memory when the stamp shipped and
    /// for the error path that never reached a workflow to be stamped with: an
    /// unstamped result still closes its run by item id. Without this, a result in
    /// flight across the change would strand its record open, which reads as
    /// `interrupted` at the next launch.
    func testResultCarryingNoExecutionIdStillClosesItsRunByItemId() async throws {
        let (server, port) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | done")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                           title: "Ship the thing", startedAt: Date()))
        land(autopilot, itemId: "item-1", title: "Ship the thing",
             outcome: .done, branch: "kiteloop/item-1", executionID: nil)

        let (status, body) = try await get("/v1/runs/run-1/result", port: port)

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["outcome"] as? String, "done")
        XCTAssertEqual(body["durationSec"] as? Int, 42)
        XCTAssertEqual(body["branch"] as? String, "kiteloop/item-1")
    }

    /// The acceptance criterion for the API half: a finished run's result carries
    /// what the item's own `verify:` answered — the exit status, the command and
    /// the last lines — so a driver auditing a green gate has the evidence
    /// without opening a transcript.
    func testRunResultCarriesTheVerifyVerdict() async throws {
        let (server, port) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | done")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        let store = makeMetricStore()
        var metric = metricRecord(itemID: "item-1", executionID: "run-1")
        metric.verify = RunVerifyVerdict(exitStatus: 65, command: "make ci",
                                         directory: "/tmp/worktrees/item-1",
                                         outputTail: "1 test failed", timedOut: false)
        store.append(metric)
        autopilot.stageMetricStoreForTesting(store)
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                           title: "Ship the thing", startedAt: Date()))
        land(autopilot, itemId: "item-1", title: "Ship the thing", outcome: .done)

        let (status, body) = try await get("/v1/runs/run-1/result", port: port)

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["verifyExitStatus"] as? Int, 65)
        XCTAssertEqual(body["verifyCommand"] as? String, "make ci")
        XCTAssertEqual(body["verifyOutputTail"] as? String, "1 test failed")
        XCTAssertEqual(body["verifyTimedOut"] as? Bool, false, "the command answered; the clock did not")
        XCTAssertEqual(body["verifyDirectory"] as? String, "/tmp/worktrees/item-1")
    }

    /// The acceptance criterion this item exists for. A verify the deadline
    /// killed reaches the field as `WorktreeManager.noExitStatus`, and `-1` is
    /// also what a command that could not be spawned reports — so on the wire the
    /// two used to be one answer. `verifyTimedOut` is the fact that separates
    /// them, and a driver reading a blocked run needs it to tell "the build is
    /// red" from "the build ran out of clock".
    func testRunResultSaysWhenTheDeadlineKilledTheVerify() async throws {
        let (server, port) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | done")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        let store = makeMetricStore()
        var metric = metricRecord(itemID: "item-1", executionID: "run-1")
        metric.verify = RunVerifyVerdict(exitStatus: WorktreeManager.noExitStatus, command: "make ci",
                                         directory: "/tmp/worktrees/item-1",
                                         outputTail: "building…", timedOut: true)
        store.append(metric)
        autopilot.stageMetricStoreForTesting(store)
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                           title: "Ship the thing", startedAt: Date()))
        land(autopilot, itemId: "item-1", title: "Ship the thing", outcome: .blocked("verify timed out"))

        let (status, body) = try await get("/v1/runs/run-1/result", port: port)

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["verifyExitStatus"] as? Int, -1, "no process returned a status")
        XCTAssertEqual(body["verifyTimedOut"] as? Bool, true,
                       "and only this says the deadline is what took it")
        XCTAssertEqual(body["verifyDirectory"] as? String, "/tmp/worktrees/item-1",
                       "in the tree it was killed in")
    }

    /// A run nobody took a verdict on says nothing rather than inventing a zero:
    /// absent is "not measured", and an exit status of 0 would read as a pass.
    func testRunResultOmitsTheVerifyFieldsWhenNoVerdictWasTaken() async throws {
        let (server, port) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | done")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                           title: "Ship the thing", startedAt: Date()))
        land(autopilot, itemId: "item-1", title: "Ship the thing", outcome: .done)

        let (status, body) = try await get("/v1/runs/run-1/result", port: port)

        XCTAssertEqual(status, 200)
        XCTAssertNil(body["verifyExitStatus"])
        XCTAssertNil(body["verifyCommand"])
        XCTAssertNil(body["verifyOutputTail"])
        XCTAssertNil(body["verifyTimedOut"], "absent, not false — false would claim a command answered")
        XCTAssertNil(body["verifyDirectory"])
    }

    /// The acceptance criterion this item exists for: land a run whose verify was
    /// measured, restart, ask again. The verdict is on the record, so the answer
    /// still says what the item's own `verify:` returned — before, the three keys
    /// were emitted only from a live metric row, and a night read back the next
    /// morning reported no verify at all, which reads as a verdict never taken.
    func testVerifyVerdictSurvivesARestart() async throws {
        let (first, firstPort) = try await startServer()
        _ = try landRunWithAVerdict(on: first)
        // The request that finalizes the run — and writes the verdict down.
        let (_, live) = try await get("/v1/runs/run-1/result", port: firstPort)
        XCTAssertEqual(live["verifyExitStatus"] as? Int, 65, "the live reading is unchanged")

        // The restart: a new process, a new registry, nothing open, the same file.
        registry = ControlSessionRegistry()
        let (_, secondPort) = try await startServer()

        let (status, body) = try await get("/v1/runs/run-1/result", port: secondPort)

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["historical"] as? Bool, true)
        XCTAssertEqual(body["verifyExitStatus"] as? Int, 65)
        XCTAssertEqual(body["verifyCommand"] as? String, "make ci")
        XCTAssertEqual(body["verifyOutputTail"] as? String, "1 test failed")
        XCTAssertEqual(body["verifyTimedOut"] as? Bool, false, "the same five facts, after the restart")
        XCTAssertEqual(body["verifyDirectory"] as? String, "/tmp/worktrees/item-1")
        XCTAssertEqual(body["item"] as? String, "item-1", "the record answers for the item it named")
    }

    /// A run nobody took a verdict on says nothing after a restart either: absent
    /// is "not measured", and a `0` exit status invented here would read as a
    /// verify that passed.
    func testHistoricalResultOmitsTheVerifyFieldsWhenNoVerdictWasTaken() async throws {
        let (first, firstPort) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | done")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        first.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                          title: "Ship the thing", startedAt: Date()))
        land(autopilot, itemId: "item-1", title: "Ship the thing", outcome: .done)
        _ = try await get("/v1/runs/run-1/result", port: firstPort)

        registry = ControlSessionRegistry()
        let (_, secondPort) = try await startServer()

        let (status, body) = try await get("/v1/runs/run-1/result", port: secondPort)

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["historical"] as? Bool, true)
        XCTAssertNil(body["verifyExitStatus"])
        XCTAssertNil(body["verifyCommand"])
        XCTAssertNil(body["verifyOutputTail"])
        XCTAssertNil(body["verifyTimedOut"], "absent, not false — false would claim a command answered")
        XCTAssertNil(body["verifyDirectory"])
    }

    /// And the record itself holds all three or none: a `verifyCommand` with no
    /// status would say a verdict was taken without saying how it went.
    func testTheDurableRecordKeepsTheVerdictOfTheRunItNames() async throws {
        let (server, port) = try await startServer()
        _ = try landRunWithAVerdict(on: server)
        _ = try await get("/v1/runs/run-1/result", port: port)

        let record = try XCTUnwrap(RunRecordStore(url: recordsURL).record(runId: "run-1"))

        XCTAssertEqual(record.verifyExitStatus, 65)
        XCTAssertEqual(record.verifyCommand, "make ci")
        XCTAssertEqual(record.verifyOutputTail, "1 test failed")
        XCTAssertEqual(record.verifyTimedOut, false)
        XCTAssertEqual(record.verifyDirectory, "/tmp/worktrees/item-1")
    }

    /// The item that ran twice, at the metric row this time. The rejected attempt
    /// and the pass that followed it each filed a row under the same item id, and
    /// reading the newest gave the *first* run's result body the second run's
    /// score, judge dimensions and verify verdict — a reading taken on a tree
    /// that run never produced.
    func testTwoRunsOfTheSameItemEachReportTheirOwnMetricRow() async throws {
        let (server, port) = try await startServer()
        _ = try landTwoAttempts(on: server)

        let (firstStatus, first) = try await get("/v1/runs/run-1/result", port: port)
        let (secondStatus, second) = try await get("/v1/runs/run-2/result", port: port)

        XCTAssertEqual(firstStatus, 200)
        XCTAssertEqual(first["qualityScore"] as? Double, 0.41,
                       "the first run's score, not whichever attempt filed the newest row")
        XCTAssertEqual((first["judgeDimensions"] as? [String: Double])?["scope_respected"], 0.2)
        XCTAssertEqual(first["verifyExitStatus"] as? Int, 65)
        XCTAssertEqual(first["verifyOutputTail"] as? String, "1 test failed")

        XCTAssertEqual(secondStatus, 200)
        XCTAssertEqual(second["qualityScore"] as? Double, 0.93)
        XCTAssertEqual((second["judgeDimensions"] as? [String: Double])?["scope_respected"], 1.0)
        XCTAssertEqual(second["verifyExitStatus"] as? Int, 0)
    }

    /// And the same on disk, after the app is gone: the record `persist` wrote for
    /// the first run keeps the first run's score once the second has ended and
    /// filed its own row. This is the copy a driver reads after a restart, so a
    /// borrowed score here outlives the session that borrowed it.
    func testTheDurableRecordKeepsTheScoreOfTheRunItNames() async throws {
        let (server, port) = try await startServer()
        _ = try landTwoAttempts(on: server)

        // Both records close in the finalization pass these requests run.
        _ = try await get("/v1/runs/run-1/result", port: port)
        _ = try await get("/v1/runs/run-2/result", port: port)

        let store = RunRecordStore(url: recordsURL)
        XCTAssertEqual(store.record(runId: "run-1")?.qualityScore, 0.41)
        XCTAssertEqual(store.record(runId: "run-1")?.judgeDimensions?["scope_respected"], 0.2)
        XCTAssertEqual(store.record(runId: "run-2")?.qualityScore, 0.93)
    }

    /// A row this run did not write says nothing about this run. Last night's
    /// attempt at the same item is the case that used to be reported as today's:
    /// absent is "nobody measured it here", and another execution's score read as
    /// this one's is worse than no score at all.
    func testAnEarlierAttemptsMetricRowIsNotReportedAsThisRuns() async throws {
        let (server, port) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | done")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        let store = makeMetricStore()
        store.append(scoredRow(executionID: "run-0", score: 0.41, verifyExitStatus: 65))
        autopilot.stageMetricStoreForTesting(store)
        // This run reached its ending without filing a row of its own.
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                           title: "Ship the thing", startedAt: Date()))
        land(autopilot, itemId: "item-1", title: "Ship the thing", outcome: .done, executionID: "run-1")

        let (status, body) = try await get("/v1/runs/run-1/result", port: port)

        XCTAssertEqual(status, 200)
        XCTAssertNil(body["qualityScore"], "run-0's reading is not run-1's")
        XCTAssertNil(body["judgeDimensions"])
        XCTAssertNil(body["judgeUnavailable"])
        XCTAssertNil(body["verifyExitStatus"])
        XCTAssertNil(body["verifyCommand"])
        XCTAssertNil(body["verifyOutputTail"])
        XCTAssertNil(RunRecordStore(url: recordsURL).record(runId: "run-1")?.qualityScore)
    }

    /// A metric row for `itemID`, stamped with the execution that wrote it, and
    /// with only the fields this file's assertions read.
    private func metricRecord(itemID: String, executionID: String?) -> TaskMetricRecord {
        let started = Date()
        return TaskMetricRecord(
            projectPath: "/tmp/alpha", projectName: "alpha", itemID: itemID, title: "Ship the thing",
            epic: nil, declaredSize: "S", startedAt: started,
            completedAt: started.addingTimeInterval(42), durationSeconds: 42, costUSD: 1,
            reviewerRetries: 0, outcome: "done", workerAgent: "worker", reviewerAgent: "reviewer",
            executionID: executionID, toolErrors: nil)
    }

    /// The rejected attempt and the pass that followed it: two tracked runs of one
    /// item, each with its own ending and its own metric row. Returns the project.
    private func landTwoAttempts(on server: KiteloopControlServer) throws -> String {
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | done")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        let store = makeMetricStore()
        store.append(scoredRow(executionID: "run-1", score: 0.41, verifyExitStatus: 65))
        store.append(scoredRow(executionID: "run-2", score: 0.93, verifyExitStatus: 0))
        autopilot.stageMetricStoreForTesting(store)
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                           title: "Ship the thing", startedAt: Date()))
        server.track(.init(runId: "run-2", projectID: projectID, itemId: "item-1",
                           title: "Ship the thing", startedAt: Date()))
        land(autopilot, itemId: "item-1", title: "Ship the thing",
             outcome: .blocked("reviewer rejected: AC 3 unimplemented"), duration: 90, executionID: "run-1")
        land(autopilot, itemId: "item-1", title: "Ship the thing", outcome: .done, executionID: "run-2")
        return projectID
    }

    /// One tracked run of `item-1` that landed with a verify verdict on its metric
    /// row — the run a driver comes back for after a restart. Returns the project.
    private func landRunWithAVerdict(on server: KiteloopControlServer) throws -> String {
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | done")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        let store = makeMetricStore()
        store.append(scoredRow(executionID: "run-1", score: 0.41, verifyExitStatus: 65))
        autopilot.stageMetricStoreForTesting(store)
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                           title: "Ship the thing", startedAt: Date()))
        land(autopilot, itemId: "item-1", title: "Ship the thing", outcome: .done, executionID: "run-1")
        return projectID
    }

    /// A metric row carrying everything `/result` reads off one: the judge's
    /// verdict and the verify the app took before the reviewer saw the diff.
    private func scoredRow(executionID: String, score: Double, verifyExitStatus: Int32) -> TaskMetricRecord {
        var row = metricRecord(itemID: "item-1", executionID: executionID)
        row.qualityScore = score
        row.judgeDimensions = ["scope_respected": score < 0.5 ? 0.2 : 1.0]
        row.verify = RunVerifyVerdict(exitStatus: verifyExitStatus, command: "make ci",
                                      directory: "/tmp/worktrees/item-1",
                                      outputTail: verifyExitStatus == 0 ? "ok" : "1 test failed",
                                      timedOut: false)
        return row
    }

    /// A metric store over this test's temp directory, so a run's rows never
    /// reach the developer's real `~/.kiteloop`.
    private func makeMetricStore() -> TaskMetricStore {
        TaskMetricStore(
            metricsURL: tempDir.appendingPathComponent("task-metrics.jsonl"),
            estimatesURL: tempDir.appendingPathComponent("task-estimates.jsonl"),
            approvalsURL: tempDir.appendingPathComponent("task-approvals.jsonl"),
            mergesURL: tempDir.appendingPathComponent("task-merges.jsonl"))
    }

    /// The ending stays re-read rather than frozen while the run still owns the
    /// autopilot — the window the quality judge's score and the pull request URL
    /// arrive in, seconds after the item lands. Matching by execution must not turn
    /// the first close into the last word.
    func testEndingIsStillRereadWhileTheRunOwnsTheAutopilot() async throws {
        let (server, port) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | done")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                           title: "Ship the thing", startedAt: Date()))
        // The item has landed, but the run is still unwinding around it.
        var landed = BacklogAutopilot.ItemResult(id: "item-1", title: "Ship the thing",
                                                 outcome: .done, duration: 42)
        landed.executionID = "run-1"
        autopilot.stageResultForTesting(landed)
        autopilot.stageExecutionIDForTesting("run-1")
        autopilot.stageRunForTesting(
            status: .running(itemIndex: 0, total: 1),
            queue: [BacklogItem(id: "item-1", title: "Ship the thing", verify: "true",
                                status: .done, type: .local, size: .s)])

        let (firstStatus, first) = try await get("/v1/runs/run-1/result", port: port)
        XCTAssertEqual(firstStatus, 200)
        XCTAssertNil(first["pullRequestUrl"], "nothing had been published yet")

        // The tail of the run: the PR is opened and the result filled in.
        autopilot.clearResultsForTesting()
        landed.pullRequestURL = "https://github.com/acme/kiteloop/pull/42"
        autopilot.stageResultForTesting(landed)

        let (_, second) = try await get("/v1/runs/run-1/result", port: port)

        XCTAssertEqual(second["pullRequestUrl"] as? String, "https://github.com/acme/kiteloop/pull/42")
        XCTAssertEqual(RunRecordStore(url: recordsURL).record(runId: "run-1")?.pullRequestURL,
                       "https://github.com/acme/kiteloop/pull/42")
    }

    // MARK: - Runs the Start button began

    /// A run started from the Autopilot tab used to leave no trace: it calls
    /// `BacklogAutopilot.start` directly, so it reached neither `POST /v1/runs`
    /// nor the scheduler, appeared in no listing, and could not afterwards be
    /// asked how it ended. Which surface pressed start is not something the
    /// history is allowed to depend on.
    func testRunStartedFromTheAutopilotTabIsRecordedAndListed() async throws {
        let (_, port) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | active")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        // Mid-run, which is what the adoption hook fires in the middle of.
        autopilot.stageExecutionIDForTesting("exec-ui-1")
        autopilot.stageRunForTesting(
            status: .running(itemIndex: 0, total: 1),
            queue: [BacklogItem(id: "item-1", title: "Ship the thing", verify: "true",
                                status: .active, type: .local, size: .s)])

        // What `MainWindow` does the moment the execution exists.
        registry.adoptRun?(projectID, "item-1", "Ship the thing", "exec-ui-1", Date())

        // The opening line is on disk before anything asks anything of the API.
        let opened = try String(contentsOf: recordsURL, encoding: .utf8)
        XCTAssertTrue(opened.contains("\"runId\":\"exec-ui-1\""), "the run was opened in the durable log")

        let (status, body) = try await get("/v1/runs", port: port)
        XCTAssertEqual(status, 200)
        let rows = try XCTUnwrap(body["runs"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["runId"] as? String, "exec-ui-1", "addressed by the execution driving it")
        XCTAssertEqual(rows[0]["executionId"] as? String, "exec-ui-1")
        XCTAssertEqual(rows[0]["item"] as? String, "item-1")
        XCTAssertEqual(rows[0]["state"] as? String, "running")
        XCTAssertEqual(rows[0]["historical"] as? Bool, false)
    }

    /// And it closes on its own. Nobody drives a UI-started run over HTTP, so a
    /// record left open until the next request is a record that reads
    /// `interrupted` at the next launch — about work that landed perfectly well.
    /// The finalization pass `MainWindow` asks for as the run finishes is what
    /// closes it, with no request in between.
    func testAdoptedRunIsClosedWhenItEndsWithoutAnyRequest() async throws {
        try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | done")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        registry.adoptRun?(projectID, "item-1", "Ship the thing", "exec-ui-1", Date())
        land(autopilot, itemId: "item-1", title: "Ship the thing", outcome: .done, branch: "kiteloop/item-1")

        // `autopilot.onRunFinished` — the only thing that happens next.
        await registry.finalizeRuns?()

        let reloaded = try XCTUnwrap(RunRecordStore(url: recordsURL).record(runId: "exec-ui-1"))
        XCTAssertEqual(reloaded.outcome, .done, "a finished run must not read as interrupted")
        XCTAssertEqual(reloaded.durationSec, 42)
        XCTAssertEqual(reloaded.branch, "kiteloop/item-1")
        XCTAssertEqual(reloaded.executionID, "exec-ui-1")
        XCTAssertNotNil(reloaded.endedAt)
    }

    /// The run `POST /v1/runs` starts is the same run the Autopilot tab's hook
    /// sees start, and both learn the same execution id within a moment of each
    /// other — in an order nothing decides. Whichever arrives second must add
    /// nothing: one run, one record, one opening line.
    func testRunTheServerStartedIsNotRecordedTwiceWhenAlsoAdopted() async throws {
        let (server, port) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | active")
        let startedAt = Date().addingTimeInterval(-5)
        server.track(.init(runId: "exec-2", projectID: projectID, itemId: "item-1",
                           title: "Ship the thing", startedAt: startedAt))

        // The hook fires for the same execution; it cannot tell who started it.
        registry.adoptRun?(projectID, "item-1", "Ship the thing", "exec-2", Date())

        let lines = try String(contentsOf: recordsURL, encoding: .utf8)
            .split(separator: "\n").filter { $0.contains("exec-2") }
        XCTAssertEqual(lines.count, 1, "the second notice of a tracked run writes nothing")
        let (_, body) = try await get("/v1/runs", port: port)
        XCTAssertEqual((body["runs"] as? [[String: Any]])?.count, 1, "one run, not two")
    }

    /// The same race the other way round: the hook is normally first — it is
    /// handed the id, while `POST /v1/runs` polls for it — so the run request's
    /// own `track` is the second notice, and must not re-open a run already
    /// under way.
    func testAdoptedRunIsNotRecordedTwiceWhenTheRunRequestCatchesUp() async throws {
        let (server, port) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | active")
        let adoptedAt = Date().addingTimeInterval(-5)
        registry.adoptRun?(projectID, "item-1", "Ship the thing", "exec-3", adoptedAt)

        server.track(.init(runId: "exec-3", projectID: projectID, itemId: "item-1",
                           title: "A second reading of the same run", startedAt: Date()))

        let lines = try String(contentsOf: recordsURL, encoding: .utf8)
            .split(separator: "\n").filter { $0.contains("exec-3") }
        XCTAssertEqual(lines.count, 1, "one opening line, whichever surface got here first")
        let (_, body) = try await get("/v1/runs", port: port)
        let rows = try XCTUnwrap(body["runs"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["title"] as? String, "Ship the thing", "the first writer owns the run")
    }

    /// The autonomous scheduler opens the run itself, and then the same hook
    /// fires for the workflow it started — it cannot tell who pressed start. Two
    /// notices of one run, under two ids, used to leave two `RunInfo`s and two
    /// records: one night's run listed twice in `GET /v1/runs`, counted twice by
    /// /health, and finalized twice from a single `ItemResult`.
    func testSchedulerOpenedRunAdoptedByItsExecutionIsRecordedOnce() async throws {
        let (server, port) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | active")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        // What `CoordinatorRunScheduler` does before it starts the autopilot.
        let runID = server.openRun(projectID: projectID, itemID: "item-1",
                                   title: "Ship the thing", startedAt: Date().addingTimeInterval(-5))
        autopilot.stageExecutionIDForTesting("exec-auto-1")
        autopilot.stageRunForTesting(
            status: .running(itemIndex: 0, total: 1),
            queue: [BacklogItem(id: "item-1", title: "Ship the thing", verify: "true",
                                status: .active, type: .local, size: .s)])

        // And moments later, what `MainWindow` does on `onExecutionStarted`.
        registry.adoptRun?(projectID, "item-1", "Ship the thing", "exec-auto-1", Date())

        let (_, body) = try await get("/v1/runs", port: port)
        let rows = try XCTUnwrap(body["runs"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1, "one run, not one per surface that noticed it")
        XCTAssertEqual(rows[0]["runId"] as? String, runID, "still addressed by the id the scheduler minted")
        XCTAssertEqual(rows[0]["executionId"] as? String, "exec-auto-1",
                       "the adoption is the run naming itself, in flight")
        let opened = try String(contentsOf: recordsURL, encoding: .utf8)
        XCTAssertFalse(opened.contains("\"runId\":\"exec-auto-1\""), "no second record was opened")

        let (_, health) = try await get("/health", port: port)
        XCTAssertEqual(health["activeRuns"] as? Int, 1, "one run in flight, counted once")
    }

    /// And the record that closes is the scheduler's, carrying the execution the
    /// adoption told it — the one field tying an unattended night's record to its
    /// transcript and its metric, and the one the `auto-…` record used to lose.
    func testAdoptedSchedulerRunClosesCarryingItsExecution() async throws {
        let (server, _) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | done")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        let runID = server.openRun(projectID: projectID, itemID: "item-1",
                                   title: "Ship the thing", startedAt: Date().addingTimeInterval(-5))
        registry.adoptRun?(projectID, "item-1", "Ship the thing", "exec-auto-2", Date())
        land(autopilot, itemId: "item-1", title: "Ship the thing", outcome: .done,
             branch: "kiteloop/item-1", executionID: "exec-auto-2")

        // The scheduler's own close, handed no execution: `currentExecutionID` is
        // cleared per item, so this is nil on every real night.
        await server.closeRun(runID)

        let lines = try String(contentsOf: recordsURL, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.filter { $0.contains("\"runId\":\"exec-auto-2\"") }.count, 0,
                       "the execution is a field on this run's record, not a record of its own")
        let reloaded = try XCTUnwrap(RunRecordStore(url: recordsURL).record(runId: runID))
        XCTAssertEqual(reloaded.outcome, .done)
        XCTAssertEqual(reloaded.executionID, "exec-auto-2", "joinable to the run's metric")
        XCTAssertNil(RunRecordStore(url: recordsURL).record(runId: "exec-auto-2"),
                     "one run, one record")
    }

    /// The claim is narrow: only a run *for this item* is the one adopting itself.
    /// A run started from the Autopilot tab while the scheduler happens to be
    /// working on something else still opens its own record, as it always did.
    func testAdoptionOpensItsOwnRunWhenTheSchedulerIsOnAnotherItem() async throws {
        let (server, port) = try await startServer()
        let projectID = try registerProject(
            named: "alpha",
            backlog: "- [ ] item-1 | Ship the thing | active\n- [ ] item-2 | Ship the other thing | active")
        let runID = server.openRun(projectID: projectID, itemID: "item-1",
                                   title: "Ship the thing", startedAt: Date().addingTimeInterval(-5))
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        autopilot.stageExecutionIDForTesting("exec-ui-9")
        autopilot.stageRunForTesting(
            status: .running(itemIndex: 0, total: 1),
            queue: [BacklogItem(id: "item-2", title: "Ship the other thing", verify: "true",
                                status: .active, type: .local, size: .s)])

        registry.adoptRun?(projectID, "item-2", "Ship the other thing", "exec-ui-9", Date())

        let (_, body) = try await get("/v1/runs", port: port)
        let rows = try XCTUnwrap(body["runs"] as? [[String: Any]])
        XCTAssertEqual(Set(rows.compactMap { $0["runId"] as? String }), [runID, "exec-ui-9"],
                       "a different item is a different run")
        let records = try String(contentsOf: recordsURL, encoding: .utf8)
        XCTAssertTrue(records.contains("\"runId\":\"exec-ui-9\""), "it opened its own record")
    }

    /// The line the adoption stays behind: a project the registry doesn't hold
    /// can never be inspected to close a run, so opening a record for one would
    /// only mint an `interrupted` line at the next launch.
    func testAdoptingARunForAnUnregisteredProjectRecordsNothing() async throws {
        let (_, port) = try await startServer()

        registry.adoptRun?("/tmp/not-open", "item-1", "Ship the thing", "exec-4", Date())

        XCTAssertFalse(FileManager.default.fileExists(atPath: recordsURL.path(percentEncoded: false)))
        let (_, body) = try await get("/v1/runs", port: port)
        XCTAssertEqual((body["runs"] as? [[String: Any]])?.count, 0)
    }

    // MARK: - Across a project close

    /// A run does not need the app to die to be stranded: closing its tab was
    /// enough. The entry went out of the registry, so the finalization pass could
    /// never reach the run again, its record stayed open, and the next launch
    /// called it `interrupted` — about work that had merged and opened a PR.
    func testRunFinishedBeforeItsProjectClosesIsRecordedWithItsRealOutcome() async throws {
        let (server, _) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | done")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                           title: "Ship the thing", startedAt: Date()))
        land(autopilot, itemId: "item-1", title: "Ship the thing", outcome: .done, branch: "kiteloop/item-1")

        // The tab closes. No request ever arrived to finalize the run.
        await registry.unregister(projectID: projectID)

        // A second store over the same file is what the next launch is.
        let reloaded = try XCTUnwrap(RunRecordStore(url: recordsURL).record(runId: "run-1"))
        XCTAssertEqual(reloaded.outcome, .done, "a run that had finished must not read as interrupted")
        XCTAssertEqual(reloaded.branch, "kiteloop/item-1")
        XCTAssertNotNil(reloaded.endedAt, "the record is closed, not merely outcome-stamped")
        XCTAssertEqual(reloaded.durationSec, 42)
    }

    /// The other half, and the line the fix has to stay behind: a run that really
    /// was still going when its project closed was interrupted, and closing it
    /// with an invented ending would be the same lie in the other direction.
    func testRunStillInFlightWhenItsProjectClosesStaysInterrupted() async throws {
        let (server, _) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | active")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                           title: "Ship the thing", startedAt: Date()))
        // Mid-run: the autopilot owns this execution and has recorded nothing.
        autopilot.stageExecutionIDForTesting("run-1")
        autopilot.stageRunForTesting(
            status: .running(itemIndex: 0, total: 1),
            queue: [BacklogItem(id: "item-1", title: "Ship the thing", verify: "true",
                                status: .active, type: .local, size: .s)])

        await registry.unregister(projectID: projectID)

        let reloaded = try XCTUnwrap(RunRecordStore(url: recordsURL).record(runId: "run-1"))
        XCTAssertEqual(reloaded.outcome, .interrupted, "nothing ended, so nothing may be written down as an ending")
        XCTAssertNil(reloaded.endedAt)
    }

    /// Criterion the fix must not trade away: finalization still skips a project
    /// it cannot inspect, so a run whose project closed while it was live keeps
    /// reading `unknown` on the live surface rather than acquiring an ending.
    func testLiveReadoutForAClosedProjectsRunIsUnchanged() async throws {
        let (server, port) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | active")
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                           title: "Ship the thing", startedAt: Date()))

        await registry.unregister(projectID: projectID)

        let (status, body) = try await get("/v1/runs", port: port)
        XCTAssertEqual(status, 200)
        let runs = try XCTUnwrap(body["runs"] as? [[String: Any]])
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0]["state"] as? String, "unknown")
        XCTAssertEqual(runs[0]["historical"] as? Bool, false)
    }

    // MARK: - Across a quit

    /// The shape of an unattended overnight batch: the last item lands at 4am,
    /// nothing polls the API afterwards, and the app is quit in the morning. A
    /// record only closes when something asks a question, so the quit used to
    /// leave that one open and the next launch called it `interrupted` — the
    /// store's word for "the app died under it", said about work that merged.
    func testRunThatEndedIsClosedByTheQuitWithNoRequestAfterIt() async throws {
        let (server, _) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | done")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                           title: "Ship the thing", startedAt: Date()))
        land(autopilot, itemId: "item-1", title: "Ship the thing", outcome: .done, branch: "kiteloop/item-1")

        await quit(server)

        // A second store over the same file is what the next launch is.
        let reloaded = try XCTUnwrap(RunRecordStore(url: recordsURL).record(runId: "run-1"))
        XCTAssertEqual(reloaded.outcome, .done, "a run that had finished must not read as interrupted")
        XCTAssertEqual(reloaded.branch, "kiteloop/item-1")
        XCTAssertNotNil(reloaded.endedAt, "the record is closed, not merely outcome-stamped")
        XCTAssertEqual(reloaded.durationSec, 42)
    }

    /// The line the quit stays behind, exactly as the project close does: a run
    /// that was still going when the app went really was interrupted, and closing
    /// it with an invented ending is the same lie in the other direction.
    func testRunStillInFlightAtQuitStaysInterrupted() async throws {
        let (server, _) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | active")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                           title: "Ship the thing", startedAt: Date()))
        // Mid-run: the autopilot owns this execution and has recorded nothing.
        autopilot.stageExecutionIDForTesting("run-1")
        autopilot.stageRunForTesting(
            status: .running(itemIndex: 0, total: 1),
            queue: [BacklogItem(id: "item-1", title: "Ship the thing", verify: "true",
                                status: .active, type: .local, size: .s)])

        await quit(server)

        let reloaded = try XCTUnwrap(RunRecordStore(url: recordsURL).record(runId: "run-1"))
        XCTAssertEqual(reloaded.outcome, .interrupted, "nothing ended, so nothing may be written down as an ending")
        XCTAssertNil(reloaded.endedAt)
    }

    /// And the quit is answered on its own terms. The terminate is already parked
    /// inside a `terminateLater` by the time the finalize runs, so a pass that
    /// never returns would be an app that never closes — a beachball with no way
    /// out, in exchange for records that were being written for free.
    func testQuitIsAnsweredEvenIfTheFinalizeNeverReturns() async throws {
        let delegate = AppDelegate()
        let wedged = WedgedFinalize()
        delegate.finalizeRuns = { await wedged.hang() }
        addTeardownBlock { await wedged.release() }

        let started = Date()
        await delegate.finalizeBeforeQuit(bound: .milliseconds(50))

        // Comfortably inside the default bound as well as the 50ms one, so a
        // `bound:` nothing honoured would be caught here rather than pass at 3s.
        XCTAssertLessThan(Date().timeIntervalSince(started), 2,
                          "the quit waits on its bound, not on the finalize")
        XCTAssertFalse(wedged.didReturn, "the finalize is still hanging — the quit went without it")
    }

    // MARK: - With nobody asking

    /// The night the scheduler drove on its own. `CoordinatorRunScheduler` mints
    /// `auto-…` runs with no HTTP traffic at all, and a record only closed when a
    /// request arrived — so every item that finished held nothing but its opening
    /// line, and a crash or a power cut turned all of them into `interrupted`:
    /// the store's word for "the app died under it", said about work that merged
    /// hours earlier.
    ///
    /// The server here is never started, so nothing in this test can reach
    /// `route(_:)` — which is the shape of the night this is about.
    func testEndedRunIsClosedByAFinalizationPassWithNoRequest() async throws {
        let server = makeServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | done")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                           title: "Ship the thing", startedAt: Date()))
        land(autopilot, itemId: "item-1", title: "Ship the thing", outcome: .done, branch: "kiteloop/item-1")

        await server.finalizeOpenRuns()

        // A second store over the same file is what the next launch is.
        let reloaded = try XCTUnwrap(RunRecordStore(url: recordsURL).record(runId: "run-1"))
        XCTAssertEqual(reloaded.outcome, .done, "a run that had finished must not read as interrupted")
        XCTAssertEqual(reloaded.branch, "kiteloop/item-1")
        XCTAssertNotNil(reloaded.endedAt, "the record is closed, not merely outcome-stamped")
        XCTAssertEqual(reloaded.durationSec, 42)
    }

    /// And the pass arrives by itself. Nothing above proves the record closes
    /// without someone calling for it, which is the whole of the bug: here the
    /// only thing that runs after the item lands is the ticker.
    func testEndedRunIsClosedByTheTickerAloneWithinAnInterval() async throws {
        let shipped = KiteloopControlServer.finalizationInterval
        KiteloopControlServer.finalizationInterval = 0.05
        addTeardownBlock { await MainActor.run { KiteloopControlServer.finalizationInterval = shipped } }
        let server = makeServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | done")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                           title: "Ship the thing", startedAt: Date()))
        land(autopilot, itemId: "item-1", title: "Ship the thing", outcome: .done, branch: "kiteloop/item-1")
        XCTAssertTrue(server.isFinalizationTickerRunning, "the record is open, so a tick is due")

        // Waited on the ticker rather than on the file: reading the file through a
        // second store while the run is still open is itself a launch, and would
        // write the interruption this test is about.
        try await eventually("the finalization ticker to stop — the tick never came, so the record is still open") {
            await server.isFinalizationTickerRunning == false
        }

        let reloaded = try XCTUnwrap(RunRecordStore(url: recordsURL).record(runId: "run-1"))
        XCTAssertEqual(reloaded.outcome, .done)
        XCTAssertEqual(reloaded.durationSec, 42)
    }

    /// The ticker exists exactly while there is something for it to close: no open
    /// run, no timer — and the next run starts one again, so a server that has been
    /// idle for a week still closes the run it takes tonight.
    func testTickerRunsOnlyWhileSomeRunIsStillOpen() async throws {
        let server = makeServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | done")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        XCTAssertFalse(server.isFinalizationTickerRunning, "nothing is open, so there is nothing to tick over")

        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                           title: "Ship the thing", startedAt: Date()))
        XCTAssertTrue(server.isFinalizationTickerRunning, "a run is open — its record has to close by itself")

        land(autopilot, itemId: "item-1", title: "Ship the thing", outcome: .done)
        await server.finalizeOpenRuns()
        XCTAssertFalse(server.isFinalizationTickerRunning, "the last record closed; the timer has no work left")

        server.track(.init(runId: "run-2", projectID: projectID, itemId: "item-2",
                           title: "Ship the other thing", startedAt: Date()))
        XCTAssertTrue(server.isFinalizationTickerRunning, "the next run starts it again")
    }

    /// A tick over a run that has already been closed writes nothing. The record is
    /// settled — `persist` keeps the first close's `endedAt` and the store drops a
    /// record identical to the one it holds — so a ticker that outlived its run
    /// could not grow the file even if it did.
    func testTickOverASettledRunWritesNoNewLine() async throws {
        let server = makeServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | done")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                           title: "Ship the thing", startedAt: Date()))
        land(autopilot, itemId: "item-1", title: "Ship the thing", outcome: .done, branch: "kiteloop/item-1")
        await server.finalizeOpenRuns()
        let settled = try lineCount()

        await server.finalizeOpenRuns()
        await server.finalizeOpenRuns()

        XCTAssertEqual(settled, 2, "the opening line and the one close")
        XCTAssertEqual(try lineCount(), settled, "a tick over a settled run has nothing to say")
    }

    /// The line the ticker stays behind, exactly as the project close and the quit
    /// do: a run that has not ended is left open, because it has not ended. An
    /// ending invented on a timer would be the same lie the interruption is, only
    /// arriving faster.
    func testTickOverARunStillInFlightLeavesItOpen() async throws {
        let server = makeServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | active")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        server.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                           title: "Ship the thing", startedAt: Date()))
        // Mid-run: the autopilot owns this execution and has recorded nothing.
        autopilot.stageExecutionIDForTesting("run-1")
        autopilot.stageRunForTesting(
            status: .running(itemIndex: 0, total: 1),
            queue: [BacklogItem(id: "item-1", title: "Ship the thing", verify: "true",
                                status: .active, type: .local, size: .s)])

        await server.finalizeOpenRuns()

        XCTAssertTrue(server.isFinalizationTickerRunning, "the run is still open, so the pass keeps coming")
        let reloaded = try XCTUnwrap(RunRecordStore(url: recordsURL).record(runId: "run-1"))
        XCTAssertEqual(reloaded.outcome, .interrupted, "nothing ended, so nothing may be written down as an ending")
        XCTAssertNil(reloaded.endedAt)
    }

    // MARK: - What the live half keeps

    /// The bound on the live half. `GET /v1/runs` lists every run this process is
    /// tracking regardless of `limit`, so that a page of finished work can never
    /// hide a live one — which, with nothing ever leaving the map, meant an app
    /// left up for a week answered every poll with every run it had ever tracked.
    /// Past the cap a run is listed from its record instead: the same rows, each
    /// exactly once, and none of them lost in the handover.
    func testEndedRunsPastTheCapAreListedOnceFromTheirRecords() async throws {
        let (server, port) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | done")
        let cap = KiteloopControlServer.endedRunRetentionLimit
        let ids = try landEndedRuns(cap + 10, on: server, projectID: projectID)

        let (status, body) = try await get("/v1/runs", port: port)

        XCTAssertEqual(status, 200)
        let rows = try XCTUnwrap(body["runs"] as? [[String: Any]])
        let listed = rows.compactMap { $0["runId"] as? String }
        XCTAssertEqual(listed.count, Set(listed).count, "a run crossing the cap is listed by both halves")
        XCTAssertEqual(Set(listed), Set(ids), "no run may drop out of the listing on its way to the records")
        for id in ids.prefix(10) {
            let row = try XCTUnwrap(rows.first { $0["runId"] as? String == id })
            XCTAssertEqual(row["historical"] as? Bool, true, "\(id) is past the cap and comes from its record")
            XCTAssertEqual(row["outcome"] as? String, "done", "and it still says how it ended")
        }
        for id in ids.suffix(cap) {
            let row = try XCTUnwrap(rows.first { $0["runId"] as? String == id })
            XCTAssertEqual(row["historical"] as? Bool, false, "\(id) is inside the cap and still tracked")
        }
    }

    /// A run the sweep dropped is not a run that vanished. `/result` answers it
    /// from its durable record — the same 200 a run from an earlier launch gets,
    /// carrying the ending, the duration and the spend that record holds.
    func testARunPastTheCapStillAnswersItsResultFromItsRecord() async throws {
        let (server, port) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | done")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        let metrics = makeMetricStore()
        // The oldest run's own charge, so the record has a cost to answer with.
        metrics.append(scoredRow(executionID: "run-000", score: 0.86, verifyExitStatus: 0))
        autopilot.stageMetricStoreForTesting(metrics)
        let cap = KiteloopControlServer.endedRunRetentionLimit
        try landEndedRuns(cap + 10, on: server, projectID: projectID)

        let (status, body) = try await get("/v1/runs/run-000/result", port: port)

        XCTAssertEqual(status, 200, "the oldest run is past the cap, and a dropped run must not 404")
        XCTAssertEqual(body["historical"] as? Bool, true, "nothing is driving it any more")
        let record = try XCTUnwrap(RunRecordStore(url: recordsURL).record(runId: "run-000"))
        XCTAssertEqual(body["outcome"] as? String, "done")
        XCTAssertEqual(body["durationSec"] as? Int, record.durationSec)
        XCTAssertEqual(body["costUSD"] as? Double, record.costUSD)
        XCTAssertEqual(body["qualityScore"] as? Double, record.qualityScore)
    }

    /// The one thing the cap may never reach. A run still open is what a driver is
    /// polling for, so it stays live however much finished work sits behind it —
    /// here it is the oldest run in the map, the first the sweep would take if it
    /// counted anything but endings.
    func testAnOpenRunIsNeverSweptHoweverMuchFinishedWorkSitsBehindIt() async throws {
        let (server, port) = try await startServer()
        let projectID = try registerProject(
            named: "alpha",
            backlog: "- [ ] item-1 | Ship the thing | done\n- [ ] item-2 | Keep at it | active")
        server.track(.init(runId: "run-open", projectID: projectID, itemId: "item-2",
                           title: "Keep at it", startedAt: sweepEpoch.addingTimeInterval(-60)))
        let cap = KiteloopControlServer.endedRunRetentionLimit
        let ids = try landEndedRuns(cap + 10, on: server, projectID: projectID)

        let (status, body) = try await get("/v1/runs", port: port)

        XCTAssertEqual(status, 200)
        let rows = try XCTUnwrap(body["runs"] as? [[String: Any]])
        let open = try XCTUnwrap(rows.first { $0["runId"] as? String == "run-open" })
        XCTAssertEqual(open["historical"] as? Bool, false, "an open run has no record to be answered from")
        XCTAssertEqual(open["state"] as? String, "running")
        let oldestEnded = try XCTUnwrap(rows.first { $0["runId"] as? String == ids[0] })
        XCTAssertEqual(oldestEnded["historical"] as? Bool, true, "the sweep did run — it just left the open run")
    }

    /// The other thing the cap may never reach: an ended run the record store has
    /// no record for. The record is what answers for a run after it is dropped, so
    /// dropping one without a record would lose the only copy of it. The store's
    /// age bound is what produces one here — a run that started before the window
    /// the file keeps, on an app that has been up longer than the window is wide.
    func testAnEndedRunWithNoRecordIsNotSwept() async throws {
        let (server, port) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | done")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        let older = Date().addingTimeInterval(-2 * RunRecordStore.retentionAge)
        server.track(.init(runId: "run-ancient", projectID: projectID, itemId: "item-1",
                           title: "Ship the thing", startedAt: older))
        land(autopilot, itemId: "item-1", title: "Ship the thing", outcome: .done, executionID: "run-ancient")
        let cap = KiteloopControlServer.endedRunRetentionLimit
        let ids = try landEndedRuns(cap + 10, on: server, projectID: projectID)

        let (status, body) = try await get("/v1/runs", port: port)

        XCTAssertEqual(status, 200)
        XCTAssertNil(RunRecordStore(url: recordsURL).record(runId: "run-ancient"),
                     "the fixture only works while the store's age bound keeps this run out of the file")
        let rows = try XCTUnwrap(body["runs"] as? [[String: Any]])
        let ancient = try XCTUnwrap(rows.first { $0["runId"] as? String == "run-ancient" },
                                    "swept with nothing to answer for it, the run would be gone from every endpoint")
        XCTAssertEqual(ancient["historical"] as? Bool, false, "it is still tracked, because it has to be")
        let oldestEnded = try XCTUnwrap(rows.first { $0["runId"] as? String == ids[0] })
        XCTAssertEqual(oldestEnded["historical"] as? Bool, true, "the sweep did run — it just left the recordless run")
    }

    // MARK: - Helpers

    private func lineCount() throws -> Int {
        try String(contentsOf: recordsURL, encoding: .utf8).split(separator: "\n").count
    }

    /// A server that is never started: no port, no listener, so nothing a test does
    /// can reach `route(_:)` and close a record by asking. Which is the point — an
    /// unattended night never asks either, and a server switched off in Settings
    /// still holds the runs it began.
    private func makeServer() -> KiteloopControlServer {
        let server = KiteloopControlServer(registry: registry, token: token,
                                           runRecords: RunRecordStore(url: recordsURL))
        servers.append(server)
        return server
    }

    /// The quit path end to end: the hook the app hands the delegate at launch,
    /// awaited the way `applicationShouldTerminate` awaits it.
    private func quit(_ server: KiteloopControlServer) async {
        let delegate = AppDelegate()
        delegate.finalizeRuns = { [weak server] in await server?.finalizeRunsAtQuit() }
        await delegate.finalizeBeforeQuit()
    }

    /// Runs an item to `done` on a first server and then throws that server away —
    /// the setup the "after a restart" tests share.
    private func landAndRestart() async throws {
        let (first, firstPort) = try await startServer()
        let projectID = try registerProject(named: "alpha", backlog: "- [ ] item-1 | Ship the thing | done")
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        first.track(.init(runId: "run-1", projectID: projectID, itemId: "item-1",
                          title: "Ship the thing", startedAt: Date()))
        land(autopilot, itemId: "item-1", title: "Ship the thing", outcome: .done)
        _ = try await get("/v1/runs/run-1/result", port: firstPort)
        registry = ControlSessionRegistry()
    }

    /// A record file inside a directory nobody may write to — a `~/.kiteloop` whose
    /// permissions have been tightened, and the cheapest stand-in for the full disk
    /// that produces the same throw. The mode is put back at teardown, since a
    /// directory that cannot be written cannot be emptied either.
    private func unwritableRecordsURL() throws -> URL {
        let locked = tempDir.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        }
        return locked.appendingPathComponent("control-runs.jsonl")
    }

    /// Half a JSON object — what the app being killed part-way through
    /// `appendLine` leaves at the end of the file.
    private let truncatedLine = "{\"runId\":\"run-2\",\"projectID\":\"/tmp/al"

    /// Adds a line to the fixture file exactly as written. `terminated: false` is
    /// the genuinely truncated case: the write never reached its newline.
    private func append(_ line: String, terminated: Bool = true) throws {
        let existing = (try? String(contentsOf: recordsURL, encoding: .utf8)) ?? ""
        try (existing + line + (terminated ? "\n" : "")).write(to: recordsURL, atomically: true, encoding: .utf8)
    }

    /// A decodable line built by hand, for fixtures that need a record *after* one
    /// the decoder refuses — which no sequence of `upsert` calls can produce.
    private func jsonLine(runId: String, startedAt: Date) -> String {
        let stamp = ISO8601DateFormatter().string(from: startedAt)
        return "{\"runId\":\"\(runId)\",\"projectID\":\"/tmp/alpha\",\"itemID\":\"item-1\"," +
               "\"title\":\"Ship the thing\",\"startedAt\":\"\(stamp)\",\"outcome\":\"done\"}"
    }

    private func openRecord(
        runId: String,
        // Inside the retention window by construction — see the note above.
        startedAt: Date = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3600).rounded())
    ) -> PersistedRunRecord {
        PersistedRunRecord(runId: runId, projectID: "/tmp/alpha", itemID: "item-1",
                           title: "Ship the thing", startedAt: startedAt)
    }

    /// What the end of an item leaves behind: a recorded result and an idle queue,
    /// so the server's finalization pass sees a run nothing is driving.
    ///
    /// `executionID` defaults to nil — the shape of a result recorded before the
    /// stamp existed, which is what most of these tests are about and what the
    /// item-id fallback has to keep closing.
    private func land(
        _ autopilot: BacklogAutopilot,
        itemId: String,
        title: String,
        outcome: BacklogAutopilot.ItemResult.Outcome,
        branch: String? = nil,
        duration: TimeInterval = 42,
        executionID: String? = nil
    ) {
        var result = BacklogAutopilot.ItemResult(id: itemId, title: title, outcome: outcome, duration: duration)
        result.executionID = executionID
        result.branch = branch
        autopilot.stageResultForTesting(result)
        autopilot.stageRunForTesting(status: .idle, queue: [])
        autopilot.stageExecutionIDForTesting(nil)
    }

    /// Where the sweep tests start their runs: comfortably inside the record
    /// store's age bound, and far enough back that a cap's worth of runs a minute
    /// apart all sit in the past.
    private let sweepEpoch = Date().addingTimeInterval(-4 * 3600)

    /// `count` finished runs of `item-1`, each with its own execution id and its
    /// own ending, started a minute apart from `sweepEpoch` — distinct starts, so
    /// which of them the sweep keeps cannot depend on how `runs` enumerates.
    /// Returns their ids, oldest first.
    @discardableResult
    private func landEndedRuns(_ count: Int, on server: KiteloopControlServer,
                               projectID: String) throws -> [String] {
        let autopilot = try XCTUnwrap(registry.entries[projectID]?.autopilot)
        let ids = (0..<count).map { String(format: "run-%03d", $0) }
        for (index, runId) in ids.enumerated() {
            server.track(.init(runId: runId, projectID: projectID, itemId: "item-1",
                               title: "Ship the thing",
                               startedAt: sweepEpoch.addingTimeInterval(TimeInterval(index) * 60)))
            land(autopilot, itemId: "item-1", title: "Ship the thing", outcome: .done, executionID: runId)
        }
        return ids
    }

    /// Starts a control server on a free loopback port, over `recordsURL` unless
    /// told otherwise. Each call builds a fresh `RunRecordStore`, which is what
    /// makes a second one a restart rather than a second view of live state.
    @discardableResult
    private func startServer(attachStore: Bool = true) async throws -> (KiteloopControlServer, UInt16) {
        let records = attachStore ? RunRecordStore(url: recordsURL) : nil
        let harness = try await ControlServerHarness.start(token: token) {
            KiteloopControlServer(registry: registry, token: $0, runRecords: records)
        }
        harnesses.append(harness)
        return (harness.server, harness.port)
    }

    /// Builds a real `ProjectSession` over a throwaway directory, seeds its backlog
    /// from markdown, and registers it. Returns the canonical project id — the key
    /// `RunInfo` uses, and the one a record is addressed by after a restart.
    @discardableResult
    private func registerProject(named name: String, backlog: String) throws -> String {
        let root = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootURL = URL(fileURLWithPath: root.path(percentEncoded: false), isDirectory: false)
        let project = KiteloopProject(rootURL: rootURL)
        try project.ensureDirectoryExists()

        let eventBus = EventBus(eventsURL: project.eventsURL)
        let orchestrator = Orchestrator(
            runtime: MockAgentRuntime(),
            eventBus: eventBus,
            subscriptionEngine: SubscriptionEngine(eventBus: eventBus),
            memoryManager: MemoryManager(project: project)
        )
        let session = ProjectSession(
            project: project,
            projectURL: rootURL,
            orchestrator: orchestrator,
            sessionStore: SessionStore(projectDir: rootURL),
            knowledgeStore: AgentKnowledgeStore(baseURL: project.knowledgeURL),
            knowledgeIndex: KnowledgeIndex(baseURL: project.knowledgeURL),
            context: makeContext()
        )
        session.backlogViewModel.backlogFile = BacklogParser.parse("## Epic: Work\n\n\(backlog)\n")

        registry.register(session: session, autopilot: BacklogAutopilot())
        return session.project.id
    }

    /// All stores are pointed at the temp directory so the tests never read or
    /// write the developer's real global config.
    private func makeContext() -> ProjectSessionContext {
        ProjectSessionContext(
            runtimeFactory: { MockAgentRuntime() },
            agentCatalogStore: AgentCatalogStore(storageURL: tempDir.appendingPathComponent("catalog.json")),
            packageResolver: nil,
            globalConfigStore: GlobalConfigStore(storageURL: tempDir.appendingPathComponent("global.json")),
            orgManifestLoader: OrgManifestLoader(),
            repoCloneService: RepoCloneService()
        )
    }

    private func get(_ path: String, port: UInt16) async throws -> (Int, [String: Any]) {
        try await harness(on: port).get(path)
    }

    private func post(_ path: String, port: UInt16) async throws -> (Int, [String: Any]) {
        try await harness(on: port).post(path)
    }

    /// The harness behind a port a test was handed by `startServer` — the
    /// restart tests hold two at once, and address each by its port.
    private func harness(on port: UInt16) throws -> ControlServerHarness {
        try XCTUnwrap(harnesses.first { $0.port == port }, "no server was started on port \(port)")
    }
}

/// A finalize that never comes back — the wedged pass the quit's bound exists
/// for. Parked on a continuation rather than a long sleep, so it is genuinely
/// stuck rather than merely slow, and `release()` lets it unwind at teardown so
/// the wedge does not outlive the test.
@MainActor
private final class WedgedFinalize {
    private(set) var didReturn = false
    private var continuation: CheckedContinuation<Void, Never>?

    func hang() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation
        }
        didReturn = true
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
