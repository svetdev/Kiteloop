import Foundation
import os.log

private let runRecordLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "run-records")

/// One control-API run, written down so it outlives the process that started it.
///
/// The control server tracks runs in memory, which is the right lifetime for the
/// live view — the workflow, the agents and the cost meter all die with the app.
/// It was the wrong lifetime for the *answer*: a driver keys everything on the
/// `runId` it was handed, and after a restart that id returned 404 for work that
/// had merged, or was sitting at its approval gate with the item still there in
/// the backlog file. This is the durable half — enough to answer "how did run X
/// end?" long after nothing is left to ask.
package struct PersistedRunRecord: Codable, Sendable, Equatable, Identifiable {

    /// How a run ended, once it has. The four the autopilot reports, plus
    /// `interrupted`, which nothing reports because whatever would have reported
    /// it is what went away.
    package enum Outcome: String, Codable, Sendable, CaseIterable {
        case done
        case awaitingApproval = "awaiting_approval"
        /// The run changed no files because the worker checked the item's
        /// premise against the tree and refuted it — a measurement, not an
        /// attempt that failed. The item is at the approval gate carrying the
        /// report, like `awaitingApproval`, but a driver counting its night
        /// must be able to tell an item that was built from one that was
        /// found not to need building (2026-09-03: four functions asserted,
        /// one qualified; the run that measured and refused scored 0.55 as a
        /// diff that added no tests).
        case investigation
        case blocked
        case cancelled
        /// A pickup gate refused the item before any work began — it spent
        /// nothing and reached no ending of its own. Distinct from `blocked`,
        /// which is a run that reached the item and could not finish it: a
        /// refusal that never started is not a run that got stuck.
        case didNotRun = "did_not_run"
        /// The app stopped while this run was still live. Not an outcome the run
        /// reached — a statement that it never reached one.
        case interrupted
    }

    package var id: String { runId }
    package let runId: String
    /// The canonical project path (`KiteloopProject.id`). Kept rather than the
    /// folder name so a record stays addressable after its project is closed —
    /// the name a listing shows is derived from it.
    package let projectID: String
    package let itemID: String
    package let title: String
    package let startedAt: Date

    /// The workflow execution this run turned out to be, filled in when the run
    /// closes. For a control-API run it is the `runId` itself; for one the
    /// scheduler opened, the `runId` is a minted `auto-…` and this is the only
    /// thing that ties the record to what the run left behind — transcripts are
    /// filed under `.kiteloop/transcripts/<executionID>/` and `GET /v1/metrics`
    /// reports the execution id as its own `runId`. Without it an unattended
    /// night's records could not be joined to either after a restart.
    ///
    /// Optional, and a new key: lines already in `control-runs.jsonl` predate it
    /// and must still decode. Nil also for a run that never got an execution —
    /// a start the pickup gates refused — because naming the minted id as one
    /// would point at a transcript that isn't there.
    package var executionID: String?

    /// Nil while the run is open. A record still open when it is read back at
    /// launch belongs to a process that is gone, and `load` closes it as
    /// `interrupted` — that is the whole reason an opening line is written at all.
    package var endedAt: Date?
    package var outcome: Outcome?
    package var durationSec: Int?
    /// The backlog item's status as the run closed. A fallback only: when the
    /// project is open the live status is the truer answer and is preferred.
    package var itemStatus: String?
    package var reason: String?
    package var branch: String?
    package var pullRequestURL: String?
    package var costUSD: Double?
    package var costCapUSD: Double?
    package var predictionSource: String?
    package var qualityScore: Double?
    package var judgeDimensions: [String: Double]?
    package var judgeUnavailable: String?
    /// `automatic` when the run cleared the item's approval gate itself, because
    /// the project has `approveReviewPassedRuns` on and the reviewer passed.
    /// Absent otherwise — including for every item a person approved, which
    /// happens after this record closes. Optional and a new key, like
    /// `executionID`: lines already in `control-runs.jsonl` predate it and must
    /// still decode. It is what tells a night's `done` runs that nobody looked
    /// at from the ones somebody accepted.
    package var approval: String?

    /// Whether the run's own merge landed the branch, and the commit it
    /// became. `false` is a merge that was attempted and refused; nil is no
    /// merge attempted by this run — a gate waiting for a person, a project
    /// that never merges, or a record written before the field existed. A
    /// merge a person triggers at the gate happens after this record closes
    /// and is not written here. It is what lets a night's `done` runs be told
    /// apart from the ones whose work is still on a branch.
    package var merged: Bool?
    package var mergeCommit: String?

    /// What the item's own `verify:` answered when the app ran it at the gate
    /// before the reviewer: the exit status (`0` and only `0` is a pass, a
    /// negative status a command that never returned one), the command as it was
    /// run, and the last lines it printed.
    ///
    /// Flat rather than a nested verdict type because `RunVerifyVerdict` lives
    /// app-side and this record is in the package. All three or none, mirroring
    /// the live readout: a `verifyCommand` with no status would say a verify was
    /// taken without saying how it went.
    ///
    /// Optional and new keys, like `executionID`: lines already in
    /// `control-runs.jsonl` predate them and must still decode. Nil there, and on
    /// a run no verdict was taken for — which is not a verify that passed, and is
    /// the whole reason the status is absent rather than zero.
    package var verifyExitStatus: Int32?
    package var verifyCommand: String?
    package var verifyOutputTail: String?

    /// The other two facts the verdict carries, kept for the same reason as the
    /// three above: whether the deadline is what ended the command rather than
    /// the command answering, and the directory it ran in.
    ///
    /// `verifyTimedOut` is what makes a negative `verifyExitStatus` readable — a
    /// killed command and one that could never be spawned both return no status,
    /// and only the first judged nothing because it ran out of clock.
    /// `verifyDirectory` is what says a verify passed in the wrong tree.
    ///
    /// Newer than the three, so they are nil on a record that kept a verdict
    /// before these two existed as well as on one that kept no verdict at all —
    /// which is why the readout emits them beside the three rather than gating
    /// the three on them.
    package var verifyTimedOut: Bool?
    package var verifyDirectory: String?

    package var isFinished: Bool { outcome != nil }

    /// The folder name, for a listing — derived, so it can't drift from the path.
    package var projectName: String { URL(fileURLWithPath: projectID).lastPathComponent }

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(runId: String, projectID: String, itemID: String, title: String, startedAt: Date, executionID: String? = nil, endedAt: Date? = nil, outcome: Outcome? = nil, durationSec: Int? = nil, itemStatus: String? = nil, reason: String? = nil, branch: String? = nil, pullRequestURL: String? = nil, costUSD: Double? = nil, costCapUSD: Double? = nil, predictionSource: String? = nil, qualityScore: Double? = nil, judgeDimensions: [String: Double]? = nil, judgeUnavailable: String? = nil, approval: String? = nil, merged: Bool? = nil, mergeCommit: String? = nil, verifyExitStatus: Int32? = nil, verifyCommand: String? = nil, verifyOutputTail: String? = nil, verifyTimedOut: Bool? = nil, verifyDirectory: String? = nil) {
        self.runId = runId
        self.projectID = projectID
        self.itemID = itemID
        self.title = title
        self.startedAt = startedAt
        self.executionID = executionID
        self.endedAt = endedAt
        self.outcome = outcome
        self.durationSec = durationSec
        self.itemStatus = itemStatus
        self.reason = reason
        self.branch = branch
        self.pullRequestURL = pullRequestURL
        self.costUSD = costUSD
        self.costCapUSD = costCapUSD
        self.predictionSource = predictionSource
        self.qualityScore = qualityScore
        self.judgeDimensions = judgeDimensions
        self.judgeUnavailable = judgeUnavailable
        self.approval = approval
        self.merged = merged
        self.mergeCommit = mergeCommit
        self.verifyExitStatus = verifyExitStatus
        self.verifyCommand = verifyCommand
        self.verifyOutputTail = verifyOutputTail
        self.verifyTimedOut = verifyTimedOut
        self.verifyDirectory = verifyDirectory
    }
}

/// Append-only store of control-API run records, JSONL-backed at
/// `~/.kiteloop/control-runs.jsonl` — the same shape and write pattern as
/// `GroomingLedger` and `TaskMetricStore`, and global for the same reason: a run
/// carries its own project, and the app has one control server.
///
/// A run is written twice: an opening line when it starts, and a closing line
/// when the control server finalizes it. The file is therefore not one line per
/// run — **the last line for a `runId` wins**, and `load` collapses the file to
/// one record each. That is also what makes an interruption visible: a `runId`
/// whose last line is still open was live when the app stopped.
@MainActor
package final class RunRecordStore {

    /// The app-wide store. Injectable for tests via `init(url:)`, like the other
    /// single-writer file logs.
    package static let shared = RunRecordStore()

    /// Oldest first, one entry per run.
    package private(set) var records: [PersistedRunRecord] = []
    /// Lines no record could be made of, held so `rewrite()` can put them back.
    /// `appendLine` writes through a `FileHandle` with no atomicity, so the app
    /// being killed mid-append leaves a truncated last line — which is exactly the
    /// run whose ending someone came back to ask about. Verbatim where the line is
    /// text at all; a line the kill cut through a multi-byte character comes back
    /// with replacement characters where those bytes were, since text is the only
    /// thing this can hold and put back.
    private var undecodableLines: [String] = []
    /// How many lines could not be read at load. Logged as well, but exposed so a
    /// caller — and a test — can see it without reading os_log.
    package private(set) var undecodableLineCount = 0
    /// How many writes did not reach the file. The read side has reported its
    /// losses since it was written; the write side used to swallow every error, so
    /// a `~/.kiteloop` that had stopped being writable left each run in `records`
    /// and nothing on disk — and the next launch answered 404 for work that had
    /// merged, which is the failure this store exists to end. Counted as well as
    /// logged, for the same reason as `undecodableLineCount`: a caller can see it
    /// without reading os_log.
    package private(set) var failedWriteCount = 0
    private var index: [String: Int] = [:]
    private let url: URL
    private let clock: () -> Date
    private let reporter: StoreProblemReporter

    /// How much history survives, so launch cost stays flat. Both bounds apply:
    /// a busy portfolio hits the count first, an idle one the age. Runs are far
    /// rarer than grooming records — a few dozen a night at most — so 500 is
    /// months of history in a file that is read once per launch.
    package static let retentionLimit = 500
    package static let retentionAge: TimeInterval = 30 * 24 * 60 * 60

    /// How this store names itself to a human, in a notification title. Spelled
    /// once because it is half `StoreProblemReporter`'s dedup key: a store that
    /// spelled itself two ways would file two rows for the one problem.
    package static let storeName = "Run history"

    /// `clock` is for tests only, so the bounds can be exercised without waiting a
    /// month. It is read on every write as well as at load, because Kiteloop is
    /// normally left running for weeks: a clock frozen at launch would put the age
    /// bound back where it was, applied once per process.
    package init(url: URL? = nil,
                 clock: @escaping () -> Date = { Date() },
                 reporter: StoreProblemReporter = .shared) {
        self.url = url ?? Self.defaultURL
        self.clock = clock
        self.reporter = reporter
        loadFromDisk()
    }

    /// Reads the file into `records`, or reports that it could not be read.
    ///
    /// A history the process cannot open at all is the one genuine read failure
    /// here — a bad line costs its own line and nothing else — and it is the most
    /// expensive one the store has: every finished run 404s and an unattended
    /// night reads as an install that has never run anything. So it goes where
    /// the write half's losses already go, the inbox the human is watching,
    /// rather than to an os_log line nobody opens. The file stays exactly as it
    /// is: nothing was read, so there is nothing to compact, and the store
    /// answers as empty until something is written.
    private func loadFromDisk() {
        let loaded: (records: [PersistedRunRecord], undecodable: [String], needsRewrite: Bool)
        do {
            loaded = try Self.load(from: url, now: clock())
        } catch {
            runRecordLog.error("Failed to read the run record file: \(error.localizedDescription, privacy: .public)")
            reporter.report(store: Self.storeName, operation: .read, url: url, error: error)
            return
        }
        records = loaded.records
        undecodableLines = loaded.undecodable
        undecodableLineCount = loaded.undecodable.count
        reindex()
        // The file always holds at least two lines per run, so a launch that read
        // anything at all has something to compact. Doing it here — once, over at
        // most `retentionLimit` records — is what keeps the next launch cheap.
        if loaded.needsRewrite { rewrite() }
    }

    private static var defaultURL: URL {
        let dir = KiteloopHome.url
            .appendingPathComponent(".kiteloop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("control-runs.jsonl")
    }

    // MARK: - Write

    /// Records a run, or replaces what was recorded for it.
    ///
    /// A record identical to the one already held writes nothing: the control
    /// server re-derives a closing record on every request while the run still
    /// owns its autopilot (the quality judge attaches its score seconds after the
    /// item lands), and appending an unchanged line per request would turn a poll
    /// loop into a file writer.
    package func upsert(_ record: PersistedRunRecord) {
        if let position = index[record.runId] {
            guard records[position] != record else { return }
            records[position] = record
        } else {
            records.append(record)
            index[record.runId] = records.count - 1
        }
        // Both bounds, on every write. The age bound used to be applied only by
        // `load`, which an always-running app reaches once — so an install left up
        // for weeks kept serving records months past `retentionAge`.
        if trimToRetention() {
            // Something was dropped, so the appended line alone would leave the
            // file disagreeing with `records`: write the whole thing instead.
            rewrite()
        } else {
            appendLine(record)
        }
    }

    /// Drops whatever falls outside either bound, keeping memory and the file in
    /// step. Returns whether anything went.
    private func trimToRetention() -> Bool {
        let kept = Self.withinBounds(records, now: clock())
        guard kept.count != records.count else { return false }
        records = kept
        reindex()
        return true
    }

    // MARK: - Read

    package func record(runId: String) -> PersistedRunRecord? {
        index[runId].map { records[$0] }
    }

    /// Newest first — the order `GET /v1/runs` lists in.
    package var newestFirst: [PersistedRunRecord] {
        records.sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: - File

    private func reindex() {
        index = Dictionary(uniqueKeysWithValues: records.enumerated().map { ($1.runId, $0) })
    }

    /// Appends one record's line.
    ///
    /// Through `AtomicFileWriter.append`, which starts a new line first when the
    /// file doesn't end in one — without that, a run recorded after a kill
    /// mid-append is glued onto the truncated remnant and ends up with no record
    /// at all, since `load` only heals a glued line on a launch that happens to
    /// ask for a rewrite, which a file of already-closed, already-collapsed runs
    /// does not.
    ///
    /// A write that fails is counted and named — whether `encode` refused the
    /// record outright or the file write itself threw. The record stays in
    /// `records`, so the live view is unaffected and the run answers for as long
    /// as this process lives — but it is not on disk, and nothing else will
    /// notice: the next write for that run is an append of its own, not a retry
    /// of this one.
    private func appendLine(_ record: PersistedRunRecord) {
        guard let line = Self.encode(record) else {
            failedWriteCount += 1
            return
        }
        do {
            try AtomicFileWriter.append(Data(line.utf8), to: url)
        } catch {
            failedWriteCount += 1
            runRecordLog.error("Failed to write run record \(record.runId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            reporter.report(store: Self.storeName, operation: .write, url: url, error: error)
        }
    }

    /// Rewrites the file from `records` — at launch, and after a trim.
    ///
    /// The lines nobody could decode go back at the end, verbatim. Compaction is
    /// what would otherwise erase them, on the same launch that failed to read
    /// them: the same choice `BacklogSerializer` makes for a section's
    /// `unparsedLines`, and for the same reason — an unreadable line is still
    /// somebody's history, and deleting it is the one thing that can't be undone.
    /// The trailing newline is added rather than preserved, so the next append
    /// starts on a line of its own.
    ///
    /// Through `AtomicFileWriter` rather than `Data.write(options: .atomic)`,
    /// which renames a temp file into place without ever flushing it: on a panic
    /// the rename can reach disk while the contents are still in the page cache,
    /// and what survives is a zero-length run history. That is not a rare path
    /// here — `load` asks for a rewrite at essentially every launch, since a run
    /// writes an opening and a closing line and the file is collapsed on read.
    /// Counted and named when it fails, like an append — and it is the more
    /// expensive loss of the two, since a rewrite that doesn't land leaves the
    /// whole file disagreeing with `records` rather than one run missing from it.
    /// The write is whole-file, so there is no single `runId` to name; the count of
    /// records that didn't land stands in for one. A record `encode` refused is
    /// named separately and counted the same way — it never reaches the body at
    /// all, so it would otherwise vanish from the file with nothing to show for it.
    private func rewrite() {
        var encodeFailures = 0
        let body = records.compactMap { record -> String? in
            guard let line = Self.encode(record) else {
                encodeFailures += 1
                return nil
            }
            return line
        }.joined() + undecodableLines.map { $0 + "\n" }.joined()
        if encodeFailures > 0 {
            failedWriteCount += encodeFailures
            runRecordLog.error("\(encodeFailures, privacy: .public) run record(s) could not be encoded and were dropped from the rewrite")
        }
        do {
            try AtomicFileWriter.write(Data(body.utf8), to: url)
        } catch {
            failedWriteCount += 1
            runRecordLog.error("Failed to rewrite the run record file holding \(self.records.count, privacy: .public) record(s): \(error.localizedDescription, privacy: .public)")
            reporter.report(store: Self.storeName, operation: .write, url: url, error: error)
        }
    }

    /// A copy of `record` with every non-finite Double field replaced by `nil`,
    /// each drop logged with the run it happened to and the field it happened in.
    /// `JSONEncoder`'s default strategy throws on NaN and infinity, which used to
    /// cost the whole record — a bad score should cost the field, not the run.
    private static func sanitized(_ record: PersistedRunRecord) -> PersistedRunRecord {
        var record = record
        if let value = record.costUSD, !value.isFinite {
            runRecordLog.error("Run record \(record.runId, privacy: .public) had a non-finite costUSD — dropping it")
            record.costUSD = nil
        }
        if let value = record.costCapUSD, !value.isFinite {
            runRecordLog.error("Run record \(record.runId, privacy: .public) had a non-finite costCapUSD — dropping it")
            record.costCapUSD = nil
        }
        if let value = record.qualityScore, !value.isFinite {
            runRecordLog.error("Run record \(record.runId, privacy: .public) had a non-finite qualityScore — dropping it")
            record.qualityScore = nil
        }
        if let dimensions = record.judgeDimensions, dimensions.values.contains(where: { !$0.isFinite }) {
            runRecordLog.error("Run record \(record.runId, privacy: .public) had a non-finite judgeDimensions value — dropping it")
            record.judgeDimensions = nil
        }
        return record
    }

    /// The encoder both write paths go through. Sanitises non-finite Doubles
    /// first, so a bad score never reaches `JSONEncoder` — its default strategy
    /// throws on NaN and infinity, and used to erase the record whole. Still
    /// returns `nil` for anything else that fails to encode, so a caller can tell
    /// the two apart from `failedWriteCount` alone: sanitised writes reach disk
    /// and don't count against it.
    private static func encode(_ record: PersistedRunRecord) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(sanitized(record)),
              let line = String(data: data, encoding: .utf8) else {
            runRecordLog.error("Failed to encode run record \(record.runId, privacy: .public)")
            return nil
        }
        return line + "\n"
    }

    /// What one line of the file turned out to be.
    private enum DecodedLine {
        case record(PersistedRunRecord)
        /// A line no record could be made of, as text it can be held as.
        case unreadable(String)
    }

    /// Reads one line's bytes on their own.
    ///
    /// On their own is the point: the file used to be decoded as a single string,
    /// so one truncated multi-byte character — a kill part-way through appending a
    /// title or a reason carrying an em dash — made the whole read fail and the
    /// store came up empty, every finished run 404ing for the sake of one broken
    /// line. Bytes that are not valid UTF-8 now join the lines the JSON decoder
    /// refuses, and are held lossily: the bad bytes come back as replacement
    /// characters, which is honest about a line that was never a record and is the
    /// only way to hold it as the text `rewrite` puts back.
    private static func decodeLine(_ line: Data, using decoder: JSONDecoder) -> DecodedLine {
        guard let text = String(data: line, encoding: .utf8) else {
            return .unreadable(String(decoding: line, as: UTF8.self))
        }
        guard let record = try? decoder.decode(PersistedRunRecord.self, from: line) else {
            return .unreadable(text)
        }
        return .record(record)
    }

    /// Collapses the file to one record per run, closes anything left open as
    /// `interrupted`, and applies both retention bounds. A line that doesn't
    /// decode costs neither the records around it nor itself: it is set aside,
    /// counted, and handed back so the caller can write it out again.
    ///
    /// Throws only when the file is there and cannot be read — the caller reports
    /// that. A file that is simply absent is not a failure: a fresh install has no
    /// history, and there is nothing to say about it.
    private static func load(from url: URL, now: Date) throws
        -> (records: [PersistedRunRecord], undecodable: [String], needsRewrite: Bool) {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return ([], [], false)
        }
        let collapsed = collapse(try Data(contentsOf: url))

        var loaded = collapsed.records
        var interrupted = 0
        for position in loaded.indices where !loaded[position].isFinished {
            // No end time and no duration: the app died without measuring either,
            // and inventing them here would put a number on a run nobody watched
            // finish.
            loaded[position].outcome = .interrupted
            interrupted += 1
        }
        if interrupted > 0 {
            runRecordLog.info("\(interrupted, privacy: .public) run record(s) were still open at launch — reporting them as interrupted")
        }
        if !collapsed.undecodable.isEmpty {
            runRecordLog.error("\(collapsed.undecodable.count, privacy: .public) line(s) in the run record file could not be read — keeping them")
        }

        let kept = withinBounds(loaded, now: now)
        // Whether the undecodable lines are there says nothing about whether the
        // file needs rewriting: they are already in it, and a rewrite puts them
        // back exactly where they were.
        return (kept, collapsed.undecodable, interrupted > 0 || kept.count != collapsed.lines)
    }

    /// The file's bytes, split on the newline byte and collapsed to one record per
    /// run — the last line for a `runId` wins — with the lines nobody could read
    /// held to one side. `lines` counts the records read, not the lines: it is what
    /// says the file holds more than the records do and so wants compacting.
    ///
    /// Split on bytes rather than on a string of the whole file, because a string
    /// of the whole file is all-or-nothing: one truncated multi-byte character
    /// cost every record behind it.
    private static func collapse(_ content: Data)
        -> (records: [PersistedRunRecord], undecodable: [String], lines: Int) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var order: [String] = []
        var byRun: [String: PersistedRunRecord] = [:]
        var undecodable: [String] = []
        var lines = 0
        for line in content.split(separator: UInt8(ascii: "\n")) {
            switch decodeLine(line, using: decoder) {
            case .unreadable(let text):
                undecodable.append(text)
            case .record(let record):
                lines += 1
                if byRun[record.runId] == nil { order.append(record.runId) }
                byRun[record.runId] = record
            }
        }
        return (order.compactMap { byRun[$0] }, undecodable, lines)
    }

    /// Both retention bounds, in one place so the load path and the write path
    /// cannot come to disagree about what "kept" means. A record outside both is
    /// dropped once — the age filter runs first, and the count is taken of what
    /// survives it.
    private static func withinBounds(_ records: [PersistedRunRecord], now: Date) -> [PersistedRunRecord] {
        let cutoff = now.addingTimeInterval(-retentionAge)
        return Array(records.filter { $0.startedAt >= cutoff }.suffix(retentionLimit))
    }
}
