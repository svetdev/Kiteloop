import XCTest
import KiteloopCore
@testable import Kiteloop

/// `MetricIndex` is a *projection*: the JSONL logs stay the source of truth and
/// the database is a rebuildable, disposable view over them. Nearly every test
/// here is about that property rather than about SQL — that replaying a log
/// doesn't duplicate rows, that deleting the file loses nothing, and that the
/// index only ever contains what the logs already said.
final class MetricIndexTests: XCTestCase {

    private var tempDir: URL!
    private var sources: MetricIndex.Sources!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try makeTemporaryDirectory(prefix: "metric-index")
        sources = .standard(in: tempDir)
    }

    // MARK: - Aggregation

    /// The question that motivated the index: throughput and spend per size, over
    /// the whole history, without pulling the records out to add them up.
    func testAggregatesRunsBySize() async throws {
        try appendRuns([
            run(itemID: "a", size: "S", cost: 1.0, duration: 100),
            run(itemID: "b", size: "S", cost: 3.0, duration: 300),
            run(itemID: "c", size: "M", cost: 8.0, duration: 900)
        ])
        let index = MetricIndex(sources: sources)

        let groups = try await index.runAggregates(projectID: nil, groupedBy: .size)

        XCTAssertEqual(groups.map(\.key), ["S", "M"])
        XCTAssertEqual(groups[0].runs, 2)
        XCTAssertEqual(groups[0].costUSD, 4.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(groups[0].avgCostUSD), 2.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(groups[0].avgDurationSeconds), 200, accuracy: 0.0001)
        XCTAssertEqual(groups[1].runs, 1)
        XCTAssertEqual(groups[1].costUSD, 8.0, accuracy: 0.0001)
    }

    /// Cost per item is spend over the runs that produced something, not over
    /// every run: a night of empty runs makes the naive average look cheap.
    func testCostPerProducedRunIgnoresRunsThatBuiltNothing() async throws {
        try appendRuns([
            run(itemID: "a", cost: 4.0, changedFileCount: 3),
            run(itemID: "b", cost: 2.0, changedFileCount: 0)
        ])
        let index = MetricIndex(sources: sources)

        let total = try await index.runAggregates(projectID: nil, groupedBy: .total)

        XCTAssertEqual(total.count, 1)
        XCTAssertEqual(total[0].runs, 2)
        XCTAssertEqual(total[0].producedWork, 1)
        XCTAssertEqual(try XCTUnwrap(total[0].costPerProducedRunUSD), 6.0, accuracy: 0.0001)
    }

    /// A pickup refusal is on the same log, so it is indexed like everything
    /// else — but it is not a run, and counting it here would disagree with the
    /// in-memory readings of the same ledger (`PortfolioReport`, `RunEconomics`,
    /// `TaskMetricStore`'s summaries), which skip it.
    func testAggregatesSkipAttemptsThatNeverRan() async throws {
        try appendRuns([
            run(itemID: "a", cost: 4.0, changedFileCount: 3),
            run(itemID: "b", cost: 2.0, changedFileCount: 0),
            refusal(itemID: "c")
        ])
        let index = MetricIndex(sources: sources)

        let total = try await index.runAggregates(projectID: nil, groupedBy: .total)

        XCTAssertEqual(total[0].runs, 2)
        XCTAssertEqual(total[0].costUSD, 6.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(total[0].avgDurationSeconds), 600, accuracy: 0.0001,
                       "a zero-length refusal must not halve the average")
    }

    /// …and the item's own page still lists it. An attempt that never started is
    /// exactly what someone opening that page is looking for.
    func testAnItemsRunsStillIncludeItsRefusals() async throws {
        try appendRuns([run(itemID: "a"), refusal(itemID: "a")])
        let index = MetricIndex(sources: sources)

        let runs = try await index.runs(projectID: nil, itemID: "a")

        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs.filter(\.didNotRun).count, 1)
    }

    /// A run with no epic is a real group, not one to drop — dropping it would
    /// silently shrink the totals a caller is summing.
    func testUngroupedValuesGetTheirOwnBucket() async throws {
        try appendRuns([run(itemID: "a", epic: nil), run(itemID: "b", epic: "Now")])
        let index = MetricIndex(sources: sources)

        let groups = try await index.runAggregates(projectID: nil, groupedBy: .epic)

        XCTAssertEqual(Set(groups.map(\.key)), ["unknown", "Now"])
        XCTAssertEqual(groups.reduce(0) { $0 + $1.runs }, 2)
    }

    /// Every counter stays optional through the aggregate for the reason
    /// `TaskMetricRecord` keeps them optional: nothing recorded is not zero.
    func testTokensAreNullWhenNoRunRecordedAny() async throws {
        try appendRuns([run(itemID: "a"), run(itemID: "b")])
        let index = MetricIndex(sources: sources)

        let total = try await index.runAggregates(projectID: nil, groupedBy: .total)

        XCTAssertNil(total[0].usage)
        XCTAssertEqual(total[0].runsWithUsage, 0)
    }

    /// Partly-measured history sums what was measured and says how many runs that
    /// was, so the average isn't quietly taken over the wrong denominator.
    func testTokensSumOverTheRunsThatRecordedThem() async throws {
        var measured = run(itemID: "a")
        measured.inputTokens = 100
        measured.outputTokens = 20
        measured.cacheCreationTokens = 5
        measured.cacheReadTokens = 900
        try appendRuns([measured, run(itemID: "b")])
        let index = MetricIndex(sources: sources)

        let total = try await index.runAggregates(projectID: nil, groupedBy: .total)

        XCTAssertEqual(total[0].usage?.inputTokens, 100)
        XCTAssertEqual(total[0].usage?.cacheReadTokens, 900)
        XCTAssertEqual(total[0].runsWithUsage, 1)
        XCTAssertEqual(total[0].runs, 2)
    }

    func testProjectFilterNarrowsTheAggregate() async throws {
        try appendRuns([
            run(itemID: "a", project: "/tmp/alpha", cost: 1.0),
            // A trailing slash is how a record often stores it; the index keys on
            // the canonical path so it still matches.
            run(itemID: "b", project: "/tmp/alpha/", cost: 2.0),
            run(itemID: "c", project: "/tmp/beta", cost: 9.0)
        ])
        let index = MetricIndex(sources: sources)

        let alpha = try await index.runAggregates(projectID: "/tmp/alpha", groupedBy: .total)

        XCTAssertEqual(alpha[0].runs, 2)
        XCTAssertEqual(alpha[0].costUSD, 3.0, accuracy: 0.0001)
    }

    // MARK: - Turns

    /// Turns come from each project's own `.kiteloop/traces`, discovered from the
    /// runs the index holds — which is what keeps "rebuildable from the logs
    /// alone" true without the app having to register anything.
    func testAggregatesTurnsByRole() async throws {
        let project = try makeProject(named: "alpha")
        try appendRuns([run(itemID: "a", project: project.path)])
        try appendTurns(in: project, [
            turn(role: "worker", cost: 3.0, input: 10, output: 5),
            turn(role: "worker", cost: 1.0, input: 20, output: 5),
            turn(role: "reviewer", cost: 2.0, input: 30, output: 5)
        ])
        let index = MetricIndex(sources: sources)

        let groups = try await index.turnAggregates(projectID: project.id, groupedBy: .role)

        XCTAssertEqual(groups.map(\.key), ["worker", "reviewer"])
        XCTAssertEqual(groups[0].turns, 2)
        XCTAssertEqual(groups[0].costUSD, 4.0, accuracy: 0.0001)
        XCTAssertEqual(groups[0].usage?.inputTokens, 30)
        XCTAssertEqual(groups[1].turns, 1)
        XCTAssertEqual(groups[1].costUSD, 2.0, accuracy: 0.0001)
    }

    /// Only `.turn` spans are turns. A tool call in the same file is not one, and
    /// counting it would inflate every per-turn number.
    func testOnlyTurnSpansAreIndexed() async throws {
        let project = try makeProject(named: "alpha")
        try appendRuns([run(itemID: "a", project: project.path)])
        try appendTurns(in: project, [turn(role: "worker"), span(type: .toolCall)])
        let index = MetricIndex(sources: sources)

        let counts = try await index.counts()
        XCTAssertEqual(counts.turns, 1)
    }

    // MARK: - The index is a projection

    /// The idempotency guarantee: replaying a log the index has already read
    /// rewrites its rows in place. Ingest is keyed on each record's own id, so
    /// the same line seen twice is the same row.
    func testReplayingTheSameLogDoesNotDuplicateRows() async throws {
        let project = try makeProject(named: "alpha")
        try appendRuns([run(itemID: "a", project: project.path), run(itemID: "b", project: project.path)])
        try appendApprovals([approval(itemID: "a", project: project.path)])
        try appendTurns(in: project, [turn(role: "worker"), turn(role: "reviewer")])
        let index = MetricIndex(sources: sources)
        _ = try await index.counts()
        try await index.refresh()
        let before = try await index.counts()

        try await index.replay()
        try await index.replay()

        let after = try await index.counts()
        XCTAssertEqual(before.runs, 2)
        XCTAssertEqual(before.turns, 2)
        XCTAssertEqual(before.approvals, 1)
        XCTAssertEqual(after.runs, before.runs)
        XCTAssertEqual(after.turns, before.turns)
        XCTAssertEqual(after.approvals, before.approvals)
    }

    /// Losing the database loses nothing: delete the file, open a new index over
    /// the same logs, and it answers identically.
    func testRebuildFromTheLogsAloneReproducesTheSameAnswers() async throws {
        try appendRuns([
            run(itemID: "a", size: "S", cost: 1.5),
            run(itemID: "b", size: "M", cost: 4.5)
        ])
        let first = MetricIndex(sources: sources)
        let expected = try await first.runAggregates(projectID: nil, groupedBy: .size)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sources.databaseURL.path(percentEncoded: false)))

        try FileManager.default.removeItem(at: sources.databaseURL)
        let rebuilt = MetricIndex(sources: sources)
        let actual = try await rebuilt.runAggregates(projectID: nil, groupedBy: .size)

        XCTAssertEqual(actual.map(\.key), expected.map(\.key))
        XCTAssertEqual(actual.map(\.runs), expected.map(\.runs))
        XCTAssertEqual(actual.map(\.costUSD), expected.map(\.costUSD))
    }

    /// Deleting `metrics.sqlite3` is how a human forces a rebuild, and the
    /// database is three files: WAL mode leaves a `-wal` and a `-shm` behind.
    /// A connection opened on the remains gets a torn database — a fresh empty
    /// main file against sidecars describing the one that was deleted — and
    /// every statement against it fails with a disk I/O error. So the index
    /// throws the whole file set away and replays, rather than staying broken
    /// until the app is restarted.
    func testDeletingOnlyTheDatabaseFileStillRebuilds() async throws {
        try appendRuns([run(itemID: "a"), run(itemID: "b")])
        let live = MetricIndex(sources: sources)
        let before = try await live.counts()
        XCTAssertEqual(before.runs, 2)
        let wal = sources.databaseURL.path(percentEncoded: false) + "-wal"
        XCTAssertTrue(FileManager.default.fileExists(atPath: wal),
                      "without a sidecar left behind this test asserts nothing")

        try FileManager.default.removeItem(at: sources.databaseURL)

        // `live` is kept alive across the reopen on purpose: it is the still-open
        // connection holding those sidecars that makes the leftovers unreadable.
        let reopened = MetricIndex(sources: sources)
        let counts = try await reopened.counts()
        withExtendedLifetime(live) {}
        XCTAssertEqual(counts.runs, 2)
    }

    /// `rebuild()` is the explicit form of the same thing — drop everything,
    /// replay the logs, land on the same numbers.
    func testExplicitRebuildLandsOnTheSameRows() async throws {
        try appendRuns([run(itemID: "a"), run(itemID: "b")])
        let index = MetricIndex(sources: sources)
        let before = try await index.counts()

        try await index.rebuild()

        let after = try await index.counts()
        XCTAssertEqual(after.runs, before.runs)
        XCTAssertEqual(before.runs, 2)
    }

    /// Ingest is incremental — a query after an append sees the new run without
    /// the log ever being read from the top again.
    func testPicksUpRunsAppendedAfterTheFirstQuery() async throws {
        try appendRuns([run(itemID: "a")])
        let index = MetricIndex(sources: sources)
        let counts = try await index.counts()
        XCTAssertEqual(counts.runs, 1)

        try appendRuns([run(itemID: "b")])

        let runs = try await index.recentRuns(projectID: nil, limit: 10)
        XCTAssertEqual(Set(runs.map(\.itemID)), ["a", "b"])
    }

    /// A truncated or hand-edited log can't be caught up from a byte offset, so
    /// the index rebuilds rather than carrying rows nothing backs any more.
    func testATruncatedLogRebuildsInsteadOfDrifting() async throws {
        try appendRuns([run(itemID: "a"), run(itemID: "b"), run(itemID: "c")])
        let index = MetricIndex(sources: sources)
        let counts = try await index.counts()
        XCTAssertEqual(counts.runs, 3)

        try appendRuns([run(itemID: "d")], truncating: true)

        let runs = try await index.recentRuns(projectID: nil, limit: 10)
        XCTAssertEqual(runs.map(\.itemID), ["d"])
    }

    /// A schema this build doesn't know is dropped and replayed, not migrated —
    /// which is only safe because the logs are the source of truth.
    func testAStaleSchemaIsDroppedAndReplayed() async throws {
        try appendRuns([run(itemID: "a")])
        let index = MetricIndex(sources: sources)
        let counts = try await index.counts()
        XCTAssertEqual(counts.runs, 1)

        let database = try SQLiteDatabase(url: sources.databaseURL)
        try database.setUserVersion(MetricIndex.schemaVersion + 1)
        try database.execute("DROP TABLE runs")

        let reopened = MetricIndex(sources: sources)
        let replayed = try await reopened.counts()
        XCTAssertEqual(replayed.runs, 1)
    }

    /// Nothing writes here that did not first land in a log: the index over an
    /// empty directory is empty, and stays empty until a log says otherwise.
    func testAnIndexOverNoLogsIsEmpty() async throws {
        let index = MetricIndex(sources: sources)

        let counts = try await index.counts()

        XCTAssertEqual(counts.runs, 0)
        XCTAssertEqual(counts.turns, 0)
        XCTAssertEqual(counts.approvals, 0)
        XCTAssertEqual(counts.merges, 0)
    }

    /// A line the current build can't decode is skipped, not fatal — the log
    /// stays readable and the rest of it still indexes.
    func testAnUndecodableLineIsSkipped() async throws {
        try appendRuns([run(itemID: "a")])
        try appendRaw("{ not json at all\n", to: sources.metricsURL)
        try appendRuns([run(itemID: "b")])
        let index = MetricIndex(sources: sources)

        let counts = try await index.counts()
        XCTAssertEqual(counts.runs, 2)
    }

    // MARK: - Merge outcomes

    /// `merged` is decided after the run's row is written, so the index joins the
    /// two rather than reading one column. An event naming the execution belongs
    /// to that run — the auto-merge case, which decides before the row exists.
    func testAMergeOutcomeNamingAnExecutionLandsOnThatRun() async throws {
        try appendRuns([run(itemID: "a"), run(itemID: "b")])
        try appendMerges([merge(itemID: "a", merged: true, execution: "exec-a")])
        let index = MetricIndex(sources: sources)

        let runs = try await index.recentRuns(projectID: nil, limit: 10)

        XCTAssertEqual(runs.first { $0.itemID == "a" }?.merged, true)
        XCTAssertNil(runs.first { $0.itemID == "b" }?.merged, "no event, so nobody said")
    }

    /// The human gate names no execution: the run ended long before anyone looked
    /// at it, so the outcome goes to the item's most recent run that had finished.
    func testAMergeOutcomeNamingNoExecutionLandsOnTheLatestFinishedRunOfTheItem() async throws {
        let base = Date(timeIntervalSince1970: 1_770_000_000)
        try appendRuns([
            run(itemID: "a", startedAt: base),                                 // ends base+600
            run(itemID: "a", startedAt: base.addingTimeInterval(1_200))        // ends base+1800
        ])
        try appendMerges([merge(itemID: "a", merged: true, at: base.addingTimeInterval(3_600))])
        let index = MetricIndex(sources: sources)

        let runs = try await index.runs(projectID: nil, itemID: "a")

        XCTAssertEqual(runs.map(\.merged), [true, nil], "newest first: only the run being approved")
    }

    /// The aggregate that reads the column — "what did a merged item cost" — sees
    /// the folded value, not the NULL the run's own row carries.
    func testAggregatesCountTheFoldedMergeOutcome() async throws {
        try appendRuns([run(itemID: "a"), run(itemID: "b"), run(itemID: "c")])
        try appendMerges([
            merge(itemID: "a", merged: true, execution: "exec-a"),
            merge(itemID: "b", merged: false, execution: "exec-b")
        ])
        let index = MetricIndex(sources: sources)

        let total = try await index.runAggregates(projectID: nil, groupedBy: .total)

        XCTAssertEqual(total.first?.runs, 3)
        XCTAssertEqual(total.first?.merged, 1)
    }

    /// An outcome recorded before its run's row was written — which is what the
    /// auto-merge always does — joins when the row arrives, not never. The index
    /// reads each log incrementally, so this is the case a one-shot fold at
    /// ingest would lose.
    func testAnOutcomeIndexedBeforeItsRunFoldsWhenTheRunArrives() async throws {
        try appendMerges([merge(itemID: "a", merged: true, execution: "exec-a")])
        let index = MetricIndex(sources: sources)
        let beforeTheRunLands = try await index.counts()
        XCTAssertEqual(beforeTheRunLands.runs, 0)

        try appendRuns([run(itemID: "a")])

        let runs = try await index.recentRuns(projectID: nil, limit: 10)
        XCTAssertEqual(runs.first?.merged, true)
    }

    /// The last outcome recorded for a run wins: a merge refused at the gate and
    /// then completed by hand reads as merged.
    func testTheLastRecordedOutcomeWins() async throws {
        let base = Date(timeIntervalSince1970: 1_770_000_000)
        try appendRuns([run(itemID: "a", startedAt: base)])
        try appendMerges([
            merge(itemID: "a", merged: false, execution: "exec-a", at: base.addingTimeInterval(700)),
            merge(itemID: "a", merged: true, at: base.addingTimeInterval(4_000))
        ])
        let index = MetricIndex(sources: sources)

        let runs = try await index.recentRuns(projectID: nil, limit: 10)

        XCTAssertEqual(runs.first?.merged, true)
    }

    /// The fold is derived, like everything else here: dropping the database and
    /// replaying the logs lands on the same answer.
    func testTheFoldSurvivesARebuild() async throws {
        try appendRuns([run(itemID: "a")])
        try appendMerges([merge(itemID: "a", merged: true, execution: "exec-a")])
        let index = MetricIndex(sources: sources)
        _ = try await index.counts()

        try await index.rebuild()

        let runs = try await index.recentRuns(projectID: nil, limit: 10)
        XCTAssertEqual(runs.first?.merged, true)
        let rebuilt = try await index.counts()
        XCTAssertEqual(rebuilt.merges, 1, "replaying the log doesn't duplicate the event")
    }

    // MARK: - Listing

    func testRecentRunsAreNewestFirstAndLimited() async throws {
        let base = Date(timeIntervalSince1970: 1_770_000_000)
        try appendRuns((0..<5).map { run(itemID: "item-\($0)", startedAt: base.addingTimeInterval(Double($0) * 60)) })
        let index = MetricIndex(sources: sources)

        let runs = try await index.recentRuns(projectID: nil, limit: 2)

        XCTAssertEqual(runs.map(\.itemID), ["item-4", "item-3"])
    }

    /// A listed run comes back as the record that was logged, field for field —
    /// the endpoint serialises the same type from either path, so a row that
    /// decodes wrong would silently change what `/v1/metrics` reports.
    func testAListedRunRoundTripsItsRecord() async throws {
        var original = run(itemID: "a", size: "L", cost: 2.5)
        original.qualityScore = 0.87
        original.judgeDimensions = ["verify_passed": 1.0, "scope_respected": 0.75]
        original.judgeUnavailableReason = nil
        original.merged = true
        original.changedFileCount = 4
        original.model = "claude-opus-5"
        original.inputTokens = 11
        original.derivedCostUSD = 2.4
        original.predictedCostUSD = 1.9
        original.predictionSource = "size-band"
        original.overItemCap = true
        try appendRuns([original])
        let index = MetricIndex(sources: sources)

        let recent = try await index.recentRuns(projectID: nil, limit: 1)
        let listed = try XCTUnwrap(recent.first)

        XCTAssertEqual(listed.id, original.id)
        XCTAssertEqual(listed.itemID, "a")
        XCTAssertEqual(listed.declaredSize, "L")
        XCTAssertEqual(listed.costUSD, 2.5, accuracy: 0.0001)
        XCTAssertEqual(listed.qualityScore, 0.87)
        XCTAssertEqual(listed.judgeDimensions?["scope_respected"], 0.75)
        XCTAssertNil(listed.judgeUnavailableReason)
        XCTAssertEqual(listed.merged, true)
        XCTAssertEqual(listed.changedFileCount, 4)
        XCTAssertEqual(listed.model, "claude-opus-5")
        XCTAssertEqual(listed.inputTokens, 11)
        XCTAssertNil(listed.outputTokens)
        XCTAssertEqual(listed.derivedCostUSD, 2.4)
        XCTAssertEqual(listed.predictedCostUSD, 1.9)
        XCTAssertEqual(listed.predictionSource, "size-band")
        XCTAssertEqual(listed.overItemCap, true)
        XCTAssertEqual(listed.startedAt.timeIntervalSince1970,
                       original.startedAt.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - One item's history

    /// What the item detail view reads. Scoped to the item and to the project:
    /// item ids are only unique within a project, and a portfolio-wide ledger
    /// would otherwise hand one project another's runs.
    func testRunsForOneItemAreNewestFirstAndScopedToTheProject() async throws {
        let base = Date(timeIntervalSince1970: 1_770_000_000)
        try appendRuns([
            run(itemID: "wanted", startedAt: base, outcome: "blocked"),
            run(itemID: "wanted", startedAt: base.addingTimeInterval(3600), outcome: "done"),
            run(itemID: "other", startedAt: base.addingTimeInterval(60)),
            run(itemID: "wanted", project: "/tmp/beta", startedAt: base.addingTimeInterval(120))
        ])
        let index = MetricIndex(sources: sources)

        let runs = try await index.runs(projectID: "/tmp/alpha", itemID: "wanted")

        XCTAssertEqual(runs.map(\.outcome), ["done", "blocked"])
    }

    /// An item that has never run answers with an empty list rather than
    /// throwing — the view renders "never run", which is a fact, not an error.
    func testRunsForAnItemWithNoHistoryIsEmpty() async throws {
        try appendRuns([run(itemID: "a")])
        let index = MetricIndex(sources: sources)

        let runs = try await index.runs(projectID: nil, itemID: "never-run")

        XCTAssertTrue(runs.isEmpty)
    }

    /// The gate decisions, oldest first — the order a timeline reads in, and the
    /// opposite of the run listing beside it.
    func testApprovalsForOneItemComeBackOldestFirst() async throws {
        let base = Date(timeIntervalSince1970: 1_770_000_000)
        try appendApprovals([
            approval(itemID: "a", at: base),
            reopen(itemID: "a", approvedAt: base, at: base.addingTimeInterval(86_400)),
            approval(itemID: "b", at: base.addingTimeInterval(10))
        ])
        let index = MetricIndex(sources: sources)

        let events = try await index.approvals(projectID: "/tmp/alpha", itemID: "a")

        XCTAssertEqual(events.map(\.kind), [.approved, .reopened])
        XCTAssertEqual(events[1].toStatus, "ready")
        XCTAssertEqual(try XCTUnwrap(events[1].approvedAt).timeIntervalSince1970,
                       base.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - Escaped defects

    /// The same rate `TaskMetricStore` walks the array for, counted in SQL. It
    /// has to agree, since `/v1/metrics` serves whichever is attached.
    func testEscapedDefectRateMatchesTheInMemoryRule() async throws {
        let approvedAt = Date(timeIntervalSince1970: 1_770_000_000)
        try appendApprovals([
            approval(itemID: "a", at: approvedAt),
            approval(itemID: "b", at: approvedAt),
            reopen(itemID: "a", approvedAt: approvedAt, at: approvedAt.addingTimeInterval(2 * 86_400)),
            reopen(itemID: "b", approvedAt: approvedAt, at: approvedAt.addingTimeInterval(30 * 86_400))
        ])
        let index = MetricIndex(sources: sources)

        let rate = try await index.escapedDefectRate(projectID: nil)

        XCTAssertEqual(rate.approvals, 2)
        XCTAssertEqual(rate.reopened, 1)
        XCTAssertEqual(rate.lateReopened, 1)
        XCTAssertEqual(rate.windowDays, 7)
        XCTAssertEqual(rate.rate, 0.5)
    }

    /// Nothing approved is "not measured yet", never a perfect 0%.
    func testEscapedDefectRateIsNilBeforeAnyApproval() async throws {
        let index = MetricIndex(sources: sources)

        let escaped = try await index.escapedDefectRate(projectID: nil)
        XCTAssertNil(escaped.rate)
    }

    /// A reopen whose approval was never observed is a retry, not a defect this
    /// review let through — it is not counted at either end.
    func testAReopenWithNoObservedApprovalIsNotCounted() async throws {
        var orphan = reopen(itemID: "a", approvedAt: Date(), at: Date())
        orphan.approvedAt = nil
        try appendApprovals([orphan])
        let index = MetricIndex(sources: sources)

        let rate = try await index.escapedDefectRate(projectID: nil)

        XCTAssertEqual(rate.approvals, 0)
        XCTAssertEqual(rate.reopened, 0)
        XCTAssertEqual(rate.lateReopened, 0)
    }

    /// The evidence behind `MergeRetryChurn`: four `done` → `active` → `done`
    /// bounces in thirteen minutes, one approval standing throughout. Both
    /// paths have to fold it away identically — reading it raw would report
    /// four extra approvals and four reopens that never escaped anything.
    @MainActor
    func testEscapedDefectRateCollapsesMergeRetryChurnLikeTheStore() async throws {
        let base = Date(timeIntervalSince1970: 1_770_000_000)
        var cursor = base
        var events: [ItemApprovalEvent] = [approval(itemID: "a", at: cursor)]
        for _ in 0..<4 {
            let reopenedAt = cursor.addingTimeInterval(2 * 60)
            events.append(reopen(itemID: "a", approvedAt: cursor, at: reopenedAt))
            cursor = reopenedAt.addingTimeInterval(60)
            events.append(approval(itemID: "a", at: cursor))
        }
        try appendApprovals(events)
        let index = MetricIndex(sources: sources)
        let store = TaskMetricStore(metricsURL: tempDir.appendingPathComponent("metrics.jsonl"),
                                    estimatesURL: tempDir.appendingPathComponent("estimates.jsonl"),
                                    approvalsURL: sources.approvalsURL)

        let indexed = try await index.escapedDefectRate(projectID: nil)
        let inMemory = store.escapedDefectRate(projectPath: nil)

        XCTAssertEqual(indexed, inMemory)
        XCTAssertEqual(indexed.approvals, 1)
        XCTAssertEqual(indexed.reopened, 0)
        XCTAssertEqual(indexed.lateReopened, 0)
    }

    /// A reopen outside `MergeRetryChurn.window` is a genuine escape, not the
    /// retry loop finishing what it started — the collapse must not eat it.
    func testAReopenOutsideTheRetryWindowIsStillCountedAsReopened() async throws {
        let approvedAt = Date(timeIntervalSince1970: 1_770_000_000)
        try appendApprovals([
            approval(itemID: "a", at: approvedAt),
            reopen(itemID: "a", approvedAt: approvedAt,
                   at: approvedAt.addingTimeInterval(MergeRetryChurn.window + 60))
        ])
        let index = MetricIndex(sources: sources)

        let rate = try await index.escapedDefectRate(projectID: nil)

        XCTAssertEqual(rate.approvals, 1)
        XCTAssertEqual(rate.reopened, 1)
        XCTAssertEqual(rate.lateReopened, 0)
    }

    /// A reopen past the seven-day escaped-defect window is `lateReopened`
    /// whether or not it also cleared the much smaller retry window.
    func testAReopenBeyondTheEscapedDefectWindowIsLateReopened() async throws {
        let approvedAt = Date(timeIntervalSince1970: 1_770_000_000)
        try appendApprovals([
            approval(itemID: "a", at: approvedAt),
            reopen(itemID: "a", approvedAt: approvedAt, at: approvedAt.addingTimeInterval(30 * 86_400))
        ])
        let index = MetricIndex(sources: sources)

        let rate = try await index.escapedDefectRate(projectID: nil)

        XCTAssertEqual(rate.approvals, 1)
        XCTAssertEqual(rate.reopened, 0)
        XCTAssertEqual(rate.lateReopened, 1)
    }

    /// `projectID` still scopes the collapsed rate to one project, and `nil`
    /// still spans every project — the fold happens per key, not globally.
    func testEscapedDefectRateScopesToOneProjectAfterTheFold() async throws {
        let approvedAt = Date(timeIntervalSince1970: 1_770_000_000)
        try appendApprovals([
            approval(itemID: "a", project: "/tmp/alpha", at: approvedAt),
            reopen(itemID: "a", project: "/tmp/alpha", approvedAt: approvedAt,
                   at: approvedAt.addingTimeInterval(60)),
            approval(itemID: "a", project: "/tmp/alpha", at: approvedAt.addingTimeInterval(120)),
            approval(itemID: "b", project: "/tmp/beta", at: approvedAt),
            reopen(itemID: "b", project: "/tmp/beta", approvedAt: approvedAt,
                   at: approvedAt.addingTimeInterval(2 * 86_400))
        ])
        let index = MetricIndex(sources: sources)

        let alpha = try await index.escapedDefectRate(projectID: "/tmp/alpha")
        let beta = try await index.escapedDefectRate(projectID: "/tmp/beta")
        let all = try await index.escapedDefectRate(projectID: nil)

        XCTAssertEqual(alpha.approvals, 1, "the churn on alpha collapses to its one standing approval")
        XCTAssertEqual(alpha.reopened, 0)
        XCTAssertEqual(beta.approvals, 1)
        XCTAssertEqual(beta.reopened, 1)
        XCTAssertEqual(all.approvals, 2)
        XCTAssertEqual(all.reopened, 1)
    }

    // MARK: - First pass (metric #3a)

    /// The whole population rule in one case: what lands in the denominator,
    /// what lands in the numerator, and what is in neither.
    func testFirstPassRateCountsOnlyTheRunsAVerdictWasReachedOn() async throws {
        try appendRuns([
            run(itemID: "a", outcome: "done", retries: 0),                     // first pass
            run(itemID: "b", outcome: "awaiting-approval", retries: 0),        // first pass
            run(itemID: "c", outcome: "done", retries: 2),                     // passed, but reworked
            run(itemID: "d", outcome: "blocked:review did not pass", retries: 0),
            run(itemID: "e", outcome: "cancelled", retries: 0)                 // neither half
        ])
        let index = MetricIndex(sources: sources)

        let rate = try await index.firstPassRate(projectID: nil)

        XCTAssertEqual(rate.judged, 4, "the cancelled run is out of the denominator")
        XCTAssertEqual(rate.firstPass, 2)
        XCTAssertEqual(try XCTUnwrap(rate.rate), 0.5, accuracy: 0.0001)
    }

    /// A run cut short before any reviewer saw it is still a run review did not
    /// pass first time. It counts against the rate — silently dropping it would
    /// make a night of stalls read as a night of clean passes.
    func testARunBlockedBeforeReviewCountsAgainstTheRate() async throws {
        try appendRuns([
            run(itemID: "a", outcome: "done", retries: 0),
            run(itemID: "b", outcome: "blocked:stalled: no progress for 20 min on worker", retries: 0)
        ])
        let index = MetricIndex(sources: sources)

        let rate = try await index.firstPassRate(projectID: nil)

        XCTAssertEqual(rate.judged, 2)
        XCTAssertEqual(rate.firstPass, 1)
        XCTAssertEqual(try XCTUnwrap(rate.rate), 0.5, accuracy: 0.0001)
    }

    /// Nothing judged is "not measured yet", never "nothing passes" — and a
    /// history of nothing but cancelled runs is exactly that state.
    func testFirstPassRateIsNilBeforeAnyRunWasJudged() async throws {
        try appendRuns([run(itemID: "a", outcome: "cancelled")])
        let index = MetricIndex(sources: sources)

        let rate = try await index.firstPassRate(projectID: nil)

        XCTAssertEqual(rate.judged, 0)
        XCTAssertEqual(rate.firstPass, 0)
        XCTAssertNil(rate.rate)
    }

    /// Scoped like every other query here: one project's rate is about its own
    /// runs, not the machine's.
    func testFirstPassRateIsScopedByProject() async throws {
        try appendRuns([
            run(itemID: "a", project: "/tmp/alpha", outcome: "done", retries: 0),
            run(itemID: "b", project: "/tmp/beta", outcome: "done", retries: 3),
            run(itemID: "c", project: "/tmp/beta", outcome: "blocked:review did not pass")
        ])
        let index = MetricIndex(sources: sources)

        let alpha = try await index.firstPassRate(projectID: KiteloopProject.canonicalPath("/tmp/alpha"))
        XCTAssertEqual(alpha.judged, 1)
        XCTAssertEqual(try XCTUnwrap(alpha.rate), 1.0, accuracy: 0.0001)

        let beta = try await index.firstPassRate(projectID: KiteloopProject.canonicalPath("/tmp/beta"))
        XCTAssertEqual(beta.judged, 2)
        XCTAssertEqual(try XCTUnwrap(beta.rate), 0.0, accuracy: 0.0001)
    }

    /// `/v1/metrics` serves whichever is attached, so the SQL count and the
    /// in-memory walk have to be the same rule — over the same log, on records
    /// spanning every branch of the classification.
    @MainActor
    func testFirstPassRateMatchesTheInMemoryRule() async throws {
        let outcomes = ["done", "awaiting-approval", "blocked:review did not pass",
                        "blocked:cost cap $8.00 exceeded", "cancelled", "DONE"]
        try appendRuns(outcomes.enumerated().map { offset, outcome in
            run(itemID: "item-\(offset)", outcome: outcome, retries: offset % 2)
        })
        let index = MetricIndex(sources: sources)
        let store = TaskMetricStore(metricsURL: sources.metricsURL,
                                    estimatesURL: tempDir.appendingPathComponent("estimates.jsonl"),
                                    approvalsURL: tempDir.appendingPathComponent("approvals.jsonl"))

        let indexed = try await index.firstPassRate(projectID: nil)

        XCTAssertEqual(indexed, store.firstPassRate(projectPath: nil))
        // `DONE` is nobody's outcome, and neither path may guess that it is one:
        // SQLite's LIKE would have matched it case-insensitively where
        // `hasPrefix` does not, which is the drift this asserts against.
        XCTAssertEqual(indexed.judged, 4)
        XCTAssertEqual(indexed.firstPass, 1)
    }

    // MARK: - Run transcripts

    /// The first of the three diagnostic questions: what a run's agents actually
    /// did, in the order they did it, across every role file the run wrote.
    func testARunsTranscriptComesBackInOrderByExecution() async throws {
        let project = try makeProject(named: "alpha")
        try appendRuns([run(itemID: "a", project: project.path)])
        let start = Date(timeIntervalSince1970: 1_770_000_000)
        await write(in: project, [
            record(.text("on it"), run: "exec-a", role: "worker", at: start),
            record(.toolCall(.init(id: "t1", name: "Bash", input: "swift build")),
                   run: "exec-a", role: "worker", at: start.addingTimeInterval(1)),
            record(.text("looks good"), run: "exec-a", role: "reviewer", at: start.addingTimeInterval(3)),
            record(.text("done — nothing to change"), run: "exec-a", role: "worker",
                   at: start.addingTimeInterval(2))
        ])
        let index = MetricIndex(sources: sources)

        let records = try await index.transcriptRecords(projectID: project.id, executionID: "exec-a")

        XCTAssertEqual(records.map(\.kind), [.text, .toolCall, .text, .text])
        XCTAssertEqual(records.map(\.role), ["worker", "worker", "worker", "reviewer"])
        XCTAssertEqual(records[1].toolName, "Bash")
        XCTAssertEqual(records[2].text, "done — nothing to change")
        XCTAssertTrue(records.allSatisfy { $0.executionID == "exec-a" })

        let workerOnly = try await index.transcriptRecords(projectID: project.id,
                                                          executionID: "exec-a", role: "worker")
        XCTAssertEqual(workerOnly.count, 3)
    }

    /// The question 2026-08-09 was spent answering by hand, and the reason this
    /// item exists: every no-work run in a window, each with the words its
    /// worker finished on — one call, no shell loop over JSON files.
    func testEveryNoWorkRunInAWindowComesBackWithItsClosingMessage() async throws {
        let project = try makeProject(named: "alpha")
        let monday = Date(timeIntervalSince1970: 1_770_000_000)
        try appendRuns([
            run(itemID: "a", project: project.path, startedAt: monday, changedFileCount: 0),
            run(itemID: "b", project: project.path, startedAt: monday.addingTimeInterval(3_600),
                changedFileCount: 3),
            // Last week's empty run — outside the window, and so not an answer.
            run(itemID: "c", project: project.path, startedAt: monday.addingTimeInterval(-9 * 86_400),
                changedFileCount: 0)
        ])
        await write(in: project, [
            record(.text("reading the item"), run: "exec-a", role: "worker", at: monday),
            record(.text("already implemented by an earlier commit — nothing to do"),
                   run: "exec-a", role: "worker", at: monday.addingTimeInterval(60)),
            // The reviewer's last word is not the worker's closing message.
            record(.text("nothing to review"), run: "exec-a", role: "reviewer",
                   at: monday.addingTimeInterval(120)),
            record(.text("shipped it"), run: "exec-b", role: "worker", at: monday),
            record(.text("nothing left to build here"), run: "exec-c", role: "worker",
                   at: monday.addingTimeInterval(-9 * 86_400))
        ])
        let index = MetricIndex(sources: sources)

        let noWork = try await index.noWorkRuns(projectID: project.id,
                                                since: monday.addingTimeInterval(-7 * 86_400),
                                                until: monday.addingTimeInterval(7 * 86_400))

        XCTAssertEqual(noWork.map(\.itemID), ["a"], "a run that produced work is not an answer")
        XCTAssertEqual(noWork[0].closingMessage,
                       "already implemented by an earlier commit — nothing to do")
        XCTAssertEqual(try XCTUnwrap(noWork[0].closingMessageAt).timeIntervalSince1970,
                       monday.addingTimeInterval(60).timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(noWork[0].agentRecordCount, 2, "the worker's own records, not the reviewer's")
        XCTAssertEqual(noWork[0].recordCount, 3)
        XCTAssertFalse(noWork[0].producedWork)
    }

    /// The third question, and the ending `noWorkRuns` cannot quote: a run whose
    /// worker said nothing at all, which is what a session that died looks like.
    /// The prompt it was given does not count as output — it is not the worker's.
    func testARunWhoseWorkerProducedNoOutputIsReportedAsSuch() async throws {
        let project = try makeProject(named: "alpha")
        let start = Date(timeIntervalSince1970: 1_770_000_000)
        try appendRuns([
            run(itemID: "a", project: project.path, startedAt: start, changedFileCount: 0),
            run(itemID: "b", project: project.path, startedAt: start, changedFileCount: 0)
        ])
        await write(in: project, [
            // The run's prompt landed, and then the session died.
            record(.text("build item a"), run: "exec-a", role: "worker", at: start, sender: .human),
            record(.text("gave up after twenty minutes"), run: "exec-b", role: "worker",
                   at: start, sender: .agent("Builder"))
        ])
        let index = MetricIndex(sources: sources)

        let silent = try await index.runsWithoutAgentOutput(
            projectID: project.id, since: start.addingTimeInterval(-86_400),
            until: start.addingTimeInterval(86_400)
        )

        XCTAssertEqual(silent.map(\.itemID), ["a"])
        XCTAssertEqual(silent[0].agentRecordCount, 0)
        XCTAssertEqual(silent[0].roleRecordCount, 1, "the prompt was recorded; the answer never came")
        XCTAssertNil(silent[0].closingMessage)

        let noWork = try await index.noWorkRuns(projectID: project.id,
                                                since: start.addingTimeInterval(-86_400))
        let a = try XCTUnwrap(noWork.first { $0.itemID == "a" })
        XCTAssertNil(a.closingMessage, "a human prompt is not the worker's closing message")
    }

    /// What the index chose to hold and what it left in the log. Thinking, tool
    /// input and tool output are three quarters of the bytes and nothing filters
    /// on them, so the row records what the record *was* and where it is — the
    /// payload stays in the JSONL.
    func testThinkingAndToolPayloadsStayInTheLog() async throws {
        let project = try makeProject(named: "alpha")
        try appendRuns([run(itemID: "a", project: project.path)])
        await write(in: project, [
            record(.thinking("a long private deliberation"), run: "exec-a", role: "worker"),
            record(.toolResult(.init(id: "r1", toolCallID: "t1", output: "40 KB of build log")),
                   run: "exec-a", role: "worker"),
            record(.error("the session died"), run: "exec-a", role: "worker")
        ])
        let index = MetricIndex(sources: sources)

        let records = try await index.transcriptRecords(projectID: project.id, executionID: "exec-a")

        let byKind = Dictionary(uniqueKeysWithValues: records.map { ($0.kind, $0) })
        XCTAssertNil(byKind[.thinking]?.text)
        XCTAssertNil(byKind[.toolResult]?.text)
        XCTAssertEqual(byKind[.error]?.text, "the session died",
                       "an error is one of the two kinds worth indexing the words of")
        XCTAssertTrue(records.allSatisfy { $0.byteCount > 0 },
                      "a row says what its payload costs in the log it stayed in")
    }

    /// Transcripts are under the same contract as every other source: replaying
    /// a log the index has already read rewrites its rows rather than adding
    /// them. The message's own id is the key that makes that true.
    func testReplayingATranscriptDoesNotDuplicateRows() async throws {
        let project = try makeProject(named: "alpha")
        try appendRuns([run(itemID: "a", project: project.path)])
        await write(in: project, [
            record(.text("one"), run: "exec-a", role: "worker"),
            record(.text("two"), run: "exec-a", role: "reviewer")
        ])
        let index = MetricIndex(sources: sources)
        let before = try await index.counts()

        try await index.replay()
        try await index.replay()

        let after = try await index.counts()
        XCTAssertEqual(before.transcripts, 2)
        XCTAssertEqual(after.transcripts, before.transcripts)
    }

    /// Deleting the index loses no transcript: the JSONL under
    /// `.kiteloop/transcripts` is the source of truth, and a fresh index over
    /// the same logs answers identically.
    func testDeletingTheIndexLosesNoTranscript() async throws {
        let project = try makeProject(named: "alpha")
        try appendRuns([run(itemID: "a", project: project.path, changedFileCount: 0)])
        await write(in: project, [
            record(.text("nothing to build"), run: "exec-a", role: "worker")
        ])
        let first = MetricIndex(sources: sources)
        _ = try await first.counts()

        try FileManager.default.removeItem(at: sources.databaseURL)
        let rebuilt = MetricIndex(sources: sources)
        let records = try await rebuilt.transcriptRecords(projectID: project.id, executionID: "exec-a")

        XCTAssertEqual(records.map(\.text), ["nothing to build"])
    }

    /// A pruned transcript must not come back. The store deletes the records and
    /// leaves a tombstone; the files the index consumed are gone, which is the
    /// case a byte offset cannot be caught up from — so the index rebuilds, and
    /// rebuilding reads only what is still on disk.
    func testARebuildAfterPruningDoesNotResurrectRecords() async throws {
        let project = try makeProject(named: "alpha")
        try appendRuns([run(itemID: "a", project: project.path, changedFileCount: 0)])
        let store = RunTranscriptStore(baseURL: project.transcripts)
        await store.append([record(.text("nothing to build"), run: "exec-a", role: "worker")])
        let index = MetricIndex(sources: sources)
        let indexed = try await index.counts().transcripts
        XCTAssertEqual(indexed, 1)

        // A month on, the run is past the seven-day window.
        await store.prune(now: Date().addingTimeInterval(30 * 86_400))
        guard case .pruned = await store.status(of: "exec-a") else {
            return XCTFail("the test asserts nothing unless the store really pruned")
        }

        let afterPrune = try await index.counts().transcripts
        XCTAssertEqual(afterPrune, 0, "the live index drops what the log no longer holds")
        try await index.rebuild()
        let afterRebuild = try await index.counts().transcripts
        XCTAssertEqual(afterRebuild, 0)
        let records = try await index.transcriptRecords(projectID: project.id, executionID: "exec-a")
        XCTAssertTrue(records.isEmpty)

        let fresh = try await MetricIndex(sources: sources).counts().transcripts
        XCTAssertEqual(fresh, 0,
                       "a replay from the first byte must not reintroduce a pruned record")
    }

    /// Indexing is off the run's path. A run writes its transcript to a file and
    /// is done; nothing about that write opens, touches or waits on the index,
    /// which only ever catches up when something asks it a question.
    func testWritingATranscriptDoesNotTouchTheIndex() async throws {
        let project = try makeProject(named: "alpha")
        try appendRuns([run(itemID: "a", project: project.path)])
        let store = RunTranscriptStore(baseURL: project.transcripts)

        await store.append([record(.text("working"), run: "exec-a", role: "worker")])

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sources.databaseURL.path(percentEncoded: false)),
            "writing a transcript must not so much as open the index"
        )
    }

    // MARK: - Fixtures

    private func run(
        itemID: String = "item-1",
        project: String = "/tmp/alpha",
        size: String? = "M",
        epic: String? = "Now",
        cost: Double = 1.0,
        duration: Double = 600,
        startedAt: Date = Date(timeIntervalSince1970: 1_770_000_000),
        outcome: String = "done",
        retries: Int = 0,
        changedFileCount: Int? = nil
    ) -> TaskMetricRecord {
        var record = TaskMetricRecord(
            projectPath: project, projectName: "alpha", itemID: itemID, title: "Task \(itemID)",
            epic: epic, declaredSize: size, startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(duration), durationSeconds: duration,
            costUSD: cost, reviewerRetries: retries, outcome: outcome,
            workerAgent: "Builder", reviewerAgent: "Reviewer", executionID: "exec-\(itemID)"
        )
        record.changedFileCount = changedFileCount
        return record
    }

    /// The row a pickup gate writes when it refuses the item: no execution, no
    /// cost, no elapsed time.
    private func refusal(itemID: String, project: String = "/tmp/alpha",
                         at: Date = Date(timeIntervalSince1970: 1_770_000_000)) -> TaskMetricRecord {
        RetryCeiling.refusalRecord(
            item: BacklogItem(id: itemID, title: "Task \(itemID)", verify: nil, status: .ready,
                              type: .local, size: .m, queries: nil, cost: nil, completedDate: nil,
                              blockedReason: nil, jiraKey: nil, team: nil, detailPath: nil),
            refusal: .notGrounded, projectPath: project, projectName: "alpha", epic: "Now", at: at)
    }

    private func approval(itemID: String, project: String = "/tmp/alpha",
                          at: Date = Date(timeIntervalSince1970: 1_770_000_000)) -> ItemApprovalEvent {
        ItemApprovalEvent(projectPath: project, projectName: "alpha", itemID: itemID,
                          kind: .approved, at: at)
    }

    private func merge(itemID: String, merged: Bool, project: String = "/tmp/alpha",
                       execution: String? = nil,
                       at: Date = Date(timeIntervalSince1970: 1_770_003_600)) -> ItemMergeEvent {
        ItemMergeEvent(projectPath: project, projectName: "alpha", itemID: itemID,
                       merged: merged, at: at, executionID: execution)
    }

    private func reopen(itemID: String, project: String = "/tmp/alpha",
                        approvedAt: Date, at: Date) -> ItemApprovalEvent {
        ItemApprovalEvent(projectPath: project, projectName: "alpha", itemID: itemID,
                          kind: .reopened, at: at, approvedAt: approvedAt, toStatus: "ready")
    }

    private func turn(role: String, cost: Double = 1.0,
                      input: Int? = nil, output: Int? = nil) -> TraceSpan {
        var metadata: [String: String] = [
            TraceSpan.MetadataKey.role: role,
            TraceSpan.MetadataKey.executionID: "exec-a",
            TraceSpan.MetadataKey.costUSD: String(cost),
            TraceSpan.MetadataKey.model: "claude-opus-5"
        ]
        if let input { metadata[TraceSpan.MetadataKey.inputTokens] = String(input) }
        if let output { metadata[TraceSpan.MetadataKey.outputTokens] = String(output) }
        return span(type: .turn, metadata: metadata)
    }

    private func span(type: TraceSpan.SpanType, metadata: [String: String] = [:]) -> TraceSpan {
        let start = Date(timeIntervalSince1970: 1_770_000_000)
        return TraceSpan(id: UUID().uuidString, agentID: "Builder", sessionID: "s-1",
                         startTime: start, endTime: start.addingTimeInterval(30),
                         type: type, metadata: metadata)
    }

    // MARK: - Log writing

    /// A project rooted in the temp directory, so its `.kiteloop/traces` and
    /// `.kiteloop/transcripts` are the directories the index discovers from the
    /// runs written against it.
    private func makeProject(named name: String) throws -> Project {
        let root = tempDir.appendingPathComponent(name, isDirectory: true)
        let project = KiteloopProject(rootURL: root)
        try FileManager.default.createDirectory(at: project.tracesURL, withIntermediateDirectories: true)
        let path = root.path(percentEncoded: false)
        return Project(path: path, id: KiteloopProject.canonicalPath(path),
                       traces: project.tracesURL, transcripts: project.runTranscriptsURL)
    }

    private struct Project {
        let path: String
        let id: String
        let traces: URL
        let transcripts: URL
    }

    /// Writes through the real store, so the tests index the format a run
    /// actually leaves behind rather than one they made up.
    private func write(in project: Project, _ records: [RunTranscriptStore.Record]) async {
        await RunTranscriptStore(baseURL: project.transcripts).append(records)
    }

    private func record(_ content: Message.Content, run: String, role: String,
                        agent: String = "Builder",
                        at: Date = Date(timeIntervalSince1970: 1_770_000_000),
                        sender: Message.Sender? = nil) -> RunTranscriptStore.Record {
        RunTranscriptStore.Record(
            executionID: run, role: role, agentID: agent, recordedAt: at,
            message: Message(id: UUID(), timestamp: at,
                             sender: sender ?? .agent(agent), content: content)
        )
    }

    private func appendRuns(_ records: [TaskMetricRecord], truncating: Bool = false) throws {
        try appendRaw(jsonl(records), to: sources.metricsURL, truncating: truncating)
    }

    private func appendApprovals(_ events: [ItemApprovalEvent]) throws {
        try appendRaw(jsonl(events), to: sources.approvalsURL)
    }

    private func appendMerges(_ events: [ItemMergeEvent]) throws {
        try appendRaw(jsonl(events), to: sources.mergesURL)
    }

    private func appendTurns(in project: Project, _ spans: [TraceSpan]) throws {
        try appendRaw(jsonl(spans), to: project.traces.appending(path: "2026-02-01.jsonl"))
    }

    private func jsonl<T: Encodable>(_ values: [T]) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return values.compactMap { value -> String? in
            guard let data = try? encoder.encode(value) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        .map { $0 + "\n" }
        .joined()
    }

    private func appendRaw(_ text: String, to url: URL, truncating: Bool = false) throws {
        let fm = FileManager.default
        let path = url.path(percentEncoded: false)
        if truncating || !fm.fileExists(atPath: path) {
            try Data(text.utf8).write(to: url)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}
