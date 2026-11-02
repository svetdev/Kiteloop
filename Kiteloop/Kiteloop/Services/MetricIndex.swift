import Foundation
import KiteloopCore
import os.log

private let indexLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "metric-index")

/// A queryable projection of the observation logs.
///
/// Every measurement this app makes is appended to a JSONL file and, until this
/// existed, read back by loading the whole file into an array — which is how
/// `GET /v1/metrics` ended up capped at 200 records and why answering "what did
/// last night cost per merged item" meant pulling JSON over HTTP and
/// aggregating it in a script.
///
/// **The logs stay the source of truth.** This index is derived and disposable:
///
/// - Nothing writes here that did not first land in a log. There is no path by
///   which a measurement reaches the database and not the file, because a write
///   that must reach two stores to be durable has two ways to be lost.
/// - A schema change is a `DROP` and a replay, never a migration — `schemaVersion`
///   is stamped into the file and a mismatch rebuilds.
/// - Deleting the database loses nothing. `rebuild()` reconstructs it from the
///   logs alone, and replaying a log that is already indexed updates rows in
///   place rather than adding them, so ingest is idempotent.
/// - The logs stay plain JSONL, which is how most debugging actually happens.
///
/// Ingest is incremental: each source file's consumed byte count is recorded, and
/// a refresh reads only what was appended since. Neither refreshing nor querying
/// loads the history into memory — the aggregates are computed by SQLite.
///
/// **Run transcripts are projected here too**, under the same deal. What an
/// agent said during a run lands in `.kiteloop/transcripts/<executionID>/<role>.jsonl`
/// (`RunTranscriptStore`) and is indexed from there, which is what makes "every
/// no-work run this week with its closing message" one query instead of a shell
/// loop over JSON files. What is indexed is what is cheap and discriminating —
/// the kind, the execution, the role, the sender, the timestamps, and the text
/// of `text` and `error` records. **Thinking, tool inputs and tool outputs stay
/// in the log**: they are three quarters of the volume by measurement (see
/// `RunTranscriptStore`) and none of them is what a diagnostic query filters on.
/// A row names its record's byte offset, so reading the full payload means
/// opening the one line it came from.
actor MetricIndex {

    /// Bumping this makes every existing database rebuild on next open. That is
    /// the intended way to change the schema: there is no migration path and
    /// there is not meant to be one.
    static let schemaVersion: Int32 = 5

    /// Where the index and the logs it projects live. Separated from the actor so
    /// tests can point the whole set at a temp directory.
    struct Sources: Sendable {
        var databaseURL: URL
        var metricsURL: URL
        var approvalsURL: URL
        var mergesURL: URL

        static func standard(in directory: URL) -> Sources {
            Sources(
                databaseURL: directory.appendingPathComponent("metrics.sqlite3"),
                metricsURL: directory.appendingPathComponent("task-metrics.jsonl"),
                approvalsURL: directory.appendingPathComponent("task-approvals.jsonl"),
                mergesURL: directory.appendingPathComponent("task-merges.jsonl")
            )
        }

        static var `default`: Sources {
            let dir = KiteloopHome.url
                .appendingPathComponent(".kiteloop", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return .standard(in: dir)
        }
    }

    private let sources: Sources
    private var database: SQLiteDatabase?

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Opening the database is deferred to the first use so constructing this at
    /// app launch costs no I/O.
    init(sources: Sources = .default) {
        self.sources = sources
    }

    // MARK: - Maintenance

    /// Catches the index up with whatever has been appended to the logs since the
    /// last call. Cheap enough to run before every query: it reads only the new
    /// tail of each file.
    func refresh() throws {
        let db = try open()
        // A source that shrank is one that was truncated, rotated or hand-edited,
        // and its already-indexed rows can no longer be trusted to correspond to
        // anything. Rebuilding is the whole recovery story, so use it.
        if try anySourceShrank(db) {
            indexLog.notice("a metric log shrank — rebuilding the index from the logs")
            try rebuild()
            return
        }
        try ingestAll(db)
    }

    /// Drops every row and replays the logs from the first byte. The recovery
    /// path for a corrupt, stale-schema or hand-deleted index.
    func rebuild() throws {
        let db = try open()
        try db.transaction {
            for table in Self.tables {
                try db.execute("DELETE FROM \(table)")
            }
        }
        try ingestAll(db)
    }

    /// Re-ingests every source from the first byte **without** dropping what is
    /// already indexed — the idempotency guarantee, exercised directly by the
    /// tests: replaying a log the index has already seen updates its rows in
    /// place and leaves the row count where it was.
    func replay() throws {
        let db = try open()
        try db.run("UPDATE sources SET bytes_consumed = 0")
        try ingestAll(db)
    }

    /// How many rows each table holds — for tests and diagnostics. Catches the
    /// index up first, like every other read here: counting straight out of the
    /// database reports whatever was ingested by some *earlier* call, so on a
    /// freshly opened index it is always zero however much the logs hold. That
    /// is a diagnostic that lies in the one direction a diagnostic must not.
    func counts() throws -> (runs: Int, turns: Int, approvals: Int, transcripts: Int, merges: Int) {
        let db = try refreshed()
        func count(_ table: String) throws -> Int {
            try db.query("SELECT COUNT(*) FROM \(table)") { $0.int(0) }.first ?? 0
        }
        return (try count("runs"), try count("turns"), try count("approvals"),
                try count("transcripts"), try count("merges"))
    }

    // MARK: - Queries

    /// The most recent measured runs, newest first — what `GET /v1/metrics`
    /// lists, read with an `ORDER BY … LIMIT` instead of by sorting the whole
    /// history in memory.
    func recentRuns(projectID: String?, limit: Int) throws -> [TaskMetricRecord] {
        let db = try refreshed()
        let columns = Self.runColumns.joined(separator: ", ")
        return try db.query(
            """
            SELECT \(columns) FROM runs
            WHERE (?1 = '' OR project_id = ?1)
            ORDER BY completed_at DESC LIMIT ?2
            """,
            [.text(projectID ?? ""), .int(Int64(limit))],
            Self.decodeRun
        )
    }

    /// Every recorded run of **one item**, newest first.
    ///
    /// What the item detail view reads instead of walking the ledger: answering
    /// "why has this been run five times" used to mean loading
    /// `task-metrics.jsonl` and filtering it by hand, which is a scan of the
    /// whole history per item and a second implementation of the filter. The
    /// `runs(project_id, item_id)` index makes it a lookup.
    func runs(projectID: String?, itemID: String, limit: Int = 200) throws -> [TaskMetricRecord] {
        let db = try refreshed()
        let columns = Self.runColumns.joined(separator: ", ")
        return try db.query(
            """
            SELECT \(columns) FROM runs
            WHERE (?1 = '' OR project_id = ?1) AND item_id = ?2
            ORDER BY completed_at DESC LIMIT ?3
            """,
            [.text(projectID ?? ""), .text(itemID), .int(Int64(limit))],
            Self.decodeRun
        )
    }

    /// One item's gate decisions, oldest first — the order a timeline reads in.
    ///
    /// The same rows `escapedDefectRate` counts, handed back individually: the
    /// rate says how often approvals came back, and this says whether *this*
    /// item's did.
    func approvals(projectID: String?, itemID: String, limit: Int = 200) throws -> [ItemApprovalEvent] {
        let db = try refreshed()
        return try db.query(
            """
            SELECT id, project_path, project_name, item_id, kind, at, approved_at, to_status
            FROM approvals
            WHERE (?1 = '' OR project_id = ?1) AND item_id = ?2
            ORDER BY at ASC LIMIT ?3
            """,
            [.text(projectID ?? ""), .text(itemID), .int(Int64(limit))]
        ) { row in
            ItemApprovalEvent(
                id: row.text(0),
                projectPath: row.text(1),
                projectName: row.text(2),
                itemID: row.text(3),
                // A kind this build doesn't know reads as a reopen rather than
                // failing the row: the timeline would rather show an event it
                // cannot name than drop one it cannot parse.
                kind: ItemApprovalEvent.Kind(rawValue: row.text(4)) ?? .reopened,
                at: row.date(5),
                approvedAt: row.optDate(6),
                toStatus: row.optText(7)
            )
        }
    }

    /// One aggregate row per group over the **whole** history — no record limit,
    /// because the answer is a handful of groups however many runs went into it.
    func runAggregates(projectID: String?, groupedBy grouping: MetricGrouping) throws -> [RunAggregate] {
        guard !grouping.isTurnDimension else { return [] }
        let db = try refreshed()
        let key = Self.keyExpression(for: grouping)
        let groupBy = grouping.column == nil ? "" : "GROUP BY k"
        let rows = try db.query(
            """
            SELECT \(key) AS k,
                   COUNT(*),
                   COALESCE(SUM(cost_usd), 0),
                   SUM(derived_cost_usd),
                   COALESCE(SUM(duration_seconds), 0),
                   COALESCE(SUM(reviewer_retries), 0),
                   COALESCE(SUM(CASE WHEN merged = 1 THEN 1 ELSE 0 END), 0),
                   COALESCE(SUM(produced_work), 0),
                   SUM(input_tokens), SUM(output_tokens),
                   SUM(cache_creation_tokens), SUM(cache_read_tokens),
                   COUNT(input_tokens)
            FROM runs
            WHERE (?1 = '' OR project_id = ?1) AND \(Self.ranSQL())
            \(groupBy)
            """,
            [.text(projectID ?? "")]
        ) { row in
            RunAggregate(
                key: row.text(0),
                runs: row.int(1),
                costUSD: row.double(2),
                derivedCostUSD: row.optDouble(3),
                durationSeconds: row.double(4),
                reviewerRetries: row.int(5),
                merged: row.int(6),
                producedWork: row.int(7),
                usage: Self.usage(row, firstColumn: 8),
                runsWithUsage: row.int(12)
            )
        }
        return Self.ordered(rows, by: grouping, key: \.key, weight: { Double($0.runs) })
    }

    /// The same shape over turns — `aggregate=role`, the split that says what
    /// share of a night's spend went to review.
    func turnAggregates(projectID: String?, groupedBy grouping: MetricGrouping) throws -> [TurnAggregate] {
        let db = try refreshed()
        let key = Self.keyExpression(for: grouping)
        let groupBy = grouping.column == nil ? "" : "GROUP BY k"
        let rows = try db.query(
            """
            SELECT \(key) AS k,
                   COUNT(*),
                   COALESCE(SUM(cost_usd), 0),
                   SUM(derived_cost_usd),
                   COALESCE(SUM(duration_seconds), 0),
                   SUM(input_tokens), SUM(output_tokens),
                   SUM(cache_creation_tokens), SUM(cache_read_tokens),
                   COUNT(input_tokens)
            FROM turns
            WHERE (?1 = '' OR project_id = ?1)
            \(groupBy)
            """,
            [.text(projectID ?? "")]
        ) { row in
            TurnAggregate(
                key: row.text(0),
                turns: row.int(1),
                costUSD: row.double(2),
                derivedCostUSD: row.optDouble(3),
                durationSeconds: row.double(4),
                usage: Self.usage(row, firstColumn: 5),
                turnsWithUsage: row.int(9)
            )
        }
        return Self.ordered(rows, by: grouping, key: \.key, weight: { Double($0.turns) })
    }

    /// Success metric #3b, folded through `MergeRetryChurn` the same way
    /// `TaskMetricStore.escapedDefectRate` is: a reopen the gate-retry loop
    /// re-approved within its own retry window is the same approval
    /// continuing, not a new approval and not an escape, so neither side of it
    /// reaches the counts below. A reopen whose approval was never observed is
    /// not counted at either end.
    func escapedDefectRate(projectID: String?,
                           window: TimeInterval = EscapedDefectRate.standardWindow) throws -> EscapedDefectRate {
        let db = try refreshed()
        let rows = try db.query(
            """
            SELECT project_path, item_id, kind, at, approved_at
            FROM approvals
            WHERE (?1 = '' OR project_id = ?1)
            ORDER BY item_id, at
            """,
            [.text(projectID ?? "")]
        ) { row -> (projectPath: String, itemID: String, kind: ItemApprovalEvent.Kind, at: Date, approvedAt: Date?) in
            (row.text(0), row.text(1),
             ItemApprovalEvent.Kind(rawValue: row.text(2)) ?? .reopened,
             row.date(3), row.optDate(4))
        }

        let moments = rows.map { row in
            MergeRetryChurn.Moment(
                key: KiteloopProject.canonicalPath(row.projectPath) + "\u{0}" + row.itemID,
                isReopen: row.kind == .reopened, at: row.at, payload: row)
        }
        return MergeRetryChurn.escapedDefectRate(moments, window: window,
                                                 kind: { $0.kind }, approvedAt: { $0.approvedAt })
    }

    /// Success metric #3a, counted by SQL rather than by walking every record:
    /// the share of judged runs review passed on the first worker attempt. Same
    /// semantics as `TaskMetricStore.firstPassRate` — both are generated from
    /// the outcome prefixes on `FirstPassRate`, so neither can drift.
    ///
    /// The whole history, like the defect rate beside it: no `LIMIT` here,
    /// because the rate is not about the page of records a caller asked for.
    func firstPassRate(projectID: String?) throws -> FirstPassRate {
        let db = try refreshed()
        let row = try db.query(
            """
            SELECT
              COALESCE(SUM(\(Self.reachedVerdictSQL)), 0),
              COALESCE(SUM((\(Self.passedReviewSQL)) AND reviewer_retries = 0), 0)
            FROM runs
            WHERE (?1 = '' OR project_id = ?1)
            """,
            [.text(projectID ?? "")]
        ) { ($0.int(0), $0.int(1)) }.first ?? (0, 0)
        return FirstPassRate(judged: row.0, firstPass: row.1)
    }

    /// `FirstPassRate`'s prefix rule as a SQL predicate. `GLOB` rather than
    /// `LIKE` because `LIKE` is case-insensitive over ASCII and `String.hasPrefix`
    /// is not — the two paths have to answer the same thing on the same rows.
    /// The prefixes are constants in this binary; no caller string reaches here.
    private static var passedReviewSQL: String {
        FirstPassRate.passedPrefixes
            .map { "outcome GLOB '\($0)*'" }
            .joined(separator: " OR ")
    }

    private static var reachedVerdictSQL: String {
        "(\(passedReviewSQL)) OR outcome GLOB '\(FirstPassRate.rejectedPrefix)*'"
    }

    /// Rows that record an execution, excluding the ones that record a pickup
    /// refusal (`TaskMetricRecord.didNotRun`). Asked wherever this index counts
    /// or averages runs, because the in-memory readings of the same ledger —
    /// `PortfolioReport`, `RunEconomics`, `TaskMetricStore`'s summaries — skip
    /// them too, and the SQL and the walk have to answer the same thing about
    /// the same night. `GLOB` for the reason `passedReviewSQL` gives.
    ///
    /// Deliberately not asked by `runs(projectID:itemID:)`: an item's own page
    /// lists every attempt at it, and a refusal is one.
    ///
    /// `column` is the qualified name of the outcome column in the query asking
    /// — a literal from this file, like the prefix itself.
    private static func ranSQL(_ column: String = "outcome") -> String {
        "\(column) NOT GLOB '\(TaskMetricRecord.didNotRunPrefix)*'"
    }

    // MARK: - Transcript queries

    /// One run's transcript records in the order they happened, optionally for a
    /// single role. The order is by timestamp and then by the record's byte
    /// offset in its file, so records a turn wrote inside the same second come
    /// back in the order they were written rather than in whatever order SQLite
    /// found them.
    func transcriptRecords(projectID: String?, executionID: String,
                           role: String? = nil, limit: Int = 5_000) throws -> [TranscriptEntry] {
        let db = try refreshed()
        return try db.query(
            """
            SELECT \(Self.transcriptQueryColumns) FROM transcripts
            WHERE (?1 = '' OR project_id = ?1) AND execution_id = ?2 AND (?3 = '' OR role = ?3)
            ORDER BY recorded_at ASC, byte_offset ASC
            LIMIT ?4
            """,
            [.text(projectID ?? ""), .text(executionID), .text(role ?? ""), .int(Int64(limit))],
            Self.decodeTranscriptEntry
        )
    }

    /// Every run in the window that left no work behind, each with the closing
    /// message its worker ended on — the question 2026-08-09 was spent answering
    /// by hand, in one statement.
    ///
    /// "No work" is `TaskMetricRecord.producedWork`, derived at ingest, so it
    /// means the same here as everywhere else: a run whose evidence is `empty`
    /// *or* `unknown`, never a run assumed productive because nobody could tell.
    /// The closing message is the last text the role's agent produced, which is
    /// what `RunClosingMessage` records off the execution's steps — the same
    /// words, from the transcript rather than from an in-memory execution that
    /// is gone by the next morning. Nil means the role said nothing at all,
    /// which `agentRecordCount == 0` confirms.
    func noWorkRuns(projectID: String?, since: Date, until: Date = .distantFuture,
                    role: String = "worker", limit: Int = 500) throws -> [RunTranscriptSummary] {
        try runSummaries(projectID: projectID, since: since, until: until,
                         role: role, filter: "r.produced_work = 0", limit: limit)
    }

    /// Runs in the window whose `role` node produced nothing at all — no text,
    /// no tool call, no error. What a session that died before it said a word
    /// looks like, and the one ending `noWorkRuns` cannot quote.
    ///
    /// Ask it over a window inside the transcript retention period. A run older
    /// than that has had its records pruned and looks identical from here; the
    /// store is what tells "aged out" from "never written" (`RunTranscriptStore.status`),
    /// and this index deliberately does not duplicate that judgement.
    func runsWithoutAgentOutput(projectID: String?, since: Date, until: Date = .distantFuture,
                                role: String = "worker", limit: Int = 500) throws -> [RunTranscriptSummary] {
        try runSummaries(projectID: projectID, since: since, until: until,
                         role: role, filter: "COALESCE(s.role_agent_records, 0) = 0", limit: limit)
    }

    /// Both transcript-against-run questions are the same join under a different
    /// `WHERE`. `filter` is a literal from this file — no caller string reaches
    /// the SQL.
    private func runSummaries(projectID: String?, since: Date, until: Date,
                              role: String, filter: String, limit: Int) throws -> [RunTranscriptSummary] {
        let db = try refreshed()
        return try db.query(
            """
            SELECT r.id, r.project_id, r.item_id, r.title, r.execution_id, r.completed_at,
                   r.outcome, r.produced_work,
                   COALESCE(s.records, 0), COALESCE(s.role_records, 0),
                   COALESCE(s.role_agent_records, 0), c.text, c.recorded_at
            FROM runs r
            LEFT JOIN (
                SELECT project_id, execution_id,
                       COUNT(*) AS records,
                       SUM(role = ?4) AS role_records,
                       SUM(role = ?4 AND sender = '\(TranscriptEntry.Sender.agent.rawValue)')
                           AS role_agent_records
                FROM transcripts GROUP BY project_id, execution_id
            ) s ON s.project_id = r.project_id AND s.execution_id = r.execution_id
            LEFT JOIN (
                SELECT project_id, execution_id, text, recorded_at,
                       ROW_NUMBER() OVER (
                           PARTITION BY project_id, execution_id
                           ORDER BY recorded_at DESC, byte_offset DESC
                       ) AS recency
                FROM transcripts
                WHERE role = ?4
                  AND sender = '\(TranscriptEntry.Sender.agent.rawValue)'
                  AND kind = '\(TranscriptEntry.Kind.text.rawValue)'
                  AND text IS NOT NULL AND TRIM(text) <> ''
            ) c ON c.project_id = r.project_id AND c.execution_id = r.execution_id AND c.recency = 1
            WHERE (?1 = '' OR r.project_id = ?1)
              AND r.completed_at >= ?2 AND r.completed_at < ?3
              -- A refusal at pickup has no transcript because it had no
              -- session, so it would answer both of these questions ("produced
              -- nothing", "the agent never spoke") without ever having been the
              -- kind of run they are asked about.
              AND \(Self.ranSQL("r.outcome"))
              AND \(filter)
            ORDER BY r.completed_at DESC
            LIMIT ?5
            """,
            [.text(projectID ?? ""), .of(since), .of(until), .text(role), .int(Int64(limit))]
        ) { row in
            RunTranscriptSummary(
                runID: row.text(0),
                projectID: row.text(1),
                itemID: row.text(2),
                title: row.text(3),
                executionID: row.optText(4),
                completedAt: row.date(5),
                outcome: row.text(6),
                producedWork: row.int(7) != 0,
                recordCount: row.int(8),
                roleRecordCount: row.int(9),
                agentRecordCount: row.int(10),
                closingMessage: row.optText(11),
                closingMessageAt: row.optDate(12)
            )
        }
    }

    // MARK: - Ingest

    private func ingestAll(_ db: SQLiteDatabase) throws {
        let newRuns = try ingestRuns(db)
        let newMerges = try ingestMerges(db)
        try ingestApprovals(db)
        // Whether a run's work landed is decided after its row was written, so
        // the join is redone whenever either side gains a line — and only then,
        // since a query that changed nothing has nothing to re-fold.
        if newRuns || newMerges { try foldMergeOutcomes(db) }
        // Derived from the runs just indexed rather than from anything the app
        // told us, which is what keeps "rebuildable from the logs alone" true:
        // a project's turns and transcripts live in its own `.kiteloop`, and the
        // runs name every project that has ever produced one.
        for (projectID, project) in try indexedProjects(db) {
            for file in jsonlFiles(in: project.tracesURL) {
                try ingestTurns(db, url: file, projectID: projectID)
            }
            // One directory per run, one file per role inside it.
            for directory in subdirectories(of: project.runTranscriptsURL) {
                for file in jsonlFiles(in: directory) {
                    try ingestTranscripts(db, url: file, projectID: projectID)
                }
            }
        }
    }

    private func ingestRuns(_ db: SQLiteDatabase) throws -> Bool {
        let sql = Self.upsert(into: "runs", columns: Self.runColumns)
        return try ingest(db, url: sources.metricsURL) { [self] line, _ in
            guard let record = try? decoder.decode(TaskMetricRecord.self, from: line) else { return }
            try db.run(sql, bindings(for: record))
        }
    }

    private func ingestMerges(_ db: SQLiteDatabase) throws -> Bool {
        let sql = Self.upsert(into: "merges", columns: Self.mergeColumns)
        return try ingest(db, url: sources.mergesURL) { [self] line, _ in
            guard let event = try? decoder.decode(ItemMergeEvent.self, from: line) else { return }
            try db.run(sql, [
                .text(event.id),
                .text(KiteloopProject.canonicalPath(event.projectPath)),
                .text(event.projectPath),
                .text(event.projectName),
                .text(event.itemID),
                .int(event.merged ? 1 : 0),
                .of(event.at),
                .of(event.executionID),
                .of(event.reason)
            ])
        }
    }

    /// Joins the merge log to the runs it describes — `MergeOutcomeFold`'s rule,
    /// written in SQL because these runs are counted by SQL.
    ///
    /// An event names its run's `execution_id` when the writer knew it (the
    /// auto-merge, which decides before the run's row is even written), and
    /// otherwise belongs to the item's most recent run that had finished by the
    /// time it was recorded (the human gate). The last event recorded for a run
    /// wins, so a merge that failed and was later retried by hand reads merged.
    /// A run no event describes is not touched: `merged` stays NULL, which is
    /// unknown rather than "did not merge".
    private func foldMergeOutcomes(_ db: SQLiteDatabase) throws {
        try db.run(Self.foldMergeOutcomesSQL)
    }

    private static let foldMergeOutcomesSQL = """
    WITH resolved AS (
        SELECT r.id AS run_id, m.merged AS merged,
               ROW_NUMBER() OVER (PARTITION BY r.id ORDER BY m.rowid DESC) AS recency
        FROM runs r
        JOIN merges m ON m.project_id = r.project_id AND m.item_id = r.item_id
        WHERE CASE WHEN m.execution_id IS NULL OR m.execution_id = ''
                   THEN m.at >= r.completed_at
                        AND NOT EXISTS (
                            SELECT 1 FROM runs later
                            WHERE later.project_id = r.project_id
                              AND later.item_id = r.item_id
                              AND later.completed_at > r.completed_at
                              AND later.completed_at <= m.at)
                   ELSE m.execution_id = r.execution_id
              END
    )
    UPDATE runs SET merged = (SELECT merged FROM resolved WHERE run_id = runs.id AND recency = 1)
    WHERE id IN (SELECT run_id FROM resolved WHERE recency = 1)
    """

    private func ingestApprovals(_ db: SQLiteDatabase) throws {
        let sql = Self.upsert(into: "approvals", columns: Self.approvalColumns)
        try ingest(db, url: sources.approvalsURL) { [self] line, _ in
            guard let event = try? decoder.decode(ItemApprovalEvent.self, from: line) else { return }
            try db.run(sql, [
                .text(event.id),
                .text(KiteloopProject.canonicalPath(event.projectPath)),
                .text(event.projectPath),
                .text(event.projectName),
                .text(event.itemID),
                .text(event.kind.rawValue),
                .of(event.at),
                .of(event.approvedAt),
                .of(event.toStatus)
            ])
        }
    }

    private func ingestTurns(_ db: SQLiteDatabase, url: URL, projectID: String) throws {
        let sql = Self.upsert(into: "turns", columns: Self.turnColumns)
        try ingest(db, url: url) { [self] line, _ in
            guard let span = try? decoder.decode(TraceSpan.self, from: line), span.type == .turn else { return }
            let usage = span.tokenUsage
            try db.run(sql, [
                .text(span.id),
                .text(projectID),
                .of(span.metadata[TraceSpan.MetadataKey.executionID]),
                .text(span.agentID),
                .text(span.sessionID),
                .of(span.metadata[TraceSpan.MetadataKey.role]),
                .of(span.startTime),
                .of(span.endTime),
                .text(DayKey.string(for: span.startTime)),
                .of(span.duration),
                .of(span.model),
                .of(span.reportedCostUSD),
                .of(span.derivedCostUSD),
                .of(span.priceVersion),
                .of(usage?.inputTokens),
                .of(usage?.outputTokens),
                .of(usage?.cacheCreationTokens),
                .of(usage?.cacheReadTokens)
            ])
        }
    }

    /// One line of a run's transcript per row. The file is
    /// `<transcripts>/<executionID>/<role>.jsonl`, but the execution and the role
    /// are read from the records themselves rather than from the path: the store
    /// sanitises both to make them safe as file names, and a row keyed on a
    /// sanitised name would not join to the run that wrote it.
    private func ingestTranscripts(_ db: SQLiteDatabase, url: URL, projectID: String) throws {
        let sql = Self.upsert(into: "transcripts", columns: Self.transcriptColumns)
        try ingest(db, url: url) { [self] line, offset in
            guard let record = try? decoder.decode(RunTranscriptStore.Record.self, from: line) else { return }
            let payload = Self.classify(record.message.content)
            try db.run(sql, [
                // The message's own id. A record is written once, so the same id
                // arriving twice is the same record — which is what makes a
                // replay rewrite rows instead of adding them.
                .text(record.message.id.uuidString),
                .text(projectID),
                .text(record.executionID),
                .text(record.role),
                .text(record.agentID),
                .text(Self.sender(of: record.message).rawValue),
                .text(payload.kind.rawValue),
                .of(payload.toolName),
                .of(record.recordedAt),
                .text(DayKey.string(for: record.recordedAt)),
                // Where the line starts in its file: a stable tiebreak for
                // records sharing a timestamp, and the offset to seek to when
                // someone wants the payload the index deliberately left behind.
                .int(Int64(offset)),
                .int(Int64(line.count)),
                .of(payload.text)
            ])
        }
    }

    /// Reads whatever `url` has gained since it was last consumed, hands each
    /// line and its byte offset to `handle`, and advances the marker — all in one
    /// transaction, so a failure part-way leaves the rows and the marker agreeing.
    ///
    /// Returns whether there was anything to read, which is what tells a caller
    /// its rows may have moved.
    @discardableResult
    private func ingest(_ db: SQLiteDatabase, url: URL, handle: (Data, UInt64) throws -> Void) throws -> Bool {
        guard let size = Self.fileSize(url) else { return false }
        let path = url.path(percentEncoded: false)
        let consumed = try db.query("SELECT bytes_consumed FROM sources WHERE path = ?1",
                                    [.text(path)]) { UInt64($0.int(0)) }.first ?? 0
        guard size > consumed else { return false }
        try db.transaction {
            let newOffset = try JSONLTail.read(url: url, from: consumed, handle)
            try db.run("""
                INSERT INTO sources (path, bytes_consumed) VALUES (?1, ?2)
                ON CONFLICT(path) DO UPDATE SET bytes_consumed = excluded.bytes_consumed
                """, [.text(path), .int(Int64(newOffset))])
        }
        return true
    }

    /// True when any source file is now smaller than the part of it already
    /// indexed — the one situation an incremental catch-up cannot repair.
    private func anySourceShrank(_ db: SQLiteDatabase) throws -> Bool {
        let markers = try db.query("SELECT path, bytes_consumed FROM sources") {
            ($0.text(0), UInt64($0.int(1)))
        }
        return markers.contains { path, consumed in
            guard let size = Self.fileSize(URL(fileURLWithPath: path)) else { return true }
            return size < consumed
        }
    }

    /// Every project that has produced a measured run. Its per-project logs —
    /// turn spans and run transcripts — are found from here rather than from
    /// anything the app told the index, which is what keeps "rebuildable from
    /// the logs alone" true.
    private func indexedProjects(_ db: SQLiteDatabase) throws -> [(projectID: String, project: KiteloopProject)] {
        try db.query("SELECT DISTINCT project_id, project_path FROM runs") { row in
            (row.text(0), KiteloopProject(rootURL: URL(fileURLWithPath: row.text(1))))
        }
    }

    private func jsonlFiles(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: directory.path(percentEncoded: false)
        )) ?? []
        return names.sorted().filter { $0.hasSuffix(".jsonl") }.map { directory.appending(path: $0) }
    }

    private func subdirectories(of directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        return contents.filter(\.hasDirectoryPath).sorted { $0.path < $1.path }
    }

    // MARK: - Schema

    private func open() throws -> SQLiteDatabase {
        if let database { return database }
        do {
            return try openPrepared()
        } catch {
            // A database this index cannot open is not a failure to report, it
            // is a file to throw away — holding nothing the logs don't is the
            // whole point. The case that reaches here: someone deleted
            // `metrics.sqlite3` to force a rebuild while a connection was still
            // open on it, which leaves the `-wal` and `-shm` behind. The next
            // connection then inherits a torn database — a fresh empty main file
            // against sidecars describing the old one — and every statement
            // against it fails with a disk I/O error.
            indexLog.error("metric index could not be opened, discarding it and replaying the logs: \(String(describing: error), privacy: .public)")
            discard()
            return try openPrepared()
        }
    }

    private func openPrepared() throws -> SQLiteDatabase {
        let db = try SQLiteDatabase(url: sources.databaseURL)
        // A file written by a different schema is dropped, not migrated. That is
        // the deal this index is built on: it holds nothing the logs don't.
        if db.userVersion != Self.schemaVersion {
            for table in Self.tables {
                try db.execute("DROP TABLE IF EXISTS \(table)")
            }
        }
        try db.execute(Self.schemaSQL)
        // A stamp that does not land leaves the file reading `0`, which is a
        // stale schema — so the tables above would be dropped and replayed on
        // every open from here on. Throwing sends that through `open()`'s
        // log-and-discard path instead of letting it pass for a healthy rebuild.
        try db.setUserVersion(Self.schemaVersion)
        database = db
        return db
    }

    /// Removes the database *and its WAL sidecars*. Deleting the main file alone
    /// is what leaves a torn database behind, so recovery has to take all three.
    private func discard() {
        database = nil
        let path = sources.databaseURL.path(percentEncoded: false)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    /// The database, caught up. Every query goes through here so a caller never
    /// reads an index that is a few appends behind the log.
    private func refreshed() throws -> SQLiteDatabase {
        do {
            try refresh()
        } catch {
            // A read is still answerable from what is already indexed, and
            // failing it because the catch-up stumbled would make the index a
            // liability rather than a projection.
            indexLog.error("metric index refresh failed: \(String(describing: error), privacy: .public)")
        }
        return try open()
    }

    private static let schemaSQL = """
    CREATE TABLE IF NOT EXISTS runs (
        id TEXT PRIMARY KEY,
        project_path TEXT NOT NULL,
        project_id TEXT NOT NULL,
        project_name TEXT NOT NULL,
        item_id TEXT NOT NULL,
        title TEXT NOT NULL,
        epic TEXT,
        declared_size TEXT,
        started_at REAL NOT NULL,
        completed_at REAL NOT NULL,
        day TEXT NOT NULL,
        duration_seconds REAL NOT NULL,
        cost_usd REAL NOT NULL,
        derived_cost_usd REAL,
        price_version TEXT,
        predicted_cost_usd REAL,
        prediction_source TEXT,
        reviewer_retries INTEGER NOT NULL,
        tool_errors INTEGER,
        outcome TEXT NOT NULL,
        worker_agent TEXT,
        reviewer_agent TEXT,
        execution_id TEXT,
        quality_score REAL,
        judge_dimensions TEXT,
        judge_unavailable_reason TEXT,
        merged INTEGER,
        changed_file_count INTEGER,
        produced_work INTEGER NOT NULL,
        model TEXT,
        input_tokens INTEGER,
        output_tokens INTEGER,
        cache_creation_tokens INTEGER,
        cache_read_tokens INTEGER,
        opening_context TEXT,
        over_item_cap INTEGER
    );
    CREATE INDEX IF NOT EXISTS runs_project_completed ON runs(project_id, completed_at DESC);
    CREATE INDEX IF NOT EXISTS runs_project_size ON runs(project_id, declared_size);
    CREATE INDEX IF NOT EXISTS runs_project_item ON runs(project_id, item_id);

    CREATE TABLE IF NOT EXISTS turns (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        execution_id TEXT,
        agent_id TEXT NOT NULL,
        session_id TEXT NOT NULL,
        role TEXT,
        started_at REAL NOT NULL,
        ended_at REAL,
        day TEXT NOT NULL,
        duration_seconds REAL,
        model TEXT,
        cost_usd REAL,
        derived_cost_usd REAL,
        price_version TEXT,
        input_tokens INTEGER,
        output_tokens INTEGER,
        cache_creation_tokens INTEGER,
        cache_read_tokens INTEGER
    );
    CREATE INDEX IF NOT EXISTS turns_project_execution ON turns(project_id, execution_id);
    CREATE INDEX IF NOT EXISTS turns_project_role ON turns(project_id, role);

    CREATE TABLE IF NOT EXISTS approvals (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        project_path TEXT NOT NULL,
        project_name TEXT NOT NULL,
        item_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        at REAL NOT NULL,
        approved_at REAL,
        to_status TEXT
    );
    CREATE INDEX IF NOT EXISTS approvals_project_item ON approvals(project_id, item_id, at);

    CREATE TABLE IF NOT EXISTS merges (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        project_path TEXT NOT NULL,
        project_name TEXT NOT NULL,
        item_id TEXT NOT NULL,
        merged INTEGER NOT NULL,
        at REAL NOT NULL,
        execution_id TEXT,
        reason TEXT
    );
    CREATE INDEX IF NOT EXISTS merges_project_item ON merges(project_id, item_id, at);

    CREATE TABLE IF NOT EXISTS transcripts (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        execution_id TEXT NOT NULL,
        role TEXT NOT NULL,
        agent_id TEXT NOT NULL,
        sender TEXT NOT NULL,
        kind TEXT NOT NULL,
        tool_name TEXT,
        recorded_at REAL NOT NULL,
        day TEXT NOT NULL,
        byte_offset INTEGER NOT NULL,
        byte_count INTEGER NOT NULL,
        text TEXT
    );
    CREATE INDEX IF NOT EXISTS transcripts_execution
        ON transcripts(project_id, execution_id, recorded_at, byte_offset);
    CREATE INDEX IF NOT EXISTS transcripts_role_kind
        ON transcripts(project_id, role, sender, kind, recorded_at);

    CREATE TABLE IF NOT EXISTS sources (
        path TEXT PRIMARY KEY,
        bytes_consumed INTEGER NOT NULL
    );
    """

    /// Every table the index owns, in the order they are dropped and replayed.
    /// `sources` is one of them on purpose: the byte markers describe rows that
    /// no longer exist once the others are emptied.
    private static let tables = ["runs", "turns", "approvals", "merges", "transcripts", "sources"]

    private static let runColumns = [
        "id", "project_path", "project_id", "project_name", "item_id", "title", "epic",
        "declared_size", "started_at", "completed_at", "day", "duration_seconds",
        "cost_usd", "derived_cost_usd", "price_version", "predicted_cost_usd",
        "prediction_source", "reviewer_retries", "tool_errors", "outcome",
        "worker_agent", "reviewer_agent", "execution_id", "quality_score",
        "judge_dimensions", "judge_unavailable_reason", "merged", "changed_file_count",
        "produced_work", "model", "input_tokens", "output_tokens",
        "cache_creation_tokens", "cache_read_tokens", "opening_context",
        "over_item_cap"
    ]

    private static let turnColumns = [
        "id", "project_id", "execution_id", "agent_id", "session_id", "role",
        "started_at", "ended_at", "day", "duration_seconds", "model",
        "cost_usd", "derived_cost_usd", "price_version",
        "input_tokens", "output_tokens", "cache_creation_tokens", "cache_read_tokens"
    ]

    private static let approvalColumns = [
        "id", "project_id", "project_path", "project_name", "item_id",
        "kind", "at", "approved_at", "to_status"
    ]

    private static let mergeColumns = [
        "id", "project_id", "project_path", "project_name", "item_id",
        "merged", "at", "execution_id", "reason"
    ]

    private static let transcriptColumns = [
        "id", "project_id", "execution_id", "role", "agent_id", "sender", "kind",
        "tool_name", "recorded_at", "day", "byte_offset", "byte_count", "text"
    ]

    /// The columns `decodeTranscriptEntry` reads, in its order — a subset of the
    /// stored ones, since `day` and `byte_offset` exist to be queried on rather
    /// than to be handed back.
    private static let transcriptQueryColumns = """
    id, project_id, execution_id, role, agent_id, sender, kind, tool_name, \
    recorded_at, text, byte_count
    """

    /// `INSERT … ON CONFLICT(id) DO UPDATE` — what makes replaying a log
    /// idempotent. The same line seen twice rewrites its row instead of adding
    /// one, because the record's own id is the primary key.
    private static func upsert(into table: String, columns: [String]) -> String {
        let placeholders = (1...columns.count).map { "?\($0)" }.joined(separator: ", ")
        let assignments = columns.dropFirst()
            .map { "\($0) = excluded.\($0)" }
            .joined(separator: ", ")
        return """
        INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(placeholders))
        ON CONFLICT(id) DO UPDATE SET \(assignments)
        """
    }

    private func bindings(for record: TaskMetricRecord) -> [SQLiteValue] {
        let judgeDimensions = record.judgeDimensions
            .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            .flatMap { String(data: $0, encoding: .utf8) }
        // Stored as the record's own JSON rather than a column per role: the
        // roles are a workflow's node names, not a fixed set, and a schema that
        // has to change when a graph gains a node is a schema that goes stale.
        let openingContext = record.openingContext
            .flatMap { try? JSONEncoder().encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) }
        return [
            .text(record.id),
            .text(record.projectPath),
            .text(KiteloopProject.canonicalPath(record.projectPath)),
            .text(record.projectName),
            .text(record.itemID),
            .text(record.title),
            .of(record.epic),
            .of(record.declaredSize),
            .of(record.startedAt),
            .of(record.completedAt),
            .text(DayKey.string(for: record.completedAt)),
            .double(record.durationSeconds),
            .double(record.costUSD),
            .of(record.derivedCostUSD),
            .of(record.priceVersion),
            .of(record.predictedCostUSD),
            .of(record.predictionSource),
            .int(Int64(record.reviewerRetries)),
            .of(record.toolErrors),
            .text(record.outcome),
            .of(record.workerAgent),
            .of(record.reviewerAgent),
            .of(record.executionID),
            .of(record.qualityScore),
            .of(judgeDimensions),
            .of(record.judgeUnavailableReason),
            .of(record.merged),
            .of(record.changedFileCount),
            // Derived at ingest so `WHERE produced_work = 1` is a query rather
            // than a scan through `outcome` strings.
            .int(record.producedWork ? 1 : 0),
            .of(record.model),
            .of(record.inputTokens),
            .of(record.outputTokens),
            .of(record.cacheCreationTokens),
            .of(record.cacheReadTokens),
            .of(openingContext),
            .of(record.overItemCap)
        ]
    }

    /// Rebuilds a record from its row. The column order is `runColumns`.
    private static func decodeRun(_ row: SQLiteDatabase.Row) -> TaskMetricRecord {
        var record = TaskMetricRecord(
            id: row.text(0),
            projectPath: row.text(1),
            projectName: row.text(3),
            itemID: row.text(4),
            title: row.text(5),
            epic: row.optText(6),
            declaredSize: row.optText(7),
            startedAt: row.date(8),
            completedAt: row.date(9),
            durationSeconds: row.double(11),
            costUSD: row.double(12),
            reviewerRetries: row.int(17),
            outcome: row.text(19),
            workerAgent: row.optText(20),
            reviewerAgent: row.optText(21),
            executionID: row.optText(22)
        )
        record.derivedCostUSD = row.optDouble(13)
        record.priceVersion = row.optText(14)
        record.predictedCostUSD = row.optDouble(15)
        record.predictionSource = row.optText(16)
        record.toolErrors = row.optInt(18)
        record.qualityScore = row.optDouble(23)
        record.judgeDimensions = row.optText(24)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Double] }
        record.judgeUnavailableReason = row.optText(25)
        record.merged = row.optBool(26)
        record.changedFileCount = row.optInt(27)
        record.model = row.optText(29)
        record.inputTokens = row.optInt(30)
        record.outputTokens = row.optInt(31)
        record.cacheCreationTokens = row.optInt(32)
        record.cacheReadTokens = row.optInt(33)
        record.openingContext = row.optText(34)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String: OpeningContext].self, from: $0) }
        record.overItemCap = row.optBool(35)
        return record
    }

    /// What a transcript record is, in the two or three facts worth a column.
    ///
    /// `text` is filled for the two kinds a diagnostic query reads — an agent's
    /// message and an error — and left NULL for everything else. Thinking, tool
    /// input and tool output are the bulk of the bytes and are not what anyone
    /// filters on; they stay in the log, which the row's byte offset points at.
    private static func classify(
        _ content: Message.Content
    ) -> (kind: TranscriptEntry.Kind, toolName: String?, text: String?) {
        switch content {
        case .text(let text): (.text, nil, text)
        case .thinking: (.thinking, nil, nil)
        case .toolCall(let call): (.toolCall, call.name, nil)
        case .toolResult: (.toolResult, nil, nil)
        case .approval(let request): (.approval, request.tool, nil)
        case .mcpAuthRequest: (.mcpAuthRequest, nil, nil)
        case .image: (.image, nil, nil)
        case .error(let text): (.error, nil, text)
        default: classifyChatNotice(content)
        }
    }

    /// The kinds Kiteloop itself posts into the chat, split off `classify`. A
    /// plan card is the agent's plan, so it is filed as its text.
    private static func classifyChatNotice(
        _ content: Message.Content
    ) -> (kind: TranscriptEntry.Kind, toolName: String?, text: String?) {
        switch content {
        case .plan(let plan): (.text, nil, plan.text)
        default: (.systemEvent, nil, nil)
        }
    }

    /// Who produced the record. The distinction the transcript queries turn on:
    /// the prompt that opened a run is in the same file as the answer to it, and
    /// "the worker said nothing" is a statement about the answers only.
    private static func sender(of message: Message) -> TranscriptEntry.Sender {
        switch message.sender {
        case .human: .human
        case .agent: .agent
        case .system: .system
        }
    }

    private static func decodeTranscriptEntry(_ row: SQLiteDatabase.Row) -> TranscriptEntry {
        TranscriptEntry(
            id: row.text(0),
            projectID: row.text(1),
            executionID: row.text(2),
            role: row.text(3),
            agentID: row.text(4),
            sender: TranscriptEntry.Sender(rawValue: row.text(5)) ?? .system,
            kind: TranscriptEntry.Kind(rawValue: row.text(6)) ?? .text,
            toolName: row.optText(7),
            recordedAt: row.date(8),
            text: row.optText(9),
            byteCount: row.int(10)
        )
    }

    // MARK: - Query helpers

    /// The grouped value, with NULL and empty folded into one visible bucket.
    /// Built from `MetricGrouping.column`, which is a closed enum — no caller
    /// string reaches the SQL.
    private static func keyExpression(for grouping: MetricGrouping) -> String {
        guard let column = grouping.column else { return "'\(MetricGrouping.total.rawValue)'" }
        return "COALESCE(NULLIF(\(column), ''), '\(MetricGrouping.unknownKey)')"
    }

    /// Nil when not one of the four counters was recorded across the group — the
    /// distinction the whole of `TokenUsage` is built to preserve.
    private static func usage(_ row: SQLiteDatabase.Row, firstColumn: Int32) -> TokenUsage? {
        let columns = (0..<4).map { firstColumn + Int32($0) }
        guard columns.contains(where: { !row.isNull($0) }) else { return nil }
        return TokenUsage(
            inputTokens: row.optInt(columns[0]) ?? 0,
            outputTokens: row.optInt(columns[1]) ?? 0,
            cacheCreationTokens: row.optInt(columns[2]) ?? 0,
            cacheReadTokens: row.optInt(columns[3]) ?? 0
        )
    }

    private static let sizeOrder = ["XS", "S", "M", "L", "XL"]

    /// Sorted for reading rather than by whatever order SQLite grouped in: sizes
    /// smallest first, days newest first, everything else biggest group first.
    private static func ordered<T>(_ groups: [T], by grouping: MetricGrouping,
                                   key: (T) -> String, weight: (T) -> Double) -> [T] {
        switch grouping {
        case .size:
            return groups.sorted {
                let lhs = sizeOrder.firstIndex(of: key($0).uppercased()) ?? sizeOrder.count
                let rhs = sizeOrder.firstIndex(of: key($1).uppercased()) ?? sizeOrder.count
                return lhs == rhs ? key($0) < key($1) : lhs < rhs
            }
        case .day:
            return groups.sorted { key($0) > key($1) }
        default:
            return groups.sorted {
                weight($0) == weight($1) ? key($0) < key($1) : weight($0) > weight($1)
            }
        }
    }

    private static func fileSize(_ url: URL) -> UInt64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return (attributes?[.size] as? NSNumber)?.uint64Value
    }
}

/// Reads whole JSONL lines from a byte offset in bounded chunks.
///
/// The point of the chunking is that neither a refresh nor a rebuild ever holds
/// the history in memory — a 300 MB log is ingested through a 64 KB window. It
/// also stops at the last complete line, so a read that races an append resumes
/// at the partial line rather than dropping it.
enum JSONLTail {
    static let chunkSize = 64 * 1024

    /// Hands each complete line after `offset` to `handle`, along with the byte
    /// offset the line starts at, and returns the offset just past the last one
    /// consumed. The offset is what lets an ingester record where a record came
    /// from — a stable ordinal within the file, and the place to seek to for
    /// whatever the index chose not to store.
    static func read(url: URL, from offset: UInt64, _ handle: (Data, UInt64) throws -> Void) throws -> UInt64 {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        try file.seek(toOffset: offset)

        var consumed = offset
        var buffer = Data()
        while let chunk = try file.read(upToCount: chunkSize), !chunk.isEmpty {
            buffer.append(chunk)
            var lineStart = buffer.startIndex
            while let newline = buffer[lineStart...].firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[lineStart..<newline]
                if !line.isEmpty {
                    try handle(Data(line), consumed + UInt64(lineStart - buffer.startIndex))
                }
                lineStart = newline + 1
            }
            consumed += UInt64(lineStart - buffer.startIndex)
            buffer = Data(buffer[lineStart...])
        }
        return consumed
    }
}
